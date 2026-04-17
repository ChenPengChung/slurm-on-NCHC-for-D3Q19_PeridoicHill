---
name: gilbm-restart
description: >
  Comprehensive reference for the GILBM Periodic Hill solver's checkpoint / restart
  subsystem, covering the per-rank binary checkpoint format, statistics continuation
  (33 accumulators + accu_count + Force + CV ring buffer + FTT-gate), and the ordered
  upgrade plan (G1-G7) that turns the current design into a fully autonomous, crash-safe,
  chain-resubmitting pipeline on shared HPC clusters (NCHC H200, Slurm). Trigger on any
  mention of: 續跑, restart, checkpoint, resume, SaveBinaryCheckpoint, LoadBinaryCheckpoint,
  INIT=1/2/3, RESTART_BIN_DIR, RESTART_VTK_FILE, accu_count, FTT-gate, CV buffer,
  sentinel file, SIGUSR1, atomic checkpoint, chain job, afterany dependency,
  STOP_NAN / STOP_DONE / STOP_USER, checkpoint/latest, rolling checkpoint, or any
  question about how to preserve simulation state across Slurm job boundaries.
---

# GILBM Periodic Hill — Checkpoint / Restart Architecture & Upgrade Plan

> **Scope**: this skill defines the authoritative design for the restart subsystem
> of the GILBM Periodic Hill solver (Edit11). It documents (A) the current
> implementation, (B) its correctness properties, (C) its seven engineering
> weaknesses, and (D) the ordered seven-step upgrade plan **G1 → G7** that makes
> the pipeline fully autonomous under Slurm on NCHC H200.
>
> Follow the ordering strictly. Each step is independently verifiable and must
> be validated before moving to the next.

---

## 0. Quick Map: Where Restart Lives in the Codebase

| Concern | File | Symbols / Lines |
|---|---|---|
| Config constants | `variables.h` | `INIT`, `RESTART_VTK_FILE`, `RESTART_BIN_DIR`, `TBINIT`, `NDTBIN`, `FTT_STATS_START` |
| Per-rank bin writer | `fileIO.h:70-80` | `result_writebin_to` |
| Per-rank bin reader | `fileIO.h:83-96` | `result_readbin` |
| Full checkpoint save | `fileIO.h:203-335` | `SaveBinaryCheckpoint(int step)` |
| Full checkpoint load | `fileIO.h:341-582` | `LoadBinaryCheckpoint(const char*)` |
| VTK restart (INIT=2) | `fileIO.h:944+` | `InitFromMergedVTK(...)` |
| Startup dispatch | `main.cu:508-534` | `INIT==2` / `INIT==3` branches |
| Statistics restore | `main.cu:746-795` | tavg restore, FTT-gate |
| Anti-windup Force cap | `main.cu:527-534` | binary restart guard |
| Periodic bin output | `main.cu:1551-1553` | `SaveBinaryCheckpoint(step)` every `NDTBIN` |
| Final exit save | `main.cu:1644-1657` | always writes one final checkpoint |
| NaN watcher | `nan_monitor.py` | scans VTK/log, should also write `STOP_NAN` |
| Compile+submit driver | `run_v2.sh` | nvcc + sbatch + nohup nan_monitor |
| Slurm jobscript | `jobscript_v3.slurm` | 1-node 8-GPU dev partition |

---

## 1. Current Architecture — The Facts

### 1.1 Storage layout (per-rank, NOT merged)

Each rank writes its own subdomain into the **same folder**. There is no MPI
gather. A single checkpoint looks like:

