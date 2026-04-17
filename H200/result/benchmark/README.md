# ERCOFTAC UFR 3-30: Periodic Hill Benchmark Data

## 三大 Benchmark 資料來源

### 1. LESOCC (Breuer) — 曲線坐標 DNS/LES
- **作者**: Breuer, M., Helmut-Schmidt-Universität Hamburg
- **方法**: 曲線體貼合網格 (body-fitted curvilinear), colocated, FVM
- **可用 Re**: 700 (DNS), 1400 (DNS), 2800 (DNS), 5600 (DNS/LES), 10595 (LES)
- **目錄**: `LESOCC (Breuer et al. 2009)/Re{Re}/UFR3-30_C_{Re}_data_MB-{001-010}.dat`
- **DOI**: https://doi.org/10.1016/j.compfluid.2008.05.002

### 2. MGLET (Manhart/Peller) — 直角坐標 DNS/LES
- **作者**: Peller, N., Manhart, M., TU München
- **方法**: 直角非均勻網格 (Cartesian), staggered, IBM, FVM
- **可用 Re**: 1400 (DNS), 2808 (DNS), 5600 (DNS), 10595 (LES), 37000 (LES)
- **目錄**: `MGLET (Breuer et al. 2009)/Re{Re}/UFR3-30_data-NP-*.dat`
- **DOI**: https://doi.org/10.1016/j.compfluid.2008.05.002

### 3. Experiment (Rapp) — PIV/LDA 實驗
- **作者**: Rapp, Ch., Manhart, M., TU München
- **方法**: 2D-PIV (場量測) + 1D-LDA (點量測), 水槽實驗
- **可用 Re**: 5600, 10600, 19000, 37000
- **目錄**: `Experiment (Rapp & Manhart 2011)/Re{Re}/UFR3-30_X_{Re}_data_CR-{001-010}.dat`
- **DOI**: https://doi.org/10.1007/s00348-011-1045-y

### 資料來源
- ERCOFTAC Wiki: https://kbwiki.ercoftac.org/w/index.php?title=UFR_3-30_Test_Case
- Breuer et al. (2009), *Comp. & Fluids* 38, 433-457

## 目錄結構
```
benchmark/
├── LESOCC (Breuer et al. 2009)/     # 曲線坐標 DNS/LES
│   ├── Re700/        # 10 files  ← 我們的主要 benchmark (DNS)
│   ├── Re1400/       # 10 files
│   ├── Re2800/       # 10 files
│   ├── Re5600/       # 10 files
│   ├── Re10595/      # 10 files
│   └── REFERENCE.txt
├── MGLET (Breuer et al. 2009)/       # 直角坐標 DNS/LES (IBM)
│   ├── Re1400/       # 11 files
│   ├── Re2808/       # 11 files
│   ├── Re5600/       # 11 files
│   ├── Re10595/      # 10 files
│   ├── Re37000/      # 10 files
│   └── REFERENCE.txt
├── Experiment (Rapp & Manhart 2011)/ # PIV/LDA 實驗
│   ├── Re5600/       # 10 files
│   ├── Re10600/      # 10 files
│   ├── Re19000/      # 10 files
│   ├── Re37000/      # 10 files
│   └── REFERENCE.txt
├── ATAAC_Report_Jakirlic_RANS_HybridLES.pdf  # ATAAC 計畫報告 (RANS/Hybrid)
└── README.md
```

## CFD 資料格式 (LESOCC, 7 欄, 空格分隔, `#` 註解)
```
# y/h   U/Ub   V/Ub   <u'u'>/Ub²   <v'v'>/Ub²   <u'v'>/Ub²   k/Ub²
```

## CFD 資料格式 (MGLET, 7 欄, 空格分隔, 無註解)
```
  y/h   U/Ub   V/Ub   <u'u'>/Ub²   <v'v'>/Ub²   <u'v'>/Ub²   k/Ub²
```
(固定寬度格式, 無 header, 直接從數據開始)

Note: MGLET Re=1400/2808/5600 有 11 個站位 (多一站), Re=10595/37000 有 10 站

- ERCOFTAC u = streamwise, v = wall-normal (NOT spanwise!)
- 所有 RS 為 fluctuation form: $\langle u'_i u'_j \rangle / U_b^2$

## 實驗資料格式 (Rapp, **6 欄**, **逗號分隔**, `#` 註解)
```
# y/h, u/u_b, v/u_b, u'u'/u_b^2, v'v'/u_b^2, u'v'/u_b^2
```
(無 TKE k 欄，因為 2D PIV 只量測兩個分量)

## VTK ↔ ERCOFTAC 座標映射
| ERCOFTAC | 意義 | VTK scalar |
|---|---|---|
| col 2: U/Ub | 流向速度 | `U_mean` |
| col 3: V/Ub | 法向速度 | `W_mean` (NOT V_mean) |
| col 4: uu | 流向 RS | `uu_RS` |
| col 5: vv | 法向 RS | `ww_RS` (NOT vv_RS) |
| col 6: uv | 剪切 RS | `uw_RS` (NOT uv_RS) |
| col 7: k  | TKE | `k_TKE` |

## x/h 站位對照
| x/h | File # | 說明 |
|-----|--------|------|
| 0.05 | 001 | 分離點附近 (hill crest) |
| 0.5  | 002 | 山丘背風面 |
| 1.0  | 003 | 回流區起始 |
| 2.0  | 004 | 回流區中段 |
| 3.0  | 005 | 回流區中段 |
| 4.0  | 006 | 接近再附著點 |
| 5.0  | 007 | 再附著後恢復區 |
| 6.0  | 008 | 恢復區 |
| 7.0  | 009 | 接近下一個山丘 |
| 8.0  | 010 | 山丘迎風面 |
