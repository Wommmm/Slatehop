import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/models/file_session_lifecycle.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class Binding extends Fake implements RustdeskImpl {
  bool disableClipboard = false;
  Completer<String>? touchOption;
  int overrideReplies = 0;
  final closedSessions = <UuidValue>[];
  @override
  Future<void> sessionClose(
      {required UuidValue sessionId, dynamic hint}) async {
    closedSessions.add(sessionId);
  }

  @override
  Future<String> sessionGetOption(
          {required UuidValue sessionId, required String arg, dynamic hint}) =>
      touchOption!.future;
  @override
  Future<void> sessionSetConfirmOverrideFile(
      {required UuidValue sessionId,
      required int actId,
      required int fileNum,
      required bool needOverride,
      required bool remember,
      required bool isUpload,
      dynamic hint}) async {
    overrideReplies++;
  }

  int reconnects = 0;
  int nextJob = 0;
  int localReads = 0;
  int localDirectoryReads = 0;
  Completer<String>? homeDirectory;
  @override
  Future<String> mainGetHomeDir({dynamic hint}) async {
    localReads++;
    return homeDirectory == null ? '/local' : await homeDirectory!.future;
  }

  @override
  Future<String> sessionGetPeerOption(
          {required UuidValue sessionId,
          required String name,
          dynamic hint}) async =>
      '';
  @override
  Future<String> sessionReadLocalDirSync(
      {required UuidValue sessionId,
      required String path,
      required bool showHidden,
      dynamic hint}) async {
    localDirectoryReads++;
    return '{"id":0,"path":"/local","entries":[]}';
  }

  @override
  Future<void> sessionReconnect(
      {required UuidValue sessionId,
      required bool forceRelay,
      dynamic hint}) async {
    reconnects++;
  }

  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;
  @override
  Future<void> mainLoadRecentPeers({dynamic hint}) async {}
  @override
  Future<void> sessionReadRemoteDir(
      {required UuidValue sessionId,
      required String path,
      required bool includeHidden,
      dynamic hint}) async {}
  @override
  String mainGetCommonSync({required String key, dynamic hint}) =>
      '${++nextJob}';
  @override
  bool sessionGetToggleOptionSync(
          {required UuidValue sessionId, required String arg, dynamic hint}) =>
      disableClipboard;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #versionToNumber:
        return 1004000;
      case #isDisableAccount:
        return true;
      case #sessionGetAuditServerSync:
        return '';
      case #isSupportMultiUiSession:
        return false;
      case #peerGetSessionsCount:
        return 1;
      case #mainGetLocalOption:
        return touchOption == null ? 'N' : '';
      case #mainGetInputSource:
        return 'Input source 1';
      case #sessionGetKeyboardMode:
        return Future<String?>.value('map');
      case #sessionIsKeyboardModeSupported:
        return true;
      case #sessionGetUseAllMyDisplaysForTheRemoteSession:
        return '';
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

class Dialogs extends OverlayDialogManager {
  Completer<bool?>? overwrite;
  int dismissals = 0;
  int shown = 0;
  @override
  void dismissAll() {
    dismissals++;
  }

  @override
  Future<T?> show<T>(DialogBuilder builder,
      {bool clickMaskDismiss = false,
      bool backDismiss = false,
      String? tag,
      bool useAnimation = true,
      bool forceGlobal = false}) async {
    shown++;
    return overwrite == null ? null : (await overwrite!.future) as T?;
  }

  @override
  String showLoading(String text,
          {bool clickMaskDismiss = false,
          bool showCancel = true,
          VoidCallback? onCancel,
          String? tag}) =>
      'test';
}

class Input extends Fake implements InputModel {
  @override
  bool setRelativeMouseMode(bool enabled) => false;
  @override
  Future<void> updateKeyboardMode() async {}
}

class Chat extends Fake implements ChatModel {
  @override
  final voiceCallStatus = VoiceCallStatus.notStarted.obs;
}

class Elevation extends Fake implements ElevationModel {
  @override
  void onPeerInfo(PeerInfo pi) {}
}

class Session extends Fake implements FFI {
  @override
  final elevationModel = Elevation();
  @override
  final inputModel = Input();
  @override
  final Dialogs dialogManager = Dialogs();
  @override
  final chatModel = Chat();
  @override
  late final fileModel = FileModel(WeakReference(this));
  @override
  final id = 'example.com:21118';
  @override
  final sessionId = UuidValue('00000000-0000-4000-8000-000000000052');
  @override
  bool closed = false;
  @override
  ConnType connType = ConnType.defaultConn;
  @override
  late final ffiModel = FfiModel(WeakReference(this));
}

// Exercise the real common authenticated peer_info path, without unrelated
// display/canvas initialization. All connection types share this lifecycle.
Future<void> authenticate(Session session, {bool cached = false}) async {
  final previousType = session.connType;
  session.connType = ConnType.portForward;
  await session.ffiModel.handlePeerInfo({
    'version': '1.4.0',
    'username': '',
    'hostname': 'Mac',
    'platform': 'Mac OS',
    'current_display': '0',
    'platform_additions': '{}'
  }, session.id, cached);
  session.connType = previousType;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final writes = <String>[];
  late Binding binding;
  setUp(() {
    writes.clear();
    binding = Binding();
    platformFFI.setBindingForTesting(binding);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        writes.add(call.arguments['text'] as String);
      }
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  test(
      'real desktop peer_info establishes an owner and reconnect replaces its generation',
      () async {
    final session = Session();
    final oldWindow = stateGlobal.windowId;
    stateGlobal.setWindowId(7);
    final evt = <String, dynamic>{
      'version': '1.4.0',
      'username': '',
      'hostname': 'Mac',
      'platform': 'Mac OS',
      'current_display': '0',
      'platform_additions': '{}',
      'displays': '[]',
      'features': '{}',
      'resolutions': '[]'
    };
    try {
      expect(session.ffiModel.fileSessionParent, isNull);
      await session.ffiModel.handlePeerInfo(evt, session.id, false);
      final first = session.ffiModel.fileSessionParent!;
      expect(first.windowId, 7);
      expect(first.sessionId, session.sessionId.toString());
      session.ffiModel
          .reconnect(session.dialogManager, session.sessionId, false);
      expect(session.ffiModel.fileSessionParent, isNull);
      await session.ffiModel.handlePeerInfo(evt, session.id, true);
      expect(session.ffiModel.fileSessionParent, isNull);
      await session.ffiModel.handlePeerInfo(evt, session.id, false);
      final next = session.ffiModel.fileSessionParent!;
      expect(next.matches(first), false);
      session.ffiModel.stopDailyOperations();
      expect(session.ffiModel.fileSessionParent, isNull);
    } finally {
      session.ffiModel.clear();
      stateGlobal.setWindowId(oldWindow);
    }
  });
  testWidgets(
      'parent revocation calls native close and old file cannot reconnect',
      (tester) async {
    final session = Session()..connType = ConnType.fileTransfer;
    final model = session.ffiModel;
    final windows = <int, FileSessionLifecycle>{};
    FileSessionLifecycle make(int id) => FileSessionLifecycle(
        windowId: () => id,
        invoke: (target, method, args) =>
            windows[target]!.handle(method, args, id));
    final parent = make(1), child = make(2);
    windows[1] = parent;
    windows[2] = child;
    final ref = parent.activateParent('desktop-parent-uuid', 1);
    session.fileModel.jobController.addTransferJob(
        Entry()
          ..name = 'pending'
          ..path = '/pending'
          ..size = 100,
        true);
    await child.attach(
        ref, session.sessionId.toString(), model.stopFileSessionForParent);
    await parent.stopParent('desktop-parent-uuid');
    expect(binding.closedSessions, [session.sessionId]);
    expect(session.closed, true);
    expect(session.fileModel.jobController.jobTable.single.display(),
        'rd-file-connection-dropped');
    parent.activateParent('desktop-parent-uuid', 2);
    model.reconnect(session.dialogManager, session.sessionId, false);
    await authenticate(session);
    final shown = session.dialogManager.shown;
    await model.startEventListener(session.sessionId, session.id)({
      'name': 'msgbox',
      'type': 'input-password',
      'title': 'Password Required',
      'text': '',
      'link': ''
    });
    expect(binding.reconnects, 0);
    expect(binding.localReads, 0);
    expect(session.dialogManager.shown, shown);
    expect(binding.closedSessions, [session.sessionId]);
    await child.detach(session.sessionId.toString());
  });
  testWidgets(
      'clear during delayed peer_info cannot authenticate a reused model',
      (tester) async {
    final session = Session();
    binding.touchOption = Completer<String>();
    final ready = authenticate(session);
    session.ffiModel.clear();
    binding.touchOption!.complete('');
    await ready;
    await session.ffiModel.startEventListener(session.sessionId, session.id)(
        {'name': 'clipboard', 'content': 'late auth'});
    expect(writes, isEmpty);
  });
  testWidgets(
      'disconnect while home option is pending prevents later directory reads',
      (tester) async {
    final session = Session()..connType = ConnType.fileTransfer;
    binding.homeDirectory = Completer<String>();
    final ready = session.fileModel.onReady();
    await tester.pump();
    expect(binding.localReads, 1);
    session.ffiModel.stopDailyOperations();
    binding.homeDirectory!.complete('/local');
    await ready;
    await tester.pump(const Duration(seconds: 2));
    expect(binding.localDirectoryReads, 0);
  });
  testWidgets('late peer_info option cannot initialize files after disconnect',
      (tester) async {
    final session = Session()..connType = ConnType.fileTransfer;
    binding.touchOption = Completer<String>();
    final ready = session.ffiModel.handlePeerInfo({
      'version': '1.4.0',
      'username': '',
      'hostname': 'Mac',
      'platform': 'Mac OS',
      'current_display': '0',
      'platform_additions': '{}'
    }, session.id, false);
    session.ffiModel.stopDailyOperations();
    binding.touchOption!.complete('');
    await tester.pump(const Duration(seconds: 1));
    expect(binding.localReads, 0);
    await ready;
    await session.fileModel.evtLoop.close();
  });
  testWidgets(
      'pending overwrite after disconnect cannot confirm or restart polling',
      (tester) async {
    final session = Session()..connType = ConnType.fileTransfer;
    final model = session.fileModel;
    final id = model.jobController.addTransferJob(
        Entry()
          ..name = 'pending.txt'
          ..path = '/pending.txt'
          ..size = 100,
        true);
    model.jobController.registerTransferConflictBatch([id]);
    session.dialogManager.overwrite = Completer<bool?>();
    await model.evtLoop.onReady();
    model.postOverrideFileConfirm({
      'id': '$id',
      'file_num': '0',
      'is_upload': 'true',
      'read_path': '/pending.txt',
      'is_identical': 'false'
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(session.dialogManager.shown, 1);
    final before = session.dialogManager.dismissals;
    session.ffiModel.stopDailyOperations();
    session.dialogManager.overwrite!.complete(true);
    await tester.pump(const Duration(seconds: 1));
    expect(binding.overrideReplies, 0);
    expect(model.jobController.jobTable.single.state, JobState.error);
    expect(session.dialogManager.dismissals, greaterThan(before));
    // No close here: the widget binding must find no resurrected periodic timer.
  });
  testWidgets(
      'disconnect during file initialization prevents later directory dispatch',
      (tester) async {
    final session = Session()..connType = ConnType.fileTransfer;
    final ready = session.fileModel.onReady();
    session.ffiModel.stopDailyOperations();
    await tester.pump(const Duration(seconds: 1));
    expect(binding.localReads, 0);
    await ready;
    await session.fileModel.evtLoop.close();
  });
  test('unauthenticated clipboard events cannot change local text', () async {
    final session = Session();
    final onEvent =
        session.ffiModel.startEventListener(session.sessionId, session.id);
    await onEvent({'name': 'clipboard', 'content': 'private preauth text'});
    expect(writes, isEmpty);
  });
  test('closed session rejects a queued clipboard event', () async {
    final session = Session()..closed = true;
    await session.ffiModel.startEventListener(session.sessionId, session.id)(
        {'name': 'clipboard', 'content': 'late closed text'});
    expect(writes, isEmpty);
  });

  test(
      'authenticated text is exact, permissions/toggle disable delivery, disconnect requires new auth',
      () async {
    final session = Session();
    final model = session.ffiModel;
    final onEvent = model.startEventListener(session.sessionId, session.id);
    Future<void> receive(Object? text) async =>
        onEvent({'name': 'clipboard', 'content': text});
    await authenticate(session);
    const text = 'line 1\n中文 👋\tline 2';
    await receive(text);
    expect(writes, [text]);
    binding.disableClipboard = true;
    await receive('disabled');
    binding.disableClipboard = false;
    model.permissions['clipboard'] = false;
    await receive('permission denied');
    model.permissions['clipboard'] = true;
    await receive(null);
    await receive(12);
    expect(writes, [text]);
    await receive('');
    expect(writes, [text, '']);
    model.handleMsgBox({
      'type': 'rd-direct-transport-error',
      'title': 'Connection Error',
      'text': '',
      'link': ''
    }, session.sessionId, session.id);
    await receive('after network loss');
    await authenticate(session, cached: true);
    await receive('stale cache');
    model.reconnect(session.dialogManager, session.sessionId, false);
    await receive('retry before auth');
    expect(binding.reconnects, 1);
    expect(writes, [text, '']);
    await authenticate(session);
    await receive('renewed');
    expect(writes, [text, '', 'renewed']);
    session.closed = true;
    await receive('closed');
    expect(writes.length, 3);
    model.clear();
  });
  test(
      'network loss marks only unfinished file transfers failed and cancels pending navigation',
      () async {
    final session = Session()..connType = ConnType.fileTransfer;
    final jobs = session.fileModel.jobController;
    final finished = jobs.addTransferJob(
        Entry()
          ..name = 'done.txt'
          ..path = '/done.txt'
          ..size = 100,
        true);
    final pending = jobs.addTransferJob(
        Entry()
          ..name = 'pending.txt'
          ..path = '/pending.txt'
          ..size = 100,
        false);
    await jobs.jobDone({'id': '$finished', 'file_num': '0'});
    jobs.tryUpdateJobProgress({
      'id': '$pending',
      'file_num': '0',
      'speed': '10',
      'finished_size': '20'
    });
    final navigation =
        session.fileModel.fileFetcher.fetchDirectory('/pending', false, false);
    final navigationResult = expectLater(navigation, throwsA(anything));
    session.ffiModel.handleMsgBox({
      'type': 'rd-direct-transport-error',
      'title': 'Connection Error',
      'text': '',
      'link': ''
    }, session.sessionId, session.id);
    expect(jobs.jobTable.first.state, JobState.done);
    expect(jobs.jobTable.last.state, JobState.error);
    expect(jobs.jobTable.last.display(), 'rd-file-connection-dropped');
    expect(jobs.jobTable.last.finishedSize, 20);
    await navigationResult;
    await jobs.jobDone({'id': '$pending', 'file_num': '0'});
    expect(jobs.jobTable.last.display(), 'rd-file-connection-dropped');
    session.ffiModel.clear();
  });
}
