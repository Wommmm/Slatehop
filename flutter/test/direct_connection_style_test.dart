import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flutter_hbb/desktop/widgets/direct_connection_form.dart';
import 'package:flutter_hbb/desktop/widgets/copper_connection_surface.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/peer_tab_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';

String label(String key) =>
    const {
      'Control Remote Desktop': 'Connect to your Mac',
      'rd-direct-name': 'Connection name (optional)',
      'Remote Host': 'Address',
      'Password': 'Remote password',
      'Enter your password': 'Enter remote password',
      'Remember password': 'Remember password',
      'rd-direct-saved-connections': 'Saved connections',
      'rd-direct-last-success': 'Last connected',
      'rd-direct-unknown-time': 'Not recorded',
      'rd-direct-validity-unknown': 'Not provided',
      'rd-direct-valid-until': 'Valid until',
      'rd-direct-invalid-address':
          'Enter a valid host name or IP address, with an optional port.',
      'Password Required': 'Enter the remote control password.',
      'rd-direct-name-required': 'Enter a connection name.',
      'rd-direct-unreachable':
          'Unable to connect. Check the address and try again.',
      'rd-direct-address-edit-tip':
          'Changing the address requires the remote password.',
    }[key] ??
    key;

class StyleBinding extends Fake implements RustdeskImpl {
  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      label(name);
  @override
  Future<bool> mainPeerHasPassword({required String id, dynamic hint}) async =>
      false;
  @override
  String getLocalFlutterOption({required String k, dynamic hint}) => '';
}

