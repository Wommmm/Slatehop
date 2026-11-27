import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/direct_endpoint.dart';
import 'package:flutter_hbb/models/platform_model.dart';

typedef PersonalAccessRequest = Future<String> Function(
    Map<String, Object?> request);

Future<String> _nativeRequest(Map<String, Object?> request) =>
    bind.mainGetCommon(key: 'slatehop-personal-access:${jsonEncode(request)}');

enum _Mode { unconfigured, personal, managed }

class PersonalDeviceAccess extends StatefulWidget {
  const PersonalDeviceAccess({
    super.key,
    required this.active,
    required this.chinese,
    this.request = _nativeRequest,
  });

  final ValueListenable<bool> active;
  final bool chinese;
  final PersonalAccessRequest request;

  @override
  State<PersonalDeviceAccess> createState() => _PersonalDeviceAccessState();
}

class _PersonalDeviceAccessState extends State<PersonalDeviceAccess> {
  final _management = TextEditingController();
  final _remote = TextEditingController();
  final _confirmation = TextEditingController();
  _Mode? _mode;
  String? _address;
  String? _passwordResult;
  String? _message;
  bool _busy = false;
  bool _isError = false;
  bool _changingPassword = false;
  bool _revealed = false;
  int _generation = 0;

  String _text(String english, String chinese) =>
      widget.chinese ? chinese : english;

  bool _current(int generation) =>
      mounted && widget.active.value && _generation == generation;

