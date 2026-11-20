import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_hbb/models/screenshot_save.dart';
import 'package:flutter_test/flutter_test.dart';

class SavePicker extends FilePicker {
  String? title;
  String? name;
  String? directory;
  List<String>? extensions;
  FileType? fileType;
  int calls = 0;
  String? result;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool lockParentWindow = false,
  }) async {
    calls++;
    title = dialogTitle;
    name = fileName;
    directory = initialDirectory;
    extensions = allowedExtensions;
    fileType = type;
    return result;
  }
}

class Flow {
  final calls = <String>[];
  final errors = <String>[];
  int captures = 0;
  int dialogs = 0;
  int sequence = 0;
  Future<String?> Function() picker = () async => '/chosen/image.png';
  Future<String> Function(String)? save;
  Future<bool> Function(String, bool)? error;
  late final controller = ScreenshotSaveController(
    action: (action) async {
      calls.add(action);
      if (action == 'begin') return 'screenshot:${++sequence}';
      if (action.contains('|0:') && save != null) return save!(action);
      return '';
    },
    capture: () async => captures++,
    pickPath: () {
      dialogs++;
      return picker();
    },
    showError: (message, retry) async {
      errors.add(message);
      return error == null ? false : await error!(message, retry);
    },
  );
  String get token => 'screenshot:$sequence';
}

