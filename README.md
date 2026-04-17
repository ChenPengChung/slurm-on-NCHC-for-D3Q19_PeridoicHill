# D3Q19 Periodic Hill — NCHC SLURM 自動續鏈模擬 (GB200 vs H200)

本專案在 **NCHC (國網中心)** 上使用 **GILBM (Generalized Interpolation LBM)** 求解 D3Q19 Periodic Hill 流場，
分別針對 **GB200** 和 **H200** 兩種 GPU 節點提供對應的編譯 / 提交腳本。

---

## 目錄結構

```
slurm/
├── README.md                  ← 本文件
├── GB200/                     ← NVIDIA GB200 (ARM aarch64) 專用
│   ├── build_and_submit.sh
│   ├── jobscript_chain.slurm
│   ├── main.cu
│   ├── variables.h
│   ├── ...                    ← 其餘 .h / .cu 原始碼 (兩資料夾共用相同邏輯)
│   ├── gilbm/                 ← GILBM 核心演算法
│   ├── animation/             ← 動畫產生工具
│   ├── J_Frohlich/            ← Periodic Hill 基準網格資料
│   └── result/                ← 後處理 & benchmark 比較
└── H200/                      ← NVIDIA H200 (x86_64) 專用
    ├── build_and_submit.sh
    ├── jobscript_chain.slurm
    ├── main.cu
    ├── variables.h
    ├── README.md              ← 多 Case 管理指南
    └── ...                    ← 結構同 GB200
```

---

## GB200 vs H200 關鍵差異

### 1. 硬體架構

| 項目 | GB200 | H200 |
|------|-------|------|
| **CPU 架構** | ARM aarch64 (Grace Neoverse-V2) | x86_64 |
| **GPU** | NVIDIA GB200 | NVIDIA H200 |
| **CUDA Compute Capability** | `sm_100` | `sm_90` |

### 2. `jobscript_chain.slurm` 差異

| 設定 | GB200 | H200 |
|------|-------|------|
| `--job-name` | `GILBM_PH` | `1.Re700_129x257x129` |
| `--partition` | `gb200-dev` | `dev` |
| `--nodes` | **2** | **1** |
| `--ntasks-per-node` | **4** | **8** |
| `--gres=gpu` | **4** (每節點 4 GPU) | **8** (單節點 8 GPU) |
| `--time` | **2:00:00** (2 小時) | **1:00:00** (1 小時) |
| `TIMEOUT` (timeout 備援) | **7140s** | **3540s** |
| `mpirun --map-by` | `ppr:4:node` | `ppr:8:node` |
| **SDK 路徑前綴** | `Linux_aarch64` | `Linux_x86_64` |
| **CUDA_HOME** | `/usr/local/cuda-13.0` | `/opt/nvidia/hpc_sdk/Linux_x86_64/25.9/cuda/13.0` |
| **MATH_LIBS target** | `sbsa-linux` | `x86_64-linux` |

> **總 GPU 數相同**：GB200 = 2 nodes × 4 GPU = 8；H200 = 1 node × 8 GPU = 8。

### 3. `build_and_submit.sh` 差異

| 項目 | GB200 | H200 |
|------|-------|------|
| **編譯方式** | 透過 `salloc` + `srun` 在 GB200 compute node 上交叉編譯 (因登入節點是 x86_64，但 GB200 是 aarch64) | 直接在登入節點編譯 (同為 x86_64) |
| **CUDA arch** | `-arch=sm_100` | `-arch=sm_90` |
| **SDK 路徑** | `Linux_aarch64/...` | `Linux_x86_64/...` |
| **編譯目標** | aarch64 binary | x86_64 binary |

**GB200 特殊之處**：登入節點 (x86_64) 無法直接編譯 aarch64 binary，
必須申請一個 GB200 節點 (`salloc -p gb200-dev`) 來執行 `nvcc`，這是此版本最大的架構差異。

### 4. `variables.h` 差異

| 參數 | GB200 | H200 |
|------|-------|------|
| `Re` | 10595 | 700 |

> 其餘物理 / 網格參數相同。Re 值可依需求自行調整（參見 H200/README.md 的多 Case 指南）。

---

## 快速使用

### GB200 節點

```bash
cd GB200/
bash build_and_submit.sh          # salloc 編譯 (aarch64) + sbatch 提交
```

### H200 節點

```bash
cd H200/
bash build_and_submit.sh          # 本機編譯 (x86_64) + sbatch 提交
```

### 常用指令

```bash
# 查看 queue
squeue -u $USER

# 手動停鏈 (當前 round 跑完後不再續投)
touch STOP_CHAIN

# 續跑已有的 chain (不清理 chain state)
bash build_and_submit.sh --no-clean

# 只編譯，不提交
bash build_and_submit.sh --build-only
```

---

## Chain 機制簡介

兩個版本共用相同的自動續鏈邏輯：

1. **Round 1** → `./a.out --cold` (冷啟動)
2. **Round ≥ 2** → `./a.out --restart=checkpoint/step_<latest>` (從最新有效 checkpoint 續算)
3. **Exit code 語意**：
   - `0` = 自然停止 (converged / diverged / FTT_STOP / STOP_CHAIN) → **停鏈**
   - `124` = SIGUSR1 walltime 救援 → **續鏈**
   - 其他非 0 = crash / node failure → **續鏈**
4. **Safety Guard**：`build_and_submit.sh` 會檢查 queue 中是否已有同名 job，防止兩個 chain 同時寫 checkpoint 造成 metadata 污染。

---

## 參考

- Periodic Hill benchmark: [Breuer et al. (2009)](result/benchmark/)
- Experiment: [Rapp & Manhart (2011)](result/benchmark/Experiment%20(Rapp%20%26%20Manhart%202011)/)
- 多 Case 管理指南: [H200/README.md](H200/README.md)