```
checkpoint/
└── step_2700001/
    ├── f00_0.bin  f00_1.bin ... f00_7.bin          (19 directions × 8 ranks = 152)
    ├── f01_0.bin  ...
    ├── ...
    ├── f18_7.bin
    ├── rho_0.bin  ... rho_7.bin                    (8)
    ├── sum_u_0.bin ... sum_u_7.bin                 (stats, 33 × 8 = 264, only if TBSWITCH && accu_count>0)
    ├── sum_v_* sum_w_*                             (1st moments)
    ├── sum_uu_* ... sum_ww_*                       (2nd moments, 6)
    ├── sum_uuu_* ... sum_www_*                     (3rd moments, 10)
    ├── sum_P_* sum_PP_* sum_Pu_* sum_Pv_* sum_Pw_* (pressure, 5)
    ├── sum_dudx2_* ... sum_dwdz2_*                 (gradient², 9)
    ├── cv_uu_history.bin                           (CV ring, rank 0 only)
    ├── cv_k_history.bin                            (CV ring, rank 0 only)
    ├── cv_ftt_history.bin                          (CV ring, rank 0 only)
    └── metadata.dat                                (rank 0 only)
```

Per-rank buffer size (for current Periodic Hill grid, `NX6×NYD6×NZ6 = 199×23×71 = 325k` doubles):
- Each `.bin` ≈ 2.6 MB
- Per checkpoint ≈ `(19 f + 1 rho + 33 stats) × 8 ranks × 2.6 MB` = **~445 MB per checkpoint**
- `cv_*_history.bin` is tiny (≤ few KB)

### 1.2 `metadata.dat` schema (rank 0 only)

```
step=2700001
FTT=156.7382...
accu_count=21450
Force=1.234567e-03
dt_global=8.765432e-04
gpu_time_ms=1234567.890
cv_count=480
```

All lines are ASCII key=value. The loader tolerates extra lines and supports
backward-compat keys (`vel_avg_count=`, `rey_avg_count=`).

### 1.3 Three restart modes (`variables.h:237`)

| `INIT` | Source | Precision | When to use |
|---|---|---|---|
| `0` | Cold start, zero velocity + rho=1 + 2× Poiseuille Force | N/A | First run |
| `1` | Legacy per-rank bin from `./result/` (flat, no subfolder) | Full f | Old workflow, do not use |
| `2` | Merged VTK (single file `velocity_merged_*.vtk`) | **f ≈ f^eq**, lossy | Visual → restart bridge |
| `3` | New binary checkpoint (`RESTART_BIN_DIR=checkpoint/step_X`) | **Full f + 33 stats** | Production |

**Canonical path**: always use `INIT=3` for unattended continuation. `INIT=2`
exists only when you have a VTK but no binary (which should never happen in a
normal pipeline).

### 1.4 What is preserved across restart (INIT=3)

| Category | Quantity | Stored as | Continuation math |
|---|---|---|---|
| Distribution f | 19 × NX6·NYD6·NZ6 | 19 `.bin`/rank | **bit-exact**, includes f^neq |
| Density | ρ | 1 `.bin`/rank | bit-exact |
| 1st moments | ⟨u⟩, ⟨v⟩, ⟨w⟩ accumulators | `sum_u`, `sum_v`, `sum_w` | `avg = sum / accu_count` |
| 2nd moments | 6 Reynolds stresses | `sum_uu ... sum_ww` | raw sum, divide at output time |
| 3rd moments | 10 triple correlations | `sum_uuu ... sum_www` | raw sum |
| Pressure statistics | ⟨p⟩, ⟨p²⟩, ⟨pu⟩, ⟨pv⟩, ⟨pw⟩ | `sum_P ... sum_Pw` | raw sum |
| Gradient-squared | 9 components | `sum_dudx2 ... sum_dwdz2` | raw sum, for dissipation |
| External driving force | `Force_h[0]` | metadata scalar | restored directly (with anti-windup cap) |
| Time step size | `dt_global` | metadata scalar | restored, reconciled with Jacobian |
| Convergence CV buffer | `uu_history`, `k_history`, `ftt_cv_history` | 3 bin (rank 0) | ring replay → immediate CV |
| Wallclock counter | `g_restored_gpu_ms` | metadata `gpu_time_ms=` | monotonic timer continuity |
| FTT-gate decision | `accu_count` vs `FTT_STATS_START` | computed in main.cu:784-795 | discard early-transient stats |

### 1.5 Why per-rank is the right choice (do not refactor to merged)

Three reasons merged-single-file looks attractive but is a trap:

