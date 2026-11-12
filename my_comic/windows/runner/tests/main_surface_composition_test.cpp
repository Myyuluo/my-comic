// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"。与 window_activation_policy_test.cpp 同一写法。
#undef NDEBUG

#include "../main_surface_composition.h"

#include <iostream>
#include <string>

namespace {

using my_comic::MainFrameMargins;
using my_comic::MainSurfaceSeeThrough;
using my_comic::MainSurfaceState;

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

bool SameMargins(const MARGINS& a, int left, int right, int top, int bottom) {
  return a.cxLeftWidth == left && a.cxRightWidth == right &&
         a.cyTopHeight == top && a.cyBottomHeight == bottom;
}

}  // namespace

int main() {
  bool ok = true;

  const MainSurfaceState plain{false, false};
  const MainSurfaceState mica{true, false};
  const MainSurfaceState mica_fullscreen{true, true};
  const MainSurfaceState plain_fullscreen{false, true};

  // Plain window keeps window_manager's hidden-title-bar shadow (1 px top).
  ok &= Expect(SameMargins(MainFrameMargins(plain), 0, 0, 1, 0),
               "plain window keeps the 1 px top shadow margin");
  ok &= Expect(!MainSurfaceSeeThrough(plain),
               "plain window paints the theme backdrop");

  // Mica: whole client area is glass.
  ok &= Expect(SameMargins(MainFrameMargins(mica), -1, -1, -1, -1),
               "Mica extends the frame over the whole client area");
  ok &= Expect(MainSurfaceSeeThrough(mica), "Mica surface is see-through");
  ok &= Expect(SameMargins(MainFrameMargins(mica_fullscreen), -1, -1, -1, -1),
               "fullscreen Mica keeps the glass margins");

  // DWM non-client rendering stays on; the opaque caption row covers row 0.
  ok &= Expect(!my_comic::MainSurfaceNcRenderingDisabled(plain),
               "plain window keeps the DWM frame");
  ok &= Expect(!my_comic::MainSurfaceNcRenderingDisabled(plain_fullscreen),
               "SDR fullscreen keeps the DWM frame");

  if (!ok) {
    return 1;
  }
  std::cout << "main_surface_composition_test: all passed\n";
  return 0;
}
