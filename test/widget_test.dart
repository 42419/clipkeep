import 'package:flutter_test/flutter_test.dart';
import 'package:clipkeep/routes/app_router.dart';

void main() {
  testWidgets('app builds and shows home', (tester) async {
    await tester.pumpWidget(getRootWidget());
    expect(find.text('ClipKeep'), findsOneWidget);
  });
}
