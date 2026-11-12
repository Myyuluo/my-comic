#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <windows.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <flutter/method_result_functions.h>

#include "clipboard_image_reader.h"
#include "flutter/generated_plugin_registrant.h"
#include "ime_association_guard.h"
#include "ime_space_dispatch.h"
#include "main_surface_composition.h"
#include "system_font_list.h"
#include "system_transparency_channel.h"
#include "utils.h"

#pragma comment(lib, "windowscodecs.lib")

namespace {

std::wstring Utf8ToWideString(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                 static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

std::string HResultMessage(HRESULT hr) {
  char buffer[128];
  snprintf(buffer, sizeof(buffer), "HRESULT 0x%08X", static_cast<unsigned>(hr));
  return std::string(buffer);
}

std::optional<std::string> CopyImageFileToClipboard(HWND hwnd,
                                                    const std::wstring& path) {
  if (hwnd == nullptr) {
    return std::string("Window handle is unavailable");
  }
  if (path.empty()) {
    return std::string("Image path is empty");
  }

  using Microsoft::WRL::ComPtr;
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    return std::string("WIC factory creation failed: ") + HResultMessage(hr);
  }

  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromFilename(
      path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad,
      &decoder);
  if (FAILED(hr)) {
    return std::string("Image decode failed: ") + HResultMessage(hr);
  }

  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr)) {
    return std::string("Image frame read failed: ") + HResultMessage(hr);
  }

  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) {
    return std::string("Image converter creation failed: ") +
           HResultMessage(hr);
  }
  hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                             WICBitmapDitherTypeNone, nullptr, 0.0,
                             WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) {
    return std::string("Image conversion failed: ") + HResultMessage(hr);
  }

  UINT width = 0;
  UINT height = 0;
  hr = converter->GetSize(&width, &height);
  if (FAILED(hr) || width == 0 || height == 0) {
    return std::string("Image size is invalid");
  }

  const size_t stride = static_cast<size_t>(width) * 4;
  const size_t pixel_bytes = stride * static_cast<size_t>(height);
  if (pixel_bytes == 0 ||
      pixel_bytes > static_cast<size_t>(std::numeric_limits<DWORD>::max())) {
    return std::string("Image is too large for the clipboard");
  }

  std::vector<BYTE> pixels(pixel_bytes);
  hr = converter->CopyPixels(nullptr, static_cast<UINT>(stride),
                             static_cast<UINT>(pixel_bytes), pixels.data());
  if (FAILED(hr)) {
    return std::string("Image pixel copy failed: ") + HResultMessage(hr);
  }

  const size_t dib_bytes = sizeof(BITMAPINFOHEADER) + pixel_bytes;
  HGLOBAL dib = GlobalAlloc(GMEM_MOVEABLE, dib_bytes);
  if (dib == nullptr) {
    return std::string("Clipboard memory allocation failed");
  }

  void* locked = GlobalLock(dib);
  if (locked == nullptr) {
    GlobalFree(dib);
    return std::string("Clipboard memory lock failed");
  }

  auto* header = static_cast<BITMAPINFOHEADER*>(locked);
  ZeroMemory(header, sizeof(BITMAPINFOHEADER));
  header->biSize = sizeof(BITMAPINFOHEADER);
  header->biWidth = static_cast<LONG>(width);
  header->biHeight = static_cast<LONG>(height);
  header->biPlanes = 1;
  header->biBitCount = 32;
  header->biCompression = BI_RGB;
  header->biSizeImage = static_cast<DWORD>(pixel_bytes);

  BYTE* dest = static_cast<BYTE*>(locked) + sizeof(BITMAPINFOHEADER);
  for (UINT row = 0; row < height; ++row) {
    const BYTE* source_row =
        pixels.data() + (static_cast<size_t>(height - 1 - row) * stride);
    memcpy(dest + (static_cast<size_t>(row) * stride), source_row, stride);
  }
  GlobalUnlock(dib);

  if (!OpenClipboard(hwnd)) {
    GlobalFree(dib);
    return std::string("OpenClipboard failed");
  }
  if (!EmptyClipboard()) {
    CloseClipboard();
    GlobalFree(dib);
    return std::string("EmptyClipboard failed");
  }
  if (SetClipboardData(CF_DIB, dib) == nullptr) {
    CloseClipboard();
    GlobalFree(dib);
    return std::string("SetClipboardData(CF_DIB) failed");
  }
  CloseClipboard();
  return std::nullopt;
}

