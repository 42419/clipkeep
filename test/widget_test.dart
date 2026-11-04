import 'package:flutter_test/flutter_test.dart';
import 'package:clipkeep/main.dart';

void main() {
  testWidgets('app builds and shows ClipKeep title', (tester) async {
    await tester.pumpWidget(const ClipKeepApp());
    expect(find.text('ClipKeep'), findsOneWidget);
  });
}
