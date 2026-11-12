// Kogado "Hy" adapter: the engine's message text lane (kogado_hy_text.inc)
// and in-game lookup (kogado_hy_lookup.inc); structural site resolution and
// every rule in kogado_hy_core.h.
//
// Identity is structural (kogado_hy_profile.h: the executable exports the Hy
// runtime library).  The hook site resolves only from the image's own code,
// read from disk so other in-process hookers cannot shift it.  Voice reaches
// the host through the generic DirectSound PCM capture.
#include "kogado_hy_profile.h"
#include "kogado_hy_text.inc"
#include "kogado_hy_lookup.inc"

class KogadoHyAdapter final : public my_comic_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "kogado_hy"; }
  // The identity is a property of the main executable: measured once, then
  // reused.  install() (startup) and diagnostics() (Poll) may run on
  // different threads: the cache is atomic.
  bool probe() const override {
    int state = probe_state_.load(std::memory_order_acquire);
    if (state == 0) {
      state = my_comic_voice_hook::MatchesKogadoHyProfile(nullptr) ? 1 : 2;
      probe_state_.store(state, std::memory_order_release);
    }
    return state == 1;
  }
  bool install() override {
    if (!probe()) return false;
    installed_ = InstallKogadoHyText() || installed_;
    // Lookup is optional: the text lane works without it.
    if (installed_) InstallKogadoHyLookup();
    return installed_;
  }
  void ProcessPendingEvents() {
    if (!installed_) return;
    ProcessKogadoHyTextTick();
    ProcessKogadoHyLookupTick();
  }
  my_comic_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    my_comic_voice_hook::LookupAdmissionReport report;
    if (KogadoHyLookupSensorInstalled()) {
      report.state = my_comic_voice_hook::kLookupAdmissionSensorInstalled;
      return report;
    }
    if (KogadoHyLookupSitesRejected()) {
      report.state = my_comic_voice_hook::kLookupAdmissionIdentityRejected;
      strncpy_s(report.executable_sha256,
                my_comic_voice_hook::HostExecutableSha256Hex(), _TRUNCATE);
      return report;
    }
    report.state = my_comic_voice_hook::kLookupAdmissionIdentityAccepted;
    return report;
  }
  my_comic_voice_hook::AdapterCapability capabilities() const override {
    return my_comic_voice_hook::AdapterCapability::kText;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    ShutdownKogadoHyLookup();
    ShutdownKogadoHyText();
    installed_ = false;
  }
  my_comic_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_kogado_hy_diag, 0, 0))};
  }

 private:
  mutable std::atomic<int> probe_state_{0};  // 0 unmeasured, 1 Hy, 2 not
  bool installed_ = false;
};
