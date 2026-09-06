import 'package:flutter_test/flutter_test.dart';

import 'package:nexus_player/main.dart';

void main() {
  testWidgets('Nexus Player opens the offline library', (tester) async {
    await tester.pumpWidget(const NexusPlayerApp());
    expect(find.text('NEXUS PLAYER'), findsOneWidget);
  });
}
