# R9700 USB 診斷工具 — 操作說明

USB 隨身碟攜帶版。插到**目標機**後直接執行，不需要在目標機安裝 ROCm 或任何額外套件。

## 製作 USB（開發機上執行一次）

```bash
git clone https://github.com/hanchi-gao/r9700-usb-diag
cd r9700-usb-diag
./build.sh          # 編譯 bin/vk_burn（需 libvulkan-dev + glslang-tools + g++）
# 複製整個資料夾到 USB 隨身碟，或直接從這個目錄對目標機跑
```

`build.sh` 若缺少 build deps 會直接提示安裝指令。

## 目標機需求

- **kernel ≥ 6.11**（6.8 以下無法列舉 gfx1201 / PCI ID `1002:7551`）
- `amdgpu` kernel module 已載入
- `/dev/dri/renderD*` 存在（amdgpu module 自動建立）
- LLM 測試額外需要 `/dev/kfd`

## USB 目錄結構

```
r9700-usb-diag/
├── bin/
│   ├── vk_burn        # Vulkan compute GPU 燒機 binary（必要）
│   └── llama-cli      # LLM 推論 binary（可選，llm_test.sh 才用）
├── models/
│   └── *.gguf         # 推論模型（可選，llm_test.sh 才用）
├── diag/
│   ├── run_all.sh         # 燒機 + LLM 推論一次接續執行（推薦入口）
│   ├── gpu_burn_test.sh   # GPU Vulkan 燒機測試（可單獨執行）
│   ├── llm_test.sh        # LLM 推論測試（可單獨執行）
│   ├── test_single_gpu.sh # 單卡 LLM 推論（由 llm_test.sh 呼叫）
│   └── setup_env.sh       # LLM 環境 pre-flight（由 llm_test.sh 呼叫）
├── logs/              # 每次測試結果（自動建立）
├── results.csv        # 累計測試紀錄（自動建立）
└── config.sh          # 閾值設定
```

## 使用方式

### 燒機 + LLM 推論一次執行（推薦）

```bash
cd <USB 掛載點>

sudo bash diag/run_all.sh --serial SN001
sudo bash diag/run_all.sh --serial SN001 --duration 300 --timeout 240
sudo bash diag/run_all.sh --serial SN001 --gpu 0
sudo bash diag/run_all.sh --serial SN001 --burn-only   # 只跑燒機，不跑 LLM
```

- Stage 1 跑 `gpu_burn_test.sh`，Stage 2 跑 `llm_test.sh`，同一條指令接續執行
- **Stage 1 FAIL 就直接跳過 Stage 2**（卡都燒機失敗了，沒必要再拿去跑 LLM 推論），exit 1
- Stage 1 PASS、Stage 2 FAIL → exit 2；兩階段都 PASS → exit 0
- 兩階段各自的 log／CSV（`results.csv`、`llm_results.csv`）跟單獨執行時完全一樣，沒有額外的彙總檔

### GPU 燒機測試（可單獨執行，不需 ROCm）

```bash
cd <USB 掛載點>

sudo bash diag/gpu_burn_test.sh --serial SN001
sudo bash diag/gpu_burn_test.sh --serial SN001 --duration 300   # 指定秒數（預設 120s）
sudo bash diag/gpu_burn_test.sh --serial SN001 --gpu 0          # 只測單張卡
```

- 使用 `bin/vk_burn`（Vulkan compute）同時對所有 R9700 加壓
- 溫度、功耗、VRAM 全部從 **sysfs hwmon** 讀取，不依賴 rocm-smi
- 燒機前自動檢查 VRAM 容量（≥28GB）與 PCIe 鏈路速度（Gen5 x16）
- 結束後掃描 dmesg 確認無 GPU reset / MES / ring timeout 錯誤

### LLM 推論測試（可單獨執行）

```bash
sudo bash diag/llm_test.sh --serial SN001
sudo bash diag/llm_test.sh --serial SN001 --gpu 0
sudo bash diag/llm_test.sh --serial SN001 --timeout 240
```

需要 USB 上備有 `bin/llama-cli` 與 `models/*.gguf`。

## 結果判讀

執行結束列印彩色 RESULT 區塊：

```
  GPU 0  [0000:01:00.0]  PASS
           Max junc: 87°C  Max power: 298W  VRAM: 31GB  PCIe: 32.0 GT/s x16

  Total: 4 GPU(s) | 4 PASS | 0 FAIL
```

- 全部 PASS → exit 0 → **此板通過**
- 任一 FAIL → exit 1 → **此板不合格**，reason 欄說明原因

詳細 log：`logs/<時間戳記>/burn.log`，累計紀錄：`results.csv`。

## Exit Code 對照表

### run_all.sh

| Code | 意義 |
|------|------|
| 0 | Stage 1（燒機）+ Stage 2（LLM）皆 PASS，或 `--burn-only` 且 Stage 1 PASS |
| 1 | Stage 1（燒機）FAIL — Stage 2 被跳過 |
| 2 | Stage 1 PASS，但 Stage 2（LLM）FAIL |

### gpu_burn_test.sh

| Code | 意義 |
|------|------|
| 0 | 全部 GPU PASS |
| 1 | 至少一張 FAIL（VRAM 不足 / 過溫 / vk_burn crash / dmesg GPU error / pre-check 失敗） |

### llm_test.sh / test_single_gpu.sh

| Code | 來源 | 意義 |
|------|------|------|
| 0 | llm_test.sh | 全部 GPU PASS |
| 1 | llm_test.sh | 至少一張推論輸出異常（空輸出 / 亂碼 / timeout） |
| 3 | test_single_gpu.sh | VRAM 不足（≥28GB 要求未達，可能 HBM 故障） |
| 4 | test_single_gpu.sh | dmesg 偵測到 GPU kernel error |
| 10 | llm_test.sh | 環境未就緒（llama-cli 或 model 不存在） |

## 閾值設定（config.sh）

| 參數 | 預設值 | 說明 |
|------|-------|------|
| `DURATION` | 120 | 燒機秒數 |
| `VRAM_MIN_GB` | 28 | VRAM 最小值（GB） |
| `TEMP_WARN_C` | 98 | Junction 溫度警告 |
| `TEMP_FAIL_C` | 100 | Junction 溫度立即 FAIL |
| `REPORT_INTERVAL` | 15 | 狀態列印間隔（秒） |
| `VRAM_PCT` | 90 | Vulkan 填充 VRAM 百分比 |

## 常見問題

**GPU 未偵測到（No discrete GPU found）**
→ 確認 PCIe 插槽正確、BIOS 沒有 SR-IOV 或 Above 4G Decoding 問題，以及 `amdgpu` module 已載入（`lsmod | grep amdgpu`）。

**VRAM 顯示不足（VRAM XGB < 28GB）**
→ 可能 HBM 故障或 amdgpu 初始化不完全。重開機後重試；若持續發生換卡。

**PCIe 非 Gen5 x16**
→ 燒機仍會繼續（降為 WARN），但需確認主板 PCIe 插槽與 riser 連接。

**vk_burn 不存在**
→ 在開發機上編譯 `src/vk_burn.cpp`（需 `libvulkan-dev` + `g++`），將 binary 複製到 `bin/vk_burn`。

**LLM 環境未就緒（exit 10）**
→ 確認 `bin/llama-cli` 與 `models/*.gguf` 已放到 USB 對應目錄。