// Decodes |path| via WIC, scales to |size|x|size| 32bpp BGRA, and builds a
// color+mask HICON. Returns nullptr on any failure. Caller owns the result and
// must DestroyIcon it. Mirrors the WIC pipeline used by CopyImageFileToClipboard.
HICON CreateIconFromImageFile(const std::wstring& path, int size) {
  if (path.empty() || size <= 0) {
    return nullptr;
  }
  using Microsoft::WRL::ComPtr;
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    return nullptr;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                          WICDecodeMetadataCacheOnLoad, &decoder);
  if (FAILED(hr)) {
    return nullptr;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr)) {
    return nullptr;
  }
  ComPtr<IWICBitmapScaler> scaler;
  hr = factory->CreateBitmapScaler(&scaler);
  if (FAILED(hr)) {
    return nullptr;
  }
  hr = scaler->Initialize(frame.Get(), size, size,
                          WICBitmapInterpolationModeFant);
  if (FAILED(hr)) {
    return nullptr;
  }
  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) {
    return nullptr;
  }
  hr = converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppBGRA,
                             WICBitmapDitherTypeNone, nullptr, 0.0,
                             WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) {
    return nullptr;
  }
  const UINT stride = static_cast<UINT>(size) * 4;
  std::vector<BYTE> pixels(static_cast<size_t>(stride) * size);
  hr = converter->CopyPixels(nullptr, stride,
                             static_cast<UINT>(pixels.size()), pixels.data());
  if (FAILED(hr)) {
    return nullptr;
  }
  BITMAPINFO bmi;
  ZeroMemory(&bmi, sizeof(bmi));
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = size;
  bmi.bmiHeader.biHeight = -size;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* dib_pixels = nullptr;
  HBITMAP color = CreateDIBSection(nullptr, &bmi, DIB_RGB_COLORS, &dib_pixels,
                                   nullptr, 0);
  if (color == nullptr || dib_pixels == nullptr) {
    if (color != nullptr) {
      DeleteObject(color);
    }
    return nullptr;
  }
  memcpy(dib_pixels, pixels.data(), pixels.size());
  // 32bpp BGRA color bitmap 带 alpha 通道时，CreateIconIndirect 直接用 color 的
  // alpha 做混合、忽略 AND mask 的内容，故 mask 仅需存在（1bpp 占位）即可，内容
  // 无关。若日后把 color 改回 24bpp，必须改用真正的 AND mask，否则透明区域花屏。
  HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
  if (mask == nullptr) {
    DeleteObject(color);
    return nullptr;
  }
  ICONINFO icon_info;
  ZeroMemory(&icon_info, sizeof(icon_info));
  icon_info.fIcon = TRUE;
  icon_info.hbmColor = color;
  icon_info.hbmMask = mask;
  HICON icon = CreateIconIndirect(&icon_info);
  DeleteObject(color);
  DeleteObject(mask);
  return icon;
}

