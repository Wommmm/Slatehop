import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:url_launcher/url_launcher.dart';

class SlateHopAbout extends StatelessWidget {
  static const _source = 'https://github.com/Wommmm/Slatehop';
  static const _upstream = 'https://github.com/rustdesk/rustdesk';
  static const _license = '$_source/blob/main/LICENCE';

  final String version;
  final String buildDate;
  final String fingerprint;
  final String deviceId;

  const SlateHopAbout({
    super.key,
    required this.version,
    required this.buildDate,
    required this.fingerprint,
    required this.deviceId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 0, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_upstreamText('slatehop_about_origin')),
          const SizedBox(height: 14),
          SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${translate('Version')}: $version'),
                Text('${translate('Build Date')}: $buildDate'),
                Text('${translate('Fingerprint')}: $fingerprint'),
                Text('${translate('ID')}: $deviceId'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Divider(),
          Wrap(
            spacing: 8,
            children: [
              _link(context, translate('SlateHop source code'), _source),
              _link(context, _upstreamText('slatehop_upstream_source'), _upstream),
              _link(context, 'GNU AGPL v3', _license),
              TextButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'SlateHop',
                  applicationVersion: version,
                ),
                child: Text(translate('Bundled open-source notices')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${_upstreamText('slatehop_upstream_copyright')}: '
            '© 2026 Purslane Tech Pte. Ltd.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  // Custom branding translates RustDesk to the product name. Insert the upstream name afterwards.
  String _upstreamText(String key) => translate(key).replaceFirst('{}', 'RustDesk');

  Widget _link(BuildContext context, String label, String url) => TextButton(
        onPressed: () async {
          try {
            if (await launchUrl(Uri.parse(url),
                mode: LaunchMode.externalApplication)) {
              return;
            }
          } on PlatformException {
            // The browser launch failed. Keep the diagnostics on screen.
          }
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text(translate('Could not open source link.'))),
            );
          }
        },
        child: Text(label),
      );
}
