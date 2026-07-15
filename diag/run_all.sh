#!/usr/bin/env bash
#==============================================================================
# run_all.sh — R9700 Full Factory Test (burn-in + LLM inference, one command)
#
# Runs gpu_burn_test.sh, then llm_test.sh, back-to-back. If burn-in fails,
# LLM inference is skipped — no point stressing a card that already failed.
#
# Usage:
#   ./run_all.sh --serial SN001
#   ./run_all.sh --serial SN001 --duration 300 --timeout 240
#   ./run_all.sh --serial SN001 --gpu 0
#   ./run_all.sh --serial SN001 --burn-only
#
# Exit: 0=burn+LLM both PASS  1=burn FAIL (LLM skipped)  2=burn PASS, LLM FAIL
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BURN_TEST="${SCRIPT_DIR}/gpu_burn_test.sh"
LLM_TEST="${SCRIPT_DIR}/llm_test.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SERIAL="${HOSTNAME:-unknown}"
DURATION=""
TIMEOUT=""
SINGLE_GPU=""
CONFIG_FILE=""
BURN_ONLY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --serial SERIAL [OPTIONS]

Runs gpu_burn_test.sh then llm_test.sh back-to-back as a single command.
If burn-in fails, the LLM inference stage is skipped.

Options:
  --serial SERIAL     Unit serial number (required for records)
  --duration SECS     Burn-in duration, passed to gpu_burn_test.sh
  --timeout SECS      LLM inference timeout, passed to llm_test.sh
  --gpu INDEX         Test a single GPU by index (both stages)
  --config FILE       Override config file (default: config.sh)
  --burn-only         Run the burn-in stage only, skip LLM inference
  -h, --help          Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)    SERIAL="$2";      shift 2 ;;
    --duration)  DURATION="$2";    shift 2 ;;
    --timeout)   TIMEOUT="$2";     shift 2 ;;
    --gpu)       SINGLE_GPU="$2";  shift 2 ;;
    --config)    CONFIG_FILE="$2"; shift 2 ;;
    --burn-only) BURN_ONLY=1;      shift 1 ;;
    -h|--help)   usage ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

BURN_ARGS=(--serial "${SERIAL}")
[[ -n "${DURATION}"    ]] && BURN_ARGS+=(--duration "${DURATION}")
[[ -n "${SINGLE_GPU}"  ]] && BURN_ARGS+=(--gpu "${SINGLE_GPU}")
[[ -n "${CONFIG_FILE}" ]] && BURN_ARGS+=(--config "${CONFIG_FILE}")

LLM_ARGS=(--serial "${SERIAL}")
[[ -n "${TIMEOUT}"     ]] && LLM_ARGS+=(--timeout "${TIMEOUT}")
[[ -n "${SINGLE_GPU}"  ]] && LLM_ARGS+=(--gpu "${SINGLE_GPU}")
[[ -n "${CONFIG_FILE}" ]] && LLM_ARGS+=(--config "${CONFIG_FILE}")

echo -e "${CYAN}${BOLD}"
echo "  +--------------------------------------------------+"
echo "  |      R9700 Full Factory Test (Burn-in + LLM)      |"
echo "  +--------------------------------------------------+"
echo -e "${NC}"
echo "  Serial  : ${SERIAL}"
echo "  Stage 1 : GPU burn-in (gpu_burn_test.sh)"
if [[ "${BURN_ONLY}" -eq 1 ]]; then
  echo "  Stage 2 : LLM inference — skipped (--burn-only)"
else
  echo "  Stage 2 : LLM inference (llm_test.sh)"
fi
echo ""
sleep 1

# ─── stage 1: burn-in ────────────────────────────────────────────────────────
bash "${BURN_TEST}" "${BURN_ARGS[@]}"
BURN_EC=$?

if [[ "${BURN_EC}" -ne 0 ]]; then
  echo ""
  echo -e "${RED}${BOLD}════════════════════════════════════════════════════${NC}"
  echo -e "${RED}${BOLD}  Stage 1 (burn-in) FAILED — skipping LLM inference${NC}"
  echo -e "${RED}${BOLD}════════════════════════════════════════════════════${NC}"
  exit 1
fi

if [[ "${BURN_ONLY}" -eq 1 ]]; then
  exit 0
fi

# ─── stage 2: LLM inference ──────────────────────────────────────────────────
bash "${LLM_TEST}" "${LLM_ARGS[@]}"
LLM_EC=$?

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
if [[ "${LLM_EC}" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}  Stage 1 (burn-in) PASS  +  Stage 2 (LLM) PASS  —  unit OK${NC}"
else
  echo -e "${RED}${BOLD}  Stage 1 (burn-in) PASS  but  Stage 2 (LLM) FAILED${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""

[[ "${LLM_EC}" -ne 0 ]] && exit 2
exit 0
