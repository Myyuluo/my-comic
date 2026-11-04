cmake_minimum_required(VERSION 3.14)
project(fushi LANGUAGES C CXX)

set(BINARY_NAME "fushi")

cmake_policy(SET CMP0063 NEW)

set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Configure build options.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()

set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Force UTF-8 source encoding for all targets (including plugins) to avoid
# C4819 warnings on CJK Windows systems where the default code page cannot
# represent characters in third-party plugin sources.
add_compile_options(/utf-8)

# GitHub's windows-latest image rolled forward to VS 2026 / MSVC 14.51, whose
# updated STL turned the <experimental/coroutine> deprecation (STL1011) from a
# warning into a hard static_assert. The forked flutter_inappwebview_windows
# plugin (via <winrt/base.h> / WIL) and the upstream permission_handler_windows
# plugin still pull that header in, so both fail to compile under the new
# toolchain even though our code is unchanged. Define the silencer Microsoft's
# own diagnostic points to, globally, so it reaches every plugin subproject
# (permission_handler_windows is a pub.dev dep we cannot edit). Remove once the
# affected plugins drop <experimental/coroutine>.
add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Compilation settings that should be applied to most targets.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# === Install prefix (bundle directory) ===
# Settled before any subproject is added: plugins (media_kit_libs_windows_video
# installs bluray/bdj, native licenses and runtime manifests) expand
# ${CMAKE_INSTALL_PREFIX} when they are configured. Set after them, a fresh
# build directory's first configure handed them the default
# "C:/Program Files/fushi": a non-admin install failed and an elevated CI build
# silently left bluray/ out of the app bundle (BUG-3074).
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")

# Flutter library and tool build rules.
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build
add_subdirectory("runner")

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# my-comic (ticket 04): flutter_webrtc is not registered on Windows (see the
# ci/patches/hosted/flutter_webrtc-* pubspec override), so the app-owned
# WGC capture adapter target no longer exists. Game streaming / WebRTC is out
# of the manga-only scope (ADR-0002).
#
# The fushidicts / fushi_aacs native targets were removed here as well:
# fushidicts backs the (non-manga) dictionary engine, and libaacs only serves
# libbluray inside the now-removed libmpv runtime.

# === Installation ===
set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} fushi_update_launcher
  RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
#
# BUG-2419：这两句是官方 Windows 模板自带的（templates/app/windows.tmpl/
# CMakeLists.txt.tmpl），本仓这份 CMakeLists 是老模板的重度定制副本，功能演进时把它
# 漏掉了——`fushi/linux/CMakeLists.txt` 有，Windows 没有。Flutter 本该自动补它的
# `cmake_native_assets_migration.dart` 靠 `replaceFirst('endforeach(bundled_library)')`
# 定位插入点，而 Windows 模板用的是 `if(PLUGIN_BUNDLED_LIBRARIES) install(FILES ...)`，
# 根本没有那个 foreach → 匹配不到 → **静默 return，不写文件不打日志**。于是这个洞
# 能一直存在而 CI 全绿。
#
# 后果不是「PDF 功能缺失」而是「PDF 永久挂死」：pdfium.dll 只落在 build/native_assets/
# 而进不了 bundle，运行期裸名 DynamicLibrary.open('pdfium.dll') 在 pdfrx 的 worker
# isolate 里抛异常，而那个 worker 的 execute() 没有 try/catch（pdfrx_engine 的
# worker.dart），回包 SendPort.send 永不执行 → 主 isolate 的 await 永不完成。
#
# sqlite3.dll 掩盖过这个缺口：它同时由 sqlite3_flutter_libs 走 PLUGIN_BUNDLED_LIBRARIES
# 装进 bundle，所以 native-assets 这条通道从来没通过也看不出来。
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
# my-comic (ticket 04): pdfium is the PDF reader's native engine, which v1 does
# not ship (local manga only covers CBZ/ZIP/folder/.mokuro). Exclude it from
# the native-assets copy so the DLL never reaches the bundle; sqlite3.dll (the
# other native asset) is still installed by sqlite3_flutter_libs and must stay.
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime
   PATTERN "pdfium.dll" EXCLUDE)

# my-comic (ticket 04): the following native runtimes are not shipped because
# they only serve non-manga features (ADR-0002):
#   - fushidicts_ffi.dll (dictionary engine)
#   - fushi_aacs / libaacs.dll (Blu-ray AACS; only used by the removed libmpv)
#   - fushi_torrent_ffi.dll + torrent-rasterbar + OpenSSL (BT/torrent)
#   - fushi_p2p.dll (Interconnect P2P)
#   - fushi_fsrs.dll (Anki SRS scheduling)
#   - voice_hook/ galgame helper files
# Their install rules were removed instead of being made optional, so a
# Release build can no longer silently re-introduce them.
# The corresponding Dart code stays compilable (out of this ticket's scope),
# but the native libraries are absent and those features are unavailable.

# === Magpie 随包精简归档（可选，本地/CI 事先构建）===
# 与上面的 helper 规则同源同理由（BUG-1246）：Magpie 删掉下载链路之后，`magpie_bundle/`
# 只由 CI 在 `flutter build windows` 之后的一个独立 YAML 步骤拷贝，于是 `flutter run` /
# `flutter build windows --debug` 出来的 exe 旁边永远没有这个目录，`_installBundledMagpie`
# 在 `if (!hasZip && !hasSidecar) return false;` 当场返回 false —— 开发构建里窗口超分
# **恒为 bundleMissing**，等于开发模式下这个功能完全用不了、也没法验证。
#
# 产物来自 repo 根 `dist/`（tools/build_magpie_slim.ps1 的默认 OutputDir），与 release
# 同源、同文件名、同目标目录；CI 那步照旧保留，它跑在本规则之后，是幂等覆盖。
# OPTIONAL 同样必需：判定发生在 install 时而非 configure 时，没跑过组包脚本的机器照常
# `flutter build windows` 成功，只是超分报「安装包不完整」——与今天的行为一致。
# 要在本地拿到它：仓库根跑 `pwsh -File tools/build_magpie_slim.ps1`。
set(FUSHI_MAGPIE_BUNDLE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../dist")
set(FUSHI_MAGPIE_BUNDLE_FILES
  "Magpie-hibiki-slim-x64.zip"
  "Magpie-hibiki-slim-x64.zip.sha256")
foreach(_magpie_file ${FUSHI_MAGPIE_BUNDLE_FILES})
  install(FILES "${FUSHI_MAGPIE_BUNDLE_DIR}/${_magpie_file}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/magpie_bundle"
    COMPONENT Runtime OPTIONAL)
endforeach()

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
