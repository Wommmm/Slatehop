import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/direct_endpoint.dart';
import 'package:flutter_hbb/desktop/widgets/direct_connection_form.dart';

void main() {
  test('normalizes concrete destinations to the native direct TCP syntax', () {
    final cases = {
      ' 192.168.1.20 ': '192.168.1.20:21118',
      '192.168.1.20:21118': '192.168.1.20:21118',
      'mini.Example.COM': 'mini.example.com:21118',
      'mini.example.com:443': 'mini.example.com:443',
      '::1': '[0:0:0:0:0:0:0:1]:21118',
      '[2001:db8::1]:21118': '[2001:db8:0:0:0:0:0:1]:21118',
    };
    for (final entry in cases.entries) {
      expect(DirectEndpoint.tryParse(entry.key)?.address, entry.value,
          reason: entry.key);
    }
  });
  test(
      'does not turn IDs, relay directives or malformed addresses into requests',
      () {
    for (final input in [
      '',
      '123456789',
      '123 456 789',
      '10.0.0.1/r',
      r'10.0.0.1\r',
      '10.0.0.1@server',
      'https://mini.example.com',
      'host.example:0',
      'host.example:65536',
      'host.example:',
      'host.example:-1',
      'host.example:abc',
      'a..example:21118',
      '-a.example:21118',
      '999.0.0.1',
      '10.0. 0.1',
      '10.0.0.1?relay=true',
      '[::1]:0',
      '[::1]junk',
      '[192.168.1.20]:21118',
      'mini.example/path'
    ]) {
      expect(DirectEndpoint.tryParse(input), isNull, reason: input);
    }
  });
  test(
      'recent endpoint display keeps the first record without changing storage',
      () {
    final recent = [
      {'id': '192.0.2.80:21118', 'name': 'newest'},
      {'id': '192.0.2.80', 'name': 'legacy'},
      {'id': '192.0.2.80:21119', 'name': 'other port'},
      {'id': 'MINI.example.com', 'name': 'domain'},
      {'id': 'mini.example.com:21118', 'name': 'same domain'},
      {'id': '123456789', 'name': 'account ID'},
      {'id': '::1', 'name': 'IPv6'},
      {'id': '[0:0:0:0:0:0:0:1]:21118', 'name': 'same IPv6'},
    ];
    final shown =
        DirectEndpoint.uniqueRecent(recent, (record) => record['id']!);
    expect(shown.map((record) => record['name']),
        ['newest', 'other port', 'domain', 'IPv6']);
    expect(identical(shown.first, recent.first), isTrue);
    expect(recent.length, 8); // No record or password migration/deletion.
  });
  testWidgets('requires address and password before invoking the session flow',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DirectConnectionForm(
      translate: (key) => key,
      onConnect: (_, __) async {
        calls++;
      },
    ))));
    await tester.tap(find.byKey(const ValueKey('direct-connect')));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('Invalid IP'), findsOneWidget);
    expect(find.text('Password Required'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('direct-address')), '123456789');
    await tester.enterText(
        find.byKey(const ValueKey('direct-password')), 'not-a-real-secret');
    await tester.tap(find.byKey(const ValueKey('direct-connect')));
    await tester.pump();
    expect(calls, 0);
  });
  testWidgets(
      'passes the exact password once, clears the field and prevents double submit',
      (tester) async {
    final pending = Completer<void>();
    final calls = <List<String>>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DirectConnectionForm(
      translate: (key) => key,
      onConnect: (address, password) {
        calls.add([address, password]);
        return pending.future;
      },
    ))));
    await tester.enterText(
        find.byKey(const ValueKey('direct-address')), ' 192.168.1.20 ');
    await tester.enterText(
        find.byKey(const ValueKey('direct-password')), ' spaced password ');
    await tester.tap(find.byKey(const ValueKey('direct-connect')));
    await tester.pump();
    expect(calls, [
      ['192.168.1.20:21118', ' spaced password ']
    ]);
    final password = tester
        .widget<TextFormField>(find.byKey(const ValueKey('direct-password')));
    expect(password.controller!.text, isEmpty);
    expect(
        tester
            .widget<ElevatedButton>(
                find.byKey(const ValueKey('direct-connect')))
            .onPressed,
        isNull);
    pending.complete();
    await tester.pumpAndSettle();
    expect(calls.length, 1);
  });
  testWidgets('form scrolls in a small window with large localized labels',
      (tester) async {
    tester.view.physicalSize = const Size(320, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.4)),
        child: child!,
      ),
      home: Scaffold(
          body: SingleChildScrollView(
              child: DirectConnectionForm(
        translate: (key) => key == 'Remote Host' ? '远程主机地址' : key,
        onConnect: (_, __) async {},
      ))),
    ));
    await tester.ensureVisible(find.byKey(const ValueKey('direct-connect')));
    await tester.tap(find.byKey(const ValueKey('direct-connect')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('远程主机地址'), findsOneWidget);
    expect(find.text('Invalid IP'), findsOneWidget);
    expect(find.text('Password Required'), findsOneWidget);
  });
}
