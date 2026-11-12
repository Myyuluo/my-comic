cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

add_executable(${BINARY_NAME} WIN32
  "clipboard_image_reader.cpp"
  "crash_dump.cpp"
  "flutter_window.cpp"
  "hang_watchdog.cpp"
  "ime_association_guard.cpp"
  "ime_space_dispatch.cpp"
  "main.cpp"
  "system_font_list.cpp"
  "system_transparency_channel.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)
apply_standard_settings(${BINARY_NAME})
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(${BINARY_NAME} PRIVATE
  "FLUTTER_VERSION=\"${FLUTTER_VERSION}\""
  "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}"
  "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}"
  "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}"
  "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}"
)
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
# dwmapi: DWM caption/text color theming, Mica backdrop and main-surface
# composition.
target_link_libraries(${BINARY_NAME} PRIVATE dwmapi)
# ole32 / shell32: IShellLink + IPersistFile + SHGetKnownFolderPath /
# SHChangeNotify for TODO-901 (rewriting desktop/Start-menu .lnk icons on app
# icon change).
target_link_libraries(${BINARY_NAME} PRIVATE ole32 shell32)
# windowscodecs: WIC decode for the clipboard image copy and runtime window
# icons. dwrite: system font enumeration for the custom-font picker.
target_link_libraries(${BINARY_NAME} PRIVATE windowscodecs dwrite)
# BUG-1450: ImmAssociateContextEx — detach the IME from the window while no text
# field has focus so CJK IMEs stop swallowing every shortcut key.
target_link_libraries(${BINARY_NAME} PRIVATE imm32)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
add_dependencies(${BINARY_NAME} flutter_assemble)

# HBK-AUDIT-052: timeout/failed installer waits must not restart an app into a
# bundle still being copied or rolled back. Uses live native function bodies.
include("tests/update_launcher_completion_test.cmake")

# BUG-1239: compile and execute the production IME Space predicate/dispatch
# seam as part of every Windows runner build. Source-string tests could not
# detect WM_KEYDOWN -> WM_KEYUP or removed Alt/Win guards.
add_executable(my_comic_windows_ime_space_test
  "ime_space_dispatch.cpp"
  "tests/ime_space_dispatch_test.cpp"
)
apply_standard_settings(my_comic_windows_ime_space_test)
target_compile_definitions(my_comic_windows_ime_space_test PRIVATE "NOMINMAX")
add_custom_target(my_comic_windows_ime_space_gate
  COMMAND "$<TARGET_FILE:my_comic_windows_ime_space_test>"
  DEPENDS my_comic_windows_ime_space_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} my_comic_windows_ime_space_gate)

# 粘贴截图：截图工具的 32bpp DIB（alpha 常全 0）→ 不透明 PNG、掩码偏移、
# CF_HDROP → UTF-8 路径。只测纯转换、不碰真剪贴板，所以能随每次构建跑。
add_executable(my_comic_windows_clipboard_image_reader_test
  "clipboard_image_reader.cpp"
  "tests/clipboard_image_reader_test.cpp"
)
apply_standard_settings(my_comic_windows_clipboard_image_reader_test)
target_compile_definitions(my_comic_windows_clipboard_image_reader_test
  PRIVATE "NOMINMAX")
target_link_libraries(my_comic_windows_clipboard_image_reader_test PRIVATE
  ole32 shell32 windowscodecs user32)
add_custom_target(my_comic_windows_clipboard_image_reader_gate
  COMMAND "$<TARGET_FILE:my_comic_windows_clipboard_image_reader_test>"
  DEPENDS my_comic_windows_clipboard_image_reader_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} my_comic_windows_clipboard_image_reader_gate)

# BUG-1450: same treatment for the IME association state machine. Getting the
# coalescing or the failure path wrong either strands the window with the IME
# detached (no Chinese/Japanese input anywhere in the app) or re-attached (the
# whole shortcut table dies again), so it runs on every Windows runner build.
add_executable(my_comic_windows_ime_association_test
  "ime_association_guard.cpp"
  "tests/ime_association_guard_test.cpp"
)
apply_standard_settings(my_comic_windows_ime_association_test)
target_compile_definitions(my_comic_windows_ime_association_test PRIVATE "NOMINMAX")
target_link_libraries(my_comic_windows_ime_association_test PRIVATE imm32)
add_custom_target(my_comic_windows_ime_association_gate
  COMMAND "$<TARGET_FILE:my_comic_windows_ime_association_test>"
  DEPENDS my_comic_windows_ime_association_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} my_comic_windows_ime_association_gate)

# BUG-1455: compile and execute the WM_ACTIVATE focus policy on every Windows
# runner build. This guards both sides of the contract: popup drag deactivation
# must not raise the main window, while ordinary main-window click/activation
# must still restore focus to the live Flutter child. HWND ownership cases cover
# view teardown/recreation and Windows handle reuse.
add_executable(my_comic_windows_activation_policy_test
  "tests/window_activation_policy_test.cpp"
)
apply_standard_settings(my_comic_windows_activation_policy_test)
target_compile_definitions(my_comic_windows_activation_policy_test PRIVATE
  "NOMINMAX")
add_custom_target(my_comic_windows_activation_policy_gate
  COMMAND "$<TARGET_FILE:my_comic_windows_activation_policy_test>"
  DEPENDS my_comic_windows_activation_policy_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} my_comic_windows_activation_policy_gate)

# BUG-2462: the Flutter child resize gate (child_resize_gate.h) closes the
# engine's resize-synchroniser hazard (A -> B -> A while Dart is busy pins the
# resize target and drops every frame = frozen window when entering fullscreen
# during video load). Its state machine is pure; keep every transition
# executable on each Windows runner build.
add_executable(my_comic_windows_child_resize_gate_test
  "tests/child_resize_gate_test.cpp"
)
apply_standard_settings(my_comic_windows_child_resize_gate_test)
target_compile_definitions(my_comic_windows_child_resize_gate_test PRIVATE
  "NOMINMAX")
add_custom_target(my_comic_windows_child_resize_gate_gate
  COMMAND "$<TARGET_FILE:my_comic_windows_child_resize_gate_test>"
  DEPENDS my_comic_windows_child_resize_gate_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} my_comic_windows_child_resize_gate_gate)

# BUG-2964: the main window's DWM frame margins / surface fill are derived from
# one state (Mica, fullscreen). Keep the decision table executable on each
# Windows runner build.
add_executable(my_comic_windows_main_surface_composition_test
  "tests/main_surface_composition_test.cpp"
)
apply_standard_settings(my_comic_windows_main_surface_composition_test)
target_compile_definitions(my_comic_windows_main_surface_composition_test PRIVATE
  "NOMINMAX")
add_custom_target(my_comic_windows_main_surface_composition_gate
  COMMAND "$<TARGET_FILE:my_comic_windows_main_surface_composition_test>"
  DEPENDS my_comic_windows_main_surface_composition_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} my_comic_windows_main_surface_composition_gate)

add_executable(my_comic_update_launcher WIN32
  "update_launcher.cpp"
)
apply_standard_settings(my_comic_update_launcher)
target_compile_definitions(my_comic_update_launcher PRIVATE "NOMINMAX")
target_link_libraries(my_comic_update_launcher PRIVATE shell32)
