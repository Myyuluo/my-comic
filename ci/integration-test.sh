#!/usr/bin/env bash
# Fully-automated, EMULATOR-ONLY integration test runner for MyComic.
#
# One command: boots/selects an emulator, builds the debug APK once, then runs
# every remaining integration_test target and aggregates the results. No real
# device, no manual `flutter drive`. A real (physical) device is deliberately
# ignored — only serials matching emulator-<port> are used.
#
# Usage:
#   bash ci/integration-test.sh                      # boot/select emulator, run all
#   bash ci/integration-test.sh --skip-build         # reuse the existing app-debug.apk
#   bash ci/integration-test.sh --only=app_smoke,reader_pagination
#   bash ci/integration-test.sh --avd=my_comic_gpu_test
#
# Env overrides: ADB, EMULATOR, FLUTTER, AVD, PKG
#
# NOTE: this runner does NOT use `set -e` — a failing target must not abort the
# remaining targets; failures are collected and reported in the final summary.
set -uo pipefail

ADB="${ADB:-$(command -v adb 2>/dev/null || echo /d/android_sdk/platform-tools/adb)}"
EMULATOR="${EMULATOR:-$(command -v emulator 2>/dev/null || echo /d/android_sdk/emulator/emulator)}"
FLUTTER="${FLUTTER:-$(command -v flutter 2>/dev/null || echo /d/flutter_sdk/flutter_extracted/flutter/bin/flutter)}"
AVD="${AVD:-}"   # resolved lazily below (boot block) if left empty
PKG="${PKG:-app.mycomic.reader}"
# MSYS /d/foo -> Windows D:/foo for native adb.exe.
win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}
APK_REL="build/app/outputs/flutter-apk/app-debug.apk"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SKIP_BUILD=false
ONLY=""
for arg in "$@"; do
  case $arg in
    --skip-build) SKIP_BUILD=true ;;
    --avd=*) AVD="${arg#*=}" ;;
    --only=*) ONLY="${arg#*=}" ;;
    *) echo ">>> Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ── Emulator-only selection. A physical device serial does not match
# emulator-<port>, so this guard guarantees we never touch a real device. ──
emulator_serial() {
  $ADB devices 2>/dev/null | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}'
}

DEVICE="$(emulator_serial)"
if [ -z "$DEVICE" ]; then
  # Resolve which AVD to boot (lazily — only needed when nothing is online,
  # so a host that already has an emulator up needs no AVD at all). The
  # default is NOT hardcoded to one fixed name that may not exist on this
  # host: prefer the GPU-verified `my_comic_gpu_test` image (android-34,
  # renders real Flutter pixels) if present, else fall back to the first AVD
  # `emulator -list-avds` reports. An explicit --avd=/AVD= override wins.
  if [ -z "$AVD" ]; then
    _avds="$("$EMULATOR" -list-avds 2>/dev/null | tr -d '\r')"
    if printf '%s\n' "$_avds" | grep -qx "my_comic_gpu_test"; then
      AVD="my_comic_gpu_test"
    else
      AVD="$(printf '%s\n' "$_avds" | grep -v '^[[:space:]]*$' | head -1)"
    fi
    if [ -z "$AVD" ]; then
      echo ">>> FAIL: no AVD available — 'emulator -list-avds' is empty and" >&2
      echo ">>>       no --avd=/AVD= was given. Create one (e.g. an android-34" >&2
      echo ">>>       'my_comic_gpu_test' image) or pass --avd=<name>." >&2
      exit 1
    fi
  fi
  echo ">>> No emulator online — booting AVD '$AVD'..."
  # GPU mode is overridable via GPU_MODE; default host. NOTE: the emulator logs
  # "aw_browser_terminator: Renderer process crash detected" during WebView
  # pre-warm under BOTH host and software rendering — it is harmless noise, not
  # a test failure (reader_pagination passes with those crashes present). Do
  # NOT treat that log line as a root cause.
  "$EMULATOR" -avd "$AVD" -no-snapshot-save -gpu "${GPU_MODE:-host}" >/dev/null 2>&1 &
  for _ in $(seq 1 120); do
    DEVICE="$(emulator_serial)"
    [ -n "$DEVICE" ] && break
    sleep 2
  done
  if [ -z "$DEVICE" ]; then
    echo ">>> FAIL: emulator did not appear after 240s." >&2
    exit 1
  fi
