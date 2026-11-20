import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/rental_validity.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/direct_connection_state.dart';

void main() {
  integratedModelTests();
  test('transport and authentication failures have distinct labels', () {
    final state = DirectConnectionState();
    state.transportFailed();
    expect(state.label, 'rd-direct-unreachable');
    state.manualRetry();
    expect(state.phase, DirectConnectionPhase.connecting);
    state.authenticationFailed();
    expect(state.label, 'rd-direct-auth-failed');
  });
  test('authenticated disconnect remains disconnected until explicit retry',
      () {
    final state = DirectConnectionState();
    state.authenticated();
    state.transportFailed();
    expect(state.label, 'rd-direct-disconnected');
    expect(state.generation, 2);
    state.manualRetry();
    expect(state.phase, DirectConnectionPhase.connecting);
    expect(state.generation, 3);
    state.transportFailed();
    expect(state.phase, DirectConnectionPhase.disconnected);
    state.manualRetry();
    state.authenticated();
    expect(state.phase, DirectConnectionPhase.connected);
  });
}

class _Binding extends Fake implements RustdeskImpl {
  int reconnects = 0;
  int recentLoads = 0;
  int rememberQueries = 0;
  @override
  Future<void> mainLoadRecentPeers({dynamic hint}) async {
    recentLoads++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #sessionGetAuditServerSync:
        return '';
      case #isSupportMultiUiSession:
        return false;
      case #peerGetSessionsCount:
        return 1;
      case #mainGetLocalOption:
        return 'N';
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

  Completer<bool?>? rememberResult;
  @override
  Future<void> sessionReconnect(
      {required UuidValue sessionId,
      required bool forceRelay,
      dynamic hint}) async {
    expect(forceRelay, isFalse);
    reconnects++;
  }

  @override
  Future<bool?> sessionGetRemember(
          {required UuidValue sessionId, dynamic hint}) =>
      _getRemember();
  Future<bool?> _getRemember() {
    rememberQueries++;
    return rememberResult?.future ?? Future.value(false);
  }

  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;
}

class _Dialogs extends OverlayDialogManager {
  int shown = 0;
  int loading = 0;
  DialogBuilder? builder;
  @override
  void dismissAll() {}
  @override
  Future<T?> show<T>(DialogBuilder builder,
      {bool clickMaskDismiss = false,
      bool backDismiss = false,
      String? tag,
      bool useAnimation = true,
      bool forceGlobal = false}) async {
    shown++;
    this.builder = builder;
    return null;
  }

  @override
  String showLoading(String text,
      {bool clickMaskDismiss = false,
      bool showCancel = true,
      VoidCallback? onCancel,
      String? tag}) {
    loading++;
    return 'test-loading';
  }
}

class _Input extends Fake implements InputModel {
  @override
  bool setRelativeMouseMode(bool enabled) => false;
  @override
  Future<void> updateKeyboardMode() async {}
}

class _Image extends Fake implements ui.Image {
  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
  }
}

class _Images extends Fake implements ImageModel {
  @override
  ui.Image? image = _Image();
  @override
  void clearForValidityDenial() {
    image?.dispose();
    image = null;
  }
}

class _Chat extends Fake implements ChatModel {
  @override
  final voiceCallStatus = VoiceCallStatus.notStarted.obs;
}

class _Session extends Fake implements FFI {
  @override
  final connType = ConnType.portForward;
  @override
  final chatModel = _Chat();
  @override
  final id = 'example.com:21118';
  @override
  final sessionId = UuidValue('00000000-0000-4000-8000-000000000042');
  @override
  final closed = false;
  @override
  final _Dialogs dialogManager = _Dialogs();
  @override
  final inputModel = _Input();
  @override
  final imageModel = _Images();
  @override
  late final ffiModel = FfiModel(WeakReference(this));
}