// Resolves an existing file to the kernel's final DOS path so equivalent path
// spellings (8.3 names, junctions, symlinks, \\?\ prefixes) compare by identity.
// Returns empty when the file cannot be opened/resolved.
std::wstring FinalPathForComparison(const std::wstring& path) {
  if (path.empty()) {
    return std::wstring();
  }
  HANDLE file = CreateFileW(path.c_str(), 0,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return std::wstring();
  }
  const DWORD required = GetFinalPathNameByHandleW(
      file, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (required == 0) {
    CloseHandle(file);
    return std::wstring();
  }
  std::wstring resolved(required, L'\0');
  const DWORD written = GetFinalPathNameByHandleW(
      file, resolved.data(), required,
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  CloseHandle(file);
  if (written == 0 || written >= required) {
    return std::wstring();
  }
  resolved.resize(written);
  return resolved;
}

// Outcome of pointing one .lnk at an icon.
enum class ShortcutIconResult {
  kSkipped,    // No such .lnk, target mismatch, or a COM step failed.
  kUnchanged,  // IconLocation already is |icon_path|,0: nothing written.
  kRewritten,  // IconLocation rewritten and saved.
};

// Points a single existing .lnk at |icon_path| (index 0), preserving its
// target/args/workdir, then notifies the shell to re-read it. A missing .lnk
// (user deleted it, or a portable unzip install with no shortcuts) is a soft
// skip, not an error. When the .lnk already carries exactly this icon nothing
// is saved or notified: cold start replays this sync on every launch, and an
// unconditional Save + shell notify made Explorer re-read icons each time.
ShortcutIconResult SetShortcutIconLocation(
    const std::wstring& lnk_path,
    const std::wstring& icon_path,
    bool require_current_executable = false) {
  if (lnk_path.empty() || icon_path.empty()) {
    return ShortcutIconResult::kSkipped;
  }
  if (GetFileAttributesW(lnk_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return ShortcutIconResult::kSkipped;  // No such .lnk: soft skip.
  }
  using Microsoft::WRL::ComPtr;
  ComPtr<IShellLinkW> shell_link;
  HRESULT hr =
      CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                       IID_PPV_ARGS(&shell_link));
  if (FAILED(hr)) {
    return ShortcutIconResult::kSkipped;
  }
  ComPtr<IPersistFile> persist_file;
  hr = shell_link.As(&persist_file);
  if (FAILED(hr)) {
    return ShortcutIconResult::kSkipped;
  }
  // Load the existing .lnk so target/args/workdir survive; we only touch icon.
  hr = persist_file->Load(lnk_path.c_str(), STGM_READWRITE);
  if (FAILED(hr)) {
    return ShortcutIconResult::kSkipped;
  }
  if (require_current_executable) {
    std::vector<wchar_t> target(32768, L'\0');
    WIN32_FIND_DATAW target_data = {};
    hr = shell_link->GetPath(target.data(), static_cast<int>(target.size()),
                             &target_data, SLGP_UNCPRIORITY);
    if (FAILED(hr) || target.front() == L'\0') {
      return ShortcutIconResult::kSkipped;
    }
    std::vector<wchar_t> executable(32768, L'\0');
    const DWORD executable_size = GetModuleFileNameW(
        nullptr, executable.data(), static_cast<DWORD>(executable.size()));
    if (executable_size == 0 ||
        executable_size >= static_cast<DWORD>(executable.size())) {
      return ShortcutIconResult::kSkipped;
    }
    const std::wstring target_final = FinalPathForComparison(target.data());
    const std::wstring executable_final =
        FinalPathForComparison(executable.data());
    if (target_final.empty() || executable_final.empty() ||
        CompareStringOrdinal(target_final.c_str(), -1,
                             executable_final.c_str(), -1, TRUE) !=
            CSTR_EQUAL) {
      return ShortcutIconResult::kSkipped;
    }
  }
  std::vector<wchar_t> current_icon(32768, L'\0');
  int current_index = 0;
  hr = shell_link->GetIconLocation(current_icon.data(),
                                   static_cast<int>(current_icon.size()),
                                   &current_index);
  if (SUCCEEDED(hr) && current_index == 0 &&
      CompareStringOrdinal(current_icon.data(), -1, icon_path.c_str(), -1,
                           TRUE) == CSTR_EQUAL) {
    return ShortcutIconResult::kUnchanged;
  }
  hr = shell_link->SetIconLocation(icon_path.c_str(), 0);
  if (FAILED(hr)) {
    return ShortcutIconResult::kSkipped;
  }
  hr = persist_file->Save(lnk_path.c_str(), TRUE);
  if (FAILED(hr)) {
    return ShortcutIconResult::kSkipped;
  }
  // Ask the shell to re-read this .lnk's icon.
  SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, lnk_path.c_str(), nullptr);
  return ShortcutIconResult::kRewritten;
}

// Joins a known-folder path with |relative| (a path tail relative to the
// folder root, e.g. the desktop .lnk filename or the Start menu group
// subfolder + .lnk). Returns empty on failure.
std::wstring MyComicShortcutInFolder(REFKNOWNFOLDERID folder_id,
                                    const wchar_t* relative) {
  PWSTR folder = nullptr;
  HRESULT hr = SHGetKnownFolderPath(folder_id, 0, nullptr, &folder);
  if (FAILED(hr) || folder == nullptr) {
    if (folder != nullptr) {
      CoTaskMemFree(folder);
    }
    return std::wstring();
  }
  std::wstring path(folder);
  CoTaskMemFree(folder);
  if (!path.empty() && path.back() != L'\\') {
    path.push_back(L'\\');
  }
  path += relative;
  return path;
}

// TODO-901: points the desktop + Start menu MyComic shortcuts at |icon_path|.
bool ApplyShortcutIcon(const std::wstring& icon_path) {
  if (icon_path.empty()) {
    return false;
  }
  bool any = false;
  bool rewritten = false;
  const auto record = [&any, &rewritten](ShortcutIconResult result) {
    any |= result != ShortcutIconResult::kSkipped;
    rewritten |= result == ShortcutIconResult::kRewritten;
  };
  const std::wstring desktop_lnk =
      MyComicShortcutInFolder(FOLDERID_Desktop, L"MyComic.lnk");
  if (!desktop_lnk.empty()) {
    record(SetShortcutIconLocation(desktop_lnk, icon_path));
  }
  const std::wstring programs_lnk =
      MyComicShortcutInFolder(FOLDERID_Programs, L"MyComic\\MyComic.lnk");
  if (!programs_lnk.empty()) {
    record(SetShortcutIconLocation(programs_lnk, icon_path));
  }
  const std::wstring taskbar_lnk = MyComicShortcutInFolder(
      FOLDERID_UserPinned, L"TaskBar\\MyComic.lnk");
  if (!taskbar_lnk.empty()) {
    record(SetShortcutIconLocation(taskbar_lnk, icon_path, true));
  }
  if (rewritten) {
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  }
  return any;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() = default;

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // Title-bar theming channel: Dart pushes surface/onSurface colors so the
  // native caption follows the in-app theme (see window_caption_channel.dart).
  caption_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.mycomic/window",
          &flutter::StandardMethodCodec::GetInstance());
  caption_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setCaptionColors") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            const auto caption_it =
                args->find(flutter::EncodableValue("caption"));
            const auto text_it = args->find(flutter::EncodableValue("text"));
            // Dart sends ARGB ints; opaque colors (alpha 0xFF) exceed int32
            // range and arrive as int64. TryGetLongValue() accepts either
            // int32 or int64 without throwing (unlike std::get<int>).
            const int64_t caption_argb =
                caption_it != args->end()
                    ? caption_it->second.TryGetLongValue().value_or(0)
                    : 0;
            const int64_t text_argb =
                text_it != args->end()
                    ? text_it->second.TryGetLongValue().value_or(0)
                    : 0;
            ApplyCaptionColors(static_cast<uint32_t>(caption_argb),
                               static_cast<uint32_t>(text_argb));
          }
          result->Success();
        } else if (call.method_name() == "setSystemBackdrop") {
          const auto* backdrop_args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          auto read_flag = [backdrop_args](const char* key) -> bool {
            if (backdrop_args == nullptr) {
              return false;
            }
            const auto it = backdrop_args->find(flutter::EncodableValue(key));
            if (it == backdrop_args->end()) {
              return false;
            }
            const bool* value = std::get_if<bool>(&it->second);
            return value != nullptr && *value;
          };
          result->Success(flutter::EncodableValue(
              ApplySystemBackdrop(read_flag("mica"), read_flag("dark"))));
        } else if (call.method_name() == "beginStartupWindowPreparation") {
          // Visible integration-test windows retain normal resize delivery.
          BeginStartupWindowPreparation();
          result->Success();
        } else if (call.method_name() == "endStartupWindowPreparation") {
          EndStartupWindowPreparation();
          result->Success();
        } else if (call.method_name() == "setCaptionMaxButtonRect") {
          // Physical-pixel rect of the Flutter maximize button in the Flutter
          // view (= child client coordinates); all zero = disabled.
          const auto* rect_args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          auto read_int = [rect_args](const char* key) -> LONG {
            if (rect_args == nullptr) {
              return 0;
            }
            const auto it = rect_args->find(flutter::EncodableValue(key));
            if (it == rect_args->end()) {
              return 0;
            }
            return static_cast<LONG>(it->second.TryGetLongValue().value_or(0));
          };
          const RECT rect{read_int("left"), read_int("top"), read_int("right"),
                          read_int("bottom")};
          caption_snap_button_.SetRect(rect);
          result->Success();
        } else if (call.method_name() == "clearTaskbarFlash") {
          // TODO-615: actively stop any taskbar "flash / request attention"
          // state on the main window. SetForegroundWindow (window_manager's
          // show()/focus()/setAlwaysOnTop() degrade into it under the foreground
          // lock) flashes our taskbar button until the user clicks it.
          HWND hwnd = GetHandle();
          if (hwnd != nullptr) {
            FLASHWINFO flash_info;
            flash_info.cbSize = sizeof(FLASHWINFO);
            flash_info.hwnd = hwnd;
            flash_info.dwFlags = FLASHW_STOP;
            flash_info.uCount = 0;
            flash_info.dwTimeout = 0;
            FlashWindowEx(&flash_info);
          }
          result->Success();
        } else if (call.method_name() == "setFullscreen") {
          // BUG-1933: runner-owned flash-free fullscreen (Win32Window::
          // SetFullscreen). Dart routes F11 and the player's native fullscreen
          // here on Windows instead of window_manager / media_kit, whose
          // style-stripping implementations reveal the redirection surface for
          // a frame (white in a light theme).
          const auto* fs_args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          bool enter = false;
          if (fs_args != nullptr) {
            const auto fs_it =
                fs_args->find(flutter::EncodableValue("fullscreen"));
            if (fs_it != fs_args->end()) {
              const bool* value = std::get_if<bool>(&fs_it->second);
              if (value != nullptr) {
                enter = *value;
              }
            }
          }
          const bool was_fullscreen = IsFullscreen();
          if (!enter) {
            // BUG-2964: give the frame its normal DWM rendering back while it
            // still hangs off-screen, before the geometry restores it.
            my_comic::MainSurfaceState leaving = main_surface_state();
            leaving.fullscreen = false;
            ApplyMainSurfaceComposition(leaving);
          }
          SetFullscreen(enter);
          ApplyMainSurfaceComposition();
          // A fullscreen/maximized transition can preserve the client size,
          // so WM_SIZE alone does not guarantee a fresh Flutter presentation.
          if (flutter_controller_ && was_fullscreen != IsFullscreen()) {
            flutter_controller_->ForceRedraw();
          }
          result->Success();
        } else if (call.method_name() == "isFullscreen") {
          result->Success(flutter::EncodableValue(IsFullscreen()));
        } else if (call.method_name() == "reportRasterizedFrameSize") {
          // BUG-2462: Dart's rasterised-frame size report, the authoritative
          // "the engine now presents at this size" signal for the child
          // resize gate (child_resize_gate.h).
          const auto* size_args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          int32_t width = 0;
          int32_t height = 0;
          if (size_args != nullptr) {
            const auto w_it = size_args->find(flutter::EncodableValue("width"));
            const auto h_it =
                size_args->find(flutter::EncodableValue("height"));
            if (w_it != size_args->end()) {
              if (const int32_t* v = std::get_if<int32_t>(&w_it->second)) {
                width = *v;
              }
            }
            if (h_it != size_args->end()) {
              if (const int32_t* v = std::get_if<int32_t>(&h_it->second)) {
                height = *v;
              }
            }
          }
          OnChildFrameRasterized(width, height);
          result->Success();
        } else if (call.method_name() == "setWindowIcon") {
          // Runtime window/taskbar icon (preset or user-picked image).
          const auto* icon_args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          std::wstring icon_path;
          if (icon_args != nullptr) {
            const auto path_it =
                icon_args->find(flutter::EncodableValue("path"));
            if (path_it != icon_args->end()) {
              const auto* s = std::get_if<std::string>(&path_it->second);
              if (s != nullptr) {
                icon_path = Utf8ToWideString(*s);
              }
            }
          }
          if (icon_path.empty()) {
            result->Error("bad_args", "Missing icon path");
          } else {
            const bool ok = ApplyWindowIcon(icon_path);
            result->Success(flutter::EncodableValue(ok));
          }
        } else if (call.method_name() == "setShortcutIcon") {
          // TODO-901: rewrite the desktop + Start menu MyComic .lnk
          // IconLocation to the freshly generated multi-size .ico Dart wrote.
          const auto* shortcut_args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          std::wstring ico_path;
          if (shortcut_args != nullptr) {
            const auto path_it =
                shortcut_args->find(flutter::EncodableValue("iconPath"));
            if (path_it != shortcut_args->end()) {
              const auto* s = std::get_if<std::string>(&path_it->second);
              if (s != nullptr) {
                ico_path = Utf8ToWideString(*s);
              }
            }
          }
          if (ico_path.empty()) {
            result->Error("bad_args", "Missing iconPath");
          } else {
            const bool ok = ApplyShortcutIcon(ico_path);
            result->Success(flutter::EncodableValue(ok));
          }
        } else {
          result->NotImplemented();
        }
      });

  clipboard_image_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.mycomic.reader/clipboard_image",
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_image_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "readImage") {
          // 剪贴板里的位图（编成 PNG）或复制的文件路径。
          my_comic_clipboard::ClipboardImage image;
          const std::optional<std::string> error =
              my_comic_clipboard::ReadClipboardImage(GetHandle(), &image);
          if (error.has_value()) {
            result->Error("read_failed", error.value());
            return;
          }
          if (image.empty()) {
            result->Success();
            return;
          }
          flutter::EncodableMap map;
          if (!image.bytes.empty()) {
            map[flutter::EncodableValue("bytes")] =
                flutter::EncodableValue(std::move(image.bytes));
          }
          if (!image.paths.empty()) {
            flutter::EncodableList paths;
            for (std::string& path : image.paths) {
              paths.emplace_back(std::move(path));
            }
            map[flutter::EncodableValue("paths")] =
                flutter::EncodableValue(std::move(paths));
          }
          result->Success(flutter::EncodableValue(std::move(map)));
          return;
        }
        if (call.method_name() != "copyImageFile") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("bad_args", "Expected a map with an image path");
          return;
        }
        const auto path_it = args->find(flutter::EncodableValue("path"));
        if (path_it == args->end()) {
          result->Error("bad_args", "Missing image path");
          return;
        }
        const auto* path = std::get_if<std::string>(&path_it->second);
        if (path == nullptr) {
          result->Error("bad_args", "Image path must be a string");
          return;
        }
        const std::wstring wide_path = Utf8ToWideString(*path);
        const std::optional<std::string> error =
            CopyImageFileToClipboard(GetHandle(), wide_path);
        if (error.has_value()) {
          result->Error("copy_failed", error.value());
          return;
        }
        result->Success();
      });

  // TODO-1092: 系统强调色/主题色实时变更通知 channel。
  system_theme_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.mycomic/system_theme",
          &flutter::StandardMethodCodec::GetInstance());

  windows_ime_space_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.mycomic/windows_ime_space",
          &flutter::StandardMethodCodec::GetInstance());

  RegisterImeGuardChannel();
  RegisterSystemFontListChannel(flutter_controller_->engine()->messenger());
  RegisterSystemTransparencyChannel(flutter_controller_->engine()->messenger());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  caption_snap_button_.Attach(
      GetHandle(), flutter_controller_->view()->GetNativeWindow(),
      [this](const char* event) {
        if (caption_channel_) {
          caption_channel_->InvokeMethod(
              "onCaptionMaxButton",
              std::make_unique<flutter::EncodableValue>(std::string(event)));
        }
      });
  return true;
}

