# 三系統 SATA 硬碟改造 + 診斷工具部署手冊

把一顆現有的雙系統（Win10 + Ubuntu 舊版）SATA 硬碟改造成三系統（加裝 Ubuntu 24.04 Server），並在上面部署 R9700 診斷工具。這份手冊是實際跑過兩次、踩過坑之後整理出來的**驗證過的流程**，不是理論規劃——遇到跟原始計畫不一樣的地方，以這份為準。

適用情境：主管希望在既有產線機器上直接跑診斷，不想每次插拔外接 USB。

---

## 角色分工

| 機器 | 用途 | 需求 |
|---|---|---|
| **開發/建置機** | 編譯 `llama-cli`、蒐集 ROCm `.so`、下載模型 | 已裝 ROCm 7.2.x |
| **目標機**（SATA 三系統改造對象） | 實際跑診斷 | **零安裝**，全靠 USB/`diag-toolkit` 自己帶的東西 |

在開發機裝 ROCm 是為了**產出**要打包進 `diag-toolkit` 的執行檔和函式庫，不代表目標機也要裝一份 ROCm——目標機從頭到尾維持零安裝的設計原則不變。

---

## Phase 0：診斷（不動任何東西）

1. 確認開機模式是 UEFI + GPT（不是 Legacy BIOS / MBR）
2. 確認 Secure Boot 狀態：`mokutil --sb-state`
3. **如果同一台機器上有另一顆絕對不能動的開機碟**（例如獨立的 M.2 開機碟）：先記錄一份 `sudo efibootmgr -v` 當作基準值，之後每個有風險的步驟做完都要重新跑一次比對，確保它的 boot entry 內容和 `BootOrder` 完全沒變
4. 確認 SATA 碟現有分割區配置（`parted -l`、`lsblk -f`）、雙系統各自實際用量，抓出縮小之後能釋出多少空間

## Phase 1：切分割區

5. 縮小既有 Linux 分割區前，先 `sudo e2fsck -f /dev/sdX2` 再 `sudo resize2fs /dev/sdX2 <目標大小>`
6. `sudo parted /dev/sdX resizepart 2 <新結尾磁區>`——下手前務必先 `parted /dev/sdX unit s print` 核對實際磁區數字,不要照抄別台機器算過的值
7. `sudo parted /dev/sdX mkpart primary ext4 <新起點> <新結尾>` 切出新分割區給 Ubuntu 24.04

## Phase 2：安裝 Ubuntu 24.04 Server

