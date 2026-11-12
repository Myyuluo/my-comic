#ifndef MYCOMIC_GALGAME_HOOK_LOOKUP_V19_RUNTIME_H_
#define MYCOMIC_GALGAME_HOOK_LOOKUP_V19_RUNTIME_H_

// Shared declarations needed by dll_main and its adapter include fragments.
// Keeping this umbrella outside dll_main's anonymous namespace is important:
// including a namespace-defining header from generic_input_shield.inc would
// accidentally create anonymous_namespace::my_comic_voice_hook.
#include "geometry_provider_registry.h"
#include "generic_input_shield.h"

#endif  // MYCOMIC_GALGAME_HOOK_LOOKUP_V19_RUNTIME_H_
