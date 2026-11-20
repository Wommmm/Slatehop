import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/direct_connection_form.dart';
import 'package:flutter_hbb/models/saved_connection.dart';

void main() {
  Future<void> showForm(WidgetTester tester,
      Future<void> Function(String, String, String, bool) submit,
      {bool editing = false,
      bool passwordOnly = false,
      bool remembered = false}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: DirectConnectionForm(
          translate: (s) => s,
          onConnect: submit,
          editing: editing,
          passwordOnly: passwordOnly,
          initialAddress: editing || passwordOnly ? 'example.com:21118' : '',
          initialName: editing ? 'Original name' : '',
          initialRemember: remembered),
    ))));
  }

  Future<void> submit(WidgetTester t) async {
    await t.ensureVisible(find.byKey(const ValueKey('direct-connect')));
    await t.tap(find.byKey(const ValueKey('direct-connect')));
    await t.pumpAndSettle();
  }

  testWidgets(
      'new connection defaults name and preserves password whitespace/case',
      (t) async {
    List<Object>? call;
    await showForm(t, (a, p, n, r) async {
      call = [a, p, n, r];
    });
    await t.enterText(
        find.byKey(const ValueKey('direct-address')), ' EXAMPLE.com ');
    await t.enterText(
        find.byKey(const ValueKey('direct-password')), ' Fake PaSs ');
    await submit(t);
    expect(
        call, ['example.com:21118', ' Fake PaSs ', 'example.com:21118', false]);
    expect(
        t
            .widget<TextFormField>(
                find.byKey(const ValueKey('direct-password')))
            .controller!
            .text,
        '');
  });
  testWidgets('invalid address is distinct and never submitted', (t) async {
    var calls = 0;
    await showForm(t, (a, p, n, r) async {
      calls++;
    });
    await t.enterText(
        find.byKey(const ValueKey('direct-address')), '123456789');
    await t.enterText(find.byKey(const ValueKey('direct-password')), 'fake');
    await submit(t);
    expect(calls, 0);
    expect(find.text('rd-direct-invalid-address'), findsOneWidget);
  });
  testWidgets('edit rejects empty name and changed address without credential',
      (t) async {
    var calls = 0;
    await showForm(t, (a, p, n, r) async {
      calls++;
    }, editing: true, remembered: true);
    await t.enterText(find.byKey(const ValueKey('direct-name')), '  ');
    await submit(t);
    expect(find.text('rd-direct-name-required'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('direct-name')), 'New name');
    await t.enterText(
        find.byKey(const ValueKey('direct-address')), 'other.example.com');
    await submit(t);
    expect(calls, 0);
    expect(find.text('Password Required'), findsOneWidget);
    await t.enterText(
        find.byKey(const ValueKey('direct-password')), ' New Fake ');
    await submit(t);
    expect(calls, 1);
  });
  testWidgets('same address name edit needs no password', (t) async {
    List<Object>? call;
    await showForm(t, (a, p, n, r) async {
      call = [a, p, n, r];
    }, editing: true);
    await t.enterText(find.byKey(const ValueKey('direct-name')), 'Renamed');
    await submit(t);
    expect(call, ['example.com:21118', '', 'Renamed', false]);
  });
  testWidgets('enabling remember requires explicit successful-password attempt',
      (t) async {
    var calls = 0;
    await showForm(t, (a, p, n, r) async {
      calls++;
    }, editing: true);
    await t.tap(find.byKey(const ValueKey('direct-remember')));
    await submit(t);
    expect(calls, 0);
    expect(find.text('Password Required'), findsOneWidget);
  });
  testWidgets('dismissing edit without submit has no effects', (t) async {
    var calls = 0;
    await showForm(t, (a, p, n, r) async {
      calls++;
    }, editing: true);
    await t.enterText(find.byKey(const ValueKey('direct-name')), 'Unsaved');
    await t.enterText(
        find.byKey(const ValueKey('direct-address')), 'other.example.com');
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(calls, 0);
  });
  testWidgets(
      'password retry preserves whitespace and explicit remember choice',
      (t) async {
    List<Object>? call;
    await showForm(t, (a, p, n, r) async {
      call = [a, p, n, r];
    }, passwordOnly: true);
    expect(find.byKey(const ValueKey('direct-address')), findsNothing);
    await t.enterText(
        find.byKey(const ValueKey('direct-password')), ' fake Retry ');
    await t.tap(find.byKey(const ValueKey('direct-remember')));
    await submit(t);
    expect(
        call, ['example.com:21118', ' fake Retry ', 'example.com:21118', true]);
  });
  testWidgets('launch failure is reported and password cleared', (t) async {
    await showForm(t, (a, p, n, r) async {
      throw StateError('synthetic launch failure');
    });
    await t.enterText(
        find.byKey(const ValueKey('direct-address')), 'example.com');
    await t.enterText(find.byKey(const ValueKey('direct-password')), 'fake');
    await submit(t);
    expect(find.text('rd-direct-unreachable'), findsOneWidget);
    expect(
        t
            .widget<TextFormField>(
                find.byKey(const ValueKey('direct-password')))
            .controller!
            .text,
        '');
  });
  testWidgets(
      'active session guidance is surfaced without misclassifying authentication',
      (t) async {
    await showForm(t, (a, p, n, r) async {
      throw const DirectConnectionSubmissionException(
          'rd-direct-active-connection');
    });
    await t.enterText(
        find.byKey(const ValueKey('direct-address')), 'example.com');
    await t.enterText(find.byKey(const ValueKey('direct-password')), 'fake');
    await submit(t);
    expect(find.text('rd-direct-active-connection'), findsOneWidget);
    expect(find.text('rd-direct-unreachable'), findsNothing);
  });
}
