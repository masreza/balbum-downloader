import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;

/// Thrown when the user requests a stop mid-download. Partial bytes are kept.
class _StoppedException implements Exception {
  final String message;
  _StoppedException([this.message = 'stopped']);
  @override
  String toString() => message;
}

/// Bunkr album downloader.
///
/// The original gallery-dl.exe embedded an OLD Bunkr protocol (API returned an
/// XOR-encrypted `url`). That scheme now returns unsigned URLs that the CDN
/// rejects with 403. Current Bunkr requires a SIGNED URL:
///   1. POST `root_api/api/_001_v2` with `{"id": data_id}`
///        -> `{"mediafiles": <cdn base>, "path": "/storage/media/...", "original": <name>}`
///   2. GET  `root_sign/sign?path=<path>`
///        -> `{"ex": ..., "token": ...}`
///   3. download `mediafiles+path` with `ex`/`token`/`n` query params
/// Only the album-page scraping is shared with the old scheme.

const String _rootApi = 'https://dl.bunkr.cr'; // API host (headers + endpoint)
const String _apiReferer = 'https://dl.bunkr.cr/'; // Referer for API/sign/download
const String _endpoint = '$_rootApi/api/_001_v2';
const String _signEndpoint = 'https://glb-apisign.cdn.cr/sign';

/// Coordinate domains used as fallback when the primary domain is
/// Cloudflare-challenge-gated.
const List<String> _domains = [
  'bunkr.ac', 'bunkr.ci', 'bunkr.cr', 'bunkr.fi', 'bunkr.ph', 'bunkr.pk',
  'bunkr.ps', 'bunkr.si', 'bunkr.sk', 'bunkr.ws', 'bunkr.black', 'bunkr.red',
  'bunkr.media', 'bunkr.site',
];

/// Extract the file extension (e.g. ".mp4") from a URL path.
String _extFromUrl(String url) {
  try {
    final p = Uri.parse(url).path;
    final i = p.lastIndexOf('.');
    if (i >= 0 && p.indexOf('/', i) == -1) return p.substring(i);
  } catch (_) {}
  return '';
}

/// A single file in a Bunkr album.
class BunkrFile {
  final String id; // data_id, used for /file/<id> referer + API
  String name; // original filename
  String slug;
  String uuid;
  int size; // bytes
  String? date;
  String url; // resolved, decrypted download URL

  // download state
  int downloaded = 0;
  bool done = false;
  bool error = false;
  String? errorMsg;

  BunkrFile({
    required this.id,
    required this.name,
    required this.slug,
    required this.uuid,
    required this.size,
    this.date,
    required this.url,
  });

  /// Filename to save on disk. Prefer the original name, else build one.
  String get safeName =>
      name.trim().isEmpty ? '$slug${_extFromUrl(url)}' : name.trim();
}

class BunkrAlbum {
  final String id;
  final String title;
  final List<BunkrFile> files;
  BunkrAlbum({required this.id, required this.title, required this.files});
}

/// Raised when every Bunkr coordinate domain is behind a CF challenge.
class CloudflareChallengeException implements Exception {
  final String message;
  CloudflareChallengeException([this.message = '']);
  @override
  String toString() => message.isEmpty
      ? 'All Bunkr domains require solving a Cloudflare challenge.'
      : message;
}

class BunkrDownloader {
  final http.Client _client;
  BunkrDownloader({http.Client? client})
      : _client = client ?? _createClient();

  /// Build a client that won't kill long/slow downloads: Dart's HttpClient
  /// defaults to a 15s idle timeout, which drops healthy-but-slow transfers.
  static http.Client _createClient() {
    final hc = HttpClient();
    hc.connectionTimeout = const Duration(seconds: 30);
    hc.idleTimeout = Duration.zero; // never time out an alive stream
    return http_io.IOClient(hc);
  }

