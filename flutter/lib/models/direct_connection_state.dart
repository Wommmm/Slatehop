enum DirectConnectionPhase {
  connecting,
  connected,
  unreachable,
  authenticationFailed,
  outOfValidity,
  disconnected
}

/// State follows native login and transport events, never image arrival.
/// This flow deliberately owns no retry timer; retry is a user action.
class DirectConnectionState {
  DirectConnectionPhase phase = DirectConnectionPhase.connecting;
  bool _wasAuthenticated = false;
  int generation = 0;
  // A denied reconnect must not expose a retained frame or let late images
  // dismiss the denial. Only a new authenticated peer_info lifts this latch.
  bool blockFramesUntilAuthenticated = false;

  void outsideValidity() {
    generation++;
    _wasAuthenticated = false;
    blockFramesUntilAuthenticated = true;
    phase = DirectConnectionPhase.outOfValidity;
  }

  void authenticated() {
    generation++;
    _wasAuthenticated = true;
    blockFramesUntilAuthenticated = false;
    phase = DirectConnectionPhase.connected;
  }

  void authenticationFailed() {
    generation++;
    phase = DirectConnectionPhase.authenticationFailed;
  }

  void transportFailed() {
    if (phase == DirectConnectionPhase.outOfValidity) return;
    generation++;
    phase = _wasAuthenticated
        ? DirectConnectionPhase.disconnected
        : DirectConnectionPhase.unreachable;
  }

  void manualRetry() {
    generation++;
    phase = DirectConnectionPhase.connecting;
  }

  String get label => switch (phase) {
        DirectConnectionPhase.connecting => 'Connecting...',
        DirectConnectionPhase.connected => 'Connected',
        DirectConnectionPhase.unreachable => 'rd-direct-unreachable',
        DirectConnectionPhase.authenticationFailed => 'rd-direct-auth-failed',
        DirectConnectionPhase.disconnected => 'rd-direct-disconnected',
        DirectConnectionPhase.outOfValidity => 'rd-direct-out-of-validity',
      };
}
