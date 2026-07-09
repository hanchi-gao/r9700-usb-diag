# GPU Diagnostic Tool — Claude Code Context

這份文件給 Claude Code 看,說明這個專案的架構、設計決策、和注意事項。

---

## 專案目的

產線用的 R9700 GPU 診斷工具。把一張顯示卡插到主板上,開機進 USB 微系統,跑腳本,輸出 PASS 或 FAIL。

目標:零安裝,插上 USB 就能跑。

---

## 硬體與環境

- **GPU**: AMD Radeon AI PRO R9700 (gfx1201 / RDNA4),32GB HBM3
- **USB 微系統**: Ubuntu 24.04 Server,用 `grub-install --target=x86_64-efi --removable` 建立
- **推論引擎**: llama.cpp (ROCm/HIP build,target: gfx1201)
- **測試模型**: Qwen2.5-0.5B-Instruct Q8 GGUF (~540MB)
- **ROCm 版本**: 7.2.2

---

## 關鍵架構決策

### 目標機零安裝

目標機(產線上的主板)不需要安裝任何東西。

**目標機只需要:**
- kernel 有 amdgpu module (Ubuntu 24.04 kernel 6.8+ 預設內建)
- `/dev/kfd` 和 `/dev/dri/renderD*` 由 kernel module 建立

**USB 自帶:**
- `bin/llama-cli` — ROCm/HIP gfx1201 build
- `bin/rocm-smi` — ROCm SMI binary
- `lib/*.so` — libamdhip64, libhsa-runtime64, librocm_smi64 等全部 shared library
- `models/qwen2.5-0.5b-instruct-q8_0.gguf`

執行時用 `LD_LIBRARY_PATH=<USB>/lib` 指向 USB 自帶的 .so,不碰目標機的系統。

### 為什麼不用 Docker

USB 微系統本身就是 Ubuntu 24.04,開機後 kernel 就在,amdgpu 就在。不需要 container 隔離,host-native 執行更簡單、啟動更快。

### 為什麼選 llama.cpp 而非 vLLM

vLLM 啟動需要 1-2 分鐘,產線不能接受。llama.cpp 單一 binary,啟動秒級。

### 為什麼選 Qwen2.5-0.5B Q8

- 夠小 (~540MB),放得進 USB
- Q8 精度夠高,推論結果穩定,不會因量化誤差造成亂碼誤判
- 不用 tokenizer/Python,llama.cpp 直接吃 GGUF

---

## 目錄結構

```
<USB 根目錄>/
├── CLAUDE.md               ← 你現在在看的這個
├── README.md               ← 操作說明
├── diag/
│   ├── run_all.sh          ← 主入口
│   ├── test_single_gpu.sh  ← 單卡測試核心邏輯
│   ├── setup_env.sh        ← 環境 pre-flight (source 執行,會 export 環境變數)
│   ├── prepare_usb_libs.sh ← 在開發機跑,打包 ROCm userspace 進 USB
│   └── install_rocm.sh     ← 備用:目標機需要安裝 ROCm 時用 (需要網路)
├── bin/
│   ├── llama-cli           ← ROCm build,gfx1201
│   └── rocm-smi            ← USB 自帶版本
├── lib/
│   └── *.so                ← ROCm userspace shared libraries
├── models/
│   └── qwen2.5-0.5b-instruct-q8_0.gguf
└── logs/
    └── YYYYMMDD_HHMMSS/    ← 每次執行自動建立
        ├── summary.log
        ├── gpu0.log
        └── gpu1.log
```

---

## 腳本說明

### `run_all.sh` (主入口)

- **source** `setup_env.sh`(不是 bash),讓 export 的 `LD_LIBRARY_PATH` 和 `PATH` 繼承到同一個 shell
- 用 `rocm-smi --showproductname` grep R9700/gfx1201 自動偵測 GPU 數量
- 對每張卡設定 `HIP_VISIBLE_DEVICES=<idx>` 後呼叫 `test_single_gpu.sh`
- 輸出彩色 PASS/FAIL ASCII banner + summary.log

**CLI:**
```bash
sudo bash /diag/run_all.sh              # 全部 GPU
sudo bash /diag/run_all.sh --gpu 0      # 單卡
sudo bash /diag/run_all.sh --verbose    # 顯示推論輸出
sudo bash /diag/run_all.sh --timeout 300
```