1. **I/O parallelism**. Each rank writes ~85 MB independently to the parallel
   filesystem. A merged file requires either MPI gather (rank 0 OOM — 8 ranks ×
   85 MB × 34 fields ≈ 23 GB on one node) or MPI-IO collective writes (adds
   header design complexity and filesystem-dependent performance).
2. **Rank count stability**. The GILBM solver uses a fixed `jp=8` domain
   partition along ξ; there is no scenario where restart would use a different
   rank count. Per-rank matches the fixed decomposition exactly.
3. **Failure atomicity**. 424 small files are easier to rolling-back than one
   1.6 GB file with corrupted tail (see G1 below).

**Rule**: per-rank binary + shared folder is the design. All upgrades assume it.

---

## 2. Correctness Properties (What Already Works)

Before upgrading, know what is **already correct** and must not be broken:

- **P1. f^neq preservation**. The full 19-direction f is stored, not just
  moments. Collision operator reconstructs f^neq exactly on restart → no spurious
  transient on step `restart_step + 1`.
- **P2. Statistics as raw sums**. `sum_*` arrays store cumulative, unnormalized
  sums. `accu_count` is the divisor at output time. Restart adds to `sum_*` with
  the same `accu_count` increment semantics → no averaging error.
- **P3. Force controller state**. The PID/Gehrke controller in the Force loop
  reads `Force_h[0]` on restart, with anti-windup cap at `FORCE_CAP_MULT ×
  F_Poiseuille` to prevent controller runaway if the checkpoint was captured
  during a spike.
- **P4. FTT-gate**. If `FTT_restart < FTT_STATS_START`, all 33 statistics
  accumulators are zeroed and `accu_count = 0`. This prevents pre-turbulence
  transient from polluting the final time-average.
- **P5. CV ring buffer continuity**. Convergence metrics (uu, k, at monitor
  plane) are restored from the ring buffer so the "is this run converged?"
  monitor does not need `CV_WINDOW_FTT` (often ≥ 20 FTT) to refill.
- **P6. Schema version tolerance**. Load path accepts old names (`f0` vs `f00`,
  `RS_UU` vs `sum_uu`, `vel_avg_count=` vs `accu_count=`). Pre-existing
  checkpoints from older versions still load.
- **P7. u, v, w recomputation**. The loader does NOT read `u_*.bin`; it
  recomputes moments from f on restart (`mx = Σ e_q · f_q`). This avoids
  storage bloat and prevents f/u desync if f is restored but u came from a
  different checkpoint.

These seven properties are load-bearing. Every upgrade below must leave them
intact — add regression tests (§5) to verify.

---

## 3. The Seven Engineering Weaknesses (Why Autonomous Restart Fails Today)

