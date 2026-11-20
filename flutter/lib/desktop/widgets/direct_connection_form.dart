import 'package:flutter/material.dart';
import '../../models/direct_endpoint.dart';
import 'copper_connection_surface.dart';
import '../../models/saved_connection.dart';

/// Uses the existing session/authentication flow; holds a new password only
/// for submission, without adding another credential store or connection list.
class DirectConnectionForm extends StatefulWidget {
  final Future<void> Function(
      String address, String password, String name, bool remember) onConnect;
  final String initialAddress;
  final String initialName;
  final bool initialRemember;
  final bool editing;
  final bool passwordOnly;
  final String Function(String) translate;
  final bool showTitle;
  final bool glassHome;

  const DirectConnectionForm(
      {super.key,
      required this.onConnect,
      required this.translate,
      this.showTitle = true,
      this.glassHome = false,
      this.initialAddress = '',
      this.initialName = '',
      this.initialRemember = false,
      this.editing = false,
      this.passwordOnly = false});

  @override
  State<DirectConnectionForm> createState() => _DirectConnectionFormState();
}

class _DirectConnectionFormState extends State<DirectConnectionForm> {
  final _form = GlobalKey<FormState>();
  final _address = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  final _name = TextEditingController();
  bool _remember = false;
  bool _submitting = false;
  bool _showName = false;

  @override
  void initState() {
    super.initState();
    _address.text = widget.initialAddress;
    _name.text = widget.initialName;
    _remember = widget.initialRemember;
  }

  String? _submitErrorKey;
  bool _validationFailed = false;
  String? _validationLabels;

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    _password.clear();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    _validationFailed = !_form.currentState!.validate();
    if (_validationFailed) return;
    final endpoint = DirectEndpoint.tryParse(_address.text)!;
    final password = _password.text; // Password whitespace is significant.
    setState(() {
      _submitting = true;
      _submitErrorKey = null;
    });
    _password.clear();
    try {
      await widget.onConnect(
          endpoint.address,
          password,
          _name.text.trim().isEmpty ? endpoint.address : _name.text.trim(),
          _remember);
    } catch (error) {
      if (mounted) {
        setState(() => _submitErrorKey =
            error is DirectConnectionSubmissionException
                ? error.messageKey
                : 'rd-direct-unreachable');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.translate;
    final labels = [
      'rd-direct-name-required',
      'rd-direct-invalid-address',
      'Password Required',
    ].map(t).join('\u0000');
    if (_validationLabels != null &&
        _validationLabels != labels &&
        _validationFailed) {
      // Window language refresh retains FormFieldState and its error strings.
      // Revalidate only an already-invalid form, never the cleared password
      // after a submitted connection attempt.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _validationFailed) {
          _validationFailed = !_form.currentState!.validate();
        }
      });
    }
    _validationLabels = labels;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.glassHome ? 440 : 520),
      child: CopperConnectionSurface(
        glassHome: widget.glassHome,
        child: Form(
          key: _form,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.showTitle && widget.glassHome) ...[
                    Text(t('New Connection'),
                        style: const TextStyle(
                            color: MacGlassColors.ink,
                            fontSize: 23,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 20),
                  ],
                  if (widget.showTitle && !widget.glassHome) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: const RadialGradient(
                            center: Alignment(-1, -1.8),
                            radius: 2,
                            colors: [Color(0xFF8E6048), Color(0xFF1B1B19)],
                            stops: [0, .8]),
                      ),
                      child: Row(children: [
                        const Icon(Icons.desktop_mac_outlined,
                            size: 26, color: Color(0xFFE7A471)),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Text(t('Connect'),
                                style: const TextStyle(
                                    color: Color(0xFFFFF9F3),
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600))),
                      ]),
                    ),
                    const SizedBox(height: 22),
                  ],
                  if (!widget.passwordOnly) ...[
                    if (!widget.glassHome) ...[
                      _buildName(),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      key: const ValueKey('direct-address'),
                      controller: _address,
                      enabled: !_submitting,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.dns_outlined, size: 19),
                          labelText: t('Remote Host'),
                          hintText: '192.168.1.20:21118'),
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                      validator: (value) =>
                          DirectEndpoint.tryParse(value ?? '') == null
                              ? t('rd-direct-invalid-address')
                              : null,
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextFormField(
                    key: const ValueKey('direct-password'),
                    controller: _password,
                    focusNode: _passwordFocus,
                    enabled: !_submitting,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                        prefixIcon:
                            const Icon(Icons.lock_outline_rounded, size: 19),
                        labelText: t('Password'),
                        hintText: t('Enter your password')),
                    textInputAction: TextInputAction.go,
                    validator: (value) {
                      final changed =
                          DirectEndpoint.tryParse(_address.text)?.address !=
                              DirectEndpoint.tryParse(widget.initialAddress)
                                  ?.address;
                      return (!widget.editing ||
                                  changed ||
                                  widget.passwordOnly ||
                                  (_remember && !widget.initialRemember)) &&
                              (value == null || value.isEmpty)
                          ? t('Password Required')
                          : null;
                    },
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    key: const ValueKey('direct-remember'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('Remember password'),
                        style: const TextStyle(
                            color: ConnectionGlassColors.muted, fontSize: 13)),
                    value: _remember,
                    onChanged: _submitting
                        ? null
                        : (value) => setState(() => _remember = value ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  if (widget.editing)
                    Text(t('rd-direct-address-edit-tip'),
                        style: const TextStyle(
                            color: ConnectionGlassColors.muted,
                            fontSize: 12,
                            height: 1.5)),
                  if (_submitErrorKey != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Semantics(
                          liveRegion: true,
                          child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: const Color(0x15B34B40),
                                  borderRadius: BorderRadius.circular(12)),
                              child: Text(t(_submitErrorKey!),
                                  style: const TextStyle(
                                      color: ConnectionGlassColors.error,
                                      fontSize: 13,
                                      height: 1.5)))),
                    ),
                  const SizedBox(height: 16),
                  SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        key: const ValueKey('direct-connect'),
                        onPressed: _submitting ? null : _submit,
                        child: Text(t(_submitting
                            ? 'Connecting...'
                            : widget.editing
                                ? 'Save'
                                : 'Connect')),
                      )),
                  if (widget.glassHome && !widget.passwordOnly) ...[
                    const SizedBox(height: 8),
                    if (_showName)
                      _buildName()
                    else
                      Center(
                        child: TextButton(
                          onPressed: _submitting
                              ? null
                              : () => setState(() => _showName = true),
                          child: Text(t('rd-direct-name')),
                        ),
                      ),
                  ],
                ]),
          ),
        ),
      ),
    );
  }

  Widget _buildName() => TextFormField(
        key: const ValueKey('direct-name'),
        controller: _name,
        enabled: !_submitting,
        decoration: InputDecoration(
          labelText: widget.translate('rd-direct-name'),
          prefixIcon: const Icon(Icons.badge_outlined, size: 19),
        ),
        validator: (value) =>
            widget.editing && (value ?? '').trim().isEmpty
                ? widget.translate('rd-direct-name-required')
                : null,
      );
}
