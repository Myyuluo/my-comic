#ifndef RUNNER_MAIN_SURFACE_COMPOSITION_H_
#define RUNNER_MAIN_SURFACE_COMPOSITION_H_

#include <windows.h>
#include <uxtheme.h>

namespace my_comic {

// How DWM composes the main window's own surface is decided in one place
// (BUG-2964).
//
// - a system backdrop (Windows 11 Mica): the frame is extended over the whole
//   client area so transparent Flutter pixels reveal the Mica material;
//
// GDI paints the surface with alpha 0, which DWM composes as premultiplied
// colour: a theme-coloured fill is *added* to whatever shows through. A
// see-through surface must therefore be filled with black, the only colour
// that is transparent at alpha 0.
struct MainSurfaceState {
  bool system_backdrop = false;
  bool fullscreen = false;
};

inline bool MainSurfaceSeeThrough(const MainSurfaceState& state) {
  return state.system_backdrop;
}

// Whether DWM non-client rendering (and with it the window shadow) is off.
inline bool MainSurfaceNcRenderingDisabled(const MainSurfaceState& state) {
  (void)state;
  return false;
}

// DwmExtendFrameIntoClientArea margins for |state|.
inline MARGINS MainFrameMargins(const MainSurfaceState& state) {
  if (state.system_backdrop) {
    return MARGINS{-1, -1, -1, -1};
  }
  // window_manager's hidden-title-bar shadow: 1 px at the top. Zero would drop
  // the shadow; -1 would make pure-black (AMOLED) themes see-through glass.
  return MARGINS{0, 0, 1, 0};
}

}  // namespace my_comic

#endif  // RUNNER_MAIN_SURFACE_COMPOSITION_H_