void main() {
  test('picker opens every time with a local editable name and no fixed folder',
      () async {
    final previous = FilePicker.platform;
    final picker = SavePicker();
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = previous);
    expect(await pickScreenshotPath('Save as...'), isNull);
    picker.result = '/another folder/my name.png';
    expect(await pickScreenshotPath('Save as...'), picker.result);
    expect(picker.calls, 2);
    expect(picker.name, 'screenshot.png');
    expect(picker.directory, isNull);
    expect(picker.fileType, FileType.custom);
    expect(picker.extensions, ['png']);
  });

  test('cancel in the save or replacement panel never issues a save', () async {
    final flow = Flow()..picker = () async => null;
    await flow.controller.start();
    await flow.controller.receive(flow.token, '');
    expect(flow.calls, ['begin', 'screenshot:1|2']);
    expect(flow.controller.busy, isFalse);
  });

  test('confirmed picker path is saved once without a second confirmation',
      () async {
    final flow = Flow()..picker = () async => '/chosen/existing.png';
    await flow.controller.start();
    await flow.controller.receive(flow.token, '');
    expect(flow.calls, ['begin', 'screenshot:1|0:/chosen/existing.png']);
    expect(flow.errors, isEmpty);
    expect(flow.dialogs, 1);
  });

  test('each sequential capture opens its own picker and keeps chosen names',
      () async {
    final flow = Flow();
    flow.picker = () async => '/folder/${flow.dialogs}.png';
    for (var i = 0; i < 2; i++) {
      await flow.controller.start();
      await flow.controller.receive(flow.token, '');
    }
    expect(flow.captures, 2);
    expect(flow.dialogs, 2);
    expect(flow.calls, [
      'begin',
      'screenshot:1|0:/folder/1.png',
      'begin',
      'screenshot:2|0:/folder/2.png',
    ]);
  });

  test('repeated shortcut and response do not open parallel save dialogs',
      () async {
    final flow = Flow();
    final pick = Completer<String?>();
    flow.picker = () => pick.future;
    await flow.controller.start();
    final receiving = flow.controller.receive(flow.token, '');
    await flow.controller.start();
    await flow.controller.receive(flow.token, '');
    expect(flow.captures, 1);
    expect(flow.dialogs, 1);
    expect(flow.controller.busy, isTrue);
    pick.complete('/chosen/one.png');
    await receiving;
    expect(flow.calls.where((s) => s.contains('|0:')).length, 1);
  });

  test('failed write retries same snapshot through another Save As', () async {
    final flow = Flow();
    var attempts = 0;
    flow.save = (_) async => ++attempts == 1 ? 'Permission denied' : '';
    flow.error = (_, canRetry) async => canRetry;
    flow.picker = () async => '/folder/${flow.dialogs}.png';
    await flow.controller.start();
    await flow.controller.receive(flow.token, '');
    expect(flow.captures, 1);
    expect(flow.dialogs, 2);
    expect(flow.calls, [
      'begin',
      'screenshot:1|0:/folder/1.png',
      'screenshot:1|0:/folder/2.png',
    ]);
    expect(flow.errors, ['Permission denied']);
  });

  test('declining retry discards only the failed request', () async {
    final flow = Flow()..save = (_) async => 'Disk full';
    await flow.controller.start();
    await flow.controller.receive(flow.token, '');
    expect(flow.calls.last, 'screenshot:1|2');
    expect(flow.controller.busy, isFalse);
    expect(flow.errors, ['Disk full']);
  });

  test('picker exception is reported and can retry the retained image',
      () async {
    final flow = Flow();
    flow.picker = () async {
      if (flow.dialogs == 1) throw StateError('picker unavailable');
      return null;
    };
    flow.error = (_, canRetry) async => canRetry;
    await flow.controller.start();
    await flow.controller.receive(flow.token, '');
    expect(flow.dialogs, 2);
    expect(flow.calls, ['begin', 'screenshot:1|2']);
    expect(flow.errors.single, contains('picker unavailable'));
  });

  test('closing while picker waits cannot save into a later request', () async {
    final flow = Flow();
    final oldPicker = Completer<String?>();
    flow.picker = () => oldPicker.future;
    await flow.controller.start();
    final oldReceive = flow.controller.receive(flow.token, '');
    await flow.controller.cancel();
    flow.picker = () async => '/new.png';
    await flow.controller.start();
    oldPicker.complete('/stale.png');
    await oldReceive;
    await flow.controller.receive('screenshot:1', '');
    await flow.controller.receive('screenshot:2', '');
    expect(flow.calls, [
      'begin',
      'screenshot:1|2',
      'begin',
      'screenshot:2|0:/new.png',
    ]);
  });

  test('close during native begin cleans only its returned token', () async {
    final begin = Completer<String>();
    final calls = <String>[];
    final controller = ScreenshotSaveController(
      action: (action) async {
        calls.add(action);
        return action == 'begin' ? await begin.future : '';
      },
      capture: () async => fail('closed request must not capture'),
      pickPath: () async => fail('closed request must not pick'),
      showError: (_, __) async => false,
    );
    final start = controller.start();
    await controller.cancel();
    begin.complete('screenshot:old');
    await start;
    expect(calls, ['begin', 'screenshot:old|2']);
    expect(controller.busy, isFalse);
  });

  testWidgets('timeout discards token and ignores a late response',
      (tester) async {
    final flow = Flow();
    await flow.controller.start();
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(flow.calls, ['begin', 'screenshot:1|2']);
    await flow.controller.start();
    await flow.controller.receive('screenshot:1', '');
    expect(flow.dialogs, 0);
    await flow.controller.receive('screenshot:2', '');
    expect(flow.calls.last, 'screenshot:2|0:/chosen/image.png');
  });

  test('remote capture error does not open Save As and permits another request',
      () async {
    final flow = Flow();
    await flow.controller.start();
    await flow.controller.receive(flow.token, 'Capture unavailable');
    expect(flow.dialogs, 0);
    expect(flow.errors, ['Capture unavailable']);
    await flow.controller.start();
    await flow.controller.receive(flow.token, '');
    expect(flow.captures, 2);
    expect(flow.dialogs, 1);
  });
  testWidgets('response arriving while timeout discard waits is ignored',
      (tester) async {
    final discard = Completer<String>();
    var dialogs = 0;
    final controller = ScreenshotSaveController(
      action: (action) async =>
          action == 'begin' ? 'screenshot:one' : await discard.future,
      capture: () async {},
      pickPath: () async {
        dialogs++;
        return '/late.png';
      },
      showError: (_, __) async => false,
    );
    await controller.start();
    await tester.pump(const Duration(seconds: 31));
    await controller.receive('screenshot:one', '');
    expect(dialogs, 0);
    discard.complete('');
    await tester.pump();
    expect(controller.busy, isFalse);
  });
}