void FlutterWindow::RegisterImeGuardChannel() {
  // BUG-1450: Dart owns focus knowledge, the runner owns the HWND. Dart calls
  // setImeEnabled(false) while nothing editable holds focus so a CJK IME stops
  // consuming shortcut keys, and setImeEnabled(true) the moment a text field
  // takes focus so Chinese/Japanese input keeps working everywhere.
  ime_association_guard_ = ImeAssociationGuard(
      [](HWND hwnd, bool enable, void*) {
        return ApplyImeAssociation(hwnd, enable);
      },
      nullptr);

  windows_ime_guard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.mycomic/windows_ime_guard",
          &flutter::StandardMethodCodec::GetInstance());

  windows_ime_guard_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setImeEnabled") {
          result->NotImplemented();
          return;
        }
        const auto* enable = std::get_if<bool>(call.arguments());
        if (enable == nullptr) {
          result->Error("bad_args", "setImeEnabled expects a bool");
          return;
        }
        // The IME context is per-HWND and applies to whichever window holds
        // focus. Win32Window::SetChildContent does SetFocus(child), so the
        // Flutter view — not the top-level frame — is the window the IME talks
        // to. Fall back to the frame only if the view is gone (teardown).
        HWND target = flutter_controller_ && flutter_controller_->view()
                          ? flutter_controller_->view()->GetNativeWindow()
                          : nullptr;
        if (target == nullptr) {
          target = GetHandle();
        }
        const ImeAssociationUpdate update =
            ime_association_guard_.SetEnabled(target, *enable);
        if (update == ImeAssociationUpdate::kFailed) {
          // Let Dart clear its optimistic cache so the same desired state can
          // be retried.
          result->Error("ime_association_failed",
                        "ImmAssociateContextEx failed for the Flutter view");
          return;
        }
        result->Success();
      });
}

