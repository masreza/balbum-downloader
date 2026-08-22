import 'dart:convert';
import 'dart:io';

import 'package:balbum_downloader/bunkr_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Ground-truth vectors generated with the actual decompiled Python logic
/// (gallery-dl util.decrypt_xor: base64(a2b) then XOR with key).
void main() {
  group('decryptXor (verified against gallery-dl.exe bytecode)', () {
    test('mp4 URL', () {
      const enc = 'OzE3IjZucGQjKnFQQltTIWswJ2o1MykwNCdLTRpOOiEmPRplbXhxdzJCAw==';
      const key = 'SECRET_KEY_2758';
      expect(BunkrDownloader.decryptXor(enc, key),
          'https://fs.bunkr.su/albumxyz/video_1234.mp4');
    });

    test('jpg URL', () {
      const enc = 'OzE3IjZucGQiPCsfUEU9LjEgaycqZCg8O1hTHzooJA1xZnEhNT4=';
      const key = 'SECRET_KEY_120';
      expect(BunkrDownloader.decryptXor(enc, key),
          'https://get.bunkrr.su/media/img_42.jpg');
    });
  });

  group('albumIdFromUrl', () {
    test('recognises /a/<id> forms', () {
      expect(BunkrDownloader.albumIdFromUrl('https://bunkr.cr/a/abc123XYZ'),
          'abc123XYZ');
      expect(BunkrDownloader.albumIdFromUrl('https://bunkr.ph/a/007'), '007');
    });
    test('rejects non-album', () {
      expect(BunkrDownloader.albumIdFromUrl('https://bunkr.si/f/foo.mp4'),
          isNull);
      expect(BunkrDownloader.albumIdFromUrl('not a url'), isNull);
    });
  });

  const albumPage = '''
<html><head>
<meta property="og:title" content="My &amp; Test Album"/>
<script>
window.albumFiles = [
{
  id: 'aa0001',
  original: "My First File.mp4",
  slug: "my-first-file",
  name: "thumb-aa0001.thumb.jpg",
  size:  1048576 ,
  timestamp: "12:34:56 01/02/2025"
},
{
  id: 'aa0002',
  original: "image two.jpg",
  slug: "image-two",
  name: "thumb-aa0002.thumb.jpg",
  size:  2048 ,
  timestamp: "08:00:00 03/04/2025"
},
]
</script>
</head></html>''';

  final apiBodies = {
    'aa0001': {
      'mediafiles': 'https://c2ri-b.cdn.cr',
      'path': '/storage/media/vid1.mp4',
      'original': 'My First File.mp4',
    },
    'aa0002': {
      'mediafiles': 'https://c2ri-b.cdn.cr',
      'path': '/storage/media/img2.jpg',
      'original': 'image two.jpg',
    },
  };

  group('fetchAlbum — fast list (no per-file API calls)', () {
    test('parses the list from the page only; URL resolved lazily = empty',
        () async {
      final apiHits = <String>[];
      final mock = MockClient((req) async {
        apiHits.add('${req.method} ${req.url.host}');
        if (req.method == 'GET' && req.url.host == 'bunkr.si') {
          return http.Response(albumPage, 200);
        }
        return http.Response('unexpected', 500);
      });
      final dl = BunkrDownloader(client: mock);
      final album = await dl.fetchAlbum('https://bunkr.si/a/ALBUM1');

      // No API calls made during listing — everything from the HTML page.
      expect(apiHits.where((h) => h.startsWith('POST')).length, 0);
      expect(apiHits.where((h) => h.contains('sign')).length, 0);

      expect(album.files.length, 2);
      expect(album.title, 'My & Test Album');
      expect(album.files[0].name, 'My First File.mp4');
      expect(album.files[0].slug, 'my-first-file');
      expect(album.files[0].uuid, 'thumb-aa0001');
      expect(album.files[0].size, 1048576);
      expect(album.files[0].url, ''); // resolved lazily at download time
      dl.close();
    });

    test('throws CloudflareChallengeException when all domains blocked',
        () async {
      final mock = MockClient((req) async => http.Response('', 403));
      final dl = BunkrDownloader(client: mock);
      expect(dl.fetchAlbum('https://bunkr.si/a/ALBUM1'),
          throwsA(isA<CloudflareChallengeException>()));
      dl.close();
    });
  });

  group('lazy URL resolution at download', () {
    MockClient signedMock({List<String>? idCaptures}) {
      return MockClient((req) async {
        final host = req.url.host;
        if (req.method == 'POST' && host == 'dl.bunkr.cr') {
          final id = (jsonDecode(req.body) as Map)['id'] as String;
          idCaptures?.add(id);
          expect(req.headers['Referer'], 'https://dl.bunkr.cr/');
          expect(req.headers['Origin'], 'https://dl.bunkr.cr');
          return http.Response(jsonEncode(apiBodies[id]!), 200);
        }
        if (req.method == 'GET' && host == 'glb-apisign.cdn.cr') {
          final paths = apiBodies.values.map((b) => b['path']).toSet();
          expect(paths, contains(req.url.queryParameters['path']));
          return http.Response(jsonEncode({'ex': 123, 'token': 'tok123'}), 200);
        }
        if (req.method == 'GET' && req.url.host == 'c2ri-b.cdn.cr') {
          expect(req.headers['Referer'], 'https://dl.bunkr.cr/');
          return http.Response.bytes([1, 2, 3, 4, 5], 200);
        }
        return http.Response('not found', 404);
      });
    }

    test('downloadFile with empty url signs via API then downloads', () async {
      final tmp = await Directory.systemTemp.createTemp('balbum_test');
      final ids = <String>[];
      final dl = BunkrDownloader(client: signedMock(idCaptures: ids));
      final f = BunkrFile(
          id: 'aa0001',
          name: 'My First File.mp4',
          slug: 'my-first-file',
          uuid: 'thumb-aa0001',
          size: 5,
          url: ''); // empty — must be resolved lazily
      await dl.downloadFile(f, tmp);

      expect(ids, ['aa0001']); // resolved the right data_id
      expect(f.url, isNotEmpty);
      expect(f.done, true);
      expect(File('${tmp.path}/My First File.mp4').existsSync(), true);
      dl.close();
      tmp.delete(recursive: true);
    });

    test('legacy XOR-decrypt branch still resolves during download', () async {
      final tmp = await Directory.systemTemp.createTemp('balbum_test');
      final legacyBody = {
        'url': _encrypt('https://media.example/vid.mp4', 'SECRET_KEY_3'),
        'encrypted': true,
        'timestamp': 3600 * 3 + 999,
      };
      final mock = MockClient((req) async {
        if (req.url.host == 'dl.bunkr.cr') {
          return http.Response(jsonEncode(legacyBody), 200);
        }
        if (req.url.host == 'media.example') {
          return http.Response.bytes([9, 9, 9], 200);
        }
        return http.Response('', 404);
      });
      final dl = BunkrDownloader(client: mock);
      final f = BunkrFile(
          id: 'aa0001',
          name: 'vid.mp4',
          slug: 'vid',
          uuid: 'u',
          size: 3,
          url: '');
      await dl.downloadFile(f, tmp);
      expect(f.url, 'https://media.example/vid.mp4');
      expect(f.done, true);
      expect(File('${tmp.path}/vid.mp4').existsSync(), true);
      dl.close();
      tmp.delete(recursive: true);
    });
  });

  group('downloadFile', () {
    test('writes bytes to disk with dl.bunkr.cr Referer', () async {
      final tmp = await Directory.systemTemp.createTemp('balbum_test');
      final capturedReferer = <String?>[];
      final mock = MockClient((req) async {
        capturedReferer.add(req.headers['Referer']);
        return http.Response.bytes([1, 2, 3, 4, 5], 200);
      });
      final dl = BunkrDownloader(client: mock);
      final f = BunkrFile(
          id: 'aa0009',
          name: 'blob.bin',
          slug: 'blob',
          uuid: 'u',
          size: 5,
          url: 'https://c2ri-b.cdn.cr/storage/media/x/blob.bin?ex=1&token=t&n=x');
      await dl.downloadFile(f, tmp);
      expect(f.done, true);
      expect(f.downloaded, 5);
      expect(capturedReferer.first, 'https://dl.bunkr.cr/');
      expect(File('${tmp.path}/blob.bin').existsSync(), true);
      dl.close();
      tmp.delete(recursive: true);
    });

    test('resumes from an existing .part via HTTP Range', () async {
      final tmp = await Directory.systemTemp.createTemp('balbum_test');
      // Simulate a previous partial download: 3 of 5 bytes.
      File('${tmp.path}/blob.bin.part').writeAsBytesSync([1, 2, 3]);

      String? rangeHeader;
      final mock = MockClient((req) async {
        rangeHeader = req.headers['Range'];
        return http.Response.bytes(
          [4, 5],
          206,
          headers: {
            'content-range': 'bytes 3-4/5',
          },
        );
      });
      final dl = BunkrDownloader(client: mock);
      final f = BunkrFile(
          id: 'aa0010',
          name: 'blob.bin',
          slug: 'blob',
          uuid: 'u',
          size: 5,
          url: 'https://c2ri-b.cdn.cr/storage/media/x/blob.bin?ex=1&token=t');
      await dl.downloadFile(f, tmp);

      // It must have requested the byte range from 3 onward.
      expect(rangeHeader, 'bytes=3-');
      expect(f.done, true);
      expect(File('${tmp.path}/blob.bin').lengthSync(), 5);
      expect(File('${tmp.path}/blob.bin').readAsBytesSync(), [1, 2, 3, 4, 5]);
      dl.close();
      tmp.delete(recursive: true);
    });
  });

  group('BunkrFile.isMedia filter', () {
    BunkrFile mk(String name) => BunkrFile(
        id: 'x', name: name, slug: 's', uuid: 'u', size: 1, url: '');

    test('recognizes pictures', () {
      expect(mk('photo.jpg').isMedia, true);
      expect(mk('photo.jpg').isPicture, true);
      expect(mk('scanned.PNG').isMedia, true);
      expect(mk('art.webp').isMedia, true);
    });

    test('recognizes videos', () {
      expect(mk('clip.mp4').isMedia, true);
      expect(mk('clip.mp4').isVideo, true);
      expect(mk('movie.MKV').isMedia, true);
      expect(mk('vid.webm').isMedia, true);
    });

    test('pictures are not videos and vice-versa', () {
      expect(mk('photo.jpg').isVideo, false);
      expect(mk('clip.mp4').isPicture, false);
    });

    test('rejects non-media files', () {
      expect(mk('document.pdf').isMedia, false);
      expect(mk('archive.zip').isMedia, false);
      expect(mk('blob.bin').isMedia, false);
    });

    test('multi-part archives are not media', () {
      expect(mk('video.mp4.001').isMedia, false);
    });
  });
}

/// base64(xor(plain, key)) — mirrors the legacy API's encrypt side.
String _encrypt(String plain, String key) {
  final kb = ascii.encode(key);
  final out = List<int>.generate(
      plain.length, (i) => plain.codeUnitAt(i) ^ kb[i % kb.length]);
  return base64.encode(out);
}