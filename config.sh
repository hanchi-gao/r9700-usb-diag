#!/usr/bin/env bash
# config.sh — R9700 diagnostic tool settings
# Sourced automatically by gpu_burn_test.sh and run_all.sh.
# All values have sane defaults — only override what you need.

# ── GPU burn-in thresholds ────────────────────────────────────────────────────
# R9700 has 32GB HBM; reports ~29.8GB. 28GB catches dead HBM stacks.
VRAM_MIN_GB=28

# Junction (hotspot) temperature thresholds (°C)
TEMP_FAIL_C=100      # abort that GPU's burn immediately
TEMP_WARN_C=98       # print warning, keep running

# Status report interval during burn-in (seconds)
REPORT_INTERVAL=15

# Default burn duration (seconds); override with --duration
DURATION=120

# Vulkan VRAM fill percentage
VRAM_PCT=90

# ── LLM inference settings ────────────────────────────────────────────────────
# Number of tokens to generate per inference run
N_PREDICT=128

# Per-card inference timeout (seconds)
TIMEOUT=180

# Minimum output characters (too few = inference didn't really run)
MIN_OUTPUT_CHARS=20

# Garbage detection: max fraction of non-printable chars (%)
MAX_NONPRINT_RATIO=5

# Number of parallel llama-cli instances (keep at 1 unless you have spare RAM)
N_PARALLEL=1