void FlutterWindow::NotifySystemColorChanged() {
  // TODO-1092: 把「系统强调色/主题色已变」事件推给 Dart。WndProc 跑在 platform
  // 线程，InvokeMethod 可直接调用。channel 在 OnCreate 建好前（极早期消息）可能为
  // 空，做 null 保护后静默忽略——启动完成后所有实时变更都会被投递。
  if (system_theme_channel_) {
    system_theme_channel_->InvokeMethod(
        "onSystemColorChanged", std::make_unique<flutter::EncodableValue>());
  }
}

void FlutterWindow::ApplyCaptionColors(uint32_t caption_argb,
                                       uint32_t text_argb) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  // ARGB (0xAARRGGBB) -> Win32 COLORREF (0x00BBGGRR). Alpha is dropped;
  // DWM caption colors are opaque.
  auto to_colorref = [](uint32_t argb) -> COLORREF {
    return RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
  };
  COLORREF caption = to_colorref(caption_argb);
  COLORREF text = to_colorref(text_argb);
  // DWMWA_CAPTION_COLOR (35) / DWMWA_TEXT_COLOR (36): Windows 11 build 22000+.
  // On older Windows these return a failure HRESULT that we intentionally
  // ignore, leaving the system-drawn title bar untouched.
  DwmSetWindowAttribute(hwnd, 35, &caption, sizeof(caption));
  DwmSetWindowAttribute(hwnd, 36, &text, sizeof(text));
  // BUG-1916: the caption colour Dart pushes is the theme's surface colour —
  // the same colour the app paints its page background with. Use it for this
  // window's own surface too, so a maximize / restore / DPI transition that
  // momentarily shows the surface shows the app background, not the splash.
  SetBackdropColor(caption);
}

