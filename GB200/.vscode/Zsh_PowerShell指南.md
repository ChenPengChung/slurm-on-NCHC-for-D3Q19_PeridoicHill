# D3Q27 PeriodicHill — 完整操作手冊

> **適用系統**：Windows (PowerShell + PuTTY) / macOS (Zsh + rsync + sshpass)  
> **最後更新**：2026-02-16  
> **腳本版本**：v2.0（統一 `Zsh_*` / `Pwshell_*` 命名）

---

## 目錄

1. [環境需求與首次設定](#1-環境需求與首次設定)
2. [命令總覽（Git-like）](#2-命令總覽git-like)
3. [九大同步指令 × 伺服器分類表](#3-九大同步指令--伺服器分類表)
4. [Push 系列 — 上傳到遠端](#4-push-系列--上傳到遠端)
5. [Pull 系列 — 從遠端下載](#5-pull-系列--從遠端下載)
6. [Fetch 系列 — 完整同步（含刪除）](#6-fetch-系列--完整同步含刪除)
7. [狀態檢查與比對](#7-狀態檢查與比對)
8. [背景自動上傳 (watchpush)](#8-背景自動上傳-watchpush)
9. [背景自動下載 (watchpull)](#9-背景自動下載-watchpull)
10. [背景完整同步 (watchfetch)](#10-背景完整同步-watchfetch)
11. [VTK 檔案自動重命名 (vtkrename)](#11-vtk-檔案自動重命名-vtkrename)
12. [SSH 連線與節點操作](#12-ssh-連線與節點操作)
13. [GPU 狀態查詢](#13-gpu-狀態查詢)
14. [編譯與執行](#14-編譯與執行)
15. [VS Code Tasks 快捷操作](#15-vs-code-tasks-快捷操作)
16. [伺服器與節點資訊](#16-伺服器與節點資訊)
17. [同步排除規則](#17-同步排除規則)
18. [VPN 路由自動修復 (macOS)](#18-vpn-路由自動修復-macos)
19. [Mac / Windows 完整功能對照表](#19-mac--windows-完整功能對照表)
20. [疑難排解](#20-疑難排解)

---

## 1. 環境需求與首次設定

### Windows 需求

| 工具 | 說明 |
|------|------|
| PuTTY (plink.exe / pscp.exe) | SSH 連線與檔案傳輸 |
| PowerShell 5.1+ | 執行 `Pwshell_mainsystem.ps1` |

腳本：`.vscode/Pwshell_mainsystem.ps1`

**首次使用** — 在 PowerShell 中執行任意指令（如 `mobaxterm help`），腳本會自動在 `$PROFILE` 建立 `mobaxterm` 函數別名。

### macOS 需求

| 工具 | 安裝方式 | 說明 |
|------|----------|------|
| ssh | 內建 | SSH 連線 |
| rsync | 內建 (`/usr/bin/rsync`) 或 `brew install rsync` | 檔案同步 |
| sshpass | `brew install hudochenkov/sshpass/sshpass` | 密碼自動輸入 |

腳本：`.vscode/Zsh_mainsystem.sh`

**首次設定：**

```bash
# 1. 給予執行權限
chmod +x .vscode/Zsh_mainsystem.sh

# 2. 安裝 sshpass（若需密碼認證）
brew install hudochenkov/sshpass/sshpass

# 3. 首次執行任意指令，腳本會自動在 ~/.profile 建立 mobaxterm 別名
.vscode/Zsh_mainsystem.sh help
```

**環境變數（可選）：**

```bash
export CFDLAB_PASSWORD='1256'          # 密碼（需搭配 sshpass）
export CFDLAB_ASSUME_YES=1             # 跳過確認提示
export CFDLAB_USER='chenpengchung'     # 使用者名稱
export CFDLAB_DEFAULT_NODE=3           # 預設節點
```

### 兩平台命令完全相容

Windows 和 macOS 使用 **相同的命令名稱**，只是底層實作不同：

| | Windows | macOS |
|---|---|---|
| 命令前綴 | `mobaxterm <cmd>` | `mobaxterm <cmd>` |
| 底層工具 | PuTTY (plink/pscp) | rsync + ssh + sshpass |
| 腳本 | `.vscode/Pwshell_mainsystem.ps1` | `.vscode/Zsh_mainsystem.sh` |

---

## 2. 命令總覽（Git-like）

所有命令都以 `mobaxterm` 開頭，對應 Git 概念：

| Git 指令 | mobaxterm 指令 | 做了什麼 |
|----------|----------------|----------|
| `git status` | `mobaxterm status` | 顯示各伺服器待推送/待拉取的檔案數量 |
| `git add .` | `mobaxterm add` | 列出所有待推送的檔案名稱 |
| `git diff` | `mobaxterm diff` | 逐檔比較本地與遠端的差異 |
| `git push` | `mobaxterm push` | 上傳到遠端 + 刪除遠端多餘檔案 |
| `git pull` | `mobaxterm pull` | 從遠端下載（不刪除本地） |
| `git fetch` | `mobaxterm fetch` | 從遠端下載 + 刪除本地多餘檔案 |
| `git log` | `mobaxterm log` | 列出遠端 log 檔清單 + 最後 20 行 |
| `git reset --hard` | `mobaxterm reset` | 只刪除遠端多餘（不上傳） |
| `git clone` | `mobaxterm clone` | 從遠端完整複製到本地 |

### 三大系列核心差異

```
┌──────────────────────────────────────────────────────────────┐
│  PUSH 系列    本地 ──⬆️ 上傳──→ 遠端    ⚠️ 刪除遠端多餘  │
│  PULL 系列    本地 ←──⬇️ 下載── 遠端    ✅ 不刪除本地      │
│  FETCH 系列   本地 ←──⬇️ 下載── 遠端    ⚠️ 刪除本地多餘  │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. 九大同步指令 × 伺服器分類表

> **所有九個指令均支援 .87、.89、.154、all 四種伺服器目標。**

### Push 系列（上傳）

| 指令 | .87 | .89 | .154 | all（預設） |
|------|-----|-----|------|-------------|
| **push** | `push87` 或 `push .87` | `push89` 或 `push .89` | `push154` 或 `push .154` | `push` 或 `pushall` |
| **autopush** | `autopush87` 或 `autopush .87` | `autopush89` 或 `autopush .89` | `autopush154` 或 `autopush .154` | `autopush` 或 `autopushall` |
| **watchpush** | — | — | — | `watchpush`（監控全部） |

### Pull 系列（下載，不刪除）

| 指令 | .87 | .89 | .154 | all（預設） |
|------|-----|-----|------|-------------|
| **pull** | `pull87` 或 `pull .87` | `pull89` 或 `pull .89` | `pull154` 或 `pull .154` | `pull`（全部） |
| **autopull** | `autopull87` 或 `autopull .87` | `autopull89` 或 `autopull .89` | `autopull154` 或 `autopull .154` | `autopull`（全部） |
| **watchpull** | `watchpull .87` | `watchpull .89` | `watchpull .154` | `watchpull`（監控全部） |

### Fetch 系列（下載 + 刪除本地多餘）

| 指令 | .87 | .89 | .154 | all（預設） |
|------|-----|-----|------|-------------|
| **fetch** | `fetch87` 或 `fetch .87` | `fetch89` 或 `fetch .89` | `fetch154` 或 `fetch .154` | `fetch`（全部） |
| **autofetch** | `autofetch87` 或 `autofetch .87` | `autofetch89` 或 `autofetch .89` | `autofetch154` 或 `autofetch .154` | `autofetch`（全部） |
| **watchfetch** | `watchfetch .87` | `watchfetch .89` | `watchfetch .154` | `watchfetch`（監控全部） |

### 快捷別名總表

```
push87    push89    push154    pushall
autopush87 autopush89 autopush154 autopushall
pull87    pull89    pull154
autopull87 autopull89 autopull154
fetch87   fetch89   fetch154
autofetch87 autofetch89 autofetch154
diff87    diff89    diff154    diffall
log87     log89     log154
```

---

## 4. Push 系列 — 上傳到遠端

### 流程

```
mobaxterm push 執行流程：
  1. 掃描本地程式碼 (.h, .cu, .cpp …)
  2. 與遠端比對 → 找出 新增/修改/遠端多餘
  3. 上傳新增+修改 → 刪除遠端多餘
  4. 依序處理 .87 → .89 → .154
```

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm push` | 上傳到全部伺服器（.87 + .89 + .154），刪除遠端多餘 |
| `mobaxterm push87` | 只上傳到 .87 |
| `mobaxterm push89` | 只上傳到 .89 |
| `mobaxterm push154` | 只上傳到 .154 |
| `mobaxterm pushall` | = `push`（全部） |
| `mobaxterm autopush` | 有變更才推送（全部） |
| `mobaxterm autopush87` | 有變更才推 .87 |
| `mobaxterm autopush89` | 有變更才推 .89 |
| `mobaxterm autopush154` | 有變更才推 .154 |

---

## 5. Pull 系列 — 從遠端下載

### 流程

```
mobaxterm pull 執行流程：
  1. 掃描遠端輸出檔案 (*.dat, *.plt, *.vtk, *.bin, log*)
  2. 比對 MD5 → 只下載新增/變更的檔案
  3. ✅ 不刪除本地任何檔案
```

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm pull` | 從全部伺服器下載（預設 all） |
| `mobaxterm pull87` | 從 .87 下載 |
| `mobaxterm pull89` | 從 .89 下載 |
| `mobaxterm pull154` | 從 .154 下載 |
| `mobaxterm autopull` | 有新檔案才下載（預設 all） |
| `mobaxterm autopull87` | 有新檔案才下載 .87 |
| `mobaxterm autopull89` | 有新檔案才下載 .89 |
| `mobaxterm autopull154` | 有新檔案才下載 .154 |

### 下載的檔案類型

| 類型 | 說明 |
|------|------|
| `*.dat` / `*.DAT` | 數據輸出檔 |
| `*.plt` | Tecplot 繪圖檔 |
| `*.vtk` | VTK 視覺化檔案 |
| `*.bin` | 二進位備份檔 |
| `log*` | 執行日誌 |

---

## 6. Fetch 系列 — 完整同步（含刪除）

### 流程

```
mobaxterm fetch 執行流程：
  1. 下載遠端有的輸出檔案
  2. ⚠️ 刪除本地有但遠端沒有的輸出檔案
  3. 結果：本地輸出 = 遠端輸出
```

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm fetch` | 從全部伺服器完整同步（預設 all） |
| `mobaxterm fetch87` | 同步 .87 |
| `mobaxterm fetch89` | 同步 .89 |
| `mobaxterm fetch154` | 同步 .154 |
| `mobaxterm autofetch` | 有差異才同步（預設 all） |
| `mobaxterm autofetch87` | 有差異才同步 .87 |
| `mobaxterm autofetch89` | 有差異才同步 .89 |
| `mobaxterm autofetch154` | 有差異才同步 .154 |

> ⚠️ **注意**：fetch 會刪除本地多餘的檔案！使用前確認本地沒有未上傳的重要資料。

---

## 7. 狀態檢查與比對

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm status` | 各伺服器的待推送/待拉取檔案數量 |
| `mobaxterm diff` | 全部伺服器逐檔差異 |
| `mobaxterm diff87` | 只比對 .87 |
| `mobaxterm diff89` | 只比對 .89 |
| `mobaxterm diff154` | 只比對 .154 |
| `mobaxterm diffall` | = `diff`（全部） |
| `mobaxterm add` | 列出待推送的檔案清單 |
| `mobaxterm issynced` | 一行狀態：`.87: [OK] \| .89: [OK] \| .154: [DIFF]` |
| `mobaxterm log` | 全部伺服器的 log 檔案（預設 all） |
| `mobaxterm log87` / `log89` / `log154` | 指定伺服器的 log |

### 進階操作

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm sync` | 互動式：diff → 確認 → push |
| `mobaxterm fullsync` | push + reset（遠端完全等於本地） |
| `mobaxterm reset` | 只刪除遠端多餘（不上傳） |
| `mobaxterm clone` | 從遠端完整複製到本地（覆蓋） |
| `mobaxterm check` | 檢查工具 + 遠端連線是否正常 |

### Code Diff Analysis（GitHub 風格差異分析）

傳輸指令（push / pull / fetch）預設會先顯示差異再確認，可用選項控制行為：

| 選項 | 說明 | 範例 |
|------|------|------|
| `--no-diff` | 跳過差異分析，直接傳輸 | `mobaxterm push --no-diff` |
| `--diff-summary` | 僅顯示統計摘要 | `mobaxterm push --diff-summary` |
| `--diff-stat` | diffstat 風格（±行數統計） | `mobaxterm push --diff-stat 87` |
| `--diff-full` | 完整逐行差異（預設） | `mobaxterm push --diff-full` |
| `--force` | 跳過確認 + 差異分析 | `mobaxterm push --force` |
| `--quick` | 同 `--no-diff` | `mobaxterm pull --quick` |

獨立差異查看（不同步）：

| 命令 | 說明 |
|------|------|
| `mobaxterm sync-diff` | 比較全部伺服器差異（不同步） |
| `mobaxterm sync-diff 87` | 只比較 .87 的差異 |
| `mobaxterm sync-diff-summary` | 快速摘要（僅統計） |
| `mobaxterm sync-diff-file main.cu` | 檢視特定檔案差異 |
| `mobaxterm sync-log` | 查看同步歷史記錄 |
| `mobaxterm sync-stop` | 停止所有背景同步任務 |

### 🔑 預設行為黃金規則

> **所有指令後面沒有指定伺服器 → 一律視為 all（全部伺服器）。**

```
mobaxterm push          # = push all   → .87 + .89 + .154
mobaxterm pull          # = pull all   → .87 + .89 + .154
mobaxterm fetch         # = fetch all  → .87 + .89 + .154
mobaxterm autopull      # = autopull all
mobaxterm autofetch     # = autofetch all
mobaxterm watchpull     # = watchpull all
mobaxterm watchfetch    # = watchfetch all
mobaxterm log           # = log all
mobaxterm diff          # = diff all

mobaxterm pull 87       # 僅 .87
mobaxterm pull89        # 僅 .89（快捷別名）
```

---

## 8. 背景自動上傳 (watchpush)

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm watchpush` | 啟動背景上傳 daemon（監控 .87 + .89 + .154，每 10 秒） |
| `mobaxterm watchpush 5` | 自訂每 5 秒掃描 |
| `mobaxterm watchpush status` | 查看 daemon 狀態 + PID |
| `mobaxterm watchpush log` | 最近 50 行上傳日誌 |
| `mobaxterm watchpush stop` | 停止 daemon |
| `mobaxterm watchpush clear` | 清除日誌 |

- **間隔**：10 秒（可自訂）
- **範圍**：程式碼 `.h` `.cu` `.c` `.cpp` 等
- **排除**：`*.dat` `log*` `*.plt` `a.out` `result/` `backup/`
- **日誌**：`.vscode/watchpush.log`

---

## 9. 背景自動下載 (watchpull)

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm watchpull` | 啟動背景下載 daemon（監控全部伺服器） |
| `mobaxterm watchpull .87` | 只監控 .87 |
| `mobaxterm watchpull .89` | 只監控 .89 |
| `mobaxterm watchpull .154` | 只監控 .154 |
| `mobaxterm watchpull status` | 查看 daemon 狀態 |
| `mobaxterm watchpull log` | 查看下載日誌 |
| `mobaxterm watchpull stop` | 停止 daemon |
| `mobaxterm watchpull clear` | 清除日誌 |

- **間隔**：30 秒
- **下載**：`*.dat` `*.plt` `*.bin` `*.vtk` `log*`
- **不刪**：本地任何檔案
- **日誌**：`.vscode/watchpull.log`

---

## 10. 背景完整同步 (watchfetch)

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm watchfetch` | 啟動背景完整同步 daemon（預設全部伺服器） |
| `mobaxterm watchfetch .87` | 同步 .87 |
| `mobaxterm watchfetch .89` | 同步 .89 |
| `mobaxterm watchfetch .154` | 同步 .154 |
| `mobaxterm watchfetch status` | 查看 daemon 狀態 |
| `mobaxterm watchfetch log` | 查看同步日誌 |
| `mobaxterm watchfetch stop` | 停止 daemon |

> ⚠️ **注意**：watchfetch 會刪除本地多餘檔案！

---

## 11. VTK 檔案自動重命名 (vtkrename)

```
velocity_merged_1001.vtk   → velocity_merged_001001.vtk
velocity_merged_31001.vtk  → velocity_merged_031001.vtk
velocity_merged_123456.vtk → 不變（已是 6 位數）
```

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm vtkrename` | 啟動 VTK 重命名 daemon（每 5 秒） |
| `mobaxterm vtkrename status` | 查看是否執行中 |
| `mobaxterm vtkrename log` | 查看重命名歷史 |
| `mobaxterm vtkrename stop` | 停止 daemon |

---

## 12. SSH 連線與節點操作

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm ssh 87:3` | SSH 到 .87 → ib3，進入工作目錄 |
| `mobaxterm ssh 89:0` | SSH 到 .89 直連 |
| `mobaxterm ssh 154:4` | SSH 到 .154 → ib4 |
| `mobaxterm issh` | 互動式 SSH 選擇器（終端選單 + GPU 狀態） |
| `mobaxterm jobs 87:3` | 查看 ib3 上正在執行的 a.out |
| `mobaxterm kill 87:3` | 終止 ib3 上的執行程序 |

### VS Code QuickPick 節點選擇

使用快捷鍵 `Ctrl+Alt+F`（Switch Node）或 `Ctrl+Alt+G`（Reconnect）時，VS Code 搜尋欄會彈出節點選單：

| 選項 | 說明 |
|------|------|
| .89 直連 | V100-32G × 8（最高效能） |
| .87 → ib2 | P100-16G × 8 |
| .87 → ib3 | P100-16G × 8 |
| .87 → ib5 | P100-16G × 8 |
| .87 → ib6 | V100-16G × 8 |
| .154 → ib1 | P100-16G × 8 |
| .154 → ib4 | P100-16G × 8 |
| .154 → ib7 | P100-16G × 8 |
| .154 → ib9 | P100-16G × 8 |
| 📊 先查 GPU 使用狀態再選 | 顯示全部 GPU 狀態 → 進入互動式 issh |

---

## 13. GPU 狀態查詢

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm gpus` | 所有伺服器的 GPU 使用概況（純資訊，不可選） |
| `mobaxterm gpu 87` | .87 的完整 nvidia-smi 輸出 |
| `mobaxterm gpu 89` | .89 的完整 nvidia-smi 輸出 |
| `mobaxterm gpu 154` | .154 的完整 nvidia-smi 輸出 |

---

## 14. 編譯與執行

| 命令 | 做了什麼 |
|------|----------|
| `mobaxterm run 87:3 4` | 在 .87 → ib3 上編譯 main.cu + 4 GPU 執行 |
| `mobaxterm run 89:0 8` | 在 .89 上編譯 + 8 GPU 執行 |
| `mobaxterm run 154:4 8` | 在 .154 → ib4 上 8 GPU 執行 |

### 編譯命令明細

```bash
cd /home/chenpengchung/D3Q27_PeriodicHill && \
nvcc main.cu -arch=sm_35 \
  -I/home/chenpengchung/openmpi-3.0.3/include \
  -L/home/chenpengchung/openmpi-3.0.3/lib \
  -lmpi -o a.out && \
nohup mpirun -np 4 ./a.out > log$(date +%Y%m%d) 2>&1 &
```

---

## 15. VS Code Tasks 快捷操作

開啟方式：`Terminal → Run Task...` 或快捷鍵

### 快捷鍵

| 快捷鍵 | macOS 按法 | 功能 |
|--------|-----------|------|
| `Ctrl+Alt+F` | `Ctrl+Option(⌥)+F` | 切換節點（QuickPick 搜尋欄選單） |
| `Ctrl+Alt+G` | `Ctrl+Option(⌥)+G` | 重新連線（QuickPick 搜尋欄選單） |
| `Ctrl+Shift+B` | `Cmd+Shift+B` | 編譯 + 執行（選 GPU 數量） |
| `Alt+5` | `Cmd+5` | **只編譯**（nvcc，不執行） |
| `Alt+4` | `Cmd+4` | **執行 4 顆 GPU**（nohup mpirun -np 4，輸出 log 當日日期） |
| `Alt+8` | `Cmd+8` | **執行 8 顆 GPU**（nohup mpirun -np 8，輸出 log 當日日期） |

### 跨平台通用任務

| 任務名稱 | 功能 |
|----------|------|
| SSH to cfdlab | 連線到伺服器節點 |
| Reconnect | 重新連線（QuickPick 選節點） |
| Switch Node | 切換子機（QuickPick 選節點） |
| Auto Sync (Watch) | 前景自動推送 |
| Quick Sync (Push if changed) | 有變更才推送 |
| Sync Status (Upload + Download) | 查看同步狀態 |
| Auto Upload (Start / Status / Stop) | 背景上傳管理 |
| Auto Download (Start / .87 only / .154 only / Status / Stop) | 背景下載管理 |

### Windows 專用任務

| 任務名稱 | 功能 |
|----------|------|
| SSH to cfdlab (.87) / (.154) | 指定母機連線 |
| Compile + Run (.87) / (.154) | 編譯 + 執行 |
| Check Running Jobs (.87) / (.154) | 查看執行中的作業 |
| Kill Running Job (.87) / (.154) | 終止作業 |

### Mac 專用任務

| 任務名稱 | 功能 |
|----------|------|
| [Mac] SSH 選單 (開啟時自動) | VS Code 開啟時自動彈出 QuickPick |
| [Mac] Check Environment | 檢查 ssh / rsync / sshpass 是否安裝 |
| [Mac] Compile + Run | 編譯 + 執行 |
| [Mac] Check Running Jobs | 查看執行中的作業 |
| [Mac] Kill Running Job | 終止作業 |
| [Mac] Sync Status | 同步狀態 |
| [Mac] Background Status (All) | 所有 daemon 狀態 |
| [Mac] GPU Status (All Servers) | GPU 使用概況 |
| [Mac] GPU Detail (.89) / (.87) / (.154) | 詳細 nvidia-smi |
| [Mac] Diff (Compare local vs remote) | 比對差異 |
| [Mac] Push (Upload + Delete remote extras) | 上傳 |
| [Mac] Pull (.87) / (.89) / (.154) | 從指定伺服器下載 |
| [Mac] Fetch (.87) / (.89) / (.154, Download + Delete) | 完整同步 |
| [Mac] Auto Pull (once) / Auto Push (once) / Auto Fetch (once) | 單次自動同步 |
| [Mac] Watch Pull / Watch Push | 在前景持續監控 |
| [Mac] Watch Fetch (Start / .87 / .89 / .154 only / Status / Stop) | 背景 fetch daemon |
| [Mac] Auto Download (.87 / .89 / .154 only / Start / Status / Stop) | 背景 pull daemon |
| [Mac] Auto Upload (Start / Status / Stop) | 背景 push daemon |
| [Mac] VTK Rename (Start / Status / Stop) | VTK 重命名 daemon |
| [Mac] Log (Remote) | 查看遠端 log |
| [Mac] Is Synced (Quick Check) | 一行同步狀態 |
| [Mac] Quick Sync (Push if changed) | 有變更才推 |

---

## 16. 伺服器與節點資訊

### 母機

| 母機 | IP | 可連節點 |
|------|-----|----------|
| .87 | 140.114.58.87 | ib2, ib3, ib5, ib6 |
| .89 | 140.114.58.89 | 直連（node=0，V100-32G × 8） |
| .154 | 140.114.58.154 | ib1, ib4, ib7, ib9 |

### 節點 GPU 配置

| 節點 | 母機 | SSH 代碼 | GPU | 說明 |
|------|------|----------|-----|------|
| .89 直連 | .89 | `89:0` | V100-SXM2-32GB × 8 | 最高效能 |
| ib6 | .87 | `87:6` | V100-SXM2-16GB × 8 | 高效能 |
| ib2 | .87 | `87:2` | P100-PCIE-16GB × 8 | 標準 |
| ib3 | .87 | `87:3` | P100-PCIE-16GB × 8 | 標準 |
| ib5 | .87 | `87:5` | P100-PCIE-16GB × 8 | 標準 |
| ib1 | .154 | `154:1` | P100-PCIE-16GB × 8 | 標準 |
| ib4 | .154 | `154:4` | P100-PCIE-16GB × 8 | 標準 |
| ib7 | .154 | `154:7` | P100-PCIE-16GB × 8 | 標準 |
| ib9 | .154 | `154:9` | P100-PCIE-16GB × 8 | 標準 |

- **工作目錄**：`/home/chenpengchung/D3Q27_PeriodicHill`
- **帳號**：`chenpengchung` / **密碼**：`1256`

---

## 17. 同步排除規則

### Push（上傳）排除

| 排除項 | 原因 |
|--------|------|
| `.git/*` / `.vscode/*` | 本地專用 |
| `a.out` / `*.o` / `*.exe` | 編譯產物 |
| `*.dat` / `*.DAT` / `*.plt` / `*.bin` / `*.vtk` | 模擬輸出 |
| `log*` | 執行日誌 |
| `backup/` / `result/` / `statistics/` | 輸出資料夾 |

### Pull/Fetch（下載）只包含

| 包含項 | 說明 |
|--------|------|
| `*.dat` / `*.DAT` | 數據輸出 |
| `*.plt` | Tecplot 檔案 |
| `*.bin` | 二進位備份 |
| `*.vtk` | VTK 視覺化 |
| `log*` | 執行日誌 |

---

## 18. VPN 路由自動修復 (macOS)

macOS VPN 連線後，`140.114.58.0/24` 可能不走 VPN 隧道導致 SSH timeout。  
三層防護：

| 層級 | 機制 | 說明 |
|------|------|------|
| 1. LaunchDaemon | 開機自動 | 每 5 秒檢查 + 自動修復，無感 |
| 2. 腳本內建 | 指令前自動 | 每次遠端操作前 `ensure_vpn_route` |
| 3. 手動指令 | 終端快捷 | `vpnfix` / `vpncheck` / `mobaxterm vpnfix` |

| 命令 | 說明 |
|------|------|
| `vpnfix` | (alias) 手動加入 VPN 路由 |
| `vpncheck` | (alias) 檢查目前路由走哪個介面 |
| `mobaxterm vpnfix` | 透過腳本修復路由 |

```bash
# LaunchDaemon 管理
sudo launchctl list | grep vpn                    # 查看狀態
cat /tmp/vpn-route-watcher.log                     # 查看 log
sudo launchctl bootout system/com.cfdlab.vpn-route-watcher  # 停止
```

---

## 19. Mac / Windows 完整功能對照表

### 同步指令（共 33 個命令）

| 指令 | Mac (Zsh) | Windows (PS1) | 說明 |
|------|:---------:|:-------------:|------|
| `push` | ✅ | ✅ | 上傳全部 |
| `push87` / `push89` / `push154` | ✅ | ✅ | 上傳指定 |
| `pushall` | ✅ | ✅ | = push |
| `autopush` | ✅ | ✅ | 有變更才推（全部） |
| `autopush87` / `autopush89` / `autopush154` | ✅ | ✅ | 有變更才推指定 |
| `autopushall` | ✅ | ✅ | = autopush |
| `watchpush` (+status/log/stop/clear) | ✅ | ✅ | 背景上傳 daemon |
| `pull` | ✅ | ✅ | 下載全部（預設 all） |
| `pull87` / `pull89` / `pull154` | ✅ | ✅ | 下載指定 |
| `autopull` | ✅ | ✅ | 有新才下載 |
| `autopull87` / `autopull89` / `autopull154` | ✅ | ✅ | 有新才下載指定 |
| `watchpull` (+.87/.89/.154/status/log/stop/clear) | ✅ | ✅ | 背景下載 daemon |
| `fetch` | ✅ | ✅ | 下載 + 刪本地多餘 |
| `fetch87` / `fetch89` / `fetch154` | ✅ | ✅ | 同步指定 |
| `autofetch` | ✅ | ✅ | 有差異才同步 |
| `autofetch87` / `autofetch89` / `autofetch154` | ✅ | ✅ | 有差異才同步指定 |
| `watchfetch` (+.87/.89/.154/status/log/stop/clear) | ✅ | ✅ | 背景同步 daemon |

### 狀態與比對指令

| 指令 | Mac (Zsh) | Windows (PS1) | 說明 |
|------|:---------:|:-------------:|------|
| `status` | ✅ | ✅ | 檔案數量總覽 |
| `diff` / `diff87` / `diff89` / `diff154` / `diffall` | ✅ | ✅ | 逐檔差異 |
| `add` | ✅ | ✅ | 待推送清單 |
| `issynced` | ✅ | ✅ | 一行同步狀態 |
| `log` / `log87` / `log89` / `log154` | ✅ | ✅ | 遠端 log |
| `sync` | ✅ | ✅ | 互動式同步 |
| `fullsync` | ✅ | ✅ | 完整同步 |
| `reset` / `delete` | ✅ | ✅ | 刪除遠端多餘 |
| `clone` | ✅ | ✅ | 完整複製 |
| `check` | ✅ | ✅ | 環境檢查 |
| `bgstatus` | ✅ | ✅ | 全部 daemon 狀態 |
| `syncstatus` | ✅ | ✅ | 同步 + daemon 狀態 |

### SSH 與 GPU 指令

| 指令 | Mac (Zsh) | Windows (PS1) | 說明 |
|------|:---------:|:-------------:|------|
| `ssh [server:node]` | ✅ | ✅ | SSH 連線 |
| `issh` | ✅ | ✅ | 互動式選擇器 |
| `run [server:node] [gpu]` | ✅ | ✅ | 編譯 + 執行 |
| `jobs [server:node]` | ✅ | ✅ | 查看作業 |
| `kill [server:node]` | ✅ | ✅ | 終止作業 |
| `gpus` | ✅ | ✅ | GPU 總覽 |
| `gpu [89\|87\|154]` | ✅ | ✅ | 詳細 nvidia-smi |

### 其他指令

| 指令 | Mac (Zsh) | Windows (PS1) | 說明 |
|------|:---------:|:-------------:|------|
| `vtkrename` (+status/log/stop) | ✅ | ✅ | VTK 重命名 daemon |
| `watch` | ✅ | ✅ | = watchpush |
| `vpnfix` | ✅ | — | 修復 VPN 路由（Mac only） |
| `help` | ✅ | ✅ | 顯示所有命令 |

---

## 20. 疑難排解

### Mac

| 問題 | 解決方式 |
|------|----------|
| `Missing command: rsync` | `brew install rsync` |
| `Missing command: sshpass` | `brew install hudochenkov/sshpass/sshpass` |
| SSH 連線失敗 | 確認在校內網路；測試 `ssh chenpengchung@140.114.58.87` |
| VPN 連上但 SSH timeout | 執行 `vpnfix` 或 `mobaxterm vpnfix` |
| `mobaxterm` 找不到 | `source ~/.profile` 或重啟終端 |
| daemon 卡住 | `mobaxterm watchpush stop && mobaxterm watchpull stop` |

### Windows

| 問題 | 解決方式 |
|------|----------|
| `plink.exe` 找不到 | 確認 PuTTY 安裝在 `C:\Program Files\PuTTY\` |
| `mobaxterm` 找不到 | `. $PROFILE` 或重啟 PowerShell |
| SSH timeout | 確認校內網路或 VPN |

### 通用

| 命令 | 用途 |
|------|------|
| `mobaxterm check` | 檢查本地工具 + 遠端連線 |
| `mobaxterm bgstatus` | 查看所有背景 daemon |
| `mobaxterm syncstatus` | 同步狀態 + daemon 狀態 |

---

## 快速參考卡

```
┌─────────────────── 日常工作流程 ───────────────────┐
│                                                      │
│  改程式碼 → mobaxterm push      (上傳全部伺服器)    │
│  看結果  → mobaxterm pull      (下載全部伺服器)    │
│  看 .89  → mobaxterm pull89    (只下載 .89 結果)   │
│  查狀態  → mobaxterm issynced  (一行看同步狀態)     │
│  查差異  → mobaxterm diff      (逐檔比對)           │
│                                                      │
│  ──── 背景自動化 ────                               │
│  mobaxterm watchpush           (自動上傳程式碼)     │
│  mobaxterm watchpull           (自動下載全部結果)   │
│  mobaxterm watchpull .89       (只自動下載 .89)     │
│  mobaxterm watchfetch .89      (自動同步 .89)       │
│  mobaxterm bgstatus            (查看全部 daemon)    │
│                                                      │
│  ──── SSH 操作 ────                                  │
│  mobaxterm ssh 89:0            (連線到 .89)          │
│  mobaxterm ssh 87:3            (連線到 .87→ib3)     │
│  mobaxterm run 89:0 8          (在 .89 用 8 GPU)    │
│  mobaxterm gpus                (GPU 狀態總覽)       │
│  Ctrl+Alt+F                   (VS Code QuickPick)   │
│                                                      │
│  ──── VPN 路由 (Mac) ────                            │
│  vpnfix                        (修復 VPN 路由)      │
│                                                      │
└──────────────────────────────────────────────────────┘
```

---

## 腳本檔案對照

| 檔案名稱 | 用途 |
|----------|------|
| `Zsh_mainsystem.sh` | Mac 主腳本（所有指令） |
| `Pwshell_mainsystem.ps1` | Windows 主腳本（所有指令） |
| `Pwshell_GPUconnect.ps1` | SSH 互動式連線器（跨平台） |
| `Pwshell_bg_watchpush.ps1` | 背景上傳 daemon |
| `Pwshell_bg_watchpull.ps1` | 背景下載 daemon |
| `Pwshell_bg_watchfetch.ps1` | 背景同步 daemon |
| `Zsh_bg_renamer.ps1` | VTK 重命名 daemon |
| `Zsh_turnmoba.sh` | Mac 別名安裝 |
| `Pwshell_turnmoba.ps1` | Windows 別名安裝 |
| `Zsh_checktroute.sh` | VPN 路由監控（Mac only） |
| `c_language.json` | C/C++ 編譯器設定 |
| `tasks.json` | VS Code 任務定義 |
