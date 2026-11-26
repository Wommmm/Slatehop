import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/rental_validity.dart';

enum LocalRentalState { configured, unconfigured, unavailable }

class LocalRentalStatus {
  final LocalRentalState state;
  final DateTime? validUntilUtc;

  const LocalRentalStatus._(this.state, [this.validUntilUtc]);
  const LocalRentalStatus.unconfigured()
      : this._(LocalRentalState.unconfigured);
  const LocalRentalStatus.unavailable() : this._(LocalRentalState.unavailable);

  /// Display data from the current executable's read-only rental command.
  factory LocalRentalStatus.fromCommandResult(int exitCode, String stdout) {
    if (exitCode != 0) return const LocalRentalStatus.unavailable();
    final line =
        stdout.endsWith('\n') ? stdout.substring(0, stdout.length - 1) : stdout;
    if (line == 'unconfigured') return const LocalRentalStatus.unconfigured();
    final milliseconds = int.tryParse(line);
    if (milliseconds == null ||
        milliseconds < 1 ||
        milliseconds > 253402300799999 ||
        milliseconds.toString() != line) {
      return const LocalRentalStatus.unavailable();
    }
    return LocalRentalStatus._(LocalRentalState.configured,
        DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true));
  }
}

Future<LocalRentalStatus> readCurrentMacRental(String executable) async {
  if (!Platform.isMacOS || executable != Platform.resolvedExecutable) {
    return const LocalRentalStatus.unavailable();
  }
  try {
    final result = await Process.run(
      executable,
      const ['--rental-expiry'],
      stdoutEncoding: ascii,
    ).timeout(const Duration(seconds: 4));
    return LocalRentalStatus.fromCommandResult(
        result.exitCode, result.stdout as String);
  } on ProcessException {
    return const LocalRentalStatus.unavailable();
  } on TimeoutException {
    return const LocalRentalStatus.unavailable();
  } on FormatException {
    return const LocalRentalStatus.unavailable();
  }
}

class RentalPasswordSettings extends StatefulWidget {
  final String hostExecutable;
  final Future<LocalRentalStatus> Function(String executable) readStatus;
  final String Function(String) translateLabel;

  const RentalPasswordSettings({
    super.key,
    required this.hostExecutable,
    this.readStatus = readCurrentMacRental,
    this.translateLabel = translate,
  });

  @override
  State<RentalPasswordSettings> createState() => _RentalPasswordSettingsState();
}

class _RentalPasswordSettingsState extends State<RentalPasswordSettings> {
  late Future<LocalRentalStatus> _status;

  @override
  void initState() {
    super.initState();
    _status = widget.readStatus(widget.hostExecutable);
  }

  @override
  void didUpdateWidget(covariant RentalPasswordSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hostExecutable != widget.hostExecutable ||
        oldWidget.readStatus != widget.readStatus) {
      _status = widget.readStatus(widget.hostExecutable);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.translateLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 0, 0, 6),
      child: FutureBuilder<LocalRentalStatus>(
        future: _status,
        builder: (context, snapshot) {
          final loading = snapshot.connectionState != ConnectionState.done;
          final status = snapshot.data ?? const LocalRentalStatus.unavailable();
          final String description;
          switch (status.state) {
            case LocalRentalState.configured:
              description = RentalValidity(validUntilUtc: status.validUntilUtc)
                  .deadlineLabel(text);
              break;
            case LocalRentalState.unconfigured:
              description = text('No rental is configured for this Mac account.');
              break;
            case LocalRentalState.unavailable:
              description = text('Rental status is unavailable.');
              break;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text('Rental for this Mac account'),
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              if (loading)
                LinearProgressIndicator(
                    semanticsLabel: text('Loading rental status'))
              else
                Text(description),
              TextButton(
                onPressed: loading
                    ? null
                    : () => setState(
                        () => _status = widget.readStatus(widget.hostExecutable)),
                child: Text(text('Refresh rental status')),
              ),
              Text(text(
                  'For remote Macs, see the last reported expiry on each saved connection.')),
            ],
          );
        },
      ),
    );
  }
}
