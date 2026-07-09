#!/usr/bin/env bash
#===============================================================================
# setup_env.sh -- Pre-flight environment validation (USB self-contained mode)
#
# Design:
#   Target machine only needs amdgpu kernel module (Ubuntu 24.04 built-in).
#   ROCm userspace (rocm-smi, libamdhip64, etc.) is all bundled on the USB.
#
# Usage: source setup_env.sh <llama_bin_path> <model_path>
# Exit: 0 = OK, 1 = FAIL
# NOTE: Must be run with 'source', not 'bash', so exports propagate to caller.
#===============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
USB_LIB="${USB_ROOT}/lib"
USB_BIN="${USB_ROOT}/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "  ${RED}[FAIL]${NC}  $*"; }

LLAMA_BIN="${1:-}"
MODEL_PATH="${2:-}"
ERRORS=0

echo "-- Environment Pre-flight -----------------------------------------------"

# --- 1. kernel version (need 6.8+ for gfx1201 full support) ------------------
KVER=$(uname -r)
KMAJ=$(echo "${KVER}" | cut -d. -f1)
KMIN=$(echo "${KVER}" | cut -d. -f2)
if [[ "${KMAJ}" -gt 6 ]] || [[ "${KMAJ}" -eq 6 && "${KMIN}" -ge 8 ]]; then
  ok "Kernel: ${KVER} (>= 6.8 OK)"
else
  err "Kernel: ${KVER} -- gfx1201 requires kernel 6.8+, R9700 may not be supported"
  ERRORS=$((ERRORS + 1))
fi

# --- 2. amdgpu kernel module (the only thing required on target machine) ------
if lsmod 2>/dev/null | grep -q '^amdgpu'; then
  ok "amdgpu: kernel module loaded"
else
  err "amdgpu: NOT loaded -- check R9700 PCIe seating and BIOS settings"
  ERRORS=$((ERRORS + 1))
fi

# --- 3. /dev/kfd (created by amdgpu module, no ROCm install needed) ----------
if [[ -c /dev/kfd ]]; then
  ok "/dev/kfd: exists"
else
  err "/dev/kfd: missing -- amdgpu loaded but KFD not initialized (check IOMMU settings)"
  ERRORS=$((ERRORS + 1))
fi

# --- 4. /dev/dri/renderD* ----------------------------------------------------
RENDER_DEVS=(/dev/dri/renderD*)
RENDER_COUNT=${#RENDER_DEVS[@]}
if [[ "${RENDER_COUNT}" -gt 0 ]] && [[ -e "${RENDER_DEVS[0]}" ]]; then
  ok "/dev/dri/renderD*: ${RENDER_COUNT} device(s) -- $(ls /dev/dri/renderD* | tr '\n' ' ')"
else
  err "/dev/dri/renderD*: no render device found"
  ERRORS=$((ERRORS + 1))
fi

# --- 5. USB lib directory ----------------------------------------------------
if [[ -d "${USB_LIB}" ]]; then
  LIB_COUNT=$(find "${USB_LIB}" -name "*.so*" | wc -l)
  ok "USB lib: ${USB_LIB} (${LIB_COUNT} .so files)"
else
  err "USB lib: ${USB_LIB} not found -- run prepare_usb_libs.sh first"
  ERRORS=$((ERRORS + 1))
fi

# --- 6. USB-bundled rocm-smi -------------------------------------------------
# rocm-smi is a Python script; PYTHONPATH must point to USB lib/rocm_smi/
USB_PYTHONPATH="${USB_LIB}/rocm_smi"
USB_ROCM_SMI="${USB_BIN}/rocm-smi"
if [[ -x "${USB_ROCM_SMI}" ]]; then
  if LD_LIBRARY_PATH="${USB_LIB}:${LD_LIBRARY_PATH:-}" PYTHONPATH="${USB_PYTHONPATH}:${PYTHONPATH:-}" \
       "${USB_ROCM_SMI}" --version &>/dev/null; then
    ROCM_VER=$(LD_LIBRARY_PATH="${USB_LIB}:${LD_LIBRARY_PATH:-}" PYTHONPATH="${USB_PYTHONPATH}:${PYTHONPATH:-}" \
      "${USB_ROCM_SMI}" --version 2>/dev/null \
      | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1 || echo "unknown")
    ok "rocm-smi: USB-bundled version ${ROCM_VER}"
  else
    warn "rocm-smi: binary exists but failed to run (lib version mismatch?)"
  fi
else
  if command -v rocm-smi &>/dev/null; then
    warn "rocm-smi: using system version (run prepare_usb_libs.sh to bundle into USB)"
  else
    err "rocm-smi: not found (not bundled in USB, not installed on target)"
    ERRORS=$((ERRORS + 1))
  fi
fi

# --- 7. llama-cli binary -----------------------------------------------------
if [[ -z "${LLAMA_BIN}" ]]; then
  err "llama-cli: path not specified"
  ERRORS=$((ERRORS + 1))
elif [[ ! -x "${LLAMA_BIN}" ]]; then
  err "llama-cli: not found or not executable -- ${LLAMA_BIN}"
  echo "    -> build with build_llama.sh and copy binary to <USB>/bin/"
  ERRORS=$((ERRORS + 1))
else
  MISSING=$(LD_LIBRARY_PATH="${USB_LIB}:${LD_LIBRARY_PATH:-}" \
    ldd "${LLAMA_BIN}" 2>/dev/null \
    | grep "not found" | awk '{print $1}' | tr '\n' ' ' || true)
  if [[ -n "${MISSING}" ]]; then
    err "llama-cli: missing shared libs: ${MISSING}"
    echo "    -> re-run prepare_usb_libs.sh to bundle missing libs"
    ERRORS=$((ERRORS + 1))
  else
    ok "llama-cli: ${LLAMA_BIN} (all .so dependencies satisfied)"
  fi
fi

# --- 8. model file -----------------------------------------------------------
if [[ -z "${MODEL_PATH}" ]]; then
  err "model: path not specified"
  ERRORS=$((ERRORS + 1))
elif [[ -f "${MODEL_PATH}" ]]; then
  MODEL_SIZE=$(du -sh "${MODEL_PATH}" 2>/dev/null | cut -f1)
  ok "model: ${MODEL_PATH} (${MODEL_SIZE})"
else
  err "model: not found -- ${MODEL_PATH}"
  ERRORS=$((ERRORS + 1))
fi

echo "-------------------------------------------------------------------------"

if [[ "${ERRORS}" -gt 0 ]]; then
  echo -e "  ${RED}Pre-flight FAILED: ${ERRORS} error(s)${NC}"
  return 1
fi

# If system ROCm exists, put it before bundled libs to avoid version mismatch
if [[ -d "/opt/rocm/lib" ]]; then
  export LD_LIBRARY_PATH="/opt/rocm/lib:${USB_LIB}:${LD_LIBRARY_PATH:-}"
else
  export LD_LIBRARY_PATH="${USB_LIB}:${LD_LIBRARY_PATH:-}"
fi
export PATH="${USB_BIN}:${PATH}"
export PYTHONPATH="${USB_PYTHONPATH}:${PYTHONPATH:-}"

echo -e "  ${GREEN}Pre-flight PASSED${NC}"
echo -e "  LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"
return 0