bool FlutterWindow::ApplySystemBackdrop(bool mica, bool dark) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return false;
  }
  // DWMWA_USE_IMMERSIVE_DARK_MODE (20): Mica tints itself from this flag.
  const BOOL dark_mode = dark ? TRUE : FALSE;
  DwmSetWindowAttribute(hwnd, 20, &dark_mode, sizeof(dark_mode));
  if (mica) {
    // DWMWA_SYSTEMBACKDROP_TYPE (38) = DWMSBT_MAINWINDOW (2), Windows 11 22621+.
    // 22000 only knows the undocumented DWMWA_MICA_EFFECT (1029) = TRUE.
    const int backdrop_type = 2;
    bool active = SUCCEEDED(DwmSetWindowAttribute(
        hwnd, 38, &backdrop_type, sizeof(backdrop_type)));
    if (!active) {
      const BOOL mica_effect = TRUE;
      active = SUCCEEDED(
          DwmSetWindowAttribute(hwnd, 1029, &mica_effect, sizeof(mica_effect)));
    }
    if (!active) {
      return false;
    }
    // The backdrop only shows through client pixels DWM treats as glass:
    // the frame is extended over the whole client area (transparent Flutter
    // pixels and the black surface fill then reveal Mica).
    SetSystemBackdrop(true);
    ApplyMainSurfaceComposition();
    return true;
  }
  const int backdrop_none = 1;  // DWMSBT_NONE
  DwmSetWindowAttribute(hwnd, 38, &backdrop_none, sizeof(backdrop_none));
  const BOOL mica_off = FALSE;
  DwmSetWindowAttribute(hwnd, 1029, &mica_off, sizeof(mica_off));
  // Back to window_manager's hidden-title-bar shadow margins.
  SetSystemBackdrop(false);
  ApplyMainSurfaceComposition();
  return false;
}

