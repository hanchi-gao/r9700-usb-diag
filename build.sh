#!/usr/bin/env bash
# build.sh — compile vk_burn from source
#
# Run this once on any Linux machine with libvulkan-dev + g++ to produce
# bin/vk_burn and src/vk_burn.comp.spv ready for USB deployment.
#
# Usage: ./build.sh [--clean]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${ROOT}/src"
BIN="${ROOT}/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}[ OK ]${NC}  $*"; }
info() { echo -e "  ${YELLOW}[INFO]${NC} $*"; }
die()  { echo -e "  ${RED}[FAIL]${NC} $*" >&2; exit 1; }

if [[ "${1:-}" == "--clean" ]]; then
  rm -f "${BIN}/vk_burn" "${SRC}/vk_burn.comp.spv"
  echo "cleaned."
  exit 0
fi

mkdir -p "${BIN}"

# ── check build deps ──────────────────────────────────────────────────────────
for cmd in g++ glslangValidator; do
  command -v "${cmd}" &>/dev/null || \
    die "${cmd} not found — run: sudo apt install ${cmd/glslangValidator/glslang-tools} ${cmd/g++/g++}"
done

if ! dpkg -s libvulkan-dev &>/dev/null 2>&1; then
  die "libvulkan-dev not installed — run: sudo apt install libvulkan-dev"
fi

# ── compile GLSL shader → SPIR-V ─────────────────────────────────────────────
info "Compiling shader: src/vk_burn.comp → src/vk_burn.comp.spv"
glslangValidator -V "${SRC}/vk_burn.comp" -o "${SRC}/vk_burn.comp.spv"
ok "src/vk_burn.comp.spv"

# ── compile vk_burn ───────────────────────────────────────────────────────────
info "Compiling: src/vk_burn.cpp → bin/vk_burn"
g++ -O2 -o "${BIN}/vk_burn" "${SRC}/vk_burn.cpp" -lvulkan
ok "bin/vk_burn"

echo ""
echo -e "${GREEN}Build complete.${NC}  bin/vk_burn is ready."
echo ""
echo "Next: copy this directory to USB, then on the target machine:"
echo "  sudo bash diag/gpu_burn_test.sh --serial SN001"
