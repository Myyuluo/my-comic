// ShouldWithholdGameCursor 的真 Win32 窗口测试（BUG-2864）。
//
// 判据里的「窗口归哪个线程」「类名是什么」只有系统自己能作证，所以这里真建窗口：
// 游戏线程 = 本测试主线程；MyComic 浮层 = 另一条线程建的窗口（runner 查词卡在 MyComic.exe 里、
// 注入侧位图卡在游戏进程的独立 UI 线程上，两者对游戏线程而言都是「别的线程」）。窗口全部
// 放到屏幕外、不显示，跑测试时不在开发机桌面上闪窗、不抢焦点。
// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 本文件用 Expect() 计数而不是 assert，但守卫要求这条不变式对所有原生测试一致成立，
// 免得后来者往里加 assert 时静默失效。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include "overlay_cursor_guard.h"

#include <cstdio>

namespace {

const wchar_t* const kMyComicOverlayClass = L"MyComicOverlayCursorGuardTestCard";
const wchar_t* const kForeignOverlayClass = L"ThirdPartyCursorGuardTestOverlay";
int g_failures = 0;

void Expect(bool condition, const char* what) {
  if (condition) return;
  ++g_failures;
  std::fprintf(stderr, "FAIL: %s\n", what);
}

void RegisterTestClass(const wchar_t* name) {
  WNDCLASSW wc = {};
  wc.lpfnWndProc = &DefWindowProcW;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = name;
  RegisterClassW(&wc);
}

HWND CreateHiddenPopup(const wchar_t* class_name) {
  return CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, class_name, L"",
                         WS_POPUP, -32000, -32000, 64, 64, nullptr, nullptr,
                         GetModuleHandleW(nullptr), nullptr);
}

// 另一条线程建的窗口；窗口随建它的线程一起销毁，所以线程要活到判定结束。
struct OverlayThread {
  HANDLE created = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE release = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE thread = nullptr;
  DWORD thread_id = 0;
  HWND my_comic = nullptr;
  HWND foreign = nullptr;

  static DWORD WINAPI Run(LPVOID param) {
    auto* self = static_cast<OverlayThread*>(param);
    self->my_comic = CreateHiddenPopup(kMyComicOverlayClass);
    self->foreign = CreateHiddenPopup(kForeignOverlayClass);
    SetEvent(self->created);
    WaitForSingleObject(self->release, INFINITE);
    DestroyWindow(self->my_comic);
    DestroyWindow(self->foreign);
    return 0;
  }

  void Start() {
    thread = CreateThread(nullptr, 0, &Run, this, 0, &thread_id);
    WaitForSingleObject(created, INFINITE);
  }

  void Stop() {
    SetEvent(release);
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
    CloseHandle(created);
    CloseHandle(release);
  }
};

void TestClassPrefix() {
  using my_comic_voice_hook::IsMyComicOverlayWindowClass;
  Expect(IsMyComicOverlayWindowClass(L"MyComicGlobalLookupWindow"),
         "runner lookup card class is a MyComic overlay");
  Expect(IsMyComicOverlayWindowClass(L"MyComicAttachedTextSurfaceWindow"),
         "attached text surface class is a MyComic overlay");
  Expect(IsMyComicOverlayWindowClass(L"MyComicLookupOverlay"),
         "injected bitmap card class is a MyComic overlay");
  Expect(!IsMyComicOverlayWindowClass(L"SiglusEngine"),
         "game window class is not a MyComic overlay");
  Expect(!IsMyComicOverlayWindowClass(L"Fush"), "truncated prefix is rejected");
  Expect(!IsMyComicOverlayWindowClass(L"myComicLowercase"),
         "prefix match is case-sensitive like the registered classes");
  Expect(!IsMyComicOverlayWindowClass(L""), "empty class is rejected");
  Expect(!IsMyComicOverlayWindowClass(nullptr), "null class is rejected");
}

void TestWithholdDecision() {
  using my_comic_voice_hook::ShouldWithholdGameCursor;
  const DWORD game_thread = GetCurrentThreadId();
  OverlayThread overlay;
  overlay.Start();
  Expect(overlay.my_comic != nullptr && overlay.foreign != nullptr,
         "overlay thread created its windows");

  // 根因场景：光标压在别的线程的 MyComic 浮层上，游戏线程每帧 SetCursor。
  Expect(ShouldWithholdGameCursor(overlay.my_comic, game_thread),
         "game cursor is withheld over a foreign-thread MyComic overlay");
  // 第三方覆盖窗口不归本 DLL 管。
  Expect(!ShouldWithholdGameCursor(overlay.foreign, game_thread),
         "non-MyComic foreign windows are left alone");
  // 浮层线程自己设光标（它的 WM_SETCURSOR）永远放行。
  Expect(!ShouldWithholdGameCursor(overlay.my_comic, overlay.thread_id),
         "the overlay's own thread may always set its cursor");

  // 同线程的 MyComic 类窗口（游戏线程自己的窗口）照常放行。
  const HWND same_thread_my_comic = CreateHiddenPopup(kMyComicOverlayClass);
  Expect(same_thread_my_comic != nullptr, "same-thread window created");
  Expect(!ShouldWithholdGameCursor(same_thread_my_comic, game_thread),
         "a window owned by the calling thread never withholds its cursor");

  // 游戏线程自己持有捕获（拖拽中）：鼠标归属窗就是捕获窗，光标归游戏。
  SetCapture(same_thread_my_comic);
  Expect(my_comic_voice_hook::MouseOwningRootWindow() == same_thread_my_comic,
         "the caller's capture window owns the mouse");
  Expect(!my_comic_voice_hook::ShouldWithholdGameCursorNow(),
         "the game keeps its cursor while it holds the capture");
  ReleaseCapture();
  DestroyWindow(same_thread_my_comic);

  Expect(!ShouldWithholdGameCursor(nullptr, game_thread),
         "no window under the cursor never withholds");

  const HWND stale = overlay.my_comic;
  overlay.Stop();
  // 浮层已销毁（MyComic 退出 / 卡片关掉）：失败放行，游戏光标立刻恢复。
  Expect(!ShouldWithholdGameCursor(stale, game_thread),
         "a destroyed overlay fails open");
}

}  // namespace

int main() {
  RegisterTestClass(kMyComicOverlayClass);
  RegisterTestClass(kForeignOverlayClass);
  TestClassPrefix();
  TestWithholdDecision();
  if (g_failures != 0) {
    std::fprintf(stderr, "%d failure(s)\n", g_failures);
    return 1;
  }
  std::printf("overlay_cursor_guard_test: OK\n");
  return 0;
}
