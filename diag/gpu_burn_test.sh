#!/usr/bin/env bash
#==============================================================================
# gpu_burn_test.sh — R9700 GPU Factory Burn-in Test
#
# Runs Vulkan compute stress on all discrete GPUs simultaneously.
# No ROCm required — all sensors read from sysfs hwmon.
#
# Usage:
#   ./gpu_burn_test.sh --serial SN001
#   ./gpu_burn_test.sh --serial SN001 --duration 300
#   ./gpu_burn_test.sh --serial SN001 --gpu 0
#
# Exit: 0=all PASS  1=at least one FAIL
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VK_BURN="${USB_ROOT}/bin/vk_burn"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── defaults (overridable via config.sh) ────────────────────────────────────
DURATION=120          # seconds
SERIAL="${HOSTNAME:-unknown}"
SINGLE_GPU=""
REPORT_INTERVAL=15    # status print interval (seconds)
TEMP_FAIL_C=100       # junction temp — immediate FAIL
TEMP_WARN_C=98        # junction temp — WARNING
VRAM_MIN_GB=28        # minimum expected VRAM

[[ -f "${USB_ROOT}/config.sh" ]] && source "${USB_ROOT}/config.sh"

# ─── args ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") --serial SERIAL [OPTIONS]

Options:
  --serial SERIAL     Unit serial number (required for records)
  --duration SECS     Burn duration in seconds (default: ${DURATION})
  --gpu INDEX         Test a single GPU by Vulkan index
  --config FILE       Override config file (default: config.sh)
  -h, --help          Show this help

Thresholds (set in config.sh):
  TEMP_WARN_C         Junction temp warning (default: ${TEMP_WARN_C}°C)
  TEMP_FAIL_C         Junction temp failure (default: ${TEMP_FAIL_C}°C)
  VRAM_MIN_GB         Minimum expected VRAM (default: ${VRAM_MIN_GB}GB)
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)   SERIAL="$2";     shift 2 ;;
    --duration) DURATION="$2";   shift 2 ;;
    --gpu)      SINGLE_GPU="$2"; shift 2 ;;
    --config)   source "$2";     shift 2 ;;
    -h|--help)  usage ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

TS="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${USB_ROOT}/logs/${TS}"
RESULTS_CSV="${USB_ROOT}/results.csv"
mkdir -p "${LOG_DIR}"

MAIN_LOG="${LOG_DIR}/burn.log"
log()  { echo -e "[$(date +%T)] $*" | tee -a "${MAIN_LOG}"; }
info() { log "${CYAN}[INFO]${NC}  $*"; }
warn() { log "${YELLOW}[WARN]${NC}  $*"; }
pass() { log "${GREEN}[PASS]${NC}  $*"; }
fail() { log "${RED}[FAIL]${NC}  $*"; }

# ─── sysfs helpers ───────────────────────────────────────────────────────────
sysfs_val() { cat "$1" 2>/dev/null || echo "0"; }

read_edge()  { echo $(( $(sysfs_val "$1/temp1_input") / 1000 )); }
read_junc()  { echo $(( $(sysfs_val "$1/temp2_input") / 1000 )); }
read_memt()  { echo $(( $(sysfs_val "$1/temp3_input") / 1000 )); }
read_power() { echo $(( $(sysfs_val "$1/power1_average") / 1000000 )); }
read_sclk()  { echo $(( $(sysfs_val "$1/freq1_input") / 1000000 )); }

read_vram() {  # read_vram BDF → "usedGB/totalGB"
  local bdf="$1"
  for c in /sys/class/drm/card[0-9]*; do
    [[ -d "$c/device" ]] || continue
    [[ "$(basename "$(readlink -f "$c/device" 2>/dev/null)")" == "${bdf}" ]] || continue
    local used total
    used=$(sysfs_val "$c/device/mem_info_vram_used")
    total=$(sysfs_val "$c/device/mem_info_vram_total")
    printf "%dGB/%dGB" "$(( used  / 1073741824 ))" "$(( total / 1073741824 ))"
    return
  done
  echo "?/?"
}

vram_total_gb() {  # vram_total_gb BDF
  local bdf="$1"
  for c in /sys/class/drm/card[0-9]*; do
    [[ "$(basename "$(readlink -f "$c/device" 2>/dev/null)")" == "${bdf}" ]] || continue
    echo $(( $(sysfs_val "$c/device/mem_info_vram_total") / 1073741824 ))
    return
  done
  echo 0
}

# ─── sanity check ────────────────────────────────────────────────────────────
if [[ ! -x "${VK_BURN}" ]]; then
  echo -e "${RED}ERROR: vk_burn not found at ${VK_BURN}${NC}" >&2; exit 1
fi

