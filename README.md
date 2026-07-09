# R9700 LLM 推論診斷工具 — 操作說明

USB 隨身碟自帶版，目標機**零安裝**，插上就能跑。

## 需求

目標機（產線主板）只需要：
- amdgpu kernel module 已載入（Ubuntu 24.04 / kernel 6.8+ 預設內建）
- `/dev/kfd` 與 `/dev/dri/renderD*` 存在（amdgpu module 自動建立）

USB 自帶 ROCm userspace 函式庫、`llama-cli`、`rocm-smi` 與測試模型，不需要在目標機安裝任何東西。

## 使用方式

```bash
cd <USB 掛載點>/diag

sudo bash run_all.sh              # 自動偵測所有 R9700,逐張測試
sudo bash run_all.sh --gpu 0      # 只測 GPU index 0
sudo bash run_all.sh --verbose    # 顯示模型推論輸出內容
sudo bash run_all.sh --timeout 60 # 自訂單卡推論逾時秒數(預設 180)
```

## 結果判讀

執行結束會印出彩色 SUMMARY:

```
GPU 0:  PASS
Total: 1 cards | 1 PASS | 0 FAIL
```

- 全部 `PASS` → exit code 0 → **此板測試通過**
- 任一張 `FAIL (exit N)` → exit code 1 → **此板不合格**,N 的意義見下表

詳細 log 在 `logs/<時間戳記>/`，含 `summary.log` 與每張卡的 `gpu<N>.log`。

## Exit Code 對照表

| Code | 來源 | 意義 |
|------|------|------|
| 0 | run_all.sh | 全部 PASS |
| 1 | run_all.sh | 至少一張卡 FAIL |
| 2 | run_all.sh | 找不到 R9700 GPU(檢查 PCIe 插槽 / amdgpu driver) |
| 10 | run_all.sh | 環境未就緒(看 pre-flight 輸出找原因) |
| 3 | test_single_gpu.sh | VRAM 不足(疑似 HBM 故障,正常應 ≥28GB) |
| 1 | test_single_gpu.sh | 推論輸出異常 / 亂碼 / timeout |
| 4 | test_single_gpu.sh | dmesg 偵測到 GPU kernel error |

## 常見問題

**pre-flight 在 amdgpu / /dev/kfd 階段失敗**
→ 目標機 kernel 沒有正確的 amdgpu 驅動或 R9700 沒插好。本工具假設目標機驅動正常；
   若需要在目標機安裝/更新 ROCm,請用 `diag/install_rocm.sh`(需網路連線)。

**Found 0 GPU(s) to test**
→ `rocm-smi --showproductname` 抓不到 R9700/gfx1201 字串,檢查 PCIe 插槽與 BIOS 設定。

## 給開發者:重新打包 USB

換新 build 的 `llama-cli` 或新版 ROCm 時,在已裝好 ROCm 的開發機上跑:

```bash
bash diag/prepare_usb_libs.sh <USB 掛載點>
```

詳見 `CLAUDE.md`。
