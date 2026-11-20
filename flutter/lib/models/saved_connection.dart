import 'dart:convert';
import 'direct_endpoint.dart';

/// Non-secret attempt metadata. Native consumes this envelope locally before
/// building the RustDesk login. Passwords stay in the existing password path.
class SavedConnectionAttempt {
  final String address;
  final String name;
  final bool remember;
  final String? replaceFrom;

  SavedConnectionAttempt(String address, String name, this.remember,
      {this.replaceFrom})
      : address = DirectEndpoint.tryParse(address)!.address,
        name = name.trim().isEmpty
            ? DirectEndpoint.tryParse(address)!.address
            : name.trim();

  String get loginMethod => 'rd-direct-v1:${jsonEncode({
            'name': name,
            'remember': remember,
            if (replaceFrom != null) 'replace_from': replaceFrom,
          })}';

  static bool addressChanged(String original, String edited) =>
      DirectEndpoint.tryParse(original)?.address !=
      DirectEndpoint.tryParse(edited)?.address;
}

class DirectConnectionSubmissionException implements Exception {
  final String messageKey;
  const DirectConnectionSubmissionException(this.messageKey);
}