### `test_single_gpu.sh` (單卡測試)

依序執行四個 stage,任一失敗就 exit:

| Stage | 內容 | 失敗 exit code |
|-------|------|---------------|
| 1 | `rocm-smi` 確認 VRAM ≥ 30GB | 3 |
| 2 | 記錄 dmesg baseline | — |
| 3 | `llama-cli` 推論,timeout 180s | 1 |
| 4 | 輸出 >20 字元、非亂碼 (<5% 不可見字元)、dmesg 無 GPU error | 1 / 4 |

**VRAM 門檻設 30GB 而非 32GB** 是因為 OS 回報值有誤差;但 HBM 故障卡回報 ~8GB,所以 30GB 的門檻能有效區分。

**dmesg 監控的 R9700 fault patterns:**
```
GCVM_L2_PROTECTION_FAULT | MES.*fail | amdgpu.*reset | ring.*timeout | GPU fault | cp_eop_interrupt
```

### `setup_env.sh` (pre-flight)

**重要:用 `source` 執行,不是 `bash`**,否則 export 的環境變數不會傳給呼叫者。

檢查項目:
1. Kernel ≥ 6.8 (gfx1201 full support)
2. amdgpu module loaded
3. /dev/kfd 存在
4. /dev/dri/renderD* 存在
5. USB lib 目錄存在 + .so 數量
6. USB 自帶 rocm-smi 可執行 (fallback 到系統版本並警告)
7. llama-cli 存在且所有 .so 依賴可滿足 (用 `ldd` 驗證)
8. model 檔案存在

成功後 export:
```bash
export LD_LIBRARY_PATH="<USB>/lib:${LD_LIBRARY_PATH}"
export PATH="<USB>/bin:${PATH}"
```

### `prepare_usb_libs.sh` (一次性準備,在開發機跑)

**在 WRX90 (ROCm 7.2.2 已裝) 上執行:**
```bash
bash diag/prepare_usb_libs.sh /media/henry/ASROCK_DIAG
```

流程:
1. 掃描 `/opt/rocm/lib`,複製 libamdhip64, libhsa-runtime64, librocm_smi64, libamd_comgr 等
2. 用 `ldd <USB>/bin/llama-cli` 補齊所有實際依賴的 .so
3. 複製 rocm-smi binary 到 `<USB>/bin/`
4. 自我測試:用 USB lib 跑一次 `rocm-smi --version` 確認可動

llama-cli 要先 build 好放進 USB 再執行此腳本,才能做 ldd 掃描。

---

## Build llama-cli (一次性,在開發機)

```bash
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp
cmake -B build \
  -DGGML_HIP=ON \
  -DAMDGPU_TARGETS=gfx1201 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build --target llama-cli -j$(nproc)
cp build/bin/llama-cli /media/henry/ASROCK_DIAG/bin/
```

---

## Exit Code 一覽

| Code | 觸發腳本 | 意義 |
|------|---------|------|
| 0 | run_all.sh | 全部 PASS |
| 1 | run_all.sh | 至少一張卡 FAIL |
| 2 | run_all.sh | 找不到 R9700 GPU |
| 10 | run_all.sh | 環境未就緒 |
| 1 | test_single_gpu.sh | 推論失敗 / 亂碼 / timeout |
| 3 | test_single_gpu.sh | VRAM 不足 (HBM 故障) |
| 4 | test_single_gpu.sh | dmesg GPU kernel error |

---

## 實際開機執行機制（重要）

**開機自動跑的不是 bash diag-toolkit，而是 Python 腳本。**

`/home/asrock/.bashrc` 在 tty1 登入時會執行：
```bash
if [ "$(tty)" = "/dev/tty1" ]; then
    export LLAMA_CLI=/opt/llama.cpp/build/bin/llama-cli
    export MODEL_PATH=/opt/models/qwen2.5-0.5b-instruct-q8_0.gguf
    python3 /opt/test/gpu_llm_factory_test_cli.py
fi
```

| 項目 | 路徑 |
|------|------|
| 主測試腳本 | `/opt/test/gpu_llm_factory_test_cli.py` |
| llama-cli | `/opt/llama.cpp/build/bin/llama-cli`（已裝在 USB 系統內） |
| 模型 | `/opt/models/qwen2.5-0.5b-instruct-q8_0.gguf` |

