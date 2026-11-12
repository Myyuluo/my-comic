#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include "caption_snap_button.h"
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "ime_association_guard.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  ~FlutterWindow() override;

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  void OnDisplayRecovered() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Receives title-bar colors pushed from Dart (app.mycomic/window channel).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      caption_channel_;

  // Windows 11 Snap Layouts on the app-drawn maximize button: HTMAXBUTTON hit
  // testing over the rect Dart reports (setCaptionMaxButtonRect), hover /
  // press / click relayed back as onCaptionMaxButton.
  CaptionSnapButton caption_snap_button_;

  // Copies decoded reader images to the Windows clipboard as CF_DIB.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_image_channel_;

  // TODO-1092: system accent/theme color change notifications.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      system_theme_channel_;

  // BUG-1239: forwards an unmodified IME-owned physical Space press before
  // Flutter turns VK_PROCESSKEY into a KeyEvent with physical/logical key 0.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_ime_space_channel_;

  // BUG-1450: Dart tells us whether anything editable holds focus; while
  // nothing does we detach the window's IME context so a CJK IME stops eating
  // every shortcut key. See ime_association_guard.h.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_ime_guard_channel_;
  ImeAssociationGuard ime_association_guard_;

  // Wires the ime_guard MethodChannel to ime_association_guard_.
  void RegisterImeGuardChannel();

  // Applies DWM caption/text colors to the top-level window. Persists across
  // focus changes, so the unfocused title bar keeps following the app theme.
  void ApplyCaptionColors(uint32_t caption_argb, uint32_t text_argb);

  // Glass material: turns the Windows 11 Mica system backdrop on / off behind
  // the (translucent) Flutter view. Returns whether Mica is actually active.
  bool ApplySystemBackdrop(bool mica, bool dark);

  // BUG-2964: single writer of the main window's DWM composition.
  void ApplyMainSurfaceComposition(const my_comic::MainSurfaceState& state);
  void ApplyMainSurfaceComposition();

  // TODO-1092: notify Dart that the OS accent/theme color changed.
  void NotifySystemColorChanged();

  // Loads an image file via WIC, builds big/small HICONs and applies them to
  // the top-level window (WM_SETICON).
  bool ApplyWindowIcon(const std::wstring& path);

  // Owned window icons set via ApplyWindowIcon. nullptr until first applied.
  HICON icon_big_ = nullptr;
  HICON icon_small_ = nullptr;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
