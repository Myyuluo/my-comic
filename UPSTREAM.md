# Upstream provenance

MyComic started from a source snapshot of **Fushi v3.0.0**. The snapshot is frozen: MyComic does not follow later Fushi updates and does not sync with the upstream repository (see [`docs/adr/0003-freeze-upstream.md`](docs/adr/0003-freeze-upstream.md)). Product identity, platform scope and the Windows-only clean break are recorded in [`docs/adr/0024-windows-only-independent-identity.md`](docs/adr/0024-windows-only-independent-identity.md).

- Upstream project: Fushi
- Upstream repository: <https://github.com/hajisensai/Fushi>
- Tag: `v3.0.0`
- Commit: `51fbb9b183829b4668fd5d69cd3a4d7349ab112b`
- Snapshot acquired: 2026-11-04
- Acquisition method: shallow clone (`git clone --depth 1 --branch v3.0.0`); full upstream history is not imported
- Upstream license: GNU General Public License v3.0 — see [`LICENSE`](LICENSE)

## Notes

- The upstream tree was imported as the source baseline. MyComic has since diverged: it is Windows-only and manga-only, uses the MyComic identity, and does not track upstream commits. This document records provenance only; it is not a sync or update target.
- Upstream `CLAUDE.md`, `AGENTS.md` and `.claude/settings.json` were preserved during import under `docs/agent/`. That archive was removed by the independence cleanup (ADR 0024); `my_comic/CLAUDE.upstream.md` remains as a historical snapshot for provenance.
- Upstream Git submodules referenced by `.gitmodules` (`references/ReinaManager`, `references/ShokoServer`, `references/mangayomi`) are research references and are not vendored in this snapshot.
- The v3.0.0 tag omits `third_party/media_kit_libs_windows_video/vendored/ANGLE.7z`, but its Windows CMake requires that file and pins its MD5 (`e866f13e8d552348058afaafe869b1ed`). The archive was restored from the upstream-pinned URL `https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z` and MD5-verified before being added.
- libtorrent prebuilt DLLs are produced locally from `native/my_comic_torrent/vcpkg.json` (pinned libtorrent 2.0.11 / vcpkg baseline `aae277acf4e7de287ddb5e208b5316614de6aad7`) and are not committed, matching upstream's `prebuilt/` ignore rule.
