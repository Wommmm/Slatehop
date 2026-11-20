import 'dart:async';
import 'package:flutter_hbb/models/file_session_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FileSessionLifecycle parent, children;
  late Map<int, FileSessionLifecycle> windows;
  setUp(() {
    windows = {};
    FileSessionLifecycle make(int id) => FileSessionLifecycle(
        windowId: () => id,
        invoke: (target, method, args) async =>
            windows[target]!.handle(method, args, id));
    parent = make(1);
    children = make(2);
    windows[1] = parent;
    windows[2] = children;
  });
  testWidgets(
      'parent stop closes only exact children; new generation cannot revive old child',
      (tester) async {
    final a = parent.activateParent('desktop-a', 1);
    final b = parent.activateParent('desktop-b', 1);
    final closed = <String>[];
    await children.attach(a, 'file-a', () async {
      closed.add('a');
    });
    await children.attach(b, 'file-b', () async {
      closed.add('b');
    });
    await parent.stopParent('desktop-a');
    final next = parent.activateParent('desktop-a', 2);
    expect(closed, ['a']);
    expect(
        await children.attach(a, 'stale-open', () async {
          closed.add('stale');
        }),
        false);
    expect(
        await children.attach(next, 'new-file', () async {
          closed.add('new');
        }),
        true);
    await children.handle(FileSessionLifecycle.revoke,
        {'parent': a.toJson(), 'child': 'new-file'}, 1);
    expect(closed, ['a', 'stale']);
    await parent.stopParent('desktop-a');
    expect(closed, ['a', 'stale', 'new']);
    for (final id in ['file-a', 'file-b', 'stale-open', 'new-file']) {
      await children.detach(id);
    }
  });
  test(
      'same-address replacement waits for native close, other addresses do not',
      () async {
    final nativeClose = Completer<void>();
    final closing =
        children.runFileClose('same-address', () => nativeClose.future);
    var opened = false;
    final replacement = children.waitForFileClose('same-address').then((_) {
      opened = true;
    });
    await children.waitForFileClose('other-address');
    expect(opened, false);
    nativeClose.complete();
    await closing;
    await replacement;
    expect(opened, true);
  });
  test('failed native close prevents replacement from joining its old channel',
      () async {
    final closing = children.runFileClose('same-address', () async {
      throw StateError('close failed');
    });
    await expectLater(closing, throwsStateError);
    await expectLater(
        children.waitForFileClose('same-address'), throwsStateError);
  });
  test('recreated model with the same UI UUID still gets a fresh owner epoch',
      () async {
    final first = parent.activateParent('desktop', 1);
    await parent.stopParent('desktop');
    final recreated = parent.activateParent('desktop', 1);
    expect(first.matches(recreated), false);
  });
  testWidgets('close before child registration denies native startup',
      (tester) async {
    final ref = parent.activateParent('desktop', 1);
    await parent.stopParent('desktop');
    var closed = 0;
    expect(
        await children.attach(ref, 'child', () async {
          closed++;
        }),
        false);
    expect(closed, 1);
    await children.detach('child');
  });
  testWidgets(
      'close while registration acknowledgement is delayed prevents startup',
      (tester) async {
    final ref = parent.activateParent('desktop', 1);
    final ack = Completer<void>();
    final child = FileSessionLifecycle(
        windowId: () => 3,
        invoke: (to, method, args) async {
          final result = await windows[to]!.handle(method, args, 3);
          if (method == FileSessionLifecycle.register) await ack.future;
          return result;
        });
    windows[3] = child;
    var closed = 0;
    final ready = child.attach(ref, 'child', () async {
      closed++;
    });
    await tester.pump();
    await parent.stopParent('desktop');
    ack.complete();
    expect(await ready, false);
    expect(closed, 1);
    await child.detach('child');
  });
  testWidgets('foreign sender cannot revoke or unregister another child',
      (tester) async {
    final ref = parent.activateParent('desktop', 1);
    var closed = 0;
    await children.attach(ref, 'child', () async {
      closed++;
    });
    final args = {'parent': ref.toJson(), 'child': 'child'};
    expect(await children.handle(FileSessionLifecycle.revoke, args, 9), false);
    expect(
        await parent.handle(FileSessionLifecycle.unregister, args, 9), false);
    await tester.pump(const Duration(seconds: 1));
    expect(closed, 0);
    await parent.stopParent('desktop');
    expect(closed, 1);
    await children.detach('child');
  });
  testWidgets('lost parent window is detected without a close notification',
      (tester) async {
    final ref = parent.activateParent('desktop', 1);
    var closed = 0;
    await children.attach(ref, 'child', () async {
      closed++;
    });
    windows.remove(1);
    await tester.pump(const Duration(seconds: 1));
    expect(closed, 1);
    await children.detach('child');
  });
  testWidgets(
      'disposed child ignores delayed register and never starts polling',
      (tester) async {
    final ref = parent.activateParent('desktop', 1);
    final ack = Completer<void>();
    final child = FileSessionLifecycle(
        windowId: () => 3,
        invoke: (to, method, args) async {
          final result = await windows[to]!.handle(method, args, 3);
          if (method == FileSessionLifecycle.register) await ack.future;
          return result;
        });
    windows[3] = child;
    var closed = 0;
    final ready = child.attach(ref, 'child', () async {
      closed++;
    });
    await tester.pump();
    await child.detach('child');
    ack.complete();
    expect(await ready, false);
    expect(closed, 1);
  });
}
