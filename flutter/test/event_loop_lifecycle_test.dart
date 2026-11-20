import 'dart:async';
import 'package:flutter_hbb/utils/event_loop.dart';
import 'package:flutter_test/flutter_test.dart';

class Event extends BaseEvent<int, int> {
  final Future<dynamic> Function(int) callback;
  Event(this.callback) : super(0, 0);
  @override
  EventCallback<int>? findCallback(int type) => callback;
}

class Loop extends BaseEventLoop<int, int> {}

void main() {
  testWidgets('closed loop cannot resume after a pending callback',
      (tester) async {
    final loop = Loop();
    final pending = Completer<void>();
    var consumed = 0;
    await loop.onReady();
    loop.pushEvent(Event((_) => pending.future));
    await tester.pump(const Duration(milliseconds: 100));
    await loop.close();
    loop.pushEvent(Event((_) async {
      consumed++;
    }));
    pending.complete();
    await tester.pump(const Duration(seconds: 1));
    expect(consumed, 0);
  });
  testWidgets('new lifecycle consumes only its own events and owns one timer',
      (tester) async {
    final loop = Loop();
    final old = Completer<void>();
    var consumed = 0;
    await loop.onReady();
    loop.pushEvent(Event((_) => old.future));
    await tester.pump(const Duration(milliseconds: 100));
    await loop.close();
    await loop.onReady();
    loop.pushEvent(Event((_) async {
      consumed++;
    }));
    old.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(consumed, 1);
    await loop.close();
    await tester.pump(const Duration(seconds: 1));
  });
}