void FlutterWindow::ApplyMainSurfaceComposition(
    const my_comic::MainSurfaceState& state) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  const MARGINS margins = my_comic::MainFrameMargins(state);
  DwmExtendFrameIntoClientArea(hwnd, &margins);
  const DWMNCRENDERINGPOLICY policy =
      my_comic::MainSurfaceNcRenderingDisabled(state) ? DWMNCRP_DISABLED
                                                   : DWMNCRP_USEWINDOWSTYLE;
  DwmSetWindowAttribute(hwnd, DWMWA_NCRENDERING_POLICY, &policy,
                        sizeof(policy));
}

void FlutterWindow::ApplyMainSurfaceComposition() {
  ApplyMainSurfaceComposition(main_surface_state());
}

bool FlutterWindow::ApplyWindowIcon(const std::wstring& path) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return false;
  }
  int big_size = GetSystemMetrics(SM_CXICON);
  int small_size = GetSystemMetrics(SM_CXSMICON);
  HICON new_big = CreateIconFromImageFile(path, big_size > 0 ? big_size : 32);
  HICON new_small =
      CreateIconFromImageFile(path, small_size > 0 ? small_size : 16);
  if (new_big == nullptr && new_small == nullptr) {
    return false;
  }
  if (new_big != nullptr) {
    SendMessage(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(new_big));
    if (icon_big_ != nullptr) {
      DestroyIcon(icon_big_);
    }
    icon_big_ = new_big;
  }
  if (new_small != nullptr) {
    SendMessage(hwnd, WM_SETICON, ICON_SMALL,
                reinterpret_cast<LPARAM>(new_small));
    if (icon_small_ != nullptr) {
      DestroyIcon(icon_small_);
    }
    icon_small_ = new_small;
  }
  return true;
}

