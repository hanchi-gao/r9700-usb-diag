#!/usr/bin/env bash
#===============================================================================
# test_single_gpu.sh — Single R9700 card LLM inference validation
#
# Called by run_all.sh with HIP_VISIBLE_DEVICES already set to isolate one card.
#
# Pass criteria:
#   1. VRAM ≥ 30 GB reported (32GB expected; catches HBM fault cards ~8GB)
#   2. Inference completes within timeout
#   3. Output length > 20 chars
#   4. Non-printable char ratio < 5% (not garbage)
#   5. No GPU kernel error in dmesg during test
#
# Exit codes:
#   0   PASS
#   1   FAIL — inference output invalid (empty / garbage / timeout)
#   3   FAIL — VRAM pre-flight failed
#   4   FAIL — kernel GPU error during test
#===============================================================================
set -uo pipefail

# ─── defaults (overridden by environment from run_all.sh) ────────────────────
LLAMA_BIN="${LLAMA_BIN:-/usb/bin/llama-cli}"
MODEL_PATH="${MODEL_PATH:-/usb/models/qwen2.5-0.5b-instruct-q8_0.gguf}"
GPU_INDEX=0
TIMEOUT=180
VERBOSE=0

EXPECTED_VRAM_GB=28       # floor (not exact) — 32GB 卡實際回報約 29.8GB, 28GB 仍可抓 8GB HBM 故障卡
N_PREDICT=128
PROMPT="Count from one to ten in English words."
MIN_OUTPUT_CHARS=20
MAX_NONPRINT_RATIO=5      # percent

# Stage 5 parallel stress config
# Per-instance VRAM estimate for Qwen2.5-0.5B Q8:
#   ~645MB model weights (--no-mmap, fully loaded) + ~50MB KV cache + ~55MB overhead
#   Measured on R9700: baseline 464MB → peak 1193MB = 729MB net per instance
N_PARALLEL=1              # Stage 5 並行推論數量，可在 config.sh 調整

# 載入設定檔（由 run_all.sh 透過 export CONFIG_FILE 傳入，覆蓋上方預設值）
if [[ -n "${CONFIG_FILE:-}" && -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

# ─── dmesg error patterns (R9700 known fault signatures) ─────────────────────
DMESG_PATTERNS="GCVM_L2_PROTECTION_FAULT|MES.*fail|amdgpu.*reset|ring.*timeout|GPU fault|cp_eop_interrupt"

# ─── colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "[$(date +%T)] $*"; }
info() { log "  [INFO]  $*"; }
warn() { log "  ${YELLOW}[WARN]${NC}  $*"; }
ok()   { log "  ${GREEN}[ OK ]${NC}  $*"; }
fail_exit() {
  local code="$1"; shift
  log "  ${RED}[FAIL]${NC}  $*"
  exit "${code}"
}

# ─── argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpu-index) GPU_INDEX="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2";   shift 2 ;;
    --verbose)   VERBOSE=1;      shift 1 ;;
    *) shift ;;
  esac
done

info "=== Single GPU Test — GPU index ${GPU_INDEX} ==="
info "HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-<not set>}"

# ─── stage 1: VRAM check ─────────────────────────────────────────────────────
info "Stage 1/4: VRAM capacity check"

# PATH 已由 setup_env.sh export,USB/bin/rocm-smi 優先於系統版本
# CSV 格式: "card<N>,VRAM Total Memory (B),VRAM Total Used Memory (B)"
# 用 GPU_INDEX 對應 card<N>,精準挑出這張卡的列(避免抓到 iGPU)
VRAM_BYTES=$(rocm-smi --showmeminfo vram --csv 2>/dev/null \
  | awk -F',' -v idx="card${GPU_INDEX}" 'NR>1 && $1==idx { print $2; exit }' \
  | tr -d ' ')

if [[ -z "${VRAM_BYTES}" ]]; then
  fail_exit 3 "rocm-smi could not read VRAM (driver issue?)"
fi

VRAM_MB=$(( VRAM_BYTES / 1024 / 1024 ))
VRAM_GB=$(( VRAM_MB / 1024 ))
info "VRAM reported: ${VRAM_GB} GB (${VRAM_MB} MB)"

