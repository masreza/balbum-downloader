import 'package:balbum_downloader/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('keepArchiveExtension', () {
    test('keeps simple extensions', () {
      expect(keepArchiveExtension('photo.jpg'), '.jpg');
      expect(keepArchiveExtension('video.mp4'), '.mp4');
      expect(keepArchiveExtension('archive.zip'), '.zip');
    });

    test('keeps multi-part archive suffix (.001 etc)', () {
      expect(keepArchiveExtension('xxx.zip.001'), '.zip.001');
      expect(keepArchiveExtension('yyy.rar.002'), '.rar.002');
      expect(keepArchiveExtension('aaa.7z.010'), '.7z.010');
    });

    test('keeps .partN suffix', () {
      expect(keepArchiveExtension('vol.zip.part1'), '.zip.part1');
      expect(keepArchiveExtension('vol.zip.part01'), '.zip.part01');
    });

    test('no extension', () {
      expect(keepArchiveExtension('name'), '');
      expect(keepArchiveExtension(''), '');
      expect(keepArchiveExtension('  name  '), '');
    });
  });

  testWidgets('app shell renders', (tester) async {
    await tester.pumpWidget(const BalbumApp());
    expect(find.text('Balbum — Bunkr Album Downloader'), findsOneWidget);
    expect(find.text('Fetch'), findsOneWidget);
  });
}
