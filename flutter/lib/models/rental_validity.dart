import 'dart:convert';

/// A display-only snapshot. Only the remote server decides authorization.
/// In particular, a past deadline is not a locally inferred rejection.
enum RentalValidityStatus { unknown, valid, outOfValidity }

class RentalValidity {
  final DateTime? validUntilUtc;
  final RentalValidityStatus status;

  const RentalValidity({
    this.validUntilUtc,
    this.status = RentalValidityStatus.unknown,
  });

  factory RentalValidity.fromPeerMetadata(Object? deadline, Object? status) =>
      RentalValidity(
        validUntilUtc: parseDeadline(deadline),
        status: switch (status) {
          'out_of_validity' => RentalValidityStatus.outOfValidity,
          'valid' => RentalValidityStatus.valid,
          _ => RentalValidityStatus.unknown,
        },
      );

  /// Called only for an authenticated peer_info (or its existing session cache).
  /// Display/platform sync events are not authorization responses.
  factory RentalValidity.fromAuthenticatedPeerInfo(Object? additions) {
    Object? decoded = additions;
    if (additions is String) {
      try {
        decoded = jsonDecode(additions);
      } on FormatException {
        decoded = null;
      }
    }
    final deadline =
        decoded is Map ? parseDeadline(decoded['rental_valid_until_ms']) : null;
    return RentalValidity(
      validUntilUtc: deadline,
      status: deadline == null
          ? RentalValidityStatus.unknown
          : RentalValidityStatus.valid,
    );
  }

  static DateTime? parseDeadline(Object? value) {
    if (value is! String || !RegExp(r'^[0-9]+$').hasMatch(value)) return null;
    final ms = int.tryParse(value);
    if (ms == null) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    } on ArgumentError {
      return null;
    }
  }

  bool get isOutsideValidity => status == RentalValidityStatus.outOfValidity;

  String deadlineLabel(String Function(String) translate) =>
      '${translate('rd-direct-valid-until')}: ${validUntilUtc == null ? translate('rd-direct-validity-unknown') : formatDeadline(validUntilUtc!)}';

  /// Format using the local time zone at that instant, with an explicit offset.
  /// There is deliberately no DateTime.now(), countdown, or validity comparison.
  static String formatDeadline(DateTime utc) {
    final local = utc.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final offset = local.timeZoneOffset;
    final minutes = offset.inMinutes.abs();
    return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)} '
        'UTC${offset.isNegative ? '-' : '+'}${two(minutes ~/ 60)}:${two(minutes % 60)}';
  }
}