if [[ "${VRAM_GB}" -lt "${EXPECTED_VRAM_GB}" ]]; then
  fail_exit 3 "VRAM too low: ${VRAM_GB} GB < ${EXPECTED_VRAM_GB} GB (HBM fault?)"
fi
ok "VRAM: ${VRAM_GB} GB -- OK"

# ─── stage 2: dmesg baseline ─────────────────────────────────────────────────
info "Stage 2/4: dmesg baseline snapshot"
DMESG_BEFORE=$(mktemp /tmp/diag_dmesg_before.XXXXXX)
dmesg 2>/dev/null | tail -n 500 > "${DMESG_BEFORE}" || true
ok "dmesg baseline captured ($(wc -l < "${DMESG_BEFORE}") lines)"

# ─── stage 3: inference ──────────────────────────────────────────────────────
info "Stage 3/4: LLM inference (timeout: ${TIMEOUT}s)"
info "  model   : ${MODEL_PATH}"
info "  n_predict: ${N_PREDICT}"
info "  prompt  : \"${PROMPT}\""

# llama-cli (b1-ac4cdde) forces conversation mode for chat-template models and
# writes all UI output to /dev/tty rather than stdout. Use 'script' to create
# a pty so the output is capturable regardless of how the caller invoked us.
INFER_CMD=(
  "${LLAMA_BIN}"
  -m "${MODEL_PATH}"
  -n "${N_PREDICT}"
  -ngl 99
  --temp 0
)

PROMPT_FILE=$(mktemp /tmp/diag_prompt.XXXXXX)
printf "%s\n/exit\n" "${PROMPT}" > "${PROMPT_FILE}"

# Wrapper script runs inside the pty created by 'script'.
# env vars (LD_LIBRARY_PATH, HIP_VISIBLE_DEVICES) are inherited.
INFER_WRAPPER=$(mktemp /tmp/diag_wrap.XXXXXX.sh)
cat > "${INFER_WRAPPER}" << WEOF
#!/bin/bash
exec timeout ${TIMEOUT} $(printf '%q ' "${INFER_CMD[@]}") < "${PROMPT_FILE}"
WEOF
chmod +x "${INFER_WRAPPER}"

INFER_RAW=$(mktemp /tmp/diag_raw.XXXXXX)
INFER_OUT=$(mktemp /tmp/diag_infer_out.XXXXXX)

START_TS=$(date +%s)
script -q -e -c "bash ${INFER_WRAPPER}" "${INFER_RAW}" 2>/dev/null
INFER_EXIT=$?
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
rm -f "${INFER_WRAPPER}"

# Strip ANSI escape codes and carriage returns from pty capture
sed -E 's/\r//g; s/\x1b\[[0-9;?]*[A-Za-z]//g' "${INFER_RAW}" > "${INFER_OUT}"
rm -f "${INFER_RAW}"

if [[ "${INFER_EXIT}" -eq 124 ]]; then
  tail -n 20 "${INFER_OUT}" >&2
  rm -f "${DMESG_BEFORE}" "${INFER_OUT}" "${PROMPT_FILE}"
  fail_exit 1 "Inference TIMEOUT after ${TIMEOUT}s (GPU hung?)"
fi

if [[ "${INFER_EXIT}" -ne 0 ]]; then
  tail -n 20 "${INFER_OUT}" >&2
  rm -f "${DMESG_BEFORE}" "${INFER_OUT}" "${PROMPT_FILE}"
  fail_exit 1 "llama-cli exited with code ${INFER_EXIT}"
fi

ok "Inference completed in ${ELAPSED}s"

# ─── stage 4: output validation + tok/s ──────────────────────────────────────
info "Stage 4/5: Output validation"

OUTPUT=$(cat "${INFER_OUT}")

# Extract generation speed from timing line: [ Prompt: N t/s | Generation: N t/s ]
GEN_TOKS=$(echo "${OUTPUT}" | grep -oP '(?<=Generation: )\d+\.?\d*' | head -1 || true)
if [[ -n "${GEN_TOKS}" ]]; then
  ok "Generation speed: ${GEN_TOKS} t/s"
else
  warn "Could not extract generation speed from output"
fi

