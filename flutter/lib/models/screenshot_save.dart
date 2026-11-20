import 'dart:async';

import 'package:file_picker/file_picker.dart';

// Desktop file_picker save panels confirm replacement before returning a path.
// In particular, the locked macOS implementation uses `choose file name`.
// Do not add a second confirmation or write anything until the panel returns.
Future<String?> pickScreenshotPath(String title) =>
    FilePicker.platform.saveFile(
      dialogTitle: title,
      fileName: 'screenshot.png',
      type: FileType.custom,
      allowedExtensions: ['png'],
    );

/// Owns one capture and its Save As dialog through completion or cancellation.
/// Every native action carries the request token, including stale cleanup.
class ScreenshotSaveController {
  ScreenshotSaveController({
    required this.action,
    required this.capture,
    required this.pickPath,
    required this.showError,
    this.captureTimeout = const Duration(seconds: 30),
  });

  final Future<String> Function(String) action;
  final Future<void> Function() capture;
  final Future<String?> Function() pickPath;
  final Future<bool> Function(String message, bool canRetry) showError;
  final Duration captureTimeout;
  Timer? _timer;
  String? _token;
  int _generation = 0;
  bool _busy = false;
  bool _saving = false;
  bool get busy => _busy;

  bool _current(int generation, String token) =>
      _busy && generation == _generation && token == _token;

  Future<void> _discard(String token) async {
    try {
      await action('$token|2');
    } catch (_) {
      // Session close also invalidates this token in native code.
    }
  }

  Future<bool> _error(String message, bool canRetry) async {
    try {
      return await showError(message, canRetry);
    } catch (_) {
      return false;
    }
  }

  Future<void> start() async {
    if (_busy) return;
    _busy = true;
    final generation = ++_generation;
    try {
      final token = await action('begin');
      if (generation != _generation) {
        if (token.startsWith('screenshot:')) await _discard(token);
        return;
      }
      if (!token.startsWith('screenshot:')) {
        _busy = false;
        await _error(token, false);
        return;
      }
      _token = token;
      _timer = Timer(captureTimeout, () async {
        if (!_current(generation, token) || _saving) return;
        await _finish(generation, token, discard: true);
        await _error('Timeout', false);
      });
      await capture();
    } catch (error) {
      if (generation != _generation) return;
      final token = _token;
      if (token != null) {
        await _finish(generation, token, discard: true);
      } else {
        _busy = false;
      }
      await _error(error.toString(), false);
    }
  }

  Future<void> receive(String token, String message) async {
    final generation = _generation;
    if (!_current(generation, token) || _saving) return;
    _timer?.cancel();
    _timer = null;
    _saving = true;
    if (message.isNotEmpty) {
      await _finish(generation, token, discard: true);
      await _error(message, false);
      return;
    }
    while (_current(generation, token)) {
      try {
        final path = await pickPath();
        if (!_current(generation, token)) return;
        if (path == null || path.isEmpty) {
          await _finish(generation, token, discard: true);
          return;
        }
        final result = await action('$token|0:$path');
        if (!_current(generation, token)) return;
        if (result.isEmpty) {
          await _finish(generation, token, discard: false);
          return;
        }
        if (!await _error(result, true)) break;
      } catch (error) {
        if (!_current(generation, token)) return;
        if (!await _error(error.toString(), true)) break;
      }
    }
    if (_current(generation, token)) {
      await _finish(generation, token, discard: true);
    }
  }

  Future<void> _finish(int generation, String token,
      {required bool discard}) async {
    if (!_current(generation, token)) return;
    // Stop accepting a response immediately, even while native discard awaits.
    _saving = true;
    _timer?.cancel();
    if (discard) await _discard(token);
    if (!_current(generation, token)) return;
    _token = null;
    _saving = false;
    _busy = false;
    ++_generation;
  }

  Future<void> cancel() async {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    final token = _token;
    _token = null;
    _saving = false;
    _busy = false;
    if (token != null) await _discard(token);
  }
}
