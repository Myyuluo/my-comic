#!/usr/bin/env bash
# Native artifact store names: the ONE place that turns build inputs into the artifact
# name `.github/actions/native-artifact-store` looks up. Producers (release-desktop.yml
# on develop) and consumers (build-multiplatform.yml PR gates) all call this through
# `.github/actions/native-store-names`, so a name can never be computed two ways.
#
#   names.sh <windows>
#
# Prints `key=value` lines and appends them to $GITHUB_OUTPUT when that is set, so a
# local dry run is just `bash .github/actions/native-store-names/names.sh windows`.
#
# my-comic is Windows-only. The per-package native artifacts for the deleted
# fushi_p2p / fushi_srs / fushi_anki_sync / fushidicts / fushi_aacs / fushi_torrent
# domains were removed together with those packages/engine subdomains; the only
# remaining native artifacts are the Mihon desktop runtime and the galgame helper.
#
# A name encodes every input of the build:
#   * source: `git ls-tree -r HEAD` of the input paths (blob ids of COMMITTED content).
#     Not hashFiles(): that hashes whatever is on disk at the time, and on Windows it
#     hashes the autocrlf-converted checkout. Blob ids are immune to both and identical
#     on every runner OS. On a pull_request run HEAD is the merge commit, so an input
#     tree the PR does not touch yields exactly the develop-side name.
#   * runner image: ImageOS + ImageVersion (preinstalled compilers, SDKs, vcpkg
#     revision) and, where the output is single-arch, the runner arch;
#   * toolchain pins that live outside the hashed tree: the job's CC/CXX.
# A build starts reading another directory => add it to the path lists below.
set -euo pipefail

platform="${1:?usage: names.sh windows}"

cd "$(git rev-parse --show-toplevel)"

sanitize() { printf '%s' "$1" | tr -c '0-9A-Za-z._-' '-'; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

image="$(sanitize "${ImageVersion:-unknown-image}")"
image_os="$(sanitize "${ImageOS:-unknown-os}")"
arch="$(sanitize "$(printf '%s' "${RUNNER_ARCH:-unknown-arch}" | tr 'A-Z' 'a-z')")"
toolchain_env="CC=${CC:-} CXX=${CXX:-}"

# tree_hash <extra-identity> <path>... : sha256 over the committed tree of <path>s plus
# the extra identity string. Fails when the paths match nothing (a renamed directory
# must not silently turn the name into a constant). Markdown is left out: no build in
# these trees reads a .md, and a README edit used to cold-rebuild every platform.
tree_hash() {
  local extra="$1"
  shift
  local listing
  listing="$(git ls-tree -r --full-tree HEAD -- "$@" | grep -viE '\.md$' || true)"
  if [ -z "$listing" ]; then
    echo "::error title=native-store-names::git ls-tree matched nothing for: $*" >&2
    exit 1
  fi
  { printf '%s\n' "$listing"; printf 'identity: %s\n' "$extra"; } | sha256 | cut -c1-64
}

MIHON=(third_party/m_extension_server third_party/jogamp tool/mihon)
GALGAME=(native/galgame_hook)

names=()
case "$platform" in
  windows)
    names+=(
      # Mihon runtime: JDK and server commit are pinned inside tool/mihon; no image input.
      "mihon=win-x64-mihon-runtime-v2-$(tree_hash "" "${MIHON[@]}")"
      "galgame=win-galgame-helper-dist-v2-$image-$(tree_hash "$toolchain_env" "${GALGAME[@]}")"
    )
    ;;
  *)
    echo "::error title=native-store-names::unsupported platform '$platform' (my-comic is Windows-only)" >&2
    exit 2
    ;;
esac

for line in "${names[@]}"; do
  echo "$line"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$line" >> "$GITHUB_OUTPUT"; fi
done
