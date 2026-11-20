import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/saved_connection.dart';

void main() {
  test('canonical endpoint and optional name produce local non-secret metadata',
      () {
    final a = SavedConnectionAttempt(' EXAMPLE.com:021118 ', '', false);
    expect(a.address, 'example.com:21118');
    expect(a.name, a.address);
    final data = jsonDecode(a.loginMethod.substring('rd-direct-v1:'.length));
    expect(data, {'name': 'example.com:21118', 'remember': false});
  });
  test('equivalent endpoint is not an address edit; changed target is explicit',
      () {
    expect(
        SavedConnectionAttempt.addressChanged(
            'EXAMPLE.com', 'example.com:21118'),
        isFalse);
    expect(
        SavedConnectionAttempt.addressChanged(
            'example.com', 'other.example.com'),
        isTrue);
    final a = SavedConnectionAttempt('other.example.com', ' Work ', true,
        replaceFrom: 'example.com:21118');
    expect(a.name, 'Work');
    expect(
        jsonDecode(
            a.loginMethod.substring('rd-direct-v1:'.length))['replace_from'],
        'example.com:21118');
  });
}