8. 用官方 **Server** 版安裝媒體（**不是 Desktop 版**，兩個 ISO 檔名容易搞混，安裝前先確認）
9. 安裝類型選手動分割，指定剛切出來的新分割區當作 `/`，ESP 沿用既有的（不要新建）
10. **已知風險**：安裝程式很可能會直接覆蓋既有 Linux 的 `\EFI\<其 bootloader-id>\` 目錄（例如原本 Ubuntu 22.04 用的 `\EFI\ubuntu\`）。**不用在安裝當下想辦法迴避**——讓它蓋過去，裝完之後 `os-prober` 通常能自動重建出一份可以正常運作的三選一 GRUB 選單。真的要讓每個系統在韌體開機選單（F11）也能分別獨立選到，留到 Phase 3 處理

## Phase 3：開機選單修復

11. 進新裝好的 Ubuntu 24.04，改 `/etc/default/grub`：
    ```
    GRUB_TIMEOUT_STYLE=menu
    GRUB_TIMEOUT=10
    ```
    然後 `sudo update-grub`。預設是 `hidden` + `0` 秒，選單完全看不到，不改的話操作人員沒辦法手動選開機系統。

12. **想讓 F11 韌體選單也能分別獨立選到每個系統**（不用先選 GRUB 再選第二層）：

    進到被蓋掉的那個舊系統，跑：
    ```bash
    sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=<不重複的新名字> --recheck
    sudo update-grub
    ```
    **`--bootloader-id` 一定要指定成獨一無二的名字，絕對不要留空或跟現有的撞名**——撞名會反過來把另一個系統的開機目錄蓋掉。

    - 如果該系統 kernel 比較舊、`efivarfs` 有問題（`grub-install` 跳出 `EFI variables cannot be set on this system`，`efibootmgr -v` 直接報 `EFI variables are not supported on this system`）：**檔案本身其實還是有寫成功**，只是沒辦法自動註冊 NVRAM 開機項。解法是切到 NVRAM 存取正常的系統（通常是新裝的 Ubuntu 24.04），手動補登記：
      ```bash
      sudo efibootmgr -c -d /dev/sdX -p <ESP的分割編號> -L "<名字>" -l '\EFI\<名字>\shimx64.efi'
      ```
    - 如果補好的新開機項選了之後直接跳回 BIOS 設定畫面（即使 Secure Boot 已確認關閉）：不用深究原因，直接把**已知能正常開機**的 `shimx64.efi`/`mmx64.efi`/`grubx64.efi` 複製過去蓋掉有問題的版本（不同系統版本附的 shim 套件在某些主機板韌體上相容性不一致），保留原本正確指向該系統分割區的 `grub.cfg` 不要動。

13. 每完成一步都重新跑一次 `efibootmgr -v`，跟 Phase 0 的基準值比對，確認沒有動到不該動的開機碟。

## Phase 4：R9700 驅動

14. 檢查：
    ```bash
    lspci -d 1002: -nnk
    dmesg | grep -i amdgpu
    ```
    如果 VGA controller 那行只顯示 `Kernel modules: amdgpu`，**沒有** `Kernel driver in use: amdgpu`，且 dmesg 出現 `Fatal error during GPU init` / `probe of 0000:03:00.0 failed with error -22`——這是已知問題：Ubuntu 24.04 預設的 in-tree kernel 不支援 gfx1201/RDNA4。

15. **先試 HWE kernel**（比較簡單，目前兩次都成功）：
    ```bash
    sudo apt install --install-recommends linux-generic-hwe-24.04
    sudo reboot
    ```
    重開機後重跑 Phase 4 步驟 14 的檢查，確認變成 `Kernel driver in use: amdgpu`。

16. HWE 沒用的話才退回 `CLAUDE.md` 記載、已驗證過的 amdgpu-dkms chroot 修復流程。

## Phase 5：在開發機準備 `bin/` `lib/` `models/`

這三個資料夾是 `.gitignore` 排除的二進位檔案，`git clone` 之後不會有內容，要自己準備：

17. **`bin/vk_burn`**（Vulkan burn-in 用）：
    ```bash
    sudo apt install g++ glslang-tools libvulkan-dev
    bash build.sh
    ```

18. **`bin/llama-cli`**（LLM 推論用，開發機需已裝 ROCm 7.2.x）：
    ```bash
    git clone https://github.com/ggerganov/llama.cpp
    cd llama.cpp
    cmake -B build -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1201 -DCMAKE_BUILD_TYPE=Release
    cmake --build build --target llama-cli -j$(nproc)
    ```

19. **`bin/rocm-smi`、`bin/rocminfo`**：ROCm 套件本身附的執行檔，不用編譯，直接從 `/opt/rocm/bin/` 複製。

20. **`lib/`**：對上面四支執行檔（`llama-cli`、`vk_burn`、`rocm-smi`、`rocminfo`）做**遞迴** `ldd` 依賴掃描，缺的 `.so` 從 `/opt/rocm*/lib`、`/opt/amdgpu/lib/x86_64-linux-gnu`、`/usr/lib/x86_64-linux-gnu` 補進去。

    **驗證時的陷阱**：開發機自己裝了 ROCm，`ldd` 檢查「有沒有 not found」會有假陽性——就算某個 `.so` 根本沒放進 `lib/`，只要開發機系統本身有裝，`ldd` 一樣顯示解析成功（其實是從系統路徑偷渡的）。正確驗證方式是看每個依賴**實際解析到的路徑**是不是真的落在 `lib/` 資料夾內：

    ```bash
    LD_LIBRARY_PATH=<lib目錄> ldd <執行檔> | while read -r line; do
      echo "$line" | grep -q "=>" || continue
      path=$(echo "$line" | awk '{print $3}')
      [[ "$path" != "<lib目錄>"* && -n "$path" && "$path" != "not" ]] && echo "LEAK: $line"
    done
    ```

    補一輪之後要重新掃一次（新補的 `.so` 自己可能又有沒補到的依賴），直到完全零洩漏、零 "not found" 為止。

21. **`models/qwen2.5-0.5b-instruct-q8_0.gguf`**：
    ```bash
    pip install -U huggingface_hub
    huggingface-cli download Qwen/Qwen2.5-0.5B-Instruct-GGUF qwen2.5-0.5b-instruct-q8_0.gguf --local-dir ./models/
    ```
    下載前先上 [Hugging Face 頁面](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF) 確認確切檔名，量化版本釋出可能會更新。

## Phase 6：部署到目標機

22. 從 GitHub 重新 clone 最新版本的 `diag/`、`config.sh`、`CLAUDE.md`、`README.md`。
23. 把 Phase 5 準備好的 `bin/`、`lib/`、`models/` 複製過去。
24. 裝開機引導畫面：
    ```bash
    cp bash_profile.tty1 <目標系統掛載點>/home/asrock/.bash_profile
    ```
25. 需要把每次測試結果同步到共用資料夾的話，`config.sh` 加：
    ```bash
    SHARED_RESULTS_DIR="/boot/efi/EFI/ubuntu/gpu_test_results"
    ```
26. **目標機**裝 Vulkan driver（`gpu_burn_test.sh`/`llm_test.sh` 的 GPU 偵測是走 `vk_burn`／Vulkan，不是 ROCm）：
    ```bash
    sudo apt install mesa-vulkan-drivers vulkan-tools
    ```
    全新的 Server 安裝預設沒有這個，沒裝的話即使 amdgpu 驅動完全正常，也會報 `No discrete GPU found`。

## Phase 7：驗證

27. ```bash
    sudo bash /diag-toolkit/diag/run_all.sh --serial <序號>
    ```
    確認 Stage 1（burn-in）跟 Stage 2（LLM inference）都是 PASS。
28. 有設定共用資料夾的話，確認結果真的同步過去了。
29. 最後再跑一次 `efibootmgr -v`，跟 Phase 0 的基準值逐項比對，確認全程沒有動到不該動的開機碟。

---

## 其他非顯而易見的坑

- **F11 韌體開機選單 跟 GRUB 自己的系統選單是兩個不同的層級**。F11 只列出 NVRAM 登記的「開機程式」（每套 bootloader 一筆），不是「作業系統」。如果兩個 Linux 共用同一套 GRUB，F11 只會看到一筆，選進去之後 GRUB 自己的選單才會列出裡面管理的所有系統。
- **`setup_env.sh` 逐項的 `[OK]`/`[FAIL]` 檢查訊息不會寫進任何 log 檔**，只有呼叫端一句概括的 `setup_env.sh failed` 訊息會被記錄，逐項明細只出現在螢幕上。要留存的話得自己額外重導向這次執行的輸出。
- **全新 Ubuntu Server 24.04 的 `/tmp` 是 tmpfs**（記憶體暫存），寫在那裡的東西只要那次開機 session 結束、或硬碟換到別台機器，就會消失。需要留存的東西要寫到 toolkit 自己 `logs/` 底下（在真正的硬碟分割區上）。

---

## 已知問題追蹤

- `diag/setup_env.sh` 原本用 `lsmod | grep -q '^amdgpu'` 檢查驅動是否載入，在某些 in-tree/HWE kernel 環境下會不可靠地誤判失敗（即使 `dmesg`、`/dev/dri/renderD*`、實際 GPU 運算都證實驅動正常）。已在 commit `f948f7e` 改成直接讀 `/proc/modules`,修復。
- `CLAUDE.md` 裡描述的 `diag/prepare_usb_libs.sh` **目前並不存在**於這個 repo 裡，Phase 5 步驟 20 的手動流程就是它應該要做的事——之後有空應該把它寫成真正的腳本並 commit 進來。