class StylePeers extends ChangeNotifier implements PeerTabModel {
  final selected = <String>{};
  @override
  bool get multiSelectionMode => false;
  @override
  bool isPeerSelected(String id) => selected.contains(id);
  @override
  void select(Peer peer) {
    selected.add(peer.id);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget savedCards(StylePeers peers, {bool compact = false}) =>
    ChangeNotifierProvider<PeerTabModel>.value(
        value: peers,
        child: SingleChildScrollView(
            child: Wrap(spacing: 16, runSpacing: 16, children: [
          for (final name in ['Studio Mac mini', 'Design workspace'])
            SizedBox(
                width: 220,
                height: compact ? 160 : 250,
                child: RecentPeerCard(
                    directOnly: true,
                    peer: Peer.fromJson({
                      'id': name == 'Studio Mac mini'
                          ? 'studio.example.com:21118'
                          : 'design.example.com:21118',
                      'alias': name,
                      'platform': 'Mac OS',
                      'rd_direct_last_success': '1794949200000',
                    }))),
        ])));

Widget styleApp(Widget child, {double scale = 1, bool reduced = false}) =>
    MaterialApp(
        theme: ThemeData.light(),
        home: MediaQuery(
            data: MediaQueryData(
                textScaler: TextScaler.linear(scale),
                disableAnimations: reduced,
                accessibleNavigation: reduced),
            child: Scaffold(body: child)));

void main() {
  setUp(() {
    platformFFI.setBindingForTesting(StyleBinding());
    stateGlobal.isPortrait.value = false;
    peerCardUiType.value = PeerUiType.grid;
  });
  testWidgets(
      'narrow layout and long validation remain scrollable at large text scale',
      (t) async {
    await t.binding.setSurfaceSize(const Size(320, 560));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final peers = StylePeers();
    await t.pumpWidget(styleApp(
        CopperConnectionLayout(
            form: DirectConnectionForm(
                showTitle: true,
                translate: label,
                onConnect: (a, p, n, r) async {}),
            savedConnections: savedCards(peers),
            savedHeading: label('rd-direct-saved-connections')),
        scale: 1.7));
    await t.pumpAndSettle();
    final button = find.byKey(const ValueKey('direct-connect'));
    await t.ensureVisible(button);
    await t.pumpAndSettle();
    await t.tap(button);
    await t.pumpAndSettle();
    expect(find.text(label('Password Required')), findsOneWidget);
    expect(find.text(label('rd-direct-invalid-address')), findsOneWidget);
    await t.ensureVisible(button);
    expect(t.getRect(button).right, lessThanOrEqualTo(320));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    peers.dispose();
  });
  testWidgets(
      'pointer movement and reduced-motion switch preserve field focus and selection',
      (t) async {
    await t.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final form = DirectConnectionForm(
        key: GlobalKey(),
        showTitle: true,
        translate: label,
        onConnect: (a, p, n, r) async {});
    Widget view(bool reduced) => styleApp(
        CopperConnectionLayout(
            form: form,
            savedConnections: const SizedBox(),
            savedHeading: label('rd-direct-saved-connections')),
        reduced: reduced);
    await t.pumpWidget(view(false));
    final finder = find.byKey(const ValueKey('direct-password'));
    await t.enterText(finder, 'Synthetic text');
    final field = t.widget<TextFormField>(finder);
    field.controller!.selection =
        const TextSelection(baseOffset: 2, extentOffset: 6);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(t.getCenter(finder));
    await t.pump();
    expect(
        t
            .widget<TextField>(
                find.descendant(of: finder, matching: find.byType(TextField)))
            .focusNode!
            .hasFocus,
        isTrue);
    await t.pumpWidget(view(true));
    await t.pump();
    await t.binding.setSurfaceSize(const Size(560, 720));
    await t.pumpAndSettle();
    final retained = t.widget<TextFormField>(finder);
    expect(retained.controller, same(field.controller));
    expect(retained.controller!.selection,
        const TextSelection(baseOffset: 2, extentOffset: 6));
    expect(
        t
            .widget<TextField>(
                find.descendant(of: finder, matching: find.byType(TextField)))
            .focusNode!
            .hasFocus,
        isTrue);
    await mouse.removePointer();
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'keyboard next and enter preserve submission and disabled-state behavior',
      (t) async {
    final pending = Completer<void>();
    List<Object>? submitted;
    await t.pumpWidget(styleApp(SingleChildScrollView(
        child: DirectConnectionForm(
            translate: label,
            onConnect: (a, p, n, r) {
              submitted = [a, p, n, r];
              return pending.future;
            }))));
    final address = find.byKey(const ValueKey('direct-address'));
    final password = find.byKey(const ValueKey('direct-password'));
    await t.enterText(address, 'example.com');
    await t.testTextInput.receiveAction(TextInputAction.next);
    await t.pump();
    expect(
        t
            .widget<TextField>(
                find.descendant(of: password, matching: find.byType(TextField)))
            .focusNode!
            .hasFocus,
        isTrue);
    await t.enterText(password, ' Synthetic Password ');
    await t.testTextInput.receiveAction(TextInputAction.go);
    await t.pump();
    expect(submitted, [
      'example.com:21118',
      ' Synthetic Password ',
      'example.com:21118',
      false
    ]);
    expect(t.widget<TextFormField>(password).controller!.text, isEmpty);
    expect(t.widget<TextFormField>(address).enabled, isFalse);
    pending.completeError(StateError('synthetic failure'));
    await t.pumpAndSettle();
    expect(t.widget<TextFormField>(address).enabled, isTrue);
    expect(t.widget<TextFormField>(address).controller!.text, 'example.com');
    expect(find.text(label('rd-direct-unreachable')), findsOneWidget);
  });
  testWidgets(
      'direct grid and compact cards retain metadata and selection at large text scale',
      (t) async {
    final peers = StylePeers();
    for (final compact in [false, true]) {
      peerCardUiType.value = compact ? PeerUiType.tile : PeerUiType.grid;
      await t
          .pumpWidget(styleApp(savedCards(peers, compact: compact), scale: 2));
      await t.pumpAndSettle();
      expect(find.text('Studio Mac mini'), findsOneWidget);
      await t.tap(find.text('Studio Mac mini'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(peers.selected, contains('studio.example.com:21118'));
      expect(find.byType(RentalValiditySummary), findsNWidgets(2));
      expect(t.takeException(), isNull);
    }
    await t.pumpWidget(const SizedBox());
    peers.dispose();
  });
  testWidgets(
      'saved menu opens edit form and cancel preserves the connection page',
      (t) async {
    await t.binding.setSurfaceSize(const Size(1180, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final peers = StylePeers();
    await t.pumpWidget(styleApp(CopperConnectionLayout(
        form: DirectConnectionForm(
            showTitle: true,
            translate: label,
            onConnect: (a, p, n, r) async {}),
        savedConnections: savedCards(peers),
        savedHeading: label('rd-direct-saved-connections'))));
    await t.pumpAndSettle();
    await t.enterText(
        find.byKey(const ValueKey('direct-address')), 'retained.example.com');
    await t.tap(find.byIcon(Icons.more_vert).first);
    await t.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('studio.example.com:21118'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('retained.example.com'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    peers.dispose();
  });
}
