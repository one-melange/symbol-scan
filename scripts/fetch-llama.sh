#!/usr/bin/env bash
#
# fetch-llama.sh — vendor the llama.cpp runtime for SymbolScan's ⌘E "explain" feature (T28).
#
# Downloads a PINNED official prebuilt llama.cpp macOS arm64 release, verifies its checksum, and
# stages the minimal `llama-server` runtime (the executable + its transitive dylib closure) into a
# gitignored vendor directory. The Xcode "Copy llama runtime" build phase bundles that into the app
# under Contents/Helpers/llama/. Run this once after checkout (documented in DEVELOPMENT.md); the app
# still builds without it (⌘E just reports the runtime isn't bundled).
#
# We vendor a prebuilt release rather than build from source: it's small (~23 MB staged), reproducible
# (pinned tag + sha256), and Metal-enabled (the Metal shaders are embedded in libggml-metal.dylib, so
# there's no separate metallib to ship). The release binaries use LC_RPATH=@loader_path, so the only
# requirement is that the dylibs sit next to the executable — no install_name_tool surgery.
set -euo pipefail

# --- Pinned release -----------------------------------------------------------------------------
LLAMA_TAG="b10375"
ASSET="llama-${LLAMA_TAG}-bin-macos-arm64.tar.gz"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/${ASSET}"
EXPECTED_SHA256="ebbeed128cde32077c5b430feafe57ce20b1bca545f430ff142472014f03bcec"

# The executable + exactly its transitive @rpath closure (verified with otool). The release ships
# these as symlinks to versioned real files; we copy the REAL files under the referenced ".0.dylib"
# names so the vendored set is flat and symlink-free (friendlier to code-signing / bundling).
BINARY="llama-server"
# "referenced-name  source-symlink-name"  (source resolves through the release's symlink to the real file)
DYLIBS=(
  "libllama-server-impl.dylib  libllama-server-impl.dylib"
  "libllama-common.0.dylib     libllama-common.0.dylib"
  "libmtmd.0.dylib             libmtmd.0.dylib"
  "libllama.0.dylib            libllama.0.dylib"
  "libggml.0.dylib             libggml.0.dylib"
  "libggml-cpu.0.dylib         libggml-cpu.0.dylib"
  "libggml-blas.0.dylib        libggml-blas.0.dylib"
  "libggml-metal.0.dylib       libggml-metal.0.dylib"
  "libggml-rpc.0.dylib         libggml-rpc.0.dylib"
  "libggml-base.0.dylib        libggml-base.0.dylib"
)

# --- Paths --------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${REPO_ROOT}/SymbolScan/Vendor/llama"

echo "==> Fetching llama.cpp ${LLAMA_TAG} (macOS arm64)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

curl -fSL --retry 3 -o "${TMP}/${ASSET}" "${URL}"

echo "==> Verifying checksum"
ACTUAL_SHA256="$(shasum -a 256 "${TMP}/${ASSET}" | awk '{print $1}')"
if [[ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
  echo "ERROR: checksum mismatch for ${ASSET}" >&2
  echo "  expected: ${EXPECTED_SHA256}" >&2
  echo "  actual:   ${ACTUAL_SHA256}" >&2
  exit 1
fi

echo "==> Extracting"
tar -xzf "${TMP}/${ASSET}" -C "${TMP}"
SRC="${TMP}/llama-${LLAMA_TAG}"
[[ -d "${SRC}" ]] || { echo "ERROR: expected ${SRC} in the archive" >&2; exit 1; }

echo "==> Staging runtime into ${DEST}"
rm -rf "${DEST}"
mkdir -p "${DEST}"

# Copy the executable (follow-symlink copy so we land a real file), then each dylib under its
# referenced name.
cp -L "${SRC}/${BINARY}" "${DEST}/${BINARY}"
chmod +x "${DEST}/${BINARY}"
for entry in "${DYLIBS[@]}"; do
  ref="$(echo "${entry}" | awk '{print $1}')"
  from="$(echo "${entry}" | awk '{print $2}')"
  cp -L "${SRC}/${from}" "${DEST}/${ref}"      # -L resolves the release's versioned symlink to the real file
done

echo "==> Verifying dylib closure is self-contained"
missing=0
while IFS= read -r macho; do
  while IFS= read -r dep; do
    base="${dep#@rpath/}"
    if [[ ! -e "${DEST}/${base}" ]]; then
      echo "  MISSING: $(basename "${macho}") needs ${base}" >&2
      missing=1
    fi
  done < <(otool -L "${macho}" | grep '@rpath/' | awk '{print $1}')
done < <(find "${DEST}" -type f \( -name '*.dylib' -o -name "${BINARY}" \))
if [[ "${missing}" -ne 0 ]]; then
  echo "ERROR: vendored runtime has unresolved @rpath dependencies" >&2
  exit 1
fi

echo "==> Smoke test"
"${DEST}/${BINARY}" --version 2>&1 | head -2

TOTAL="$(du -sh "${DEST}" | awk '{print $1}')"
echo "==> Done. Vendored ${TOTAL} into ${DEST#${REPO_ROOT}/}"
