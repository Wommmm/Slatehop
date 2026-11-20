import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

// Only the unavailable native translation/cancel boundary is replaced.
class _StatusBinding extends Fake implements RustdeskImpl {
  String filesLabel = '文件';

  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name == 'files'
          ? filesLabel
          : const {
                'rd-file-connection-dropped': '连接已断',
                'Cancel': '取消',
                'Skipped': '已跳过',
              }[name] ??
              name;

  @override
  Future<void> sessionCancelJob(
      {required UuidValue sessionId, required int actId, dynamic hint}) async {}
}

JobProgress _transfer(int number, int count) => JobProgress()
  ..id = 1
  ..type = JobType.transfer
  ..state = JobState.inProgress
  ..fileNum = number
  ..fileCount = count;

void main() {
  late _StatusBinding binding;
  late JobController controller;
  setUp(() {
    binding = _StatusBinding();
    platformFFI.setBindingForTesting(binding);
    controller = JobController(
        () => UuidValue('00000000-0000-0000-0000-000000000000'), () => null);
  });

  test(
      'disconnect before the first completed file shows zero and localized units',
      () {
    final job = _transfer(-1, 1);
    controller.jobTable.add(job);
    controller.failActiveTransfers();
    expect(job.getStatus(), '连接已断, 0/1 文件');
    expect(job.fileNum,
        -1); // Display normalization must not rewrite native state.
    binding.filesLabel = 'files';
    expect(job.getStatus(), '连接已断, 0/1 files');
  });

  test('handled counts stay within the displayed total, including empty jobs',
      () {
    for (final sample in [
      (-2, 3, '0/3 文件'),
      (0, 3, '0/3 文件'),
      (2, 3, '2/3 文件'),
      (9, 3, '3/3 文件'),
      (-1, 0, '0/0 文件'),
      (1, 0, '0/0 文件'),
    ]) {
      expect(_transfer(sample.$1, sample.$2).getStatus(), sample.$3);
    }
  });

  test('cancellation preserves partial counts and is not reported as complete',
      () async {
    final job = _transfer(1, 3);
    controller.jobTable.add(job);
    await controller.cancelJob(job.id);
    expect(job.getStatus(), '取消, 1/3 文件');
    final notStarted = _transfer(-1, 1);
    controller.jobTable
      ..clear()
      ..add(notStarted);
    await controller.cancelJob(notStarted.id);
    expect(notStarted.getStatus(), '取消, 0/1 文件');
  });

  test('skipped jobs retain their distinct completed-processing status', () {
    final job = _transfer(-1, 1)
      ..state = JobState.done
      ..err = 'skipped';
    expect(job.getStatus(), '已跳过, 1/1 文件');
  });

  test('directory jobs keep their response-based count increment', () {
    final job = JobProgress()
      ..type = JobType.deleteDir
      ..state = JobState.inProgress
      ..fileNum = 0
      ..fileCount = 3
      ..recvJobRes = true;
    expect(job.getStatus(), '1/3 文件');
  });
}
