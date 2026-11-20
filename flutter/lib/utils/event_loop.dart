import 'dart:async';

import 'package:flutter/foundation.dart';

typedef EventCallback<Data> = Future<dynamic> Function(Data data);

abstract class BaseEvent<EventType, Data> {
  EventType type;
  Data data;

  /// Constructor.
  BaseEvent(this.type, this.data);

  /// Consume this event.
  @visibleForTesting
  Future<dynamic> consume() async {
    final cb = findCallback(type);
    if (cb == null) {
      return null;
    } else {
      return cb(data);
    }
  }

  EventCallback<Data>? findCallback(EventType type);
}

abstract class BaseEventLoop<EventType, Data> {
  final List<BaseEvent<EventType, Data>> _evts = [];
  Timer? _timer;
  int _generation = 0;
  bool _closed = false;

  List<BaseEvent<EventType, Data>> get evts => _evts;

  Future<void> onReady() async {
    _timer?.cancel();
    _closed = false;
    final generation = ++_generation;
    _timer = Timer.periodic(const Duration(milliseconds: 100),
        (timer) => _handleTimer(timer, generation));
  }

  /// An Event is about to be consumed.
  Future<void> onPreConsume(BaseEvent<EventType, Data> evt) async {}

  /// An Event was consumed.
  Future<void> onPostConsume(BaseEvent<EventType, Data> evt) async {}

  /// Events are all handled and cleared.
  Future<void> onEventsClear() async {}

  /// Events start to consume.
  Future<void> onEventsStartConsuming() async {}

  Future<void> _handleTimer(Timer timer, int generation) async {
    bool current() => !_closed && generation == _generation;
    if (!current() || _evts.isEmpty) return;
    timer.cancel();
    _timer = null;
    try {
      await onEventsStartConsuming();
      if (!current()) return;
      while (_evts.isNotEmpty) {
        final evt = _evts.removeAt(0);
        await onPreConsume(evt);
        if (!current()) return;
        await evt.consume();
        if (!current()) return;
        await onPostConsume(evt);
        if (!current()) return;
      }
      await onEventsClear();
    } finally {
      if (current()) {
        _timer = Timer.periodic(const Duration(milliseconds: 100),
            (timer) => _handleTimer(timer, generation));
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _evts.clear();
  }

  void pushEvent(BaseEvent<EventType, Data> evt) {
    if (!_closed) _evts.add(evt);
  }

  void clear() {
    _evts.clear();
  }
}
