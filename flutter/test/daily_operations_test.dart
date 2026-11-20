import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/file_manager_page.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

final sid = UuidValue('00000000-0000-4000-8000-000000000051');

class Binding extends Fake implements RustdeskImpl {
  int nextId = 0;
  @override
  Future<String> sessionGetPlatform(
          {required UuidValue sessionId,
          required bool isRemote,
          dynamic hint}) async =>
      'Mac OS';
  @override
  int getDoubleClickTime({dynamic hint}) => 500;
  @override
  String mainGetLocalOption({required String key, dynamic hint}) => '';
  @override
  int versionToNumber({required String v, dynamic hint}) =>
      v == '1.4.0' ? 10400 : 10303;
  final cancelled = <int>[];
  final sent = <Map<String, Object>>[];
  Completer<void>? cancelResult;
  @override
  String mainGetCommonSync({required String key, dynamic hint}) =>
      '${++nextId}';
  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;
  @override
  Future<void> sessionCancelJob(
      {required UuidValue sessionId, required int actId, dynamic hint}) {
    cancelled.add(actId);
    return cancelResult?.future ?? Future.value();
  }

  @override
  Future<void> sessionSendFiles(
      {required UuidValue sessionId,
      required int actId,
      required String path,
      required String to,
      required int fileNum,
      required bool includeHidden,
      required bool isRemote,
      required bool isDir,
      dynamic hint}) async {
    sent.add({'id': actId, 'path': path, 'to': to, 'remote': isRemote});
  }
}

class Session extends Fake implements FFI {
  @override
  final connType = ConnType.fileTransfer;
  @override
  late final fileModel = FileModel(WeakReference(this));
  @override
  final id = 'example.com:21118';
  @override
  final sessionId = sid;
  @override
  late final ffiModel = FfiModel(WeakReference(this));
}

Entry file(String name) => Entry()
  ..name = name
  ..path = '/source/$name'
  ..size = 100;
Map<String, String> progress(int id, int size) =>
    {'id': '$id', 'file_num': '0', 'speed': '10', 'finished_size': '$size'};