void integratedModelTests() {
  testWidgets(
      'first validity rejection never queries or overwrites credentials',
      (tester) async {
    final binding = _Binding();
    platformFFI.setBindingForTesting(binding);
    final session = _Session();
    session.ffiModel.handleMsgBox({
      'type': 'rd-direct-validity-error',
      'title': 'rd-direct-out-of-validity',
      'text': '',
      'link': '',
      'hasRetry': 'true',
    }, session.sessionId, session.id);
    await tester.pump(const Duration(minutes: 5));
    expect(binding.rememberQueries, 0);
    expect(binding.reconnects, 0);
    expect(binding.recentLoads, 1);
    expect(session.dialogManager.shown, 1);
    expect(session.ffiModel.directConnectionState.label,
        'rd-direct-out-of-validity');
    // Any native login/storage call is an unimplemented Fake method and fails.
    session.ffiModel.clear();
  });

  testWidgets(
      'server denial blocks stale frames and prompts until explicit retry and real success',
      (tester) async {
    final binding = _Binding()..rememberResult = Completer<bool?>();
    platformFFI.setBindingForTesting(binding);
    final session = _Session();
    final model = session.ffiModel;
    final retained = session.imageModel.image as _Image;
    model.directConnectionState.authenticated();
    model.handleMsgBox(
        {'type': 'rd-direct-auth-error', 'title': '', 'text': '', 'link': ''},
        session.sessionId,
        session.id);
    model.handleMsgBox({
      'type': 'rd-direct-validity-error',
      'title': 'rd-direct-out-of-validity',
      'text': '',
      'link': '',
      'hasRetry': 'true'
    }, session.sessionId, session.id);
    expect(retained.disposed, isTrue);
    expect(session.imageModel.image, isNull);
    expect(binding.recentLoads, 1);
    expect(model.rentalValidity.isOutsideValidity, isTrue);
    expect(model.rect, isNull);
    expect(model.rentalFramesBlocked, isTrue);
    expect(model.directConnectionState.label, 'rd-direct-out-of-validity');
    binding.rememberResult!.complete(false);
    for (final type in [
      'rd-direct-auth-error',
      'input-password',
      'error',
      'restarting',
      'rd-direct-transport-error'
    ]) {
      model.handleMsgBox({
        'type': type,
        'title': '',
        'text': '',
        'link': '',
        'hasRetry': 'true'
      }, session.sessionId, session.id);
    }
    await tester.pump(const Duration(minutes: 5));
    expect(binding.rememberQueries, 1);
    expect(binding.reconnects, 0);
    expect(session.dialogManager.shown, 1);
    final images = ImageModel(WeakReference<FFI>(session));
    final lateFrame = _Image();
    await images.update(lateFrame);
    expect(lateFrame.disposed, isTrue);
    expect(images.image, isNull);
    await model.handlePeerInfo({}, session.id, true);
    expect(model.rentalFramesBlocked, isTrue);
    model.reconnect(session.dialogManager, session.sessionId, false);
    expect(binding.reconnects, 1);
    expect(model.rentalFramesBlocked, isTrue);
    final duringRetry = _Image();
    await images.update(duringRetry);
    expect(duringRetry.disposed, isTrue);
    final event = <String, dynamic>{
      'version': '1.4.0',
      'username': '',
      'hostname': 'Mac',
      'platform': 'Mac OS',
      'current_display': '0',
      'platform_additions': '{"rental_valid_until_ms":"1893456000000"}'
    };
    await model.handlePeerInfo(event, session.id, false);
    expect(model.rentalFramesBlocked, isFalse);
    expect(model.directConnectionState.phase, DirectConnectionPhase.connected);
    expect(model.rentalValidity.status, RentalValidityStatus.valid);
    expect(model.rentalValidity.validUntilUtc, DateTime.utc(2030));
    expect(binding.recentLoads, 2);
    await model.handlePeerInfo(
        {...event, 'platform_additions': '{}'}, session.id, false);
    expect(model.rentalValidity.validUntilUtc, isNull);
    expect(model.rentalValidity.isOutsideValidity, isFalse);
    model.clear();
  });

  testWidgets(
      'actual FfiModel retains frame and never retries transport/restart events automatically',
      (tester) async {
    final binding = _Binding();
    platformFFI.setBindingForTesting(binding);
    final session = _Session();
    final model = session.ffiModel;
    final frame = session.imageModel.image;
    model.directConnectionState.authenticated();
    var staleWaitFired = false;
    model.waitForImageTimer =
        Timer(const Duration(seconds: 1), () => staleWaitFired = true);
    for (final type in [
      'rd-direct-transport-error',
      'error',
      'restarting',
      'restarting-show'
    ]) {
      model.handleMsgBox({
        'type': type,
        'title': 'Connection Error',
        'text': 'Timeout',
        'link': '',
        'hasRetry': 'true'
      }, session.sessionId, session.id);
      await tester.pump(const Duration(minutes: 5));
      expect(binding.reconnects, 0);
      expect(model.directConnectionState.phase,
          DirectConnectionPhase.disconnected);
      expect(identical(session.imageModel.image, frame), isTrue);
    }
    expect(staleWaitFired, isFalse);
    model.reconnect(session.dialogManager, session.sessionId, false);
    expect(binding.reconnects, 1);
    expect(session.dialogManager.loading, 1);
    expect(model.directConnectionState.phase, DirectConnectionPhase.connecting);
    await tester.pump(const Duration(minutes: 5));
    expect(binding.reconnects, 1);
    model.clear();
  });

  testWidgets(
      'preauth transport is unreachable; delayed auth dialog cannot replace disconnect',
      (tester) async {
    final binding = _Binding()..rememberResult = Completer<bool?>();
    platformFFI.setBindingForTesting(binding);
    final session = _Session();
    final model = session.ffiModel;
    model.handleMsgBox({
      'type': 'rd-direct-auth-error',
      'title': 'rd-direct-auth-failed',
      'text': '',
      'link': ''
    }, session.sessionId, session.id);
    expect(model.directConnectionState.phase,
        DirectConnectionPhase.authenticationFailed);
    model.handleMsgBox({
      'type': 'rd-direct-transport-error',
      'title': 'rd-direct-unreachable',
      'text': '',
      'link': ''
    }, session.sessionId, session.id);
    expect(
        model.directConnectionState.phase, DirectConnectionPhase.unreachable);
    expect(session.dialogManager.shown, 1);
    binding.rememberResult!.complete(false);
    await tester.pump();
    expect(session.dialogManager.shown, 1);
    expect(binding.reconnects, 0);
    model.clear();
  });
}
