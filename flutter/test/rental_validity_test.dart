import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/rental_validity.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';

void main() {
  test('timestamp boundaries are display data, never local authorization', () {
    for (final value in ['0', '1', '1735689600000', '8640000000000000']) {
      final rental = RentalValidity.fromPeerMetadata(value, 'valid');
      expect(rental.validUntilUtc!.millisecondsSinceEpoch, int.parse(value));
      expect(rental.validUntilUtc!.isUtc, isTrue);
      expect(rental.isOutsideValidity, isFalse);
      expect(rental.deadlineLabel((s) => s), contains('UTC'));
    }
    for (final value in [
      null,
      '',
      '-1',
      '1.2',
      ' 123',
      '123 ',
      'nope',
      '8640000000000001',
      '99999999999999999999999999',
      123,
      {},
      []
    ]) {
      final rental = RentalValidity.fromPeerMetadata(value, 'out_of_validity');
      expect(rental.validUntilUtc, isNull, reason: '$value');
      expect(rental.isOutsideValidity, isTrue);
      expect(rental.deadlineLabel((s) => s),
          contains('rd-direct-validity-unknown'));
    }
    expect(RentalValidity.fromPeerMetadata('1', '').isOutsideValidity, isFalse);
    expect(
        RentalValidity.fromPeerMetadata('8640000000000000', 'out_of_validity')
            .isOutsideValidity,
        isTrue);
  });

  test(
      'authenticated metadata replaces a denial; legacy/malformed stays unknown',
      () {
    final valid = RentalValidity.fromAuthenticatedPeerInfo(
        '{"rental_valid_until_ms":"1735689600000"}');
    expect(valid.status, RentalValidityStatus.valid);
    expect(valid.validUntilUtc, DateTime.utc(2025));
    for (final value in [
      null,
      '',
      '{',
      'null',
      '[]',
      '{}',
      {'rental_valid_until_ms': 123},
      {'rental_valid_until_ms': 'invalid'}
    ]) {
      final rental = RentalValidity.fromAuthenticatedPeerInfo(value);
      expect(rental.validUntilUtc, isNull);
      expect(rental.status, RentalValidityStatus.unknown);
    }
  });

  test(
      'native record fixtures preserve identity, successful time and saved fields',
      () {
    final fixture = <String, dynamic>{
      'id': 'example.com:21118',
      'alias': 'Mac mini',
      'rd_direct_last_success': '1735600000',
      'hash': 'synthetic-hash',
      'password': 'synthetic-only',
      'rd_direct_valid_until': '1735689600000',
      'rd_direct_validity_status': 'valid'
    };
    final before = Peer.fromJson(fixture);
    final denied = Peer.fromJson(
        {...fixture, 'rd_direct_validity_status': 'out_of_validity'});
    expect(before.equal(denied), isFalse);
    expect(denied.rentalValidity.isOutsideValidity, isTrue);
    for (final key in [
      'id',
      'alias',
      'rd_direct_last_success',
      'hash',
      'password'
    ]) {
      expect(denied.toJson()[key], before.toJson()[key]);
    }
    expect(Peer.copy(denied).equal(denied), isTrue);
    expect(Peer.fromJson(denied.toJson()).equal(denied), isTrue);
    final renewed =
        Peer.fromJson({...fixture, 'rd_direct_valid_until': '1893456000000'});
    expect(renewed.rentalValidity.isOutsideValidity, isFalse);
    expect(renewed.equal(before), isFalse);
    final legacy =
        Peer.fromJson({'id': fixture['id'], 'rd_direct_valid_until': 1});
    expect(legacy.rentalValidity.validUntilUtc, isNull);
    expect(legacy.rentalValidity.status, RentalValidityStatus.unknown);
    expect(before.toJson()['rd_direct_validity_status'], 'valid');
  });

  testWidgets(
      'saved-card summary shows deadline and distinct denial in eight languages',
      (tester) async {
    const labels = [
      '不在有效期内',
      '不在有效期內',
      'Outside the validity period',
      '有効期間外です',
      '유효 기간이 아닙니다',
      'Außerhalb des Gültigkeitszeitraums',
      'Hors de la période de validité',
      'Вне срока действия'
    ];
    for (final label in labels) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(
                  child: SizedBox(
                      width: 130,
                      height: 120,
                      child: RentalValiditySummary(
                        validity: RentalValidity.fromPeerMetadata(
                            '1735689600000', 'out_of_validity'),
                        style: const TextStyle(fontSize: 11),
                        translateLabel: (key) =>
                            key == 'rd-direct-out-of-validity' ? label : '截止时间',
                      ))))));
      expect(find.text(label), findsOneWidget);
      expect(find.textContaining('UTC'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RentalValiditySummary(
                validity: const RentalValidity(),
                translateLabel: (key) => key))));
    expect(find.textContaining('rd-direct-validity-unknown'), findsOneWidget);
    expect(find.text('rd-direct-out-of-validity'), findsNothing);
  });
}