  @override
  void initState() {
    super.initState();
    widget.active.addListener(_visibilityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active.value && !_busy && _mode == null) {
        unawaited(_reload());
      }
    });
  }

  @override
  void didUpdateWidget(covariant PersonalDeviceAccess oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      oldWidget.active.removeListener(_visibilityChanged);
      widget.active.addListener(_visibilityChanged);
      _visibilityChanged();
    }
  }

  @override
  void dispose() {
    widget.active.removeListener(_visibilityChanged);
    _generation++;
    _passwordResult = null;
    _management.dispose();
    _remote.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _clearInputs() {
    _management.clear();
    _remote.clear();
    _confirmation.clear();
  }

  void _visibilityChanged() {
    if (widget.active.value) {
      unawaited(_reload());
    } else {
      _generation++;
      setState(() {
        _clearInputs();
        _mode = null;
        _address = null;
        _passwordResult = null;
        _message = null;
        _changingPassword = false;
        _revealed = false;
        _busy = false;
      });
    }
  }

  Future<void> _reload() => _run(const {'op': 'status'});

  void _notice(String message, {required bool error}) {
    setState(() {
      _message = message;
      _isError = error;
    });
  }

  Future<void> _submit(String op) async {
    if (_busy || !widget.active.value) return;
    final management = _management.text;
    if (management.isEmpty) {
      _notice(_text('Enter the management password.', '请输入管理密码。'), error: true);
      return;
    }
    final proposed = _remote.text;
    final confirmation = _confirmation.text;
    if ((op == 'setup' && confirmation != management) ||
        (op == 'set' && (proposed.isEmpty || confirmation != proposed))) {
      _notice(_text('Check both password fields.', '请核对两次输入的密码。'), error: true);
      return;
    }

    await _run({
      'op': op,
      'managementPassword': management,
      if (op == 'set') 'remotePassword': proposed,
    });
  }

  Future<void> _run(Map<String, Object?> request) async {
    if (_busy || !widget.active.value) return;
    final generation = ++_generation;
    final op = request['op'];
    setState(() {
      _clearInputs();
      _passwordResult = null;
      _revealed = false;
      _busy = true;
      _message = null;
      if (op == 'status') {
        _mode = null;
        _address = null;
      }
    });
    try {
      final response = await widget.request(request);
      if (!_current(generation)) return;
      if (response.length > 16384) throw const FormatException();
      final result = jsonDecode(response);
      if (result is! Map<String, dynamic>) throw const FormatException();
      if (result['ok'] == false) {
        _handleFailure(result['error']);
        return;
      }

      final mode = switch (result['mode']) {
        'unconfigured' => _Mode.unconfigured,
        'personal' => _Mode.personal,
        'managed' => _Mode.managed,
        _ => throw const FormatException(),
      };
      if (result['ok'] != true ||
          (op != 'status' && mode == _Mode.unconfigured)) {
        throw const FormatException();
      }
      final address = result['address'];
      final password = result['remotePassword'];
      final returnsPassword =
          mode == _Mode.personal && (op == 'show' || op == 'set');
      if (returnsPassword &&
          ((op == 'show' && password == null) ||
              (password != null &&
                  (password is! String ||
                      password.isEmpty ||
                      password.length > 1024)))) {
        throw const FormatException();
      }
      setState(() {
        _mode = mode;
        if (mode == _Mode.managed) {
          _address = null;
        } else if (address is String &&
            address.length <= 64 &&
            RegExp(r'^(?:\[[0-9A-Fa-f:.]+\]|[0-9.]+):[0-9]+$')
                .hasMatch(address) &&
            DirectEndpoint.tryParse(address) != null) {
          _address = address;
        }
        if (returnsPassword && password is String) _passwordResult = password;
        _changingPassword = false;
        if (mode == _Mode.personal && op == 'setup') {
          _message = _text('Management password saved.', '管理密码已保存。');
        } else if (mode == _Mode.personal && op == 'set') {
          _message = _text('Remote password saved.', '远控密码已保存。');
        }
        _isError = false;
      });
    } catch (_) {
      if (_current(generation)) _handleFailure('unavailable');
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  void _handleFailure(Object? code) {
    setState(() {
      if (code == 'managed') {
        _mode = _Mode.managed;
        _address = null;
        _changingPassword = false;
        _message = null;
        return;
      }

      _isError = true;
      _message = switch (code) {
        'invalid_password' => _text(
            'The management password is incorrect.',
            '管理密码不正确。',
          ),
        'invalid_input' => _text(
            'The password does not meet the requirements.',
            '密码不符合要求。',
          ),
        'no_password' => _text(
            'No remote password is available to show.',
            '当前没有可显示的远控密码。',
          ),
        'already_configured' => _text(
            'Personal access is already configured. Refresh the status.',
            '这台 Mac 已设置管理密码，请刷新状态。',
          ),
        _ => _text(
            'Could not confirm the result. Refresh the status.',
            '无法确认结果，请刷新状态。',
          ),
      };
      if (code == 'already_configured' ||
          (code != 'invalid_password' &&
              code != 'invalid_input' &&
              code != 'no_password')) {
        _mode = null;
        _address = null;
        _changingPassword = false;
      }
    });
  }

  Future<void> _copy(String value, {required bool password}) async {
    if (!widget.active.value || _busy || (password && !_revealed)) return;
    final generation = _generation;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (_current(generation)) {
        _notice(
          password
              ? _text('Password copied.', '已复制密码。')
              : _text('Address copied.', '已复制地址。'),
          error: false,
        );
      }
    } catch (_) {
      if (_current(generation)) {
        _notice(
          _text('Could not copy to the clipboard.', '无法复制到剪贴板。'),
          error: true,
        );
      }
    }
  }

  Widget _field(TextEditingController controller, String label) => TextField(
        controller: controller,
        enabled: !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: label),
      );

  @override
  Widget build(BuildContext context) {
    if (!widget.active.value) return const SizedBox.shrink();
    final setup = _mode == _Mode.unconfigured;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_message case final message?)
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  style: TextStyle(
                    color:
                        _isError ? Theme.of(context).colorScheme.error : null,
                  ),
                ),
              ),
            if (_mode == _Mode.managed)
              Text(
                _text(
                  'This Mac is managed. Personal access is locked.',
                  '这台 Mac 处于托管状态，本机自用入口已锁定。',
                ),
              )
            else if (setup || _mode == _Mode.personal) ...[
              if (_address case final address?) ...[
                Text(_text('Connection address', '远控连接地址')),
                SelectableText(address),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed:
                        _busy ? null : () => _copy(address, password: false),
                    child: Text(_text('Copy address', '复制地址')),
                  ),
                ),
              ],
              if (setup)
                Text(
                  _text(
                    'Setting a management password keeps your existing remote password.',
                    '设置管理密码会保留已有远控密码。',
                  ),
                ),
              _field(
                _management,
                setup
                    ? _text('New management password', '新管理密码')
                    : _text('Management password', '管理密码'),
              ),
              if (setup)
                _field(
                  _confirmation,
                  _text('Confirm management password', '确认管理密码'),
                )
              else if (_changingPassword) ...[
                _field(_remote, _text('New remote password', '新远控密码')),
                _field(
                  _confirmation,
                  _text('Confirm remote password', '确认远控密码'),
                ),
              ],
              const SizedBox(height: 12),
              _actions(setup),
              if (_passwordResult case final result?) _result(result),
            ],
            if (!_busy && _mode != _Mode.managed)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _reload,
                  child: Text(_text('Refresh status', '刷新状态')),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _actions(bool setup) {
    if (setup || _changingPassword) {
      return Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          ElevatedButton(
            onPressed: _busy ? null : () => _submit(setup ? 'setup' : 'set'),
            child: Text(
              setup
                  ? _text('Save management password', '保存管理密码')
                  : _text('Save remote password', '保存远控密码'),
            ),
          ),
          if (!setup)
            TextButton(
              onPressed: _busy ? null : () => _setChanging(false),
              child: Text(_text('Cancel', '取消')),
            ),
        ],
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        ElevatedButton(
          onPressed: _busy ? null : () => _submit('show'),
          child: Text(_text('Authenticate to view password', '验证后查看远控密码')),
        ),
        TextButton(
          onPressed: _busy ? null : () => _setChanging(true),
          child: Text(_text('Change remote password', '设置或重置远控密码')),
        ),
      ],
    );
  }

  void _setChanging(bool changing) {
    setState(() {
      _remote.clear();
      _confirmation.clear();
      _passwordResult = null;
      _message = null;
      _revealed = false;
      _changingPassword = changing;
    });
  }

  Widget _result(String password) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(_revealed ? password : '••••••••'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: () => setState(() => _revealed = !_revealed),
                child: Text(
                  _revealed
                      ? _text('Hide password', '隐藏密码')
                      : _text('Show password', '显示密码'),
                ),
              ),
              if (_revealed)
                TextButton(
                  onPressed: () => _copy(password, password: true),
                  child: Text(_text('Copy password', '复制密码')),
                ),
              TextButton(
                onPressed: () => setState(() {
                  _passwordResult = null;
                  _revealed = false;
                }),
                child: Text(_text('Clear result', '清除结果')),
              ),
            ],
          ),
        ],
      );
}