fi
ADBD="$ADB -s $DEVICE"
echo ">>> Using emulator: $DEVICE"

until [ "$(MSYS_NO_PATHCONV=1 $ADBD shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  echo ">>> waiting for boot..."
  sleep 2
done
echo ">>> Emulator booted."

# ── Android 16+ (API >= 36) guest images: SurfaceFlinger's RegionSamplingThread
#    aborts inside mapper.ranchu.so with
#      'Assertion failed: !rcEnc->featureInfo()->hasReadColorBufferDma'
#    every few seconds. It takes system_server down with it, so the UI restarts
#    forever ("stuck loading") and the host emulator finally abort()s and pops
#    its crash-report dialog. The sampler only runs while the gestural
#    navigation handle has a RegionSamplingListener registered, so moving to
#    3-button navigation removes the only trigger.
#    This is a guest-image defect we cannot patch: the assertion lives in
#    mapper.ranchu.so inside system.img. It is NOT a host/GPU problem —
#    reproduced identically under -gpu host, swiftshader_indirect and
#    -no-window, on emulator 36.5.11 and 37.1.11, on both android-36 and
#    android-36.1; android-34 never hits it. Drop this block once Google ships
#    a fixed image.
#    Measured: gestural = 8..14 SF aborts / 90s, surfaceflinger uptime 00:01;
#              3-button = 0 aborts / 90s, surfaceflinger uptime stable.
#    Side effect of the same bug: 'adb shell screencap' also walks readFromHost
#    and dies on API >= 36. Use 'adb emu screenrecord screenshot <dir>' instead.
_sdk="$(MSYS_NO_PATHCONV=1 $ADBD shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
if [ -n "$_sdk" ] && [ "$_sdk" -ge 36 ] 2>/dev/null; then
  echo ">>> API $_sdk: switching to 3-button navigation (works around the SurfaceFlinger RegionSampling abort)."
  MSYS_NO_PATHCONV=1 $ADBD shell cmd overlay enable com.android.internal.systemui.navbar.threebutton >/dev/null 2>&1 || true
  MSYS_NO_PATHCONV=1 $ADBD shell cmd overlay disable com.android.internal.systemui.navbar.gestural >/dev/null 2>&1 || true
fi

cd "$REPO_ROOT/my_comic"

# ── Build once ──
if [ "$SKIP_BUILD" = false ]; then
  echo ">>> Building debug APK (once)..."
  if ! "$FLUTTER" build apk --debug; then
    echo ">>> FAIL: build failed." >&2
    exit 1
  fi
fi
if [ ! -f "$APK_REL" ]; then
  echo ">>> FAIL: $APK_REL not found (run without --skip-build first)." >&2
  exit 1
fi

# ── Pre-install with all runtime perms granted (preserved across flutter
#    drive's -r reinstall). ──
echo ">>> Pre-installing MyComic with runtime permissions granted..."
MSYS_NO_PATHCONV=1 $ADBD install -r -g "$(win_path "$APK_REL")"

# Re-enable the default launcher activity-alias. MyComic's runtime icon switcher
# (IconSwitchHelper) disables .MainActivityDefault when the user picks a
# different launcher icon; a fresh `install -r` can land with that alias still
# disabled, leaving the app with no enabled LAUNCHER component — `flutter drive`
# then resolves no launchable activity. Idempotent (no-op if already enabled);
# non-fatal so a manifest rename never aborts the run.
MSYS_NO_PATHCONV=1 $ADBD shell pm enable "$PKG/.MainActivityDefault" >/dev/null 2>&1 || true

# All-Files-Access (MANAGE_EXTERNAL_STORAGE) is an appop, NOT a runtime
# permission, so `install -g` does not grant it. The app needs it to read
# user-selected manga directories through dart:io. It must be set with `--uid`
# (the per-package form fails on API 35), and the grant DOES survive flutter
# drive's -r reinstall.
#
# CRITICAL: appops must NOT run in the post-install window before the package
# manager has registered the new uid — `appops set --uid <pkg>` then fails with
# "No UID for <pkg>" and (previously, swallowed by `|| true`) the app silently
# never got all-files access. Poll until the appop actually reads back "allow".
echo ">>> Granting MANAGE_EXTERNAL_STORAGE (waiting for uid registration)..."
for _ in $(seq 1 15); do
  MSYS_NO_PATHCONV=1 $ADBD shell appops set --uid "$PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1
  if MSYS_NO_PATHCONV=1 $ADBD shell appops get --uid "$PKG" MANAGE_EXTERNAL_STORAGE 2>/dev/null \
       | tr -d '\r' | grep -q "MANAGE_EXTERNAL_STORAGE: allow"; then
    echo ">>> MANAGE_EXTERNAL_STORAGE: allow"
    break
  fi
  sleep 1
done

# ── Target list ──
# Only targets that still exist after the manga-only cleanup. Video /
# dictionary / Anki / audiobook integration targets were deleted with their
# features; listing them would only produce misleading SKIP lines.
ALL_TARGETS=(
  app_smoke
  settings_validation
  user_path
  desktop_reader_columns_dom
  desktop_reader_css_dom
  desktop_settings_smoke
)

TARGETS=()
if [ -n "$ONLY" ]; then
  IFS=',' read -ra TARGETS <<< "$ONLY"
else
  TARGETS=("${ALL_TARGETS[@]}")
fi
if [ ${#TARGETS[@]} -eq 0 ]; then
  echo ">>> FAIL: no targets to run (empty --only?)." >&2
  exit 2
fi

PASS=(); FAIL=(); SKIP=(); NOTES=()
LOGDIR="$REPO_ROOT/.codex-test/itest-logs"
mkdir -p "$LOGDIR"

run_target() {
  local t="$1"
  local file="integration_test/${t}_test.dart"
  if [ ! -f "$file" ]; then
    echo ">>> SKIP $t (no such target)"
    SKIP+=("$t")
    return
  fi
  echo ">>> RUN  $t"
  local log="$LOGDIR/${t}.log"
  # A target passes only if flutter drive exits 0, the log shows "All tests
  # passed", and it does NOT also report "Some tests failed" (belt-and-
  # suspenders against a 0-test run that exits 0 with no clear verdict).
  # BUG-2500: Flutter drive's default completion cleanup stops AND uninstalls
  # the app. Keep it installed/running so each target preserves app data.
  if "$FLUTTER" drive \
        --keep-app-running \
        --driver=test_driver/integration_test.dart \
        --target="$file" -d "$DEVICE" >"$log" 2>&1 \
     && grep -q "All tests passed" "$log" \
     && ! grep -q "Some tests failed" "$log"; then
    echo ">>> PASS $t"
    PASS+=("$t")
    # Surface intentionally-skipped sub-assertions so a green PASS is not
    # mistaken for full coverage.
    local skipped
    skipped=$(grep -ioE "SKIP [A-Z0-9_-]+" "$log" | sort -u | tr '\n' ' ')
    [ -n "$skipped" ] && NOTES+=("$t: ${skipped% }")
  else
    echo ">>> FAIL $t  (see $log)"
    FAIL+=("$t")
    grep -iE "fail\(|Expected:|Exception|Error:|No books" "$log" | head -3
  fi
}

# ── Proxy is two-phased. Earlier internet-facing setup — `flutter build apk`
#    fetching native deps may rely on HTTPS_PROXY/HTTP_PROXY. But `flutter drive`
#    below talks to the Dart VM service on 127.0.0.1:<port>; routing that
#    localhost socket through an HTTP proxy makes it get closed mid-handshake
#    (HttpException: Connection closed), failing EVERY target. All downloads are
#    done by now, so drop the proxy for the drive phase — localhost must be
#    direct. (--skip-build reaches here too: unset is a harmless no-op.) ──
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy

for t in "${TARGETS[@]}"; do
  run_target "$t"
done

echo ""
echo "==================== INTEGRATION SUMMARY ===================="
echo "Emulator     : $DEVICE"
echo "PASS (${#PASS[@]}): ${PASS[*]:-none}"
echo "SKIP (${#SKIP[@]}): ${SKIP[*]:-none}"
echo "FAIL (${#FAIL[@]}): ${FAIL[*]:-none}"
if [ ${#NOTES[@]} -gt 0 ]; then
  echo "NOTES (partial coverage — passed but with skipped sub-assertions):"
  printf '  - %s\n' "${NOTES[@]}"
fi
echo "Logs         : $LOGDIR"
echo "============================================================"

# Green only if nothing failed AND at least one target actually passed — so a
# run where every requested target was skipped (e.g. a mistyped --only) does
# not report a misleading success (review W1).
[ ${#FAIL[@]} -eq 0 ] && [ ${#PASS[@]} -gt 0 ]
