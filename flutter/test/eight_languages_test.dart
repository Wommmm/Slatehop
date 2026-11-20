import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/desktop/widgets/copper_connection_surface.dart';
import 'package:flutter_hbb/desktop/widgets/direct_connection_form.dart';
import 'package:flutter_hbb/desktop/pages/file_manager_page.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/rental_validity.dart';
import 'package:flutter_hbb/models/saved_connection.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:uuid/uuid.dart';
import 'package:get/get.dart';

import 'direct_connection_style_test.dart'
    show StyleBinding, StylePeers, savedCards;

const languages = ['cn', 'tw', 'en', 'ja', 'ko', 'de', 'fr', 'ru'];

// Native FFI is unavailable in widget tests. Read the actual product dictionaries
// at that boundary; these tests do not claim to exercise native persistence/IPC.
class LanguageBinding extends StyleBinding {
  String language = 'en';
  final tables = <String, Map<String, String>>{};

  LanguageBinding() {
    final pairs =
        RegExp(r'\(\s*("(?:[^"\\]|\\.)*")\s*,\s*("(?:[^"\\]|\\.)*")\s*\)');
    for (final lang in languages) {
      tables[lang] = {
        for (final pair in pairs
            .allMatches(File('../src/lang/$lang.rs').readAsStringSync()))
          jsonDecode(pair[1]!) as String: jsonDecode(pair[2]!) as String,
      };
    }
  }

  String label(String key) {
    final value = tables[language]?[key];
    return value != null && value.isNotEmpty
        ? value
        : tables['en']?[key] ?? key;
  }

  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      label(name);

  @override
  int getDoubleClickTime({dynamic hint}) => 500;
  @override
  String mainGetLocalOption({required String key, dynamic hint}) => '';
  @override
  Future<String> sessionGetPlatform(
          {required UuidValue sessionId,
          required bool isRemote,
          dynamic hint}) async =>
      'Mac OS';
}

final session = UuidValue('00000000-0000-0000-0000-000000000000');

