import 'package:balbum_downloader/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app shell renders', (tester) async {
    await tester.pumpWidget(const BalbumApp());
    expect(find.text('Balbum — Bunkr Album Downloader'), findsOneWidget);
    expect(find.text('Fetch'), findsOneWidget);
  });
}