  /// Parse a bunkr album URL ending in `/a/{id}` and return the album id.
  static String? albumIdFromUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    final segs = uri.pathSegments;
    for (int i = 0; i < segs.length - 1; i++) {
      if (segs[i] == 'a') {
        final id = segs[i + 1];
        return id.isEmpty ? null : id;
      }
    }
    return null;
  }

  static String? hostFromUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return null;
    return uri.host;
  }

  // ---------------------------------------------------------------------------
  // Album fetch + parse (mirrors fetch_album + _extract_files)
  // ---------------------------------------------------------------------------

  Future<BunkrAlbum> fetchAlbum(String url, {bool Function()? isStopped}) async {
    final id = albumIdFromUrl(url);
    if (id == null) {
      throw ArgumentError('Not a valid Bunkr album URL (need /a/<id>): $url');
    }
    final host = hostFromUrl(url) ?? 'bunkr.si';

    // Try the user's domain first, then every coordinate domain as fallback.
    final candidates = <String>[host, ..._domains.where((d) => d != host)];

    String? page;
    for (final h in candidates) {
      final tryPage = await _tryGet('https://$h/a/$id?advanced=1');
      if (tryPage != null) {
        // must contain the albumFiles blob to be a real album page
        if (tryPage.contains('window.albumFiles = [')) {
          page = tryPage;
          break;
        }
      }
    }
    if (page == null) {
      throw CloudflareChallengeException();
    }

    final title = _unescape(_unescape(
        _extr(page, 'property="og:title" content="', '"')));
    final raw = _extr(page, 'window.albumFiles = [', '</script>');
    if (raw.isEmpty) {
      throw StateError('Album page parsed but no albumFiles blob found.');
    }
    final items = raw.split('\n},\n');

    final files = <BunkrFile>[];
    final seen = <String>{};
    for (final item in items) {
      if (isStopped?.call() ?? false) break;
      // data_id may be quoted or bare in the page; strip whitespace + quotes.
      var dataId = _extr(item, ' id: ', ',').trim();
      while (dataId.length >= 2 &&
          ((dataId.startsWith("'") && dataId.endsWith("'")) ||
              (dataId.startsWith('"') && dataId.endsWith('"')))) {
        dataId = dataId.substring(1, dataId.length - 1).trim();
      }
      if (dataId.isEmpty || seen.contains(dataId)) continue;
      seen.add(dataId);

      final name = _jsonLoads(
          _extr(item, 'original:', ',\n').replaceAll("\\'", "'"));
      final slug = _jsonLoads(
          _extr(item, 'slug: ', ',\n').replaceAll("\\'", "'"));
      final uuid = _extr(item, 'name: "', '.');
      final size = _parseInt(_extr(item, 'size:  ', ',\n'));
      final date = _extr(item, 'timestamp: "', '"');

      // Resolve the real download URL via the API (one POST per file).
      final urlResolved = await _resolveFile(dataId);
      files.add(BunkrFile(
        id: dataId,
        name: name,
        slug: slug,
        uuid: uuid,
        size: size,
        date: date.isEmpty ? null : date,
        url: urlResolved,
      ));
      // gentle throttle between per-file API calls to avoid rate limiting
      if (items.length > 20) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }

    return BunkrAlbum(id: id, title: title, files: files);
  }

  /// GET helper with CF-fallback: returns body on success, null if blocked.
  Future<String?> _tryGet(String url) async {
    try {
      final resp = await _client
          .get(Uri.parse(url), headers: _browserHeaders())
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return null;
      final body = resp.body;
      // A 403-page / empty body means CF challenge -> try next domain
      if (body.isEmpty) return null;
      return body;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  /// Perform an API/sign request with automatic backoff+retry on HTTP 429
  /// (rate limit). Respects the server's `Retry-After` header when present.
  Future<http.Response> _api(String method, Uri url,
      {Map<String, String>? headers, String? body}) async {
    for (int attempt = 0; attempt < 5; attempt++) {
      final resp = await (method == 'POST'
              ? _client.post(url, headers: headers, body: body)
              : _client.get(url, headers: headers))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 429) return resp;
      final ra = resp.headers['retry-after'];
      final wait = (ra != null ? int.tryParse(ra) : null) ?? (1 + attempt * 2);
      await Future<void>.delayed(Duration(seconds: wait));
    }
    return method == 'POST'
        ? await _client.post(url, headers: headers, body: body)
            .timeout(const Duration(seconds: 30))
        : await _client.get(url, headers: headers)
            .timeout(const Duration(seconds: 30));
  }

  /// Resolve a file's signed download URL (current Bunkr scheme).
  ///
  /// Mirrors gallery-dl's current `_extract_file`:
  ///   1. POST `api/_001_v2` `{id}` -> `{mediafiles, path, original}`
  ///   2. GET  `sign?path=` + path -> `{ex, token}`
  ///   3. final = mediafiles + path + "?ex=&token=&n=&lt;original&gt;"
  /// Falls back to the old XOR-decrypt scheme if a stale API still returns
  /// `{encrypted, url}`.
  Future<String> _resolveFile(String dataId) async {
    final headers = <String, String>{
      'Referer': _apiReferer,
      'Origin': _rootApi,
      ..._browserHeaders(),
    };

    final resp = await _api(
      'POST',
      Uri.parse(_endpoint),
      headers: {...headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'id': dataId}),
    );
    if (resp.statusCode != 200) {
      throw HttpException('API /api/_001_v2 returned HTTP ${resp.statusCode}',
          uri: Uri.parse(_endpoint));
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;

    // New signed-URL scheme: {mediafiles, path, original}
    if (data['path'] is String && data['mediafiles'] is String) {
      final signResp = await _api(
        'GET',
        Uri.parse(_signEndpoint).replace(
            queryParameters: {'path': data['path'] as String}),
        headers: headers,
      );
      if (signResp.statusCode != 200) {
        throw HttpException('Sign endpoint returned HTTP ${signResp.statusCode}',
            uri: Uri.parse(_signEndpoint));
      }
      final sign = jsonDecode(signResp.body) as Map<String, dynamic>;
      final query = <String, String>{
        if (sign['ex'] != null) 'ex': '${sign['ex']}',
        if (sign['token'] != null) 'token': '${sign['token']}',
      };
      final original = data['original'];
      if (original is String && original.isNotEmpty) {
        query['n'] = original;
      }
      final base = data['mediafiles'] as String;
      final path = data['path'] as String;
      return Uri.parse('$base$path')
          .replace(queryParameters: query)
          .toString();
    }

    // Legacy XOR-decrypt scheme: {encrypted, url}
    final String url;
    if (data['encrypted'] == true || data['encrypted'] == 1) {
      final key =
          'SECRET_KEY_${(data['timestamp'] as num).toInt() ~/ 3600}';
      url = decryptXor(data['url'] as String, key);
    } else if (data['url'] is String) {
      url = data['url'] as String;
    } else {
      throw StateError('API response had no usable URL: ${data.keys}');
    }
    return url;
  }

  /// Download a single file, resuming from any partially-downloaded `.part`
  /// file. Long/slow connections that get dropped are automatically retried
  /// (via HTTP `Range`) instead of failing the whole file.
  /// If [isStopRequested] turns true mid-stream, the download aborts cleanly
  /// and the partial bytes are kept as `.part` (no error flag set).
  Future<void> downloadFile(BunkrFile f, Directory dir,
      {void Function(int current, int total)? onProgress,
      bool Function()? isStopRequested}) async {
    final dest = File('${dir.path}${Platform.pathSeparator}${f.safeName}');
    final part = File('${dir.path}${Platform.pathSeparator}${f.safeName}.part');

    // Already fully present?
    if (f.size > 0 && dest.existsSync() && dest.lengthSync() >= f.size) {
      f.done = true;
      f.downloaded = f.size;
      return;
    }

    // Existing partial already larger than the target -> corrupt, restart.
    int have = part.existsSync() ? part.lengthSync() : 0;
    if (f.size > 0 && have > f.size) {
      try {
        part.deleteSync();
      } catch (_) {}
      have = 0;
    }
    f.downloaded = have;

    // The fetched URL is already fresh (2h token). Only re-sign if it's
    // missing or will expire soon — avoids redundant /sign calls that can
    // trigger rate limiting on large albums.
    if (!_tokenFresh(f.url)) {
      f.url = await _freshUrl(f);
    }

    const maxTries = 8;
    bool done = false;
    bool stopped = false;
    for (int attempt = 0; attempt < maxTries && !done; attempt++) {
      if (isStopRequested?.call() ?? false) {
        stopped = true;
        break;
      }
      f.error = false;
      f.errorMsg = null;
      try {
        final ok =
            await _streamRange(f, part, have, onProgress, isStopRequested);
        if (ok) {
          done = true;
          break;
        }
        // A 403 usually means the signed token expired mid-download ->
        // re-sign and retry with a fresh URL instead of giving up.
        if ((f.errorMsg ?? '').contains('403')) {
          f.url = await _freshUrl(f);
          have = part.existsSync() ? part.lengthSync() : 0;
          f.downloaded = have;
          continue;
        }
        // other permanent failure (maintenance, 404, …) — no retry
        break;
      } on _StoppedException {
        // user pressed Stop — keep partial, no error
        have = part.existsSync() ? part.lengthSync() : 0;
        f.downloaded = have;
        stopped = true;
        break;
      } on Exception {
        // connection dropped / timed out mid-stream -> resume from what we got
        have = part.existsSync() ? part.lengthSync() : 0;
        f.downloaded = have;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    if (done) {
      if (dest.existsSync()) {
        try {
          dest.deleteSync();
        } catch (_) {}
      }
      await part.rename(dest.path);
      f.downloaded = dest.existsSync() ? dest.lengthSync() : f.downloaded;
      f.done = true;
      f.error = false;
      f.errorMsg = null;
    } else if (!stopped && !f.error) {
      f.error = true;
      f.errorMsg =
          'Connection dropped (${f.downloaded} bytes). Part saved — tap Download to resume.';
    }
  }

  /// Resolve a fresh signed URL for [f] (new token). Falls back to the current
  /// URL if the API/sign call fails, so a hiccup never breaks the download.
  Future<String> _freshUrl(BunkrFile f) async {
    try {
      return await _resolveFile(f.id);
    } catch (_) {
      return f.url;
    }
  }

  /// True if the signed URL's `ex` token is still valid for at least
  /// [marginSeconds]. Unknown token -> false (so we re-sign).
  bool _tokenFresh(String url, [int marginSeconds = 300]) {
    try {
      final ex = int.tryParse(Uri.parse(url).queryParameters['ex'] ?? '');
      if (ex == null) return false;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return ex - now > marginSeconds;
    } catch (_) {
      return false;
    }
  }

  /// Stream one range segment. Returns true when the file is fully received,
  /// false on permanent failure (sets [f.error]); throws on retryable
  /// connection errors so the caller can resume.
  Future<bool> _streamRange(BunkrFile f, File part, int fromBytes,
      void Function(int current, int total)? onProgress,
      bool Function()? isStopRequested) async {
    final req = http.Request('GET', Uri.parse(f.url));
    req.headers.addAll({..._browserHeaders(), 'Referer': _apiReferer});
    if (isStopRequested?.call() ?? false) {
      throw const _StoppedException();
    }
    if (fromBytes > 0) {
      req.headers['Range'] = 'bytes=$fromBytes-';
    }

    final streamed = await _client
        .send(req)
        .timeout(const Duration(seconds: 90));

    // maintenance-mode redirect
    final finalUrl = streamed.request?.url.toString() ?? f.url;
    if (streamed.statusCode >= 300 && streamed.statusCode < 400 &&
        finalUrl.endsWith('/maintenance-vid.mp4')) {
      await streamed.stream.drain<void>();
      f.error = true;
      f.errorMsg = 'File server in maintenance mode';
      return false;
    }

    // rate-limited: back off and let the caller retry (resuming the range)
    if (streamed.statusCode == 429) {
      await streamed.stream.drain<void>();
      final ra = streamed.headers['retry-after'];
      final wait = (ra != null ? int.tryParse(ra) : null) ?? 5;
      await Future<void>.delayed(Duration(seconds: wait));
      throw const SocketException('Rate limited (429), retrying');
    }

    // Determine start offset + total from response headers so we never
    // finalize a partial file just because the album-listed size was 0/missing.
    // Priority: Content-Range total (206) > Content-Length (200) > f.size.
    var start = 0;
    var total = f.size;
    if (streamed.statusCode == 206) {
      start = fromBytes;
      final cr = streamed.headers['content-range'];
      final m = cr == null ? null : RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(cr);
      if (m != null) {
        start = int.parse(m.group(1)!);
        total = int.parse(m.group(3)!);
      } else {
        final cl = int.tryParse(streamed.headers['content-length'] ?? '');
        if (cl != null && cl > 0) total = cl;
      }
    } else if (streamed.statusCode == 200) {
      final cl = int.tryParse(streamed.headers['content-length'] ?? '');
      if (cl != null && cl > 0) total = cl;
    }

    if (streamed.statusCode != 200 && streamed.statusCode != 206) {
      await streamed.stream.drain<void>();
      f.error = true;
      f.errorMsg = 'HTTP ${streamed.statusCode}';
      return false; // permanent
    }

    // If the server ignored our Range (200) but we already have bytes, restart.
    final append = streamed.statusCode == 206;
    final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
    var received = 0;
    var stopped = false;
    try {
      // takeWhile stops + cancels the upstream socket the moment stop is hit
      await for (final chunk
          in streamed.stream.takeWhile((_) {
        stopped = isStopRequested?.call() ?? false;
        return !stopped;
      })) {
        sink.add(chunk);
        received += chunk.length;
        f.downloaded = start + received;
        onProgress?.call(f.downloaded, total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (stopped) {
      throw const _StoppedException();
    }

    f.downloaded = start + received;
    final got = part.lengthSync();
    // If we know the total and fell short, the server dropped the stream early.
    if (total > 0 && got < total) {
      throw const SocketException('Stream ended early, resumable');
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Decompiled helpers
  // ---------------------------------------------------------------------------

  /// base64-decode then XOR with key (mirrors util.decrypt_xor,
  /// defaults base64=True, fromhex=False).
  static String decryptXor(String encrypted, String key) {
    final enc = base64.decode(encrypted);
    final kb = ascii.encode(key);
    final out = List<int>.generate(
        enc.length, (i) => enc[i] ^ kb[i % kb.length]);
    return utf8.decode(out);
  }

  /// text.extr: substring of [txt] between [begin] and [end].
  static String _extr(String txt, String begin, String end,
      [String default_ = '']) {
    final i = txt.indexOf(begin);
    if (i < 0) return default_;
    final first = i + begin.length;
    final j = txt.indexOf(end, first);
    if (j < 0) return default_;
    return txt.substring(first, j);
  }

  static int _parseInt(String value, [int default_ = 0]) {
    final n = int.tryParse(value.trim());
    return n ?? default_;
  }

  static String _unescape(String value) {
    // Minimal HTML entity unescaper sufficient for og:title / names.
    const map = {
      '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"',
      '&#39;': "'", '&apos;': "'", '&nbsp;': ' ',
    };
    var out = value;
    map.forEach((k, v) => out = out.replaceAll(k, v));
    // numeric entities &#NN; &#xHH;
    out = out.replaceAllMapped(
        RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
      final base = m.group(1)!.toLowerCase();
      final code = int.parse(m.group(2)!, radix: base == 'x' ? 16 : 10);
      return String.fromCharCode(code);
    });
    return out;
  }

  static String _jsonLoads(String value) {
    var s = value.trim();
    if (s.startsWith('"') && s.endsWith('"')) {
      try {
        return jsonDecode(s) as String;
      } catch (_) {
        return s.substring(1, s.length - 1);
      }
    }
    // bare string value
    if (s.startsWith("'") && s.endsWith("'")) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  static Map<String, String> _browserHeaders() => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/json,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      };

  void close() => _client.close();
}