class LanguageFFI implements FFI {
  @override
  String id = 'language-test';
  @override
  UuidValue get sessionId => session;
  @override
  late final FfiModel ffiModel = FfiModel(WeakReference(this));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget app(Widget child) => MaterialApp(
    theme: MyTheme.lightTheme.copyWith(
        textTheme:
            MyTheme.lightTheme.textTheme.apply(fontFamily: 'LanguagePreview')),
    home: Scaffold(body: child));

void main() {
  late LanguageBinding binding;
  setUp(() {
    binding = LanguageBinding();
    platformFFI.setBindingForTesting(binding);
    stateGlobal.isPortrait.value = false;
    peerCardUiType.value = PeerUiType.grid;
  });

  testWidgets(
      'existing validation errors switch language without losing entered fields',
      (tester) async {
    final key = GlobalKey();
    Widget host() => app(SingleChildScrollView(
            child: DirectConnectionForm(
          key: key,
          editing: true,
          initialAddress: 'studio.example.com:21118',
          translate: binding.label,
          onConnect: (a, p, n, r) async {},
        )));
    await tester.pumpWidget(host());
    await tester.enterText(
        find.byKey(const ValueKey('direct-address')), 'bad address!');
    await tester.tap(find.byKey(const ValueKey('direct-connect')));
    await tester.pumpAndSettle();
    expect(find.text('Invalid address'), findsOneWidget);
    binding.language = 'de';
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('Ungültige Adresse'), findsOneWidget);
    expect(find.text('Invalid address'), findsNothing);
    expect(find.text(binding.label('rd-direct-name-required')), findsOneWidget);
    expect(find.text('Passwort erforderlich'), findsOneWidget);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('direct-address')))
            .controller!
            .text,
        'bad address!');
  });

  testWidgets(
      'existing submission error switches language without a second connection',
      (tester) async {
    var calls = 0;
    final key = GlobalKey();
    Widget host() => app(SingleChildScrollView(
            child: DirectConnectionForm(
          key: key,
          initialAddress: 'studio.example.com:21118',
          translate: binding.label,
          onConnect: (a, p, n, r) async {
            calls++;
            throw DirectConnectionSubmissionException('rd-direct-unreachable');
          },
        )));
    await tester.pumpWidget(host());
    await tester.enterText(
        find.byKey(const ValueKey('direct-password')), 'fixture-password');
    await tester.tap(find.byKey(const ValueKey('direct-connect')));
    await tester.pumpAndSettle();
    expect(find.text('Cannot connect'), findsOneWidget);
    for (final language in languages) {
      binding.language = language;
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.text(binding.tables[language]!['rd-direct-unreachable']!),
          findsOneWidget);
      expect(find.text(binding.label('Password Required')), findsNothing);
    }
    expect(calls, 1);
    expect(
        tester
            .widget<TextFormField>(
                find.byKey(const ValueKey('direct-password')))
            .controller!
            .text,
        isEmpty);
  });

  testWidgets(
      'existing directory error retranslates in the production file view without navigating again',
      (tester) async {
    final ffi = LanguageFFI();
    final controller = FileController(
      isLocal: false,
      getSessionID: () => session,
      rootState: WeakReference(ffi),
      jobController: JobController(() => session, () => null),
      fileFetcher:
          FileFetcher(() => session, readRemoteDirectory: (_, path, __) async {
        throw 'Permission denied';
      }),
      getOtherSideDirectoryData: () =>
          DirectoryData(FileDirectory(), DirectoryOptions()),
    );
    controller.directory.value = FileDirectory()..path = '/kept';
    expect(await controller.openDirectory('/denied'), isFalse);
    expect(controller.directory.value.path, '/kept');
    expect(controller.directoryError.value, 'rd-file-no-permission');
    final mouseFocus = MouseFocusScope.none.obs;
    for (final language in languages) {
      binding.language = language;
      await tester
          .pumpWidget(app(FileManagerView(controller, ffi, mouseFocus)));
      await tester.pumpAndSettle();
      expect(find.text(binding.tables[language]!['rd-file-no-permission']!),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('four connection failures stay distinct in every language',
      (tester) async {
    const errors = [
      'rd-direct-invalid-address',
      'rd-direct-unreachable',
      'rd-direct-auth-failed',
      'rd-direct-out-of-validity'
    ];
    for (final language in languages) {
      binding.language = language;
      expect(errors.map(binding.label).toSet().length, 4);
      for (final error in errors) {
        await tester.pumpWidget(app(SingleChildScrollView(
            child: DirectConnectionForm(
          key: ValueKey('$language-$error'),
          initialAddress: error == errors.first
              ? 'bad address!'
              : 'studio.example.com:21118',
          translate: binding.label,
          onConnect: (a, p, n, r) async {
            throw DirectConnectionSubmissionException(error);
          },
        ))));
        await tester.enterText(
            find.byKey(const ValueKey('direct-password')), 'fixture-password');
        await tester.tap(find.byKey(const ValueKey('direct-connect')));
        await tester.pumpAndSettle();
        expect(find.text(binding.tables[language]![error]!), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox());
  });

  test(
      'existing transfer failures stay distinct and retranslate in all eight languages',
      () {
    final errors = {
      'Connection reset by peer': 'rd-file-connection-dropped',
      'Permission denied': 'rd-file-no-permission',
      'ENOSPC': 'rd-file-no-space'
    };
    final jobs = [
      for (final error in errors.keys)
        JobProgress()
          ..type = JobType.transfer
          ..state = JobState.error
          ..err = error
    ];
    for (final lang in languages) {
      binding.language = lang;
      expect(jobs.map((job) => job.display()).toSet().length, 3);
      for (final job in jobs) {
        expect(job.display(), binding.tables[lang]![errors[job.err]]);
      }
    }
  });

  for (final lang in languages) {
    testWidgets(
        '$lang: live form, saved cards and validity fit at desktop and narrow widths',
        (tester) async {
      binding.language = lang;
      if (Platform.environment['LANGUAGE_PREVIEWS'] == '1') {
        final loader = FontLoader('LanguagePreview')
          ..addFont(Future.value(ByteData.sublistView(
              File('../fonts/NotoSansCJK-Regular.ttc').readAsBytesSync())));
        await tester.runAsync(loader.load);
        final icons = FontLoader('MaterialIcons')
          ..addFont(Future.value(ByteData.sublistView(File(
                  '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
              .readAsBytesSync())));
        await tester.runAsync(icons.load);
      }
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final peers = StylePeers();
      addTearDown(peers.dispose);
      final boundary = GlobalKey();
      Widget host() => app(RepaintBoundary(
          key: boundary,
          child: CopperConnectionLayout(
            form: DirectConnectionForm(
                initialAddress: 'studio.example.com:21118',
                translate: binding.label,
                onConnect: (a, p, n, r) async {}),
            savedConnections: savedCards(peers),
            savedHeading: binding.label('rd-direct-saved-connections'),
          )));
      for (final size in [const Size(1080, 760), const Size(360, 760)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(host());
        await tester.pumpAndSettle();
        expect(find.text(binding.label('rd-direct-saved-connections')),
            findsOneWidget);
        expect(find.textContaining(binding.label('rd-direct-valid-until')),
            findsWidgets);
        expect(find.text(binding.label('Remote Host')), findsOneWidget);
        expect(find.text(binding.label('Remember password')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (Platform.environment['LANGUAGE_PREVIEWS'] == '1' &&
            size.width == 1080) {
          await tester.runAsync(() async {
            final image = await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            Directory('../language-previews').createSync(recursive: true);
            File('../language-previews/$lang.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      await tester.pumpWidget(app(RentalValiditySummary(
          validity:
              const RentalValidity(status: RentalValidityStatus.outOfValidity),
          translateLabel: binding.label)));
      expect(find.text(binding.label('rd-direct-out-of-validity')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
