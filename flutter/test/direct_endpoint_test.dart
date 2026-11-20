import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/direct_endpoint.dart';

void main() {
  test('canonical addresses deduplicate without modifying source records', () {
    final records = [
      'EXAMPLE.com',
      'example.com:021118',
      '192.0.2.1',
      '192.0.2.1:21118',
      '[::1]',
      '[0:0:0:0:0:0:0:1]:21118'
    ];
    expect(DirectEndpoint.uniqueRecent(records, (s) => s),
        ['EXAMPLE.com', '192.0.2.1', '[::1]']);
    expect(records.length, 6);
  });
  test('invalid transport/relay syntax and ports are rejected', () {
    for (final value in [
      '',
      '123456789',
      'https://example.com',
      'example.com/r',
      'example.com:0',
      'example.com:65536',
      'example.com:notaport',
      'user@example.com'
    ]) {
      expect(DirectEndpoint.tryParse(value), isNull, reason: value);
    }
    expect(DirectEndpoint.tryParse('example.com:1')!.address, 'example.com:1');
    expect(DirectEndpoint.tryParse('example.com:65535')!.address,
        'example.com:65535');
  });
}
