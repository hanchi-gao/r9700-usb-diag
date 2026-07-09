#!/usr/bin/env bash
#==============================================================================
# llm_test.sh — R9700 LLM Inference Validation Test
#
# Runs a small language model on each GPU to verify AI compute is functional.
# Requires ROCm environment (bundled in diag-toolkit/lib/).
#
# Usage:
#   ./llm_test.sh --serial SN001
#   ./llm_test.sh --serial SN001 --gpu 0
#   ./llm_test.sh --serial SN001 --timeout 240
#
# Exit: 0=all PASS  1=at least one FAIL  10=environment not ready
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VK_BURN="${USB_ROOT}/bin/vk_burn"
LLAMA_BIN="${USB_ROOT}/bin/llama-cli"
MODEL_PATH="${USB_ROOT}/models/qwen2.5-0.5b-instruct-q8_0.gguf"
SINGLE_TEST="${SCRIPT_DIR}/test_single_gpu.sh"
SETUP_SCRIPT="${SCRIPT_DIR}/setup_env.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── defaults (overridable via config.sh) ────────────────────────────────────
SERIAL="${HOSTNAME:-unknown}"
SINGLE_GPU=""
TIMEOUT=180

[[ -f "${USB_ROOT}/config.sh" ]] && source "${USB_ROOT}/config.sh"
export CONFIG_FILE="${USB_ROOT}/config.sh"

# ─── args ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") --serial SERIAL [OPTIONS]

Options:
  --serial SERIAL     Unit serial number (required for records)
  --gpu INDEX         Test a single GPU by index
  --timeout SECS      Per-GPU inference timeout (default: ${TIMEOUT}s)
  --config FILE       Override config file (default: config.sh)
  -h, --help          Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)  SERIAL="$2";     shift 2 ;;
    --gpu)     SINGLE_GPU="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2";    shift 2 ;;
    --config)  source "$2"; export CONFIG_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

TS="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${USB_ROOT}/logs/${TS}"
RESULTS_CSV="${USB_ROOT}/llm_results.csv"
mkdir -p "${LOG_DIR}"

MAIN_LOG="${LOG_DIR}/llm.log"
log()  { echo -e "[$(date +%T)] $*" | tee -a "${MAIN_LOG}"; }
info() { log "${CYAN}[INFO]${NC}  $*"; }
warn() { log "${YELLOW}[WARN]${NC}  $*"; }
pass() { log "${GREEN}[PASS]${NC}  $*"; }
fail() { log "${RED}[FAIL]${NC}  $*"; }

# ─── results.csv init ────────────────────────────────────────────────────────
if [[ ! -f "${RESULTS_CSV}" ]]; then
  echo "timestamp,serial,gpu_index,result,fail_reason,log_dir" > "${RESULTS_CSV}"
fi

# ─── banner ──────────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
echo "  +--------------------------------------------------+"
echo "  |      R9700 LLM Inference Validation Test         |"
echo "  +--------------------------------------------------+"
echo -e "${NC}"
info "Serial    : ${SERIAL}"
info "Model     : $(basename "${MODEL_PATH}")"
info "Timeout   : ${TIMEOUT}s per GPU"
info "Log       : ${LOG_DIR}"
echo ""

# ─── environment check ───────────────────────────────────────────────────────
info "=== Environment check ==="
ENV_OK=1

if [[ ! -f "${LLAMA_BIN}" ]]; then
  fail "llama-cli not found: ${LLAMA_BIN}"
  ENV_OK=0
fi
if [[ ! -f "${MODEL_PATH}" ]]; then
  fail "Model not found: ${MODEL_PATH}"
  ENV_OK=0
fi
if [[ ! -f "${SETUP_SCRIPT}" ]]; then
  fail "setup_env.sh not found: ${SETUP_SCRIPT}"
  ENV_OK=0
fi

if [[ "${ENV_OK}" -eq 0 ]]; then
  fail "Environment not ready — cannot run LLM test"
  exit 10
fi

# source setup_env.sh to set LD_LIBRARY_PATH for USB ROCm libs
if ! source "${SETUP_SCRIPT}" "${LLAMA_BIN}" "${MODEL_PATH}" 2>/dev/null; then
  fail "setup_env.sh failed — ROCm environment not available"
  exit 10
fi
info "ROCm environment ready"
echo ""

# ─── GPU detection ───────────────────────────────────────────────────────────
info "=== Detecting GPUs ==="
declare -a GPU_INDICES=()

if [[ -n "${SINGLE_GPU}" ]]; then
  GPU_INDICES=("${SINGLE_GPU}")
  info "Single-GPU mode: index ${SINGLE_GPU}"
elif [[ -x "${VK_BURN}" ]]; then
  while IFS=$'\t' read -r idx name dtype; do
    [[ "${dtype}" == "2" ]] && GPU_INDICES+=("${idx}")
  done < <("${VK_BURN}" --list 2>/dev/null || true)
  info "Found ${#GPU_INDICES[@]} discrete GPU(s) via Vulkan: [${GPU_INDICES[*]:-none}]"
