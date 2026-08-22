import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'bunkr_client.dart';

void main() {
  runApp(const BalbumApp());
}

class BalbumApp extends StatelessWidget {
  const BalbumApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Balbum — Bunkr Album Downloader',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        useMaterial3: true,
      ),
      home: const DownloaderPage(),
    );
  }
}

class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key});
  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage> {
  final _client = BunkrDownloader();
  final _urlCtrl = TextEditingController();
  final _dirCtrl = TextEditingController();

  bool _loading = false;
  bool _downloading = false;
  bool _stopRequested = false;
  bool _mediaOnly = false; // only download pictures & videos when true
  int _currentFile = 0; // 1-based index of the file currently downloading
  String? _status;
  BunkrAlbum? _album;
  String? _error;

  @override
  void dispose() {
    _client.close();
    _urlCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Please paste a Bunkr album URL.');
      return;
    }
    setState(() {
      _loading = true;
      _stopRequested = false;
      _error = null;
      _status = 'Fetching album…';
      _album = null;
    });
    try {
      final album =
          await _client.fetchAlbum(url, isStopped: () => _stopRequested);
      if (_stopRequested) {
        setState(() {
          _loading = false;
          _status = 'Stopped.';
        });
        return;
      }
      setState(() {
        _album = album;
        _status =
            'Album: ${album.title.isEmpty ? album.id : album.title} — '
            '${album.files.length} file(s)';
        _loading = false;
      });
      // auto-download as soon as the list is ready — no extra press needed
      if (album.files.isNotEmpty && !_stopRequested) {
        await _downloadAll();
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to load album: $e';
        _status = null;
      });
    }
  }

  Future<void> _pickFolder() async {
    final dir = await getDirectoryPath(
      initialDirectory: _dirCtrl.text.trim().isEmpty ? null : _dirCtrl.text.trim(),
    );
    if (dir != null) {
      setState(() => _dirCtrl.text = dir);
    }
  }

  /// Resolve the base output directory from the "Save to" field, prompting the
  /// user with the native folder picker if it's empty. Returns null if the user
  /// cancels.
  Future<Directory?> _resolveOutDir() async {
    var path = _dirCtrl.text.trim();
    if (path.isEmpty) {
      final p = await getDirectoryPath();
      if (p == null) return null;
      path = p;
      setState(() => _dirCtrl.text = p);
    }
    return Directory(path);
  }

  Future<void> _downloadAll() async {
    final album = _album;
    if (album == null) return;
    final out = await _resolveOutDir();
    if (out == null) return;
    // save directly into the chosen folder (no album subfolder)
    await out.create(recursive: true);

    // honor the media-only filter
    final targets = _mediaOnly ? album.files.where((f) => f.isMedia).toList() : List.of(album.files);
    if (targets.isEmpty) {
      if (!mounted) return;
      setState(() => _error = 'No files match the current filter.');
      return;
    }

    setState(() {
      _downloading = true;
      _stopRequested = false;
      _currentFile = 1;
      for (final f in album.files) {
        f.downloaded = 0;
        f.done = false;
        f.error = false;
        f.errorMsg = null;
      }
      _error = null;
    });

    try {
      final key = album.id;
      var stopped = false;
      for (var i = 0; i < targets.length; i++) {
        if (_stopRequested) {
          stopped = true;
          break;
        }
        final f = targets[i];
        setState(() => _currentFile = i + 1);
        // prefix the original filename with the album id: ALBUMID_original
        f.name = '${key}_${f.originalName}';
        // keep going even if one file fails — never stop the whole batch
        try {
          await _client.downloadFile(f, out,
              onProgress: (cur, total) => setState(() {}),
              isStopRequested: () => _stopRequested);
        } catch (e) {
          if (!mounted) return;
          setState(() {
            f.error = true;
            f.errorMsg = f.errorMsg ?? 'Download error: $e';
          });
        }
      }
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _status = stopped
            ? 'Stopped. ${album.files.where((f) => f.done).length} done, '
                'partial files kept as .part.'
            : 'Finished. ${album.files.where((f) => f.done).length} '
                'downloaded to ${out.path}';
      });
      if (!stopped) {
        await _showCompleteDialog(album, out);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = 'Download error: $e';
      });
    }
  }

  /// Re-download (resume) a single failed file.
  Future<void> _retryFile(BunkrFile f) async {
    final out = await _resolveOutDir();
    if (out == null) return;
    await out.create(recursive: true);
    if (!mounted) return;
    setState(() {
      f.error = false;
      f.errorMsg = null;
      f.done = false;
    });
    try {
      await _client.downloadFile(f, out,
          onProgress: (cur, total) {
        if (mounted) setState(() {});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        f.error = true;
        f.errorMsg = f.errorMsg ?? 'Download error: $e';
      });
    }
    if (!mounted) return;
    setState(() {});
  }

  /// Popup shown when every file has been processed.
  Future<void> _showCompleteDialog(BunkrAlbum album, Directory dir) async {
    final ok = album.files.where((f) => f.done).length;
    final failed = album.files.where((f) => f.error).length;

    final String title;
    final String body;
    if (ok > 0 && failed == 0) {
      title = 'Download complete';
      body = '$ok file(s) downloaded.';
    } else if (ok > 0 && failed > 0) {
      title = 'Download finished with errors';
      body = '$ok downloaded, $failed failed.';
    } else {
      title = 'Download failed';
      body = 'All $failed file(s) failed to download.';
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text('$body\n\nSaved to:\n${dir.path}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
          if (ok > 0)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _openFolder(dir);
              },
              child: const Text('Open folder'),
            ),
        ],
      ),
    );
  }

  Future<void> _openFolder(Directory dir) async {
    try {
      final proc = await Process.start(
        Platform.isWindows ? 'explorer' : 'xdg-open',
        [dir.path],
      );
      proc.stdout.drain<void>();
      proc.stderr.drain<void>();
    } catch (e) {
      debugPrint('Could not open folder: $e');
    }
  }

  String _fmtBytes(int b) {
    if (b <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = b.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Balbum — Bunkr Album Downloader'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    enabled: !_loading && !_downloading,
                    decoration: const InputDecoration(
                      labelText: 'Bunkr album URL',
                      hintText: 'https://bunkr.si/a/xxxxxx',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _fetch(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: (_loading || _downloading) ? null : _fetch,
                  child: _loading
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Fetch'),
                ),
                const SizedBox(width: 8),
                if (_loading || _downloading)
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _stopRequested = true),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Checkbox(
                  value: _mediaOnly,
                  onChanged: (_loading || _downloading)
                      ? null
                      : (v) => setState(() => _mediaOnly = v ?? false),
                ),
                const Text('Media only (pictures & videos)'),
                const SizedBox(width: 12),
                if (_mediaOnly)
                  const Text('Downloads only pictures & video files.',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.folder_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _dirCtrl,
                    enabled: !_loading && !_downloading,
                    decoration: const InputDecoration(
                      labelText: 'Save to folder',
                      hintText:
                          r'C:\Downloads (leave empty to pick at download)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: (_loading || _downloading) ? null : _pickFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Browse…'),
                ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                _error!,
                style: const TextStyle(color: Colors.red),
              ),
            ],
            const SizedBox(height: 12),
            if (album == null)
              const Expanded(
                child: Center(
                  child: Text('Paste an album URL and press Fetch.'),
                ),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${album.title.isEmpty ? album.id : album.title}  '
                      '•  ${album.files.length} files',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed:
                        (_downloading || album.files.isEmpty) ? null : _downloadAll,
                    icon: const Icon(Icons.download),
                    label: Text(_downloading
                        ? 'Downloading…'
                        : 'Download all'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (_mediaOnly && !_downloading)
                Text(
                  '${album.files.where((f) => f.isMedia).length} media files '
                  'will be downloaded.',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              const SizedBox(height: 8),
              if (_downloading)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Downloading $_currentFile of '
                    '${_mediaOnly ? album.files.where((f) => f.isMedia).length : album.files.length} files...',
                    style: const TextStyle(
                        fontSize: 13, color: Colors.grey),
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: album.files.length,
                  itemBuilder: (context, i) {
                    final f = album.files[i];
                    return _FileTile(
                      file: f,
                      fmtBytes: _fmtBytes,
                      onRetry:
                          (_downloading || !f.error) ? null : () => _retryFile(f),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  final BunkrFile file;
  final String Function(int) fmtBytes;
  final VoidCallback? onRetry;
  const _FileTile(
      {required this.file, required this.fmtBytes, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final total = file.size;
    final prog = total > 0 ? (file.downloaded / total).clamp(0.0, 1.0) : 0.0;
    final IconData icon;
    if (file.error) {
      icon = Icons.error_outline;
    } else if (file.done) {
      icon = Icons.check_circle;
    } else {
      icon = Icons.insert_drive_file;
    }
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: Icon(icon,
            color: file.error
                ? Colors.red
                : file.done
                    ? Colors.green
                    : null),
        title: Text(
          file.safeName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (file.error && file.errorMsg != null)
              Text(file.errorMsg!,
                  style: const TextStyle(color: Colors.red, fontSize: 12))
            else
              LinearProgressIndicator(value: prog, minHeight: 4),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (file.error)
              IconButton(
                onPressed: onRetry,
                tooltip: 'Retry (resumes from where it stopped)',
                icon: const Icon(Icons.refresh),
                color: Colors.deepOrange,
                iconSize: 20,
              )
            else
              Text(
                file.done
                    ? fmtBytes(file.downloaded)
                    : '${fmtBytes(file.downloaded)} / ${fmtBytes(total)}',
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}