# Extract model response: between /glob <pattern> line and [ Prompt: timing line
RESPONSE=$(echo "${OUTPUT}" | awk '
  /\/glob <pattern>/ { found=1; next }
  !found             { next }
  /^\[ Prompt:/      { exit }
  /^>/               { next }
  { print }
')
RESPONSE=$(echo "${RESPONSE}" | sed -e '/[^[:space:]]/,$!d')
[[ -z "${RESPONSE//[$'\n\t ']/}" ]] && RESPONSE="${OUTPUT}"

OUTPUT_LEN=${#RESPONSE}
info "  output length: ${OUTPUT_LEN} chars"

if [[ "${OUTPUT_LEN}" -lt "${MIN_OUTPUT_CHARS}" ]]; then
  rm -f "${DMESG_BEFORE}" "${INFER_OUT}" "${PROMPT_FILE}"
  fail_exit 1 "Output too short: ${OUTPUT_LEN} chars (< ${MIN_OUTPUT_CHARS})"
fi

NONPRINT=$(echo "${RESPONSE}" | tr -cd '\000-\010\013-\037\177-\377' | wc -c)
RATIO=$(( OUTPUT_LEN > 0 ? NONPRINT * 100 / OUTPUT_LEN : 0 ))
info "  non-printable chars: ${NONPRINT} / ${OUTPUT_LEN} = ${RATIO}%"

if [[ "${RATIO}" -gt "${MAX_NONPRINT_RATIO}" ]]; then
  rm -f "${DMESG_BEFORE}" "${INFER_OUT}" "${PROMPT_FILE}"
  fail_exit 1 "Garbage output: ${RATIO}% non-printable (threshold: ${MAX_NONPRINT_RATIO}%)"
fi
ok "Output content: ${RATIO}% non-printable -- OK"

if [[ "${VERBOSE}" -eq 1 ]]; then
  info "  output preview:"
  echo "${RESPONSE}" | head -5 | sed 's/^/    /'
fi

# ─── dmesg delta check ───────────────────────────────────────────────────────
DMESG_AFTER=$(mktemp /tmp/diag_dmesg_after.XXXXXX)
dmesg 2>/dev/null | tail -n 500 > "${DMESG_AFTER}" || true

NEW_ERRORS=$(comm -13 <(sort "${DMESG_BEFORE}") <(sort "${DMESG_AFTER}") \
  | grep -E "${DMESG_PATTERNS}" || true)

rm -f "${DMESG_BEFORE}" "${DMESG_AFTER}" "${INFER_OUT}"

if [[ -n "${NEW_ERRORS}" ]]; then
  warn "Kernel GPU errors detected during test:"
  echo "${NEW_ERRORS}" >&2
  rm -f "${PROMPT_FILE}"
  fail_exit 4 "dmesg GPU errors during inference"
fi
ok "dmesg: no GPU errors -- OK"

# ─── stage 5: parallel inference ─────────────────────────────────────────────
info "Stage 5/5: Parallel inference (N_PARALLEL=${N_PARALLEL})"
info "  launching ${N_PARALLEL} concurrent instance(s)..."

PAR_PIDS=()
PAR_OUTFILES=()
STRESS_TIMEOUT="${TIMEOUT}"
for i in $(seq 1 "${N_PARALLEL}"); do
  OUTF=$(mktemp /tmp/diag_par.XXXXXX)
  PAR_OUTFILES+=("${OUTF}")
  timeout "${STRESS_TIMEOUT}" "${INFER_CMD[@]}" <"${PROMPT_FILE}" >"${OUTF}" 2>/dev/null &
  PAR_PIDS+=($!)
done

PAR_FAIL=0
for i in "${!PAR_PIDS[@]}"; do
  wait "${PAR_PIDS[$i]}" || PAR_FAIL=$((PAR_FAIL + 1))
done
for F in "${PAR_OUTFILES[@]}"; do rm -f "${F}"; done
rm -f "${PROMPT_FILE}"

if [[ "${PAR_FAIL}" -gt 0 ]]; then
  fail_exit 1 "Parallel stress: ${PAR_FAIL}/${N_PARALLEL} instances failed (OOM or GPU error)"
fi
ok "Parallel stress: ${N_PARALLEL}/${N_PARALLEL} instances completed -- OK"

# ─── all stages passed ───────────────────────────────────────────────────────
echo ""
log "${GREEN}==================================================${NC}"
log "${GREEN}  GPU ${GPU_INDEX}  ALL STAGES PASSED  (${ELAPSED}s)${NC}"
log "${GREEN}==================================================${NC}"
exit 0