fi

if [[ ${#GPU_INDICES[@]} -eq 0 ]]; then
  fail "No GPU found — check PCIe seating and amdgpu driver"
  exit 2
fi
echo ""

# ─── per-GPU LLM test ────────────────────────────────────────────────────────
info "=== LLM Inference Test (sequential, one card at a time) ==="
declare -A RESULTS
declare -A FAIL_REASONS
PASS_COUNT=0; FAIL_COUNT=0

for IDX in "${GPU_INDICES[@]}"; do
  CARD_LOG="${LOG_DIR}/gpu${IDX}_llm.log"
  echo -e "${BOLD}  ── GPU ${IDX} ────────────────────────────────────────${NC}"

  if HIP_VISIBLE_DEVICES="${IDX}" \
       LLAMA_BIN="${LLAMA_BIN}" \
       MODEL_PATH="${MODEL_PATH}" \
       bash "${SINGLE_TEST}" \
         --gpu-index "${IDX}" \
         --timeout "${TIMEOUT}" \
         2>&1 | tee "${CARD_LOG}"; then
    RESULTS["${IDX}"]="PASS"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    pass "GPU ${IDX} → PASS"
    echo "$(date '+%Y-%m-%d %H:%M:%S'),${SERIAL},${IDX},PASS,,${LOG_DIR}" >> "${RESULTS_CSV}"
  else
    EC=${PIPESTATUS[0]}
    case "${EC}" in
      3)  reason="VRAM below threshold (HBM fault?)" ;;
      4)  reason="kernel GPU error during inference" ;;
      1)  reason="inference output invalid or timed out" ;;
      *)  reason="test script exited ${EC}" ;;
    esac
    RESULTS["${IDX}"]="FAIL"
    FAIL_REASONS["${IDX}"]="${reason}"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fail "GPU ${IDX} → FAIL: ${reason}"
    echo "$(date '+%Y-%m-%d %H:%M:%S'),${SERIAL},${IDX},FAIL,${reason},${LOG_DIR}" >> "${RESULTS_CSV}"
  fi
  echo ""
done

# ─── final results ───────────────────────────────────────────────────────────
GPU_COUNT=${#GPU_INDICES[@]}
echo -e "${BOLD}════════════════════════════════════════════════════${NC}" | tee -a "${MAIN_LOG}"
echo -e "${BOLD}  RESULTS  ──  $(date '+%Y-%m-%d %H:%M:%S')${NC}"       | tee -a "${MAIN_LOG}"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}" | tee -a "${MAIN_LOG}"
echo ""

for IDX in "${GPU_INDICES[@]}"; do
  if [[ "${RESULTS[${IDX}]}" == "PASS" ]]; then
    echo -e "  GPU ${IDX}  ${GREEN}${BOLD}PASS${NC}"                    | tee -a "${MAIN_LOG}"
  else
    echo -e "  GPU ${IDX}  ${RED}${BOLD}FAIL${NC}"                      | tee -a "${MAIN_LOG}"
    echo -e "           Reason : ${FAIL_REASONS[${IDX}]:-unknown}"      | tee -a "${MAIN_LOG}"
  fi
  echo ""
done

echo -e "  Total: ${GPU_COUNT} GPU(s) | ${GREEN}${BOLD}${PASS_COUNT} PASS${NC} | ${RED}${BOLD}${FAIL_COUNT} FAIL${NC}" \
  | tee -a "${MAIN_LOG}"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"

# PASS / FAIL banner
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo -e "${RED}${BOLD}"
  echo "  ███████╗ █████╗ ██╗██╗     "
  echo "  ██╔════╝██╔══██╗██║██║     "
  echo "  █████╗  ███████║██║██║     "
  echo "  ██╔══╝  ██╔══██║██║██║     "
  echo "  ██║     ██║  ██║██║███████╗"
  echo "  ╚═╝     ╚═╝  ╚═╝╚═╝╚══════╝"
  echo -e "${NC}"
else
  echo -e "${GREEN}${BOLD}"
  echo "  ██████╗  █████╗ ███████╗███████╗"
  echo "  ██╔══██╗██╔══██╗██╔════╝██╔════╝"
  echo "  ██████╔╝███████║███████╗███████╗"
  echo "  ██╔═══╝ ██╔══██║╚════██║╚════██║"
  echo "  ██║     ██║  ██║███████║███████║"
  echo "  ╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝"
  echo -e "${NC}"
fi

echo -e "${BOLD}  ── Result location ────────────────────────────────${NC}"
echo -e "  Log  : ${CYAN}${LOG_DIR}${NC}"
echo -e "${BOLD}  ──────────────────────────────────────────────────${NC}"
echo ""

[[ "${FAIL_COUNT}" -gt 0 ]] && exit 1 || exit 0
