import 'package:flutter_test/flutter_test.dart';

import 'package:plantie_android/app.dart';

void main() {
  testWidgets('shows Plantie dashboard shell', (WidgetTester tester) async {
    await tester.pumpWidget(const PlantieApp());

    expect(find.text('Plantie Monitor'), findsOneWidget);
    expect(find.text('Saved Devices'), findsOneWidget);
    expect(find.text('Discovered Nearby Devices'), findsOneWidget);
  });
}
