import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/desktop/widgets/personal_device_access.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _mount(
  WidgetTester tester,
  ValueNotifier<bool> active,
  Future<String> Function(Map<String, Object?>) request,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: PersonalDeviceAccess(
                active: active,
                chinese: false,
                request: request,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _reply(String mode, {String? password}) => jsonEncode({
      'ok': true,
      'mode': mode,
      'address': '192.0.2.18:21118',
      if (password != null) 'remotePassword': password,
    });

void main() {
  testWidgets('setup sends only the confirmed management password', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    final requests = <Map<String, Object?>>[];
    await _mount(tester, active, (request) async {
      requests.add(request);
      return _reply(request['op'] == 'status' ? 'unconfigured' : 'personal');
    });

    await tester.enterText(find.byType(TextField).at(0), 'fixture-manager');
    await tester.enterText(find.byType(TextField).at(1), 'different');
    await tester.tap(find.text('Save management password'));
    await tester.pump();
    expect(requests, hasLength(1));

    await tester.enterText(find.byType(TextField).at(1), 'fixture-manager');
    await tester.tap(find.text('Save management password'));
    await tester.pumpAndSettle();
    expect(requests, [
      {'op': 'status'},
      {'op': 'setup', 'managementPassword': 'fixture-manager'},
    ]);
    expect(find.text('fixture-manager'), findsNothing);
    expect(find.text('Authenticate to view password'), findsOneWidget);
  });

  testWidgets('set sends one custom password and keeps its result masked', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    final requests = <Map<String, Object?>>[];
    await _mount(tester, active, (request) async {
      requests.add(request);
      return _reply(
        'personal',
        password: request['op'] == 'set' ? 'fixture-new-remote' : null,
      );
    });
    await tester.tap(find.text('Change remote password'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), 'fixture-manager');
    await tester.enterText(find.byType(TextField).at(1), 'fixture-new-remote');
    await tester.enterText(find.byType(TextField).at(2), 'fixture-new-remote');
    await tester.tap(find.text('Save remote password'));
    await tester.pumpAndSettle();

    expect(requests, [
      {'op': 'status'},
      {
        'op': 'set',
        'managementPassword': 'fixture-manager',
        'remotePassword': 'fixture-new-remote',
      },
    ]);
    expect(find.text('fixture-new-remote'), findsNothing);
    await tester.tap(find.text('Show password'));
    await tester.pump();
    expect(find.text('fixture-new-remote'), findsOneWidget);
    active.value = false;
    await tester.pump();
    expect(find.text('fixture-new-remote'), findsNothing);
  });

  testWidgets('losing visibility discards an in-flight password result', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    final result = Completer<String>();
    await _mount(tester, active, (request) {
      if (request['op'] == 'show') return result.future;
      return Future.value(_reply('personal'));
    });
    await tester.enterText(find.byType(TextField), 'fixture-manager');
    await tester.tap(find.text('Authenticate to view password'));
    await tester.pump();
    active.value = false;
    active.value = true;
    result.complete(_reply('personal', password: 'late-secret'));
    await tester.pumpAndSettle();
    expect(find.text('Show password'), findsNothing);
    expect(find.text('late-secret'), findsNothing);
    expect(find.text('fixture-manager'), findsNothing);
  });

  testWidgets('clipboard copies only the requested address or revealed value',
      (tester) async {
    final active = ValueNotifier(true);
    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _mount(
        tester,
        active,
        (request) async => _reply('personal',
            password: request['op'] == 'show' ? 'fixture-remote' : null));

    await tester.tap(find.text('Copy address'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fixture-manager');
    await tester.tap(find.text('Authenticate to view password'));
    await tester.pumpAndSettle();
    expect(find.text('Copy password'), findsNothing);
    await tester.tap(find.text('Show password'));
    await tester.pump();
    await tester.tap(find.text('Copy password'));
    await tester.pumpAndSettle();
    expect(copied, ['192.0.2.18:21118', 'fixture-remote']);
  });

  testWidgets('managed mode hides credentials even in a malformed reply', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    await _mount(tester, active, (_) async {
      return _reply('managed', password: 'unexpected-secret');
    });
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Copy address'), findsNothing);
    expect(find.text('Show password'), findsNothing);
    expect(find.text('unexpected-secret'), findsNothing);
  });
}
