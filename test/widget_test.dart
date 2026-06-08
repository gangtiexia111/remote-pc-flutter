import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pc/main.dart';

void main() {
  testWidgets('App renders smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const RemotePcApp());
    expect(find.text('Remote PC Control'), findsOneWidget);
  });
}
