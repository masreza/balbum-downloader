import 'package:balbum_downloader/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('keepArchiveExtension', () {
    test('keeps simple extensions', () {
      expect(keepArchiveExtension('photo.jpg'), '.jpg');
      expect(keepArchiveExtension('video.mp4'), '.mp4');
      expect(keepArchiveExtension('archive.zip'), '.zip');
    });

    test('only .001-style numeric suffix is special-cased', () {
      expect(keepArchiveExtension('xxx.zip.001'), '.zip.001');
      expect(keepArchiveExtension('yyy.rar.002'), '.rar.002');
      expect(keepArchiveExtension('aaa.7z.010'), '.7z.010');
      // .partN is a normal extension, not special-cased
      expect(keepArchiveExtension('vol.zip.part01'), '.part01');
      expect(keepArchiveExtension('vol.zip.part1'), '.part1');
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
