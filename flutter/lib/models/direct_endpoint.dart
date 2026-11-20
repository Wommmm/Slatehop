import 'dart:io';

/// A concrete address for RustDesk's existing direct TCP path. Numeric IDs,
/// relay suffixes and URL syntax must never be interpreted as destinations.
class DirectEndpoint {
  static const defaultPort = 21118;
  final String address;

  const DirectEndpoint._(this.address);

  /// Display one existing recent record per concrete endpoint, in original
  /// (recent-first) order. Never mutates, deletes or migrates stored records.
  static List<T> uniqueRecent<T>(
      Iterable<T> records, String Function(T) addressOf) {
    final seen = <String>{};
    return records.where((record) {
      final endpoint = tryParse(addressOf(record));
      return endpoint != null && seen.add(endpoint.address);
    }).toList();
  }

  static DirectEndpoint? tryParse(String input) {
    final value = input.trim();
    if (value.isEmpty || RegExp(r'[\s/@?#\\%]').hasMatch(value)) return null;

    String host;
    String? portText;
    if (value.startsWith('[')) {
      final match = RegExp(r'^\[([^\]]+)\](?::([0-9]+))?$').firstMatch(value);
      if (match == null) return null;
      host = match[1]!;
      portText = match[2];
      if (InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6) {
        return null;
      }
    } else if (InternetAddress.tryParse(value)?.type ==
        InternetAddressType.IPv6) {
      host = value;
    } else {
      final parts = value.split(':');
      if (parts.length > 2) return null;
      host = parts.first;
      if (parts.length == 2) portText = parts.last;
    }
    if (portText != null && !RegExp(r'^[0-9]+$').hasMatch(portText)) {
      return null;
    }
    final port = portText == null ? defaultPort : int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) return null;

    final ip = InternetAddress.tryParse(host);
    if (ip != null) {
      if (ip.type == InternetAddressType.IPv6) {
        // Expand all groups: the pinned native direct-address recognizer does
        // not accept every compressed form (notably ::1) even though it is valid.
        final bytes = ip.rawAddress;
        final groups = List.generate(8,
            (i) => ((bytes[i * 2] << 8) | bytes[i * 2 + 1]).toRadixString(16));
        return DirectEndpoint._('[${groups.join(':')}]:$port');
      }
      return DirectEndpoint._('${ip.address}:$port');
    }
    // Match the pinned native domain:port recognizer, not RustDesk account IDs.
    final domain = host.toLowerCase();
    if (domain.length > 253 ||
        !RegExp(r'^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z-]{0,61}[a-z]$')
            .hasMatch(domain)) {
      return null;
    }
    return DirectEndpoint._('$domain:$port');
  }
}
