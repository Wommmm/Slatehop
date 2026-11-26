import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/rental_password_settings.dart';
import 'package:flutter_hbb/models/rental_validity.dart';
import 'package:flutter_test/flutter_test.dart';

const _runner = '/Library/SlateHopHost/RustDesk.app/Contents/MacOS/RustDesk';

void main() {
  test('accepts the real single-line UTC expiry and explicit no-rental status',
      () {
    final result = LocalRentalStatus.fromCommandResult(0, '1893456000000\n');
    expect(result.state, LocalRentalState.configured);
    expect(result.validUntilUtc, DateTime.utc(2030));
    expect(LocalRentalStatus.fromCommandResult(0, 'unconfigured\n').state,
        LocalRentalState.unconfigured);
  });

  test('reports failures and unexpected output as unavailable without dates',
      () {
    for (final output in [
      '',
      'unconfigured\n\n',
      '1893456000000\n\n',
      '1893456000000\nlog message',
      '1893456000000 ',
      '0',
      '-1',
      '253402300800000',
    ]) {
      final result = LocalRentalStatus.fromCommandResult(0, output);
      expect(result.state, LocalRentalState.unavailable, reason: output);
      expect(result.validUntilUtc, isNull);
    }
    expect(LocalRentalStatus.fromCommandResult(1, '1893456000000\n').state,
        LocalRentalState.unavailable);
  });

  testWidgets('renders a real deadline without a demo or administration action',
      (tester) async {
    final result = LocalRentalStatus.fromCommandResult(0, '1893456000000\n');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RentalPasswordSettings(
          hostExecutable: _runner,
          readStatus: (executable) async {
            expect(executable, _runner);
            return result;
          },
          translateLabel: (label) => label,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(
        find.textContaining(RentalValidity.formatDeadline(DateTime.utc(2030))),
        findsOneWidget);
    expect(find.text('Open host administration'), findsNothing);
    expect(find.text('Open demo'), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('refresh distinguishes no configured rental from unavailable',
      (tester) async {
    var status = const LocalRentalStatus.unconfigured();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RentalPasswordSettings(
          hostExecutable: _runner,
          readStatus: (_) async => status,
          translateLabel: (label) => label,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No rental is configured for this Mac account.'),
        findsOneWidget);

    status = const LocalRentalStatus.unavailable();
    await tester.tap(find.text('Refresh rental status'));
    await tester.pumpAndSettle();
    expect(find.text('Rental status is unavailable.'), findsOneWidget);
    expect(find.textContaining('UTC'), findsNothing);
  });
}