void main() {
  testWidgets(
      'file pane presents failed navigation without replacing last folder',
      (tester) async {
    final binding = Binding();
    platformFFI.setBindingForTesting(binding);
    final session = Session();
    late FileFetcher fetcher;
    fetcher = FileFetcher(() => sid, readRemoteDirectory: (_, path, __) async {
      if (path == '/denied') throw 'rd-file-no-permission';
      fetcher.tryCompleteTask(
          jsonEncode({'id': 0, 'path': path, 'entries': []}), 'false');
    });
    final controller = FileController(
        isLocal: false,
        getSessionID: () => sid,
        rootState: WeakReference(session),
        jobController: session.fileModel.jobController,
        fileFetcher: fetcher,
        getOtherSideDirectoryData: () => DirectoryData(
            FileDirectory()..path = '/local', DirectoryOptions()));
    controller.directory.value = FileDirectory()..path = '/kept';
    await tester.pumpWidget(MaterialApp(
        theme: MyTheme.lightTheme,
        home: Scaffold(
            body: FileManagerView(
                controller, session, MouseFocusScope.none.obs))));
    await controller.openDirectory('/denied');
    await tester.pump();
    expect(find.text('rd-file-no-permission'), findsOneWidget);
    expect(controller.directory.value.path, '/kept');
    await controller.openDirectory('/next');
    await tester.pump();
    expect(find.text('rd-file-no-permission'), findsNothing);
    expect(controller.directory.value.path, '/next');
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  late Binding binding;
  late JobController jobs;
  setUp(() {
    binding = Binding();
    platformFFI.setBindingForTesting(binding);
    jobs = JobController(() => sid, () => null);
  });
  for (final download in [false, true]) {
    test(
        '${download ? 'download' : 'upload'} error remains terminal after late done/progress',
        () async {
      final id = jobs.addTransferJob(file('a.txt'), download);
      jobs.tryUpdateJobProgress(progress(id, 25));
      jobs.jobError({'id': '$id', 'file_num': '0', 'err': 'rd-file-no-space'});
      await jobs.jobDone({'id': '$id', 'file_num': '0'});
      jobs.tryUpdateJobProgress(progress(id, 90));
      final item = jobs.jobTable.single;
      expect(item.state, JobState.error);
      expect(item.finishedSize, 25);
      expect(item.display(), 'rd-file-no-space');
    });
  }
  test(
      'cancel is immediate and affects only the selected file; late events cannot undo it',
      () async {
    final a = jobs.addTransferJob(file('a.txt'), false);
    final b = jobs.addTransferJob(file('b.txt'), false);
    jobs.registerTransferConflictBatch([a, b]);
    jobs.tryUpdateJobProgress(progress(a, 25));
    binding.cancelResult = Completer<void>();
    final cancelling = jobs.cancelJob(a);
    expect(jobs.jobTable[0].display(), 'Cancel');
    expect(jobs.jobTable[1].state, JobState.inProgress);
    expect(jobs.hasTransferConflictJob(a), isFalse);
    expect(jobs.hasTransferConflictJob(b), isTrue);
    await jobs.jobDone({'id': '$a', 'file_num': '0'});
    jobs.tryUpdateJobProgress(progress(a, 99));
    jobs.jobError(
        {'id': '$a', 'file_num': '0', 'err': 'rd-file-connection-dropped'});
    jobs.jobTable[0].getStatus();
    expect(jobs.jobTable[0].display(), 'Cancel');
    expect(jobs.jobTable[0].finishedSize, 25);
    binding.cancelResult!.complete();
    await cancelling;
    expect(binding.cancelled, [a]);
    await jobs.jobDone({'id': '$b', 'file_num': '0'});
    expect(jobs.jobTable[1].state, JobState.done);
    expect(jobs.jobTable[0].display(), 'Cancel');
  });
  test('progress is bounded and reading status does not invent completed bytes',
      () {
    final item = JobProgress()
      ..type = JobType.transfer
      ..state = JobState.inProgress
      ..fileCount = 1
      ..totalSize = 100
      ..finishedSize = 125;
    expect(item.percent, 1);
    item.finishedSize = -1;
    expect(item.percent, 0);
    item
      ..state = JobState.done
      ..err = 'cancel'
      ..finishedSize = 25;
    expect(item.getStatus(), contains('Cancel'));
    expect(item.finishedSize, 25);
    expect(item.getStatus(), contains('0/1'));
  });
  for (final local in [true, false]) {
    test(
        'multiple ${local ? 'uploads' : 'downloads'} retain separate IDs, paths and completion',
        () async {
      final session = Session();
      session.ffiModel.pi.version = '1.4.0';
      final controller = FileController(
          isLocal: local,
          getSessionID: () => sid,
          rootState: WeakReference(session),
          jobController: jobs,
          fileFetcher: FileFetcher(() => sid),
          getOtherSideDirectoryData: () =>
              DirectoryData(FileDirectory(), DirectoryOptions()));
      final selected = SelectedItems(isLocal: local)
        ..selectAll([file('a.txt'), file('b.txt')]);
      await controller.sendFiles(selected,
          DirectoryData(FileDirectory()..path = '/target', DirectoryOptions()));
      expect(binding.sent, [
        {
          'id': 1,
          'path': '/source/a.txt',
          'to': '/target/a.txt',
          'remote': !local
        },
        {
          'id': 2,
          'path': '/source/b.txt',
          'to': '/target/b.txt',
          'remote': !local
        },
      ]);
      jobs.tryUpdateJobProgress(progress(1, 30));
      jobs.tryUpdateJobProgress(progress(2, 70));
      expect(jobs.jobTable.map((j) => j.finishedSize), [30, 70]);
      await jobs.jobDone({'id': '1', 'file_num': '0'});
      expect(jobs.jobTable.map((j) => j.state),
          [JobState.done, JobState.inProgress]);
      expect(jobs.jobTable.map((j) => j.fileCount), [1, 1]);
    });
  }
  test('three file errors stay distinct', () {
    for (final key in [
      'rd-file-no-permission',
      'rd-file-no-space',
      'rd-file-connection-dropped'
    ]) {
      final id = jobs.addTransferJob(file('$key.txt'), true);
      jobs.jobError({'id': '$id', 'file_num': '0', 'err': key});
      expect(jobs.jobTable.last.getStatus(), contains(key));
    }
  });
}