| # | Weakness | Failure mode under Slurm preemption / timeout |
|---|---|---|
| W1 | Non-atomic write | Node killed mid-`SaveBinaryCheckpoint` → `step_X/` has partial .bin files → next run's `LoadBinaryCheckpoint` tries to read, `result_readbin` hits EOF, `MPI_Abort`. The previous intact checkpoint `step_X-NDTBIN/` is never tried. |
| W2 | Hard-coded `RESTART_BIN_DIR` | `variables.h` is a `#define` compiled in. After each save, you must manually edit the string, `bash run_v2.sh` to rebuild, re-submit. No automation possible. |
| W3 | No final checkpoint on Slurm timeout | `#SBATCH --time=1:00:00` expires → SIGKILL to mpirun → process dies between two `NDTBIN` marks → up to `NDTBIN × dt_per_iter` of work lost. For `NDTBIN=100000` at 6 ms/iter, that's 10 minutes wasted. |
| W4 | No chain-submit logic | Job ends (success, crash, preempt, timeout — all look the same at Slurm level). Nothing resubmits. User must manually notice and `sbatch` again. |
| W5 | No "why did it end?" signal | When job died, was it a NaN (bad — investigate), a crash (retry), a timeout (retry), or "user wanted it stopped" (don't retry)? No way to tell from outside. |
| W6 | Unbounded rolling | No rolling purge. After 10 checkpoints, disk has `10 × 445 MB = 4.45 GB`. On long runs this fills quota. |
| W7 | No schema version field | `metadata.dat` has no `checkpoint_version`. Future schema changes will either silently corrupt loads or require branching logic. |

---

## 4. The Upgrade Plan — Ordered G1 → G7

**Implementation order matters**. Each step is a prerequisite for the next.
Do not skip ahead. Each step ends with an explicit pass criterion.

### G1 — Atomic Write with `.WRITING` staging

**Target**: fix W1. A mid-write crash leaves the previous checkpoint intact.

**Changes**:

1. `fileIO.h` — modify `SaveBinaryCheckpoint(int step)`:

```cpp
void SaveBinaryCheckpoint(int ckpt_step) {
    ostringstream dir_oss, tmp_oss;
    dir_oss << "checkpoint/step_" << ckpt_step;
    tmp_oss << "checkpoint/step_" << ckpt_step << ".WRITING";
    string final_dir = dir_oss.str();
    string tmp_dir   = tmp_oss.str();

    if (myid == 0) {
        ExistOrCreateDir("checkpoint");
        // If a stale .WRITING exists (previous crash), remove it first
        string rm_cmd = "rm -rf " + tmp_dir;
        system(rm_cmd.c_str());
        ExistOrCreateDir(tmp_dir.c_str());
    }
    MPI_Barrier(MPI_COMM_WORLD);

    // ... all result_writebin_to calls now use tmp_dir.c_str() instead of dir_name.c_str()

    MPI_Barrier(MPI_COMM_WORLD);
    if (myid == 0) {
        // Atomic commit: rename .WRITING → final name
        // POSIX rename is atomic on the same filesystem
        int rc = rename(tmp_dir.c_str(), final_dir.c_str());
        if (rc != 0) {
            perror("rename checkpoint");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    }
    MPI_Barrier(MPI_COMM_WORLD);
}
```

2. `LoadBinaryCheckpoint` — add guard: reject `.WRITING` paths. If a stale
   `.WRITING` dir exists at load time, warn and delete it before proceeding.

**Pass criterion**: manually kill the program during a save (use `sleep` to
widen the window). Verify: (a) `step_X.WRITING/` exists but `step_X/` does not,
(b) next restart ignores `.WRITING` and loads the last complete `step_X/`.

---

### G2 — `checkpoint/latest` symlink + runtime auto-detect

**Target**: fix W2. Eliminate compile-time `RESTART_BIN_DIR`. Enable zero-config
chain submission.

**Changes**:

1. After the `rename` in G1, rank 0 updates the symlink:

```cpp
if (myid == 0) {
    // rename already done above; now point "latest" at it
    string link_path = "checkpoint/latest";
    unlink(link_path.c_str());  // ignore ENOENT
    // Relative target so the link works regardless of absolute pwd
    ostringstream target;
    target << "step_" << ckpt_step;
    if (symlink(target.str().c_str(), link_path.c_str()) != 0) {
        perror("symlink latest");
        // non-fatal: log and continue
    }
}
```

2. `main.cu` — add startup auto-detect BEFORE the existing `INIT` dispatch:

```cpp
int actual_init = INIT;
if (actual_init == 0) {
    // Cold-start configured, but if a checkpoint exists, auto-switch to INIT=3
    struct stat st;
    if (stat("checkpoint/latest/metadata.dat", &st) == 0) {
        actual_init = 3;
        if (myid == 0)
            printf("[AUTO-RESTART] Found checkpoint/latest → switching INIT=0 to INIT=3\n");
    }
}
// Then use actual_init everywhere INIT was checked
if (actual_init == 3) LoadBinaryCheckpoint("checkpoint/latest");
else if (actual_init == 2) InitFromMergedVTK(RESTART_VTK_FILE);
// ...
```

**Do not** touch the `#define INIT` constant. It remains the user's manual
override for cold re-init (e.g. deliberately wiping statistics by deleting
`checkpoint/latest`).

**Pass criterion**: compile with `INIT=0`, run, save one checkpoint, `scancel`,
`sbatch` again — program prints `[AUTO-RESTART]` and resumes from `latest`.

---

### G3 — SIGUSR1 emergency checkpoint

**Target**: fix W3. On Slurm timeout, write one last checkpoint before the job
dies.

**Changes**:

1. `jobscript_v3.slurm`:

```bash
#SBATCH --signal=B:USR1@120      # Send SIGUSR1 120s before timeout
#SBATCH --open-mode=append        # Don't clobber log on restart
```

2. `main.cu` top level:

```cpp
#include <signal.h>
volatile sig_atomic_t g_emergency_ckpt = 0;
static void sigusr1_handler(int) { g_emergency_ckpt = 1; }
// In main(), right after MPI_Init:
signal(SIGUSR1, sigusr1_handler);
```

3. In the main time loop (same place as `NDTBIN` check):

```cpp
if (g_emergency_ckpt) {
    if (myid == 0)
        printf("[SIGUSR1] Emergency checkpoint at step=%d (timeout imminent)\n", step);
    // Drain GPU buffers so checkpoint is consistent
    cudaDeviceSynchronize();
    SendDataToCPU();           // whatever the project's D2H function is
    SaveBinaryCheckpoint(step);
    MPI_Barrier(MPI_COMM_WORLD);
    if (myid == 0) {
        FILE* fp = fopen("CHECKPOINT_LAST_REASON", "w");
        fprintf(fp, "SIGUSR1 at step=%d\n", step);
        fclose(fp);
    }
    MPI_Finalize();
    exit(0);  // clean exit, Slurm sees exit code 0
}
```

**Pass criterion**: submit with `--time=0:03:00` and `NDTBIN=1000000`
(so no scheduled checkpoint would fire). After ~1 min Slurm sends SIGUSR1.
Log shows `[SIGUSR1] Emergency checkpoint` and `checkpoint/latest` is updated.

**Pitfall**: do NOT call `SaveBinaryCheckpoint` from the signal handler itself
(non-async-signal-safe). Only set a flag. Handle the flag in the main loop
between iterations.

---

### G4 — Sentinel files + chain-submit logic

**Target**: fix W4 and W5. Distinguish crash/preempt/done/NaN/user-stop. Chain
only when appropriate.

**Sentinel file contract**:

| File | Who writes it | Meaning | Resubmit? |
|---|---|---|---|
| `STOP_DONE` | main.cu on reaching `step == NSTEP` | Simulation complete | No |
| `STOP_NAN` | `nan_monitor.py` | NaN detected, halt for inspection | No |
| `STOP_USER` | User runs `touch STOP_USER` | Graceful stop | No (and delete the file) |
| (none) | (any other exit) | Crash / preempt / timeout | **Yes** |

**Changes**:

1. `main.cu` — at the natural end of the time loop:

```cpp
if (myid == 0) {
    FILE* fp = fopen("STOP_DONE", "w");
    fprintf(fp, "step=%d NSTEP=%d\n", step, NSTEP);
    fclose(fp);
}
```

2. `nan_monitor.py` — when NaN is found, in addition to logging:

```python
from pathlib import Path
import os, subprocess
Path("STOP_NAN").write_text(f"iter={last_iter} vtk={vtk_file}\n")
# Cancel the currently running job so chain doesn't wait out full timeout
subprocess.run(["scancel", "--name=CPCrun2", "-u", os.getenv("USER")])
```

3. `jobscript_v3.slurm` — append chain logic:

```bash
mpirun -np 8 --map-by ppr:8:node --bind-to none stdbuf -oL ./a.out &
MPI_PID=$!
wait $MPI_PID
EXIT=$?
echo "=== Exit $EXIT at $(date) ==="

MAX=$(cat MAX_RESTARTS 2>/dev/null || echo 20)
mkdir -p restart_state
CUR=$(cat restart_state/count 2>/dev/null || echo 0)

if   [ -f STOP_DONE ]; then echo "[CHAIN] simulation complete"
elif [ -f STOP_NAN  ]; then echo "[CHAIN] NaN halt — inspect STOP_NAN"
elif [ -f STOP_USER ]; then echo "[CHAIN] user stop"; rm -f STOP_USER
elif [ $CUR -ge $MAX ]; then echo "[CHAIN] max restarts reached ($MAX)"
else
    NEXT=$((CUR + 1))
    echo $NEXT > restart_state/count
    echo "[CHAIN] resubmit $NEXT/$MAX"
    sbatch --dependency=afterany:$SLURM_JOB_ID jobscript_v3.slurm
fi
```

4. Create a `MAX_RESTARTS` file at project root (e.g. `echo 20 > MAX_RESTARTS`)
   to bound the chain length.

**Pass criterion**: kill one node mid-run. The job ends with exit ≠ 0, no
sentinel written → next job is auto-submitted via `afterany`. Run again with
`touch STOP_USER` during execution → chain stops.

---

### G5 — Rolling checkpoint purge (keep 3)

**Target**: fix W6. Bound disk usage.

**Change** (add to `SaveBinaryCheckpoint`, rank 0 only, after `rename` + symlink):

```cpp
if (myid == 0) {
    // Collect step numbers under checkpoint/, sort descending, delete index >= 3
    // (Keep current + 2 older = 3 total)
    const int KEEP = 3;
    DIR* d = opendir("checkpoint");
    std::vector<int> steps;
    struct dirent* e;
    while ((e = readdir(d)) != NULL) {
        int s;
        if (sscanf(e->d_name, "step_%d", &s) == 1 &&
            strstr(e->d_name, ".WRITING") == NULL)
            steps.push_back(s);
    }
    closedir(d);
    std::sort(steps.begin(), steps.end(), std::greater<int>());
    for (size_t i = KEEP; i < steps.size(); ++i) {
        char cmd[256];
        snprintf(cmd, sizeof cmd, "rm -rf checkpoint/step_%d", steps[i]);
        system(cmd);
        printf("[ROLLING] Purged checkpoint/step_%d\n", steps[i]);
    }
}
```

**Pass criterion**: run long enough to produce 5 checkpoints. Verify only 3
remain. `checkpoint/latest` still resolves correctly after purges.

---

### G6 — `checkpoint_version` schema field

**Target**: fix W7. Future-proof against schema changes.

**Change**: in `SaveBinaryCheckpoint`, first line written to `metadata.dat`:

```cpp
meta << "checkpoint_version=2\n";
```

In `LoadBinaryCheckpoint`, parse and validate:

```cpp
int ckpt_ver = 1;  // default: assume old format if field missing
// ... in the key=value parse loop:
else if (line.find("checkpoint_version=") == 0)
    sscanf(line.c_str() + 19, "%d", &ckpt_ver);

if (ckpt_ver > 2) {
    if (myid == 0) fprintf(stderr,
        "[CHECKPOINT] ERROR: version %d newer than this binary supports (2). "
        "Aborting to prevent silent data corruption.\n", ckpt_ver);
    MPI_Abort(MPI_COMM_WORLD, 1);
}
// ckpt_ver == 1: old format, use backward-compat branches
// ckpt_ver == 2: new format
```

**Pass criterion**: hand-craft a `metadata.dat` with `checkpoint_version=99` →
load aborts with clear error.

---

### G7 — Verification: bit-exact restart regression test

**Target**: lock down that all upgrades G1–G6 preserved P1–P7.

**Protocol**:

1. Cold start, run N=10000 steps, save `reference.vtk` at step 10000.
2. Cold start again, run N=5000, let a checkpoint save at 5000 (set `NDTBIN=5000`).
3. `scancel`, `sbatch` again (or run normally with `INIT=0` + auto-detect G2).
4. Let it run to step 10000. Save `restart.vtk`.
5. `diff reference.vtk restart.vtk` — the macroscopic fields (u, v, w, rho)
   must match to last bit. Statistics (if `accu_count > 0`) must match to
   at most 1 ULP per accumulator (floating-point summation order).

**If G7 fails**: the most common bug is forgetting to drain device buffers
before save (missing `cudaDeviceSynchronize()` or a stale host copy). Second
most common: a statistics accumulator was added but not listed in
SaveBinaryCheckpoint's macro block.

---

## 5. Pitfall Register (Read Before Coding)

These are the traps that bite every attempt at this kind of system. The
upgrade plan avoids them by design, but if you deviate from G1–G7, re-read
this list.

| # | Trap | Symptom | Defense |
|---|---|---|---|
| 1 | Writing `sum_uu.bin` when accu_count=0 | Garbage averaged into stats after restart | Always save `accu_count`; load path divides only if count > 0 (already implemented) |
| 2 | Storing `<u>` instead of `sum_u` | Restart statistics drift as new samples add to an already-averaged value | Store raw sums, divide only at output |
| 3 | Restarting with different rank count | Per-rank files don't match subdomain partition | Hard-assert `jp_ckpt == jp_runtime` at load (add in G2) |
| 4 | Force cap not applied on VTK restart | INIT=2 Force from VTK can be an outlier | Already implemented at main.cu:527; keep covering INIT=3 too |
| 5 | `cudaMemcpy` in signal handler | Undefined behavior, likely hang | Only set `volatile sig_atomic_t` flag; handle in main loop (G3 follows this) |
| 6 | `rename` across filesystems | EXDEV error, not atomic | Keep `.WRITING` in same directory as final — same FS guaranteed (G1 follows this) |
| 7 | Symlink with absolute path | Breaks if project is moved | Use relative target in `symlink()` (G2 follows this) |
| 8 | Stale sentinel from previous run | New run wrongly thinks NaN/done/user-stop already happened | A fresh-start helper script (`start_fresh.sh`) deletes all `STOP_*` + `restart_state/count` |
| 9 | `afterany` dependency on a job that was cancelled by admin | Chain silently stops | Log Slurm's `sacct --job` state; have a watchdog or cron check `squeue -u $USER` weekly |
| 10 | Filesystem full mid-save | `.WRITING` fails silently if ofstream error not checked | Every `ofstream` write should check `!file.good()` and `MPI_Abort` on failure |
| 11 | `checkpoint/latest` race | Reader sees link during update → points at deleted dir | Sequence: write+rename step_X → unlink latest → symlink latest (readers see either old or new, never nothing) |
| 12 | NDTBIN vs NSTEP misalignment | Final `step == NSTEP` might not trigger a save | main.cu:1644-1657 already has final unconditional save; keep this |
| 13 | Clock skew on `gpu_time_ms` | Chained restarts under-count or double-count wallclock | Save monotonic `(restored + elapsed_this_job)`, not wall clock |
| 14 | Restart right after Force spike | PID integrator restarts with stale integral | FORCE_CAP_MULT=70× already bounds this; consider G+ optional: clear PID integrator on restart |
| 15 | CV buffer restored but `FTT_STATS_START` not yet reached | CV metric computed on pre-transient data | FTT-gate already zeros stats in that case; ensure CV ring also clears (verify monitor.h:246) |

---

## 6. File-by-File Diff Summary

For the implementer, here is exactly which files change in what order:

| Step | `fileIO.h` | `main.cu` | `jobscript_v3.slurm` | `nan_monitor.py` | New files |
|---|---|---|---|---|---|
| G1 | `SaveBinaryCheckpoint` body: `.WRITING` + `rename` | — | — | — | — |
| G2 | `symlink("checkpoint/latest")` at end of save | startup auto-detect block before INIT dispatch | — | — | — |
| G3 | — | `signal(SIGUSR1, ...)`, flag, in-loop emergency save | add `--signal=B:USR1@120` + `--open-mode=append` | — | — |
| G4 | — | `STOP_DONE` write at end of main loop | chain-submit block at tail | write `STOP_NAN` + scancel | `MAX_RESTARTS`, `restart_state/` dir |
| G5 | rolling purge at end of save | — | — | — | — |
| G6 | `checkpoint_version=2` in meta; version check at load | — | — | — | — |
| G7 | — | — | — | — | `tests/restart_bitexact.sh` |

---

## 7. Non-goals (Do NOT Implement)

These are tempting but wrong. If asked to do any of them, push back.

- **❌ Merged single-file checkpoint**. Rank 0 gather OOMs; MPI-IO adds
  complexity without benefit on fixed 8-rank deployment. Per-rank in a folder
  is the right design.
- **❌ Runtime flag for INIT**. Environment variable override sounds clean
  but adds a parse path and error surface. G2's auto-detect covers every
  real-world need.
- **❌ Compressed checkpoints**. Add-on complexity, marginal saving (<10%
  compression on IEEE doubles), cost GPU/CPU cycles at save time.
- **❌ Cross-rank-count restart**. Requires regridding logic. Project has
  fixed `jp=8`; there is no use case.
- **❌ Asynchronous save (save kernel while next iteration runs)**. Current
  save ≈ 3s, iteration ≈ 6ms, so save at every `NDTBIN=100000` costs 3s out
  of 600s = 0.5% overhead. Not worth the GPU-host synchronization headache.
- **❌ Storing the random seed state**. Periodic Hill has no active RNG after
  init (perturbations are applied only at `PERTURB_INIT=1` at t=0). If RNG
  is added later, this restriction must be revisited.

---

## 8. Operator Quick Reference

**Fresh start** (wipe everything):
```bash
rm -rf checkpoint/ restart_state/ STOP_* slurm_*.log slurm_*.err
echo 20 > MAX_RESTARTS
bash run_v2.sh    # compiles + sbatches
```

**Resume** (after any kind of stop — crash, preempt, user):
```bash
rm -f STOP_DONE STOP_NAN STOP_USER
echo 0 > restart_state/count    # reset chain counter
sbatch jobscript_v3.slurm       # auto-detects checkpoint/latest
```

**Graceful stop** (let current iteration finish, save, don't chain):
```bash
touch STOP_USER    # next iteration check picks this up
# OR if program doesn't poll STOP_USER yet, scancel + touch STOP_USER
```

**Diagnose last stop reason**:
```bash
ls -la STOP_* CHECKPOINT_LAST_REASON 2>/dev/null
sacct -j <JOBID> --format=JobID,State,ExitCode,Elapsed,Reason
tail -30 slurm_<JOBID>.log
```

**Inspect latest checkpoint health**:
```bash
ls -la checkpoint/latest/          # should be a symlink
cat checkpoint/latest/metadata.dat
du -sh checkpoint/step_*           # rolling purge working?
```

---

## 9. Acceptance Checklist

Before declaring the upgrade complete, tick every box:

- [ ] G1: kill-mid-save test leaves `step_X.WRITING/` but keeps previous `step_X/` intact
- [ ] G2: `INIT=0` + existing `checkpoint/latest` → auto `[AUTO-RESTART]` log line
- [ ] G3: `--time=0:03:00` short job → `[SIGUSR1]` log + checkpoint written before exit
- [ ] G4: crash exit triggers `afterany` resubmit; `STOP_DONE` stops chain; `STOP_USER` stops chain and is deleted
- [ ] G5: after 5 saves, only 3 `step_*` directories present
- [ ] G6: hand-edited `checkpoint_version=99` → load aborts with clear error
- [ ] G7: bit-exact diff of `reference.vtk` vs `restart.vtk` at step 10000
- [ ] P1–P7: all seven correctness properties still hold (re-verify via G7 diff on statistics too)
- [ ] 15 pitfalls from §5: code review confirms none are violated
- [ ] `MAX_RESTARTS` file exists, chain counter bounded
- [ ] `run_v2.sh`, `jobscript_v3.slurm`, `nan_monitor.py`, `main.cu`, `fileIO.h` all committed with atomic, reviewable diffs per G-step

When all boxes are ticked, the system survives NCHC H200 preemptions,
Slurm timeouts, node failures, and NaN detections without human intervention,
while preserving bit-exact physics and full statistics continuity.
