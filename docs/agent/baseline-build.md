# Baseline build record — Fushi v3.0.0

Ticket: `.scratch/my-comic-v1/issues/01-baseline-build.md`
Date: 2026-11-04
Host: Windows 10 Pro 22H2 (build 19045.6466), x64

## Toolchain

- Flutter 3.47.6 (framework revision `5fc346839b`, Dart 3.13.5), project-local SDK copy at `E:\tmp\flutter-3.47.6-mycomic`; the global SDK at `D:\ProgramData\flutter_3.47.6` was not modified.
- Visual Studio Community 2026 18.11.2, MSVC 14.51.36231, Windows SDK 10.0.26100.0, C++ ATL present.
- Upstream: Fushi `v3.0.0`, commit `51fbb9b183829b4668fd5d69cd3a4d7349ab112b` (see `UPSTREAM.md`).

## Build steps

1. `flutter pub get` at the workspace root with the upstream `pubspec.lock`. The lock's hosted URLs were locally pointed at the configured pub mirror (`https://pub.flutter-io.cn`) so pub honored the locked versions; the lock was restored to the upstream file before commit.
2. `bash ci/apply-patches.sh` with `FLUTTER_ROOT` pointing at the project SDK. The Flutter SDK patch was already present; pub-cache patches were applied (13 skipped because the exact versions are not in the cache).
3. `cd fushi && dart run slang && dart format lib/i18n/strings.g.dart`. The v3.0.0 tree does not contain the generated `lib/i18n/strings.g.dart`; it is a build artifact and is ignored by `.gitignore`.
4. libtorrent runtime DLLs: `vcpkg install` in manifest mode with `native/fushi_torrent/vcpkg-ports` as an overlay, pinned by `native/fushi_torrent/vcpkg.json` (`builtin-baseline aae277acf4e7de287ddb5e208b5316614de6aad7`, libtorrent 2.0.11, Boost 1.91.0, OpenSSL 3.6.3). The `fushi_torrent_ffi` bridge was built with CMake (Release, x64) against the vcpkg install tree.
5. `third_party/media_kit_libs_windows_video/vendored/ANGLE.7z` is required by upstream's Windows CMake but missing from the v3.0.0 tag; it was restored from the upstream-pinned URL and MD5-verified (`e866f13e8d552348058afaafe869b1ed`).
6. `cd fushi && flutter build windows --release --no-pub` (equivalent to the documented `flutter build windows --release`; `--no-pub` keeps the already-resolved upstream lock).

No application source was changed.

## Result

Build succeeded (`√ Built build\windows\x64\runner\Release\fushi.exe`), last build duration 7 min 28 s.
The baseline executable was started from the Release directory, stayed alive for the smoke interval
(observed via `tasklist`, ~297,748 KB working set), then was terminated.

## Artifact sizes

| Artifact | Size |
| --- | --- |
| `fushi.exe` | 1,257,472 B (1.20 MiB) |
| `fushi_update_launcher.exe` | 62,464 B |
| Release bundle (`build/windows/x64/runner/Release/`) | 375 MiB, 512 files, 160 DLLs |
| Root-level DLLs (160) | 287,532,140 B |
| `data/` (Flutter assets) | 94 MiB |
| Upstream v3.0.0 Windows installer (reference asset, not rebuilt locally) | 303,508,616 B, SHA-256 `71b59d654ba9637c62fe0499da6d411bf90d8e95c5933a163dfd1b56444ed1ed` |

Top native libraries in the Release bundle:

| DLL | Size |
| --- | --- |
| `fbdx265-217.dll` | 22,667,339 B |
| `flutter_windows.dll` | 21,274,112 B |
| `fbdodec-63.dll` | 20,632,509 B |
| `libwebrtc.dll` | 20,538,880 B |
| `onnxruntime.dll` | 17,253,176 B |
| `fbdrsvg-2-2.dll` | 11,755,598 B |
| `fbdshaderc_shared.dll` | 10,596,561 B |
| `fbdaom.dll` | 9,688,502 B |
| `fbdSvtAv1Enc-4.dll` | 7,573,028 B |
| `libGLESv2.dll` | 7,414,088 B |
| `pdfium.dll` | 7,176,704 B |
| `fbdilter-12.dll` | 6,816,518 B |
| `fbdjxl.dll` | 6,218,625 B |
| `fbdcrypto-3-x64.dll` | 5,495,630 B |
| `libcrypto-3-x64.dll` | 5,357,568 B |

Also bundled for the download runtime: `torrent-rasterbar.dll` (4,724,224 B), `libssl-3-x64.dll` (877,568 B), `fushi_torrent_ffi.dll` (223,744 B).

No installer was produced by `flutter build`; Inno Setup is not installed on this host. The upstream v3.0.0 installer size above is recorded as the baseline installer reference.

## Notes / deviations

- `tool/bootstrap.ps1` could not be run because this agent's sandbox blocks PowerShell invocations; its two steps (`flutter pub get`, `ci/apply-patches.sh`) were run directly with the same environment.
- `flutter pub get` was run against the configured pub mirror; the upstream lock was restored after the build so the committed snapshot is unmodified apart from the imported sources and documented additions.
- Native prerequisites that upstream CI obtains from its artifact store were produced locally: libtorrent DLLs via vcpkg, WebView2 SDK via NuGet, and the ANGLE archive from its pinned URL.
- The JVM sidecar runtime (`mihon_bridge`) is not installed by `flutter build windows`; it is built by a separate upstream step and was out of scope for this baseline.
