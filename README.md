# Balbum — Bunkr Album Downloader (Flutter, Windows desktop)

A Flutter Windows desktop app that downloads every file in a Bunkr album.

> **Note:** The original `gallery-dl.exe` you provided embeds an **outdated**
> Bunkr protocol (the API returned an XOR-encrypted URL). Bunkr changed to a
> **signed-URL** CDN scheme, so that old logic now gets HTTP 403 on download.
> This app implements the **current working protocol** (matching recent
> gallery-dl).

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

Files are saved into `<chosen folder>/<album name or id>/`.

## Build & run (on your Windows machine)

You need Flutter with the Windows desktop toolchain (Visual Studio with the
"C++ desktop development" workload).

```powershell
cd balbum_downloader
flutter pub get
flutter run -d windows        # run in debug
flutter build windows --release   # or build a release .exe
```

The release `.exe` is produced at
`build\windows\x64\runner\Release\balbum_downloader.exe`.

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
- `lib/main.dart` — the Windows desktop UI.
- `test/bunkr_client_test.dart` — unit tests.
