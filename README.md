# Balbum — Bunkr Album Downloader (Flutter desktop)

A cross-platform Flutter desktop app (Windows & Linux, macOS soon) that
downloads every file in a Bunkr album.

## How it works (current Bunkr protocol)

1. **Fetch album page:** `GET https://<domain>/a/<album_id>?advanced=1`
2. **Parse HTML** (no JSON API for the list) — pull the `window.albumFiles = [...]`
   JS blob out of the `<script>` tag and split its object literals.
3. **Resolve each file's signed URL** (two calls per file):
   - `POST https://dl.bunkr.cr/api/_001_v2` with JSON `{"id": <data_id>}` and
     headers `Referer: https://dl.bunkr.cr/` and `Origin: https://dl.bunkr.cr`
     → returns `{"mediafiles": <cdn base>, "path": "/storage/media/...", "original": <name>}`
   - `GET https://glb-apisign.cdn.cr/sign?path=<path>` (same headers)
     → returns `{"ex": ..., "token": ...}`
   - Final URL = `mediafiles + path + "?ex=..&token=..&n=<original>"`
4. **Download** the signed URL with `Referer: https://dl.bunkr.cr/`
   (no `Origin`). The signed `ex`/`token` are short-lived (~15 min). If it
   redirects to `/maintenance-vid.mp4`, that file is skipped.
5. **Cloudflare fallback:** if a coordinate domain is challenge-gated (403 /
   empty body), the app retries the album page on the next coordinate domain in
   the pool (`bunkr.si`, `bunkr.ph`, `bunkr.ac`, …).

For backwards compatibility, if the API ever returns the legacy
`{"encrypted", "url"}` shape, the app falls back to the old XOR-decrypt
(`key = "SECRET_KEY_" + (timestamp ~/ 3600)`, base64 → XOR).

Files are saved directly into the chosen `<chosen folder>` (no subfolder).

## Build & run

**Windows** (needs Flutter's Windows toolchain — Visual Studio with the
"C++ desktop development" workload):

```powershell
cd balbum_downloader
flutter pub get
flutter run -d windows
flutter build windows --release
```
Release `.exe` at `build\windows\x64\runner\Release\balbum_downloader.exe`.

**Linux** (needs `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`):

```bash
cd balbum_downloader
flutter pub get
flutter build linux --release
```
Build at `build/linux/x64/release/bundle/balbum_downloader`.

**macOS:** planned — once added, `flutter run -d macos` / `flutter build macos --release`.

Pre-built binaries for each release are available for download from the
repo's **Releases** page.

## Tests

```bash
flutter test
```

Covers `decryptXor` (using ground-truth vectors generated with the real
Python logic), album-id parsing, album-page parsing + per-file resolution
(encrypted and plain), CF-coordinate-domain fallback, and file download with
the correct `Referer` header — all against a mock HTTP client.

## Layout

- `lib/bunkr_client.dart` — the protocol port (`BunkrDownloader`, `decryptXor`,
  `BunkrAlbum`/`BunkrFile`). Pure Dart, no Flutter dependency.
- `lib/main.dart` — the desktop UI.
- `test/bunkr_client_test.dart` — unit tests.
