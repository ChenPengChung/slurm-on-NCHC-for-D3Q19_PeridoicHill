# GILBM Periodic Hill — 多 Case 管理指南

## 快速總結：跑新 Case 只需改 2 個檔案

| # | 檔案 | 要改的位置 | 說明 |
|---|------|-----------|------|
| 1 | `jobscript_chain.slurm` | Line 2: `--job-name=` | 改成唯一的 case 名稱，用來區分 SLURM queue 中的 job |
| 2 | `variables.h` | Line 135: `Re` / Line 136: `Uref` | 改 Reynolds number 和對應的參考速度 |

> **不需要改** `build_and_submit.sh` — 它會自動從 `jobscript_chain.slurm` 讀取 job name。

---

## 完整步驟（以 Re1400 為例）

### Step 1：複製整個資料夾

```bash
cp -r 1.Re700_129x257x129  2.Re1400_129x257x129
cd 2.Re1400_129x257x129
```

### Step 2：改 Job Name（`jobscript_chain.slurm`）

```diff
- #SBATCH --job-name=1.Re700_129x257x129
+ #SBATCH --job-name=2.Re1400_129x257x129
```

同時更新 Line 17 的註解（非必要，但建議）：

```diff
- # jobscript_chain.slurm — 1.Re700_129x257x129 自動續鏈 jobscript
+ # jobscript_chain.slurm — 2.Re1400_129x257x129 自動續鏈 jobscript
```

### Step 3：改物理參數（`variables.h`）

```diff
- #define     Re      700
+ #define     Re      1400

- #define     Uref    0.015
+ #define     Uref    0.0776
```

**Uref 對照表**（來自 `variables.h` Line 137-138 的註解）：

| Re | Uref | 備註 |
|----|------|------|
| 700 | 0.015 | — |
| 1400 | 0.0776 | — |
| 2800 | 0.0776 | 與 Re1400 相同 |
| 5600 | 0.0464 | — |
| 10595 | 0.0878 | — |

> 限制：`Uref <= cs = 0.1732`（Ma < 1）

### Step 4：清除舊 chain state & 提交

```bash
# 清除複製過來的舊 checkpoint 和 chain state
rm -rf checkpoint/ .chain_jobid .chain_count STOP_CHAIN chain.log slurm_*.log slurm_*.err

# 編譯 + 提交
bash build_and_submit.sh
```

### Step 5：確認兩個 case 並行

```bash
squeue -u $USER
```

預期輸出：

```
JOBID  NAME                    STATE
19408  GILBM_PH                RUNNING    ← 舊 case
19500  2.Re1400_129x257x129    RUNNING    ← 新 case
```

**名字不同 → 安全防護不會互擋。**

---

## 為什麼不會衝突？

### 1. Safety Guard 只擋同名 job

`build_and_submit.sh` (Line 78-85) 的防禦邏輯：

```bash
JOB_NAME=$(awk ... jobscript_chain.slurm)        # 從 slurm 抓 job name
squeue -u "$USER" ... | grep "${JOB_NAME}"        # 只找同名 job
```

不同 `--job-name` → `grep` 找不到 → 不觸發防護。

### 2. Checkpoint 是相對路徑

每個 case 的 checkpoint 寫在自己的資料夾內：

```
1.Re700_129x257x129/checkpoint/step_1000/
2.Re1400_129x257x129/checkpoint/step_1000/    ← 獨立, 不互相覆蓋
```

---

## 進階：如果也要改網格

除了上述 2 個檔案外，還需額外修改 `variables.h` 的網格設定：

```c
// §3. 網格設定
#define     NX      129     // 展向格點
#define     NY      257     // 流向格點 (需 (NY-1)%jp==0)
#define     NZ      129     // 法向格點
#define     jp      8       // GPU 數量
```

以及可能需要更換網格檔案：

```c
// 外部網格
#define     GRID_DAT_DIR    "J_Frohlich"
#define     GRID_DAT_REF    "3.fine grid.dat"    // 可改成 "2.medium grid.dat"
```

可用的網格檔：

| 檔案 | 說明 |
|------|------|
| `J_Frohlich/3.fine grid.dat` | 細網格（目前使用） |
| `J_Frohlich/2.medium grid.dat` | 中等網格 |
| `J_Frohlich/adaptive_3.fine grid_I129_J65_a0.5.dat` | 自適應細網格 |

**注意**：改 NY 後必須確保 `(NY-1) % jp == 0`，否則編譯會報錯。

---

## 檔案修改速查表

| 場景 | `jobscript_chain.slurm` | `variables.h` Re/Uref | `variables.h` NX/NY/NZ | 網格 .dat |
|------|:-:|:-:|:-:|:-:|
| 同網格、不同 Re | V | V | — | — |
| 不同網格、同 Re | V | — | V | V |
| 不同網格、不同 Re | V | V | V | V |

V = 需要修改, — = 不需要修改

> **每個 case 一定要改 job name**，這是避免 checkpoint 污染的關鍵。
