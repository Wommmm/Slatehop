import 'dart:async';

/// Non-secret UI ownership. Never derive this identity from an auth token or
/// peer address: a new desktop at the same address is a different owner.
class FileSessionParent {
  final int windowId;
  final String sessionId;
  final int generation;
  const FileSessionParent(this.windowId, this.sessionId, this.generation);

  Map<String, dynamic> toJson() => {
        'windowId': windowId,
        'sessionId': sessionId,
        'generation': generation,
      };

  static FileSessionParent? fromJson(dynamic value) {
    if (value is! Map ||
        value['windowId'] is! int ||
        value['sessionId'] is! String ||
        value['generation'] is! int ||
        (value['sessionId'] as String).isEmpty) {
      return null;
    }
    return FileSessionParent(
        value['windowId'], value['sessionId'], value['generation']);
  }

  bool matches(FileSessionParent? other) =>
      other != null &&
      windowId == other.windowId &&
      sessionId == other.sessionId &&
      generation == other.generation;
}

typedef FileSessionCall = Future<dynamic> Function(
    int windowId, String method, Map<String, dynamic> arguments);

class _FileParent {
  final FileSessionParent ref;
  final Map<String, int> children = {};
  final int lifecycleGeneration;
  _FileParent(this.ref, this.lifecycleGeneration);
}

class _FileChild {
  final FileSessionParent parent;
  final Future<void> Function() onStop;
  bool stopped = false;
  bool checking = false;
  Timer? timer;
  Future<void>? stopping;
  _FileChild(this.parent, this.onStop);
  Future<void> stop() {
    stopped = true;
    timer?.cancel();
    return stopping ??= onStop();
  }
}

/// Uses the existing window method channel. Child registration precedes native
/// startup, and revocation is permanent for that child even if its parent logs
/// in again. A liveness check also fails closed if the owner window disappears.
class FileSessionLifecycle {
  static const register = 'rd-file-parent-register';
  static const unregister = 'rd-file-parent-unregister';
  static const check = 'rd-file-parent-check';
  static const revoke = 'rd-file-parent-revoke';
  static bool handles(String method) =>
      [register, unregister, check, revoke].contains(method);
  final int Function() windowId;
  final FileSessionCall invoke;
  int _nextGeneration = 0;
  final Map<String, _FileParent> _parents = {};
  final Map<String, _FileChild> _children = {};
  final Map<String, Future<void>> _fileClosing = {};
  FileSessionLifecycle({required this.windowId, required this.invoke});

  /// RustDesk shares the native file channel by peer/type. A replacement must
  /// wait for the previous UI session to actually leave the native registry.
  Future<void> waitForFileClose(String peerId) async {
    final closing = _fileClosing[peerId];
    if (closing != null) await closing;
  }

  Future<void> runFileClose(String peerId, Future<void> Function() close) {
    final previous = _fileClosing[peerId];
    final operation = Future<void>.sync(close);
    final closing = previous == null
        ? operation
        : Future.wait([previous, operation]).then<void>((_) {});
    _fileClosing[peerId] = closing;
    closing.then((_) {
      if (identical(_fileClosing[peerId], closing)) {
        _fileClosing.remove(peerId);
      }
    }, onError: (Object _, StackTrace __) {
      // Keep a failed close as a barrier: a fresh window must not join a
      // native channel whose termination could not be confirmed.
    });
    return closing;
  }

  FileSessionParent activateParent(String sessionId, int generation) {
    final previous = _parents[sessionId];
    if (previous != null && previous.lifecycleGeneration == generation) {
      return previous.ref;
    }
    if (previous != null) unawaited(stopParent(sessionId));
    // Window-local epochs remain unique even when a model is recreated with
    // an existing UI session UUID and its local counter starts over.
    final ref = FileSessionParent(windowId(), sessionId, ++_nextGeneration);
    _parents[sessionId] = _FileParent(ref, generation);
    return ref;
  }

  FileSessionParent? parentFor(String sessionId) => _parents[sessionId]?.ref;

  Future<void> stopParent(String sessionId) async {
    final parent = _parents.remove(sessionId);
    if (parent == null) return;
    await Future.wait(parent.children.entries.map((entry) async {
      try {
        await invoke(entry.value, revoke, {
          'parent': parent.ref.toJson(),
          'child': entry.key,
        }).timeout(const Duration(seconds: 3));
      } catch (_) {
        // The child's liveness check covers a lost notification/window exit.
      }
    }));
  }

  Future<bool> attach(FileSessionParent parent, String childId,
      Future<void> Function() onStop) async {
    final child = _FileChild(parent, onStop);
    _children[childId] = child;
    bool accepted = false;
    try {
      accepted = await invoke(parent.windowId, register, {
            'parent': parent.toJson(),
            'child': childId,
          }).timeout(const Duration(seconds: 3)) ==
          true;
    } catch (_) {}
    if (!accepted || child.stopped || !identical(_children[childId], child)) {
      await child.stop();
      return false;
    }
    child.timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (child.checking || child.stopped) return;
      child.checking = true;
      bool alive = false;
      try {
        alive = await invoke(parent.windowId, check, {
              'parent': parent.toJson(),
              'child': childId,
            }).timeout(const Duration(seconds: 3)) ==
            true;
      } catch (_) {}
      child.checking = false;
      if (!alive && identical(_children[childId], child)) await child.stop();
    });
    return true;
  }

  Future<void> detach(String childId) async {
    final child = _children.remove(childId);
    if (child == null) return;
    child.stopped = true;
    child.timer?.cancel();
    try {
      await invoke(child.parent.windowId, unregister, {
        'parent': child.parent.toJson(),
        'child': childId,
      }).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<dynamic> handle(
      String method, dynamic arguments, int fromWindowId) async {
    if (arguments is! Map) return false;
    final ref = FileSessionParent.fromJson(arguments['parent']);
    final childId = arguments['child'];
    if (ref == null || childId is! String || childId.isEmpty) return false;
    if (method == revoke) {
      final child = _children[childId];
      if (child == null ||
          fromWindowId != child.parent.windowId ||
          !child.parent.matches(ref)) {
        return false;
      }
      await child.stop();
      return true;
    }
    final parent = _parents[ref.sessionId];
    if (parent == null || !parent.ref.matches(ref)) return false;
    switch (method) {
      case register:
        final existing = parent.children[childId];
        if (existing != null && existing != fromWindowId) return false;
        parent.children[childId] = fromWindowId;
        return true;
      case check:
        return parent.children[childId] == fromWindowId;
      case unregister:
        if (parent.children[childId] != fromWindowId) return false;
        parent.children.remove(childId);
        return true;
      default:
        return false;
    }
  }
}