# ─── GPU detection ───────────────────────────────────────────────────────────
declare -a VK_INDICES=()
declare -a GPU_NAMES=()
declare -a GPU_BDFS=()
declare -a HWMON_DIRS=()

# enumerate amdgpu hwmon dirs in order
declare -a ALL_AMDGPU_HW=()
for d in $(ls -d /sys/class/hwmon/hwmon* 2>/dev/null | sort -V); do
  [[ "$(cat "$d/name" 2>/dev/null)" == "amdgpu" ]] && ALL_AMDGPU_HW+=("$d")
done

# discrete GPUs from vk_burn (type 2 = discrete)
while IFS=$'\t' read -r idx name dtype; do
  [[ "${dtype}" == "2" ]] || continue
  [[ -z "${SINGLE_GPU}" || "${idx}" == "${SINGLE_GPU}" ]] || continue
  VK_INDICES+=("${idx}")
  GPU_NAMES+=("${name}")
done < <("${VK_BURN}" --list 2>/dev/null || true)

if [[ ${#VK_INDICES[@]} -eq 0 ]]; then
  echo -e "${RED}ERROR: No discrete GPU found. Check PCIe seating and amdgpu driver.${NC}" >&2
  exit 1
fi

# map Vulkan index → hwmon + BDF (by position among discrete GPUs)
for i in "${!VK_INDICES[@]}"; do
  if [[ "${i}" -lt "${#ALL_AMDGPU_HW[@]}" ]]; then
    hw="${ALL_AMDGPU_HW[$i]}"
    HWMON_DIRS+=("${hw}")
    bdf="$(basename "$(readlink -f "${hw}/device" 2>/dev/null)" 2>/dev/null || echo "unknown")"
    GPU_BDFS+=("${bdf}")
  else
    HWMON_DIRS+=("")
    GPU_BDFS+=("unknown")
  fi
done

GPU_COUNT=${#VK_INDICES[@]}

# ─── results.csv init ────────────────────────────────────────────────────────
if [[ ! -f "${RESULTS_CSV}" ]]; then
  echo "timestamp,serial,gpu_index,gpu_name,bdf,vram_gb,pcie_link,max_junc_c,max_power_w,result,fail_reason,log_dir" \
    > "${RESULTS_CSV}"
fi

# ─── banner ──────────────────────────────────────────────────────────────────
[[ "${NO_CLEAR:-0}" -eq 1 ]] || clear
echo -e "${CYAN}${BOLD}"
echo "  +--------------------------------------------------+"
echo "  |      R9700 GPU Factory Burn-in Test              |"
echo "  +--------------------------------------------------+"
echo -e "${NC}"
info "Serial    : ${SERIAL}"
info "GPUs      : ${GPU_COUNT}"
info "Duration  : ${DURATION}s"
info "Threshold : WARN ≥${TEMP_WARN_C}°C  FAIL ≥${TEMP_FAIL_C}°C (junction)"
info "Log       : ${LOG_DIR}"
echo ""

# ─── pre-checks ──────────────────────────────────────────────────────────────
info "=== Pre-checks ==="
declare -A PRE_FAIL
PRE_FAIL_COUNT=0
declare -A GPU_VRAM_GB
declare -A GPU_PCIE

for i in "${!VK_INDICES[@]}"; do
  idx="${VK_INDICES[$i]}"
  bdf="${GPU_BDFS[$i]}"
  name="${GPU_NAMES[$i]:-unknown}"

  info "GPU ${idx}: ${name}"

  # VRAM
  vgb=$(vram_total_gb "${bdf}")
  GPU_VRAM_GB["${idx}"]="${vgb}"
  if [[ "${vgb}" -lt "${VRAM_MIN_GB}" ]]; then
    fail "GPU ${idx} [${bdf}] VRAM ${vgb}GB < ${VRAM_MIN_GB}GB — possible HBM fault"
    PRE_FAIL["${idx}"]="VRAM ${vgb}GB below minimum ${VRAM_MIN_GB}GB"
    PRE_FAIL_COUNT=$(( PRE_FAIL_COUNT + 1 ))
  else
    pass "GPU ${idx} [${bdf}] VRAM ${vgb}GB"
  fi

  # PCIe link speed + width
  pcie_speed="$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null || echo "unknown")"
  pcie_width="$(cat "/sys/bus/pci/devices/${bdf}/current_link_width" 2>/dev/null || echo "?")"
  pcie_str="${pcie_speed} x${pcie_width}"
  GPU_PCIE["${idx}"]="${pcie_str}"

  info "GPU ${idx} PCIe: ${pcie_str}"
  [[ "${pcie_speed}" != *"32.0"* ]] && warn "GPU ${idx} not PCIe Gen5 — check slot/riser"
  [[ "${pcie_width}"  != "16"   ]] && warn "GPU ${idx} link width x${pcie_width} (expected x16)"
done
echo ""

if [[ ${PRE_FAIL_COUNT} -gt 0 ]]; then
  fail "Pre-check failed — aborting"
  for i in "${!VK_INDICES[@]}"; do
    idx="${VK_INDICES[$i]}"
    bdf="${GPU_BDFS[$i]}"
    name="${GPU_NAMES[$i]:-unknown}"
    vgb="${GPU_VRAM_GB[$idx]:-0}"
    reason="${PRE_FAIL[${idx}]:-}"
    [[ -n "${reason}" ]] && \
      echo "$(date '+%Y-%m-%d %H:%M:%S'),${SERIAL},${idx},\"${name}\",${bdf},${vgb},${GPU_PCIE[$idx]:-?},0,0,FAIL,${reason},${LOG_DIR}" \
        >> "${RESULTS_CSV}"
  done
  exit 1
fi

# ─── launch vk_burn (all GPUs simultaneously) ────────────────────────────────
info "=== Burn-in started ==="
DEADLINE=$(( $(date +%s) + DURATION ))
BURN_START_UPTIME=$(awk '{printf "%.0f\n", $1}' /proc/uptime)
declare -a VK_PIDS=()
declare -A GPU_ACTIVE

for i in "${!VK_INDICES[@]}"; do
  idx="${VK_INDICES[$i]}"
  "${VK_BURN}" "${DEADLINE}" 90 "${idx}" \
    > "${LOG_DIR}/gpu${idx}_vkburn.log" 2>&1 &
  VK_PIDS+=("$!")
  GPU_ACTIVE["${idx}"]=1
  info "  GPU ${idx} → pid $!"
done
echo ""

# ─── per-GPU tracking ────────────────────────────────────────────────────────
declare -A FAIL_REASONS
declare -A MAX_JUNC
declare -A MAX_POWER
for idx in "${VK_INDICES[@]}"; do
  MAX_JUNC["${idx}"]=0
  MAX_POWER["${idx}"]=0
done

kill_gpu() {
  local idx="$1" pos="$2" reason="$3"
  [[ "${GPU_ACTIVE[${idx}]:-0}" -eq 0 ]] && return
  GPU_ACTIVE["${idx}"]=0
  FAIL_REASONS["${idx}"]="${reason}"
  kill "${VK_PIDS[$pos]}" 2>/dev/null || true
  fail "GPU ${idx} → ${reason}"
}

# ─── monitoring loop ─────────────────────────────────────────────────────────
NEXT_REPORT=$(date +%s)

while [[ $(date +%s) -lt ${DEADLINE} ]]; do
  NOW=$(date +%s)

  if [[ ${NOW} -ge ${NEXT_REPORT} ]]; then
    NEXT_REPORT=$(( NOW + REPORT_INTERVAL ))
    REMAINING=$(( DEADLINE - NOW ))

    echo -e "${BOLD}  ── $(date +%T)  ${REMAINING}s remaining ──────────────────${NC}" \
      | tee -a "${MAIN_LOG}"

    for i in "${!VK_INDICES[@]}"; do
      idx="${VK_INDICES[$i]}"
      hw="${HWMON_DIRS[$i]}"
      bdf="${GPU_BDFS[$i]}"
      [[ "${GPU_ACTIVE[${idx}]:-0}" -eq 0 ]] && continue
      [[ -z "${hw}" ]] && continue

      edge=$(read_edge  "${hw}")
      junc=$(read_junc  "${hw}")
      memt=$(read_memt  "${hw}")
      pwr=$(read_power  "${hw}")
      sclk=$(read_sclk  "${hw}")
      vram=$(read_vram  "${bdf}")

      [[ "${junc}"  -gt "${MAX_JUNC[$idx]}"  ]] && MAX_JUNC["${idx}"]="${junc}"
      [[ "${pwr}"   -gt "${MAX_POWER[$idx]}" ]] && MAX_POWER["${idx}"]="${pwr}"

      if [[ "${junc}" -ge "${TEMP_FAIL_C}" ]]; then
        STATUS="${RED}${BOLD}FAIL${NC}"
        kill_gpu "${idx}" "${i}" "junction ${junc}°C ≥ ${TEMP_FAIL_C}°C (limit)"
      elif [[ "${junc}" -ge "${TEMP_WARN_C}" ]]; then
        STATUS="${YELLOW}${BOLD}WARN${NC}"
      else
        STATUS="${GREEN}OK${NC}"
      fi

      printf "  GPU %-2s  edge:%3s°C  junc:%3s°C  mem:%3s°C  %4sW  %4sMHz  %-12s  " \
        "${idx}" "${edge}" "${junc}" "${memt}" "${pwr}" "${sclk}" "${vram}" \
        | tee -a "${MAIN_LOG}"
      echo -e "${STATUS}" | tee -a "${MAIN_LOG}"
    done
    echo ""
  fi

  # check for unexpected crash
  for i in "${!VK_INDICES[@]}"; do
    idx="${VK_INDICES[$i]}"
    [[ "${GPU_ACTIVE[${idx}]:-0}" -eq 0 ]] && continue
    if ! kill -0 "${VK_PIDS[$i]}" 2>/dev/null; then
      wait "${VK_PIDS[$i]}" 2>/dev/null; ec=$?
      [[ "${ec}" -ne 0 ]] && \
        kill_gpu "${idx}" "${i}" "vk_burn process crashed (exit ${ec})"
    fi
  done

  sleep 2
done

# wait for any still-running processes
for i in "${!VK_INDICES[@]}"; do
  idx="${VK_INDICES[$i]}"
  [[ "${GPU_ACTIVE[${idx}]:-0}" -eq 1 ]] && \
    wait "${VK_PIDS[$i]}" 2>/dev/null || true
done

# ─── dmesg check ─────────────────────────────────────────────────────────────
# Only check errors logged AFTER burn-in started (skips boot-time display init warnings).
# Also excludes display-controller patterns (optc/crtc) which are harmless on headless GPUs.
info "Checking dmesg for GPU errors..."
DMESG_ERRS="$(dmesg 2>/dev/null \
  | awk -v t="${BURN_START_UPTIME}" \
      '{ if (match($0, /\[[ \t]*[0-9]+/)) { ts = substr($0, RSTART+1, RLENGTH-1); gsub(/[ \t]/, "", ts); if (ts+0 >= t) print } }' \
  | grep -E "amdgpu.*(reset|gpu fault)|ring.*timeout|GCVM_L2|MES.*fail" \
  | grep -Ev "optc|disable_crtc|REG_WAIT" \
  || true)"

if [[ -n "${DMESG_ERRS}" ]]; then
  warn "dmesg GPU errors found:"
  echo "${DMESG_ERRS}" | tee -a "${MAIN_LOG}"
  for i in "${!VK_INDICES[@]}"; do
    idx="${VK_INDICES[$i]}"
    bdf="${GPU_BDFS[$i]}"
    if echo "${DMESG_ERRS}" | grep -q "${bdf}"; then
      [[ -z "${FAIL_REASONS[${idx}]:-}" ]] && \
        FAIL_REASONS["${idx}"]="kernel GPU error in dmesg (${bdf})"
    fi
  done
fi

# ─── final results ───────────────────────────────────────────────────────────
echo "" | tee -a "${MAIN_LOG}"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}" | tee -a "${MAIN_LOG}"
echo -e "${BOLD}  RESULTS  ──  $(date '+%Y-%m-%d %H:%M:%S')${NC}"       | tee -a "${MAIN_LOG}"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}" | tee -a "${MAIN_LOG}"
echo ""

PASS_COUNT=0; FAIL_COUNT=0

for i in "${!VK_INDICES[@]}"; do
  idx="${VK_INDICES[$i]}"
  bdf="${GPU_BDFS[$i]}"
  name="${GPU_NAMES[$i]:-unknown}"
  vgb="${GPU_VRAM_GB[$idx]:-?}"
  pcie="${GPU_PCIE[$idx]:-?}"
  max_j="${MAX_JUNC[$idx]:-0}"
  max_p="${MAX_POWER[$idx]:-0}"
  reason="${FAIL_REASONS[${idx}]:-}"

  if [[ -n "${reason}" ]]; then
    echo -e "  GPU ${idx}  [${name}]  [${bdf}]  ${RED}${BOLD}FAIL${NC}" | tee -a "${MAIN_LOG}"
    echo -e "           Reason  : ${reason}"                  | tee -a "${MAIN_LOG}"
    echo -e "           Max temp: ${max_j}°C  Max power: ${max_p}W" | tee -a "${MAIN_LOG}"
    echo "$(date '+%Y-%m-%d %H:%M:%S'),${SERIAL},${idx},\"${name}\",${bdf},${vgb},${pcie},${max_j},${max_p},FAIL,${reason},${LOG_DIR}" \
      >> "${RESULTS_CSV}"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  else
    echo -e "  GPU ${idx}  [${name}]  [${bdf}]  ${GREEN}${BOLD}PASS${NC}" | tee -a "${MAIN_LOG}"
    echo -e "           Max junc: ${max_j}°C  Max power: ${max_p}W  VRAM: ${vgb}GB  PCIe: ${pcie}" \
      | tee -a "${MAIN_LOG}"
    echo "$(date '+%Y-%m-%d %H:%M:%S'),${SERIAL},${idx},\"${name}\",${bdf},${vgb},${pcie},${max_j},${max_p},PASS,,${LOG_DIR}" \
      >> "${RESULTS_CSV}"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
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