**bash diag-toolkit** (`/diag-toolkit/diag/run_all.sh`) 是獨立的，需要手動執行，**開機不會自動呼叫**。

### Python 腳本測試流程

4 個 stage，任一失敗就印 FAIL banner 並 exit 1：

| Stage | 內容 |
|-------|------|
| 1 | rocm-smi 確認 VRAM ≥ 28 GB |
| 2 | llama-cli 推論（`--single-turn`，timeout 180s） |
| 3 | 輸出驗證（長度 ≥ 50 字元、非可印比例 ≤ 1%、耗時上限） |
| 4 | dmesg GPU error check |

**tty1 中文亂碼修復（2026-06-16）**：Python 腳本原本所有 `stage()` 呼叫和錯誤訊息都是中文，在 tty1 顯示為 ■。已將 `/opt/test/gpu_llm_factory_test_cli.py` 內所有中文字串改為英文。

---

## 已知問題 / 限制

- **Ubuntu 20.04 完全不支援 R9700** — kernel 5.4/5.15 沒有 gfx1201 amdgpu 支援,Docker 也繞不過去,必須 22.04.5+ 或 24.04
- **USB 微系統內建的 kernel 6.8.0-124-generic 也不支援 R9700 (gfx1201/RDNA4)** — 雖然是 24.04,但 in-tree amdgpu driver 沒有 gfx1201 IP block,開機 dmesg 會出現:
  ```
  amdgpu 0000:03:00.0: Fatal error during GPU init
  amdgpu: probe of 0000:03:00.0 failed with error -22
  ```
  症狀:`/dev/kfd` 存在但只有 CPU node,`/dev/dri/` 只有 `card0` 沒有 `renderD*`,`rocm-smi` 找不到 GPU。這跟 USB 上的 diag-toolkit 完全無關 — kernel 沒生出 GPU device node,userspace 再齊全也沒用。

  **修法**: 裝 `amdgpu-dkms` (out-of-tree driver),針對 `6.8.0-124-generic` 編譯模組:
  1. 把 USB 微系統的 `/dev/sda` 插到有網路的開發機(此機已裝 ROCm,apt repo `amdgpu.list`/`rocm.list` 已設好)
  2. `chroot` 進 USB 的根目錄分割區 (`sda2`),bind mount `/dev /proc /sys`,mount `/dev/sda1` 到 `boot/efi`
  3. chroot 內 `apt-get install amdgpu-dkms amdgpu-dkms-firmware`(USB 上已裝好對應 `linux-headers-6.8.0-124-generic` + `build-essential`/`gcc`/`make`,postinst 會自動針對 `6.8.0-124-generic` build DKMS module)
  4. 確認 `dkms status` 顯示 `amdgpu/<ver>, 6.8.0-124-generic, x86_64: installed`,`update-initramfs -u -k 6.8.0-124-generic`
  5. unmount、還原 `resolv.conf`,插回產線主板開機

  完整自動化腳本: `fix_usb_kernel_amdgpu.sh`(在開發機 `/home/asrock/QT_test/` 下)。**每一支 USB 微系統都要各跑一次**這個流程(已驗證一支,2026-06-15)。
- **llama-cli 是 amd64 動態 binary** — 不跨架構,和 ROCm lib 版本要對齊 (目前 7.2.2)
- **`RCCL_WARP_SPEED_AUTO=1` 對這個工具無效** — WarpSpeed 只對 AllReduce ≥64MB 有效,llama.cpp 單卡推論不走 RCCL
- **`--disable-prefix-caching`** — 如果之後換成 vLLM 測試要加這個,否則跨 NUMA KV block 會 fault

---

## 環境變數速查

| 變數 | 設定者 | 用途 |
|------|-------|------|
| `HIP_VISIBLE_DEVICES` | run_all.sh | 隔離單卡,每張卡獨立測試 |
| `LD_LIBRARY_PATH` | setup_env.sh | 指向 USB 自帶 ROCm .so |
| `PATH` | setup_env.sh | 讓 USB bin/ 的 rocm-smi 優先於系統版本 |
| `LLAMA_BIN` | run_all.sh → test_single_gpu.sh | llama-cli 路徑 |
| `MODEL_PATH` | run_all.sh → test_single_gpu.sh | GGUF 模型路徑 |
