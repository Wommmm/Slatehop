import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:window_manager/window_manager.dart';

import 'personal_device_access.dart';

bool _usesChinese(BuildContext context) {
  final preference = bind.mainGetLocalOption(key: kCommConfKeyLang);
  if (preference.isEmpty || preference == defaultOptionLang) {
    return Localizations.localeOf(context).languageCode == 'zh';
  }
  return preference.toLowerCase().split(RegExp('[-_]')).first == 'zh';
}

String ownerDeviceManagementLabel(BuildContext context) =>
    _usesChinese(context) ? '设备管理' : 'Device management';

class OwnerDeviceManagementPage extends StatefulWidget {
  const OwnerDeviceManagementPage({super.key, required this.visible});

  final ValueListenable<bool> visible;

  @override
  State<OwnerDeviceManagementPage> createState() => _OwnerDeviceManagementPageState();
}

class _OwnerDeviceManagementPageState extends State<OwnerDeviceManagementPage>
    with WidgetsBindingObserver, WindowListener {
  final _active = ValueNotifier(false);
  bool _focused = true;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    widget.visible.addListener(_refresh);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant OwnerDeviceManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      oldWidget.visible.removeListener(_refresh);
      widget.visible.addListener(_refresh);
      _refresh();
    }
  }

  void _refresh() => _active.value = widget.visible.value && _focused && _foreground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _refresh();
  }

  @override
  void onWindowFocus() {
    _focused = true;
    _refresh();
  }

  @override
  void onWindowBlur() {
    _focused = false;
    _refresh();
  }

  @override
  void onWindowMinimize() => onWindowBlur();

  @override
  void onWindowClose() => onWindowBlur();

  @override
  void dispose() {
    widget.visible.removeListener(_refresh);
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    _active.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chinese = _usesChinese(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(chinese ? '这台 Mac' : 'This Mac', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        PersonalDeviceAccess(active: _active, chinese: chinese),
      ],
    );
  }
}