void FlutterWindow::OnDestroy() {
  // Before the Flutter view / channels go away: unhook the child subclass and
  // drop the Dart relay.
  caption_snap_button_.Detach();
  if (icon_big_ != nullptr) {
    DestroyIcon(icon_big_);
    icon_big_ = nullptr;
  }
  if (icon_small_ != nullptr) {
    DestroyIcon(icon_small_);
    icon_small_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::OnDisplayRecovered() {
  // The display came back (monitor power-on / WM_DISPLAYCHANGE). The engine does
  // not produce a new frame on its own, so the window can stay blank until some
  // other event wakes it. Force one fresh frame (TODO-689).
  if (!flutter_controller_) {
    return;
  }
  flutter_controller_->ForceRedraw();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // BUG-1239: inspect VK_PROCESSKEY before Flutter handles the message. The
  // engine deliberately reports IME-owned keys as physical=0/logical=0, so
  // checking after HandleTopLevelWindowProc can no longer identify Space.
  // Notify Dart without consuming the Win32 message; Flutter/IME processing
  // continues unchanged.
  if (windows_ime_space_channel_) {
    const ImeSpaceModifierState modifiers{
        GetKeyState(VK_CONTROL) < 0, GetKeyState(VK_SHIFT) < 0,
        GetKeyState(VK_MENU) < 0,    GetKeyState(VK_LWIN) < 0,
        GetKeyState(VK_RWIN) < 0};
    DispatchInitialUnmodifiedImeSpaceDown(
        message, wparam, lparam, modifiers,
        [](void* context) {
          auto* channel = static_cast<
              flutter::MethodChannel<flutter::EncodableValue>*>(context);
          channel->InvokeMethod(
              "onImeSpaceDown",
              std::make_unique<flutter::EncodableValue>());
        },
        windows_ime_space_channel_.get());
  }

  // Snap Layouts hit testing for the app-drawn maximize button (before the
  // plugins: window_manager answers WM_NCHITTEST on its own otherwise).
  if (std::optional<LRESULT> snap =
          caption_snap_button_.HandleTopLevel(hwnd, message, wparam, lparam)) {
    return *snap;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    // BUG-1933: fullscreen deliberately sizes the window LARGER than the
    // monitor (frame off-screen, see Win32Window::SetFullscreen). The default
    // ptMaxTrackSize (SM_C*MAXTRACK) silently clamps that SetWindowPos and
    // leaves a strip of desktop/taskbar exposed at the bottom. window_manager's
    // delegate consumes WM_GETMINMAXINFO (it applies our minimum size), so the
    // override must happen here, after the delegates ran: lift the max track
    // size while fullscreen, keeping whatever minimums the plugins wrote.
    if (message == WM_GETMINMAXINFO && IsFullscreen()) {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      if (info != nullptr) {
        // Generous fixed headroom over any real monitor: monitor + frame.
        info->ptMaxTrackSize.x = GetSystemMetrics(SM_CXVIRTUALSCREEN) + 256;
        info->ptMaxTrackSize.y = GetSystemMetrics(SM_CYVIRTUALSCREEN) + 256;
      }
      return 0;
    }
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
    // TODO-1092: 系统强调色/主题色实时变更。三条广播覆盖不同触发面：
    //   WM_DWMCOLORIZATIONCOLORCHANGED — DWM 玻璃/强调色变（改强调色即发）；
    //   WM_SETTINGCHANGE + lParam=="ImmersiveColorSet" — 设置里改「浅色/深色/强调色」；
    //   WM_THEMECHANGED — 经典主题切换。
    // 收到后通知 Dart 重新取系统色（refreshSystemPalette），随后 **不消费** 消息、
    // 落到下面 Win32Window::MessageHandler 走默认处理，保持既有其它消息分支语义不变。
    case WM_DWMCOLORIZATIONCOLORCHANGED:
    case WM_THEMECHANGED:
      NotifySystemColorChanged();
      break;
    case WM_SETTINGCHANGE: {
      const auto* area = reinterpret_cast<const wchar_t*>(lparam);
      if (area != nullptr && wcscmp(area, L"ImmersiveColorSet") == 0) {
        NotifySystemColorChanged();
        // 「透明效果」开关同样以 ImmersiveColorSet 广播；内部按值去重。
        NotifySystemTransparencySettingChanged();
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
