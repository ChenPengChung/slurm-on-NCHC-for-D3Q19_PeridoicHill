#!/bin/bash
# ==============================================================================
# build_and_submit.sh
#   1. 編譯 main.cu → a.out
#   2. 清理上輪 chain state (.chain_jobid / .chain_count / STOP_CHAIN / chain.log)
#   3. 提交 jobscript_chain.slurm (Round 1 = cold start)
#
# 用法:
#   bash build_and_submit.sh                # 清理+編譯+提交 (全新 chain)
#   bash build_and_submit.sh --no-clean     # 只編譯+提交 (保留 chain state, 續跑)
#   bash build_and_submit.sh --build-only   # 只編譯, 不提交
# ==============================================================================

set -eo pipefail   # 不使用 -u: hpcx-init.sh 會踩 unbound variable HPCX_ENABLE_NCCLNET_PLUGIN

CLEAN_CHAIN=1
SUBMIT=1
for arg in "$@"; do
    case "$arg" in
        --no-clean)   CLEAN_CHAIN=0 ;;
        --build-only) SUBMIT=0 ;;
        -h|--help)
            sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg"; exit 2 ;;
    esac
done

# ═══════════════════════════════════════════════════════════════════════════
# GB200 aarch64 編譯模式
# ---------------------------------------------------------------------------
# 登入節點是 x86_64，但 GB200 compute node 是 ARM (Grace Neoverse-V2 aarch64).
# 必須用 salloc 申請一個 GB200 節點來編譯 aarch64 binary.
# 路徑:
#   CUDA:      /usr/local/cuda-13.0  (在 GB200 上原生)
#   HPC-X:     /opt/nvidia/hpc_sdk/Linux_aarch64/25.9/comm_libs/13.0/hpcx/hpcx-2.24
#   math_libs: /opt/nvidia/hpc_sdk/Linux_aarch64/25.9/math_libs/13.0/targets/sbsa-linux
# ═══════════════════════════════════════════════════════════════════════════

echo "=== Compiling main.cu on GB200 node (aarch64) ==="

salloc -p gb200-dev -N 1 --gres=gpu:1 -t 00:10:00 --account=MST114348 \
  srun bash -c '
    set -eo pipefail
    module purge
    module load cuda/13.0

    export CUDA_HOME=/usr/local/cuda-13.0
    export PATH=$CUDA_HOME/bin:$PATH

    export HPCX_HOME=/opt/nvidia/hpc_sdk/Linux_aarch64/25.9/comm_libs/13.0/hpcx/hpcx-2.24
    source $HPCX_HOME/hpcx-init.sh
    hpcx_load

    echo "Host:         $(hostname)"
    echo "Arch:         $(uname -m)"
    echo "Using nvcc:   $(which nvcc)"
    echo "Using mpicxx: $(which mpicxx)"
    echo "Using mpirun: $(which mpirun)"

    export MATH_LIBS=/opt/nvidia/hpc_sdk/Linux_aarch64/25.9/math_libs/13.0/targets/sbsa-linux

    nvcc -arch=sm_100 -O3 main.cu \
        -I${CUDA_HOME}/include \
        -I${MATH_LIBS}/include \
        -I${HPCX_MPI_DIR}/include \
        -L${CUDA_HOME}/lib64 \
        -L${MATH_LIBS}/lib \
        -L${HPCX_MPI_DIR}/lib -lmpi \
        -lcufft \
        -o a.out

    echo "Compilation successful (aarch64 binary)."
    file a.out
'

if [ ! -x ./a.out ]; then
    echo "[FATAL] Compilation failed - a.out not produced."
    exit 1
fi

# ---- Submit ----
if [ "$SUBMIT" -eq 0 ]; then
    echo "[--build-only] Skipping sbatch submission."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# [SAFETY-GUARD] 防止兩個 chain 同時寫 checkpoint/ 造成 metadata.dat 互相覆蓋
# ---------------------------------------------------------------------------
# 觸發情境: 使用者看 chain 跑不順 → 手動重投, 但忘記先 scancel 舊的 job.
#   → 舊鏈的 Round N+1 仍在 queue 中 (SIGUSR1 自動投出)
#   → 新鏈 Round 1 也被投出
#   → 兩個 job 同時 RUN, 都寫 checkpoint/step_*/ + checkpoint/latest
#   → metadata.dat 互相覆蓋, restart 時讀到錯誤 step/Force/FTT
# ---------------------------------------------------------------------------
# 本檢查: 投新 job 前檢查 queue 裡是否已有 GILBM_PH 名的 job
#   有 → 要求使用者先處理 (scancel / --no-clean 續跑) 再回來
# ═══════════════════════════════════════════════════════════════════════════
# 從 jobscript 自動抓取 JobName (避免硬編碼 GILBM_PH)
JOB_NAME=$(awk -F= '/^#SBATCH[[:space:]]+--job-name=/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' jobscript_chain.slurm)
JOB_NAME="${JOB_NAME:-GILBM_PH}"   # fallback if parse fails

# 抓 queue 裡同名 job. %i=JobID, %j=JobName, %T=State.
# grep pattern 用 [[:space:]] 確保跨 shell 相容 (某些 grep 不認 \s)
EXISTING_JOBS=$(squeue -u "$USER" -h -o '%i %j %T' 2>/dev/null \
                | grep -E "[[:space:]]${JOB_NAME}([[:space:]]|$)" || true)
if [ -n "$EXISTING_JOBS" ]; then
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  ⚠  SAFETY-GUARD: 偵測到已有 ${JOB_NAME} job 在 queue"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  目前 queue 裡的 ${JOB_NAME} jobs:"
    echo "$EXISTING_JOBS" | awk '{printf "    JOBID=%s  NAME=%s  STATE=%s\n", $1, $2, $3}'
    echo ""
    echo "  如果此時再投新 chain, 兩個 chain 會同時寫 checkpoint/,"
    echo "  metadata.dat 互相覆蓋 → restart 讀到錯誤 step/Force/FTT"
    echo "  → Round 之間 Force 值不連續, 統計量污染."
    echo ""
    JOBIDS_TO_CANCEL=$(echo "$EXISTING_JOBS" | awk '{print $1}' | xargs)
    echo "  請先選一個做完再回來:"
    echo "    (A) 停舊 chain:   scancel ${JOBIDS_TO_CANCEL}"
    echo "    (B) 不投新的:     bash build_and_submit.sh --build-only  (只編不投)"
    echo "    (C) 強制覆蓋:     FORCE_SUBMIT=1 bash build_and_submit.sh   (不建議)"
    echo ""
    # 規範:
    #   FORCE_SUBMIT=1 → 不管任何 flag, 都強制投 (使用者明知後果)
    #   否則 (無論 --no-clean 或 cold) → 一律 ABORT
    # 舊版允許 --no-clean 跳過檢查, 但 --no-clean 本意是「續跑自己的 chain state」,
    # 不是「允許多 chain 並存」。兩個 chain 同時存在,不管誰 clean 都會污染 checkpoint/.
    if [ "${FORCE_SUBMIT:-0}" = "1" ]; then
        echo "  [FORCE_SUBMIT=1] 使用者強制投遞, 責任自負."
    else
        echo "  [ABORT] 為避免 checkpoint 污染, 本次提交取消 (exit 3)."
        echo "         若確定要並存 (e.g. 測試場景), 用 FORCE_SUBMIT=1 覆蓋."
        exit 3
    fi
    echo ""
fi

if [ "$CLEAN_CHAIN" -eq 1 ]; then
    echo "Cleaning chain state (.chain_jobid, .chain_count, STOP_CHAIN, chain.log)"
    rm -f .chain_jobid .chain_count STOP_CHAIN chain.log
else
    echo "[--no-clean] Preserving chain state for warm re-submit."
fi

# ═══════════════════════════════════════════════════════════════════════════
# [AUTO-EXCLUDE] 提交前查詢當下壞節點 (3 來源)，自動注入 --exclude=
#   (A) sinfo -R                 - Slurm 當下標 drain/down/fail 的節點
#   (B) ./.bad_nodes             - 本專案 fast-fail 歷史累積
#   (C) ~/.bad_nodes_global      - 跨專案個人黑名單（選配）
# 同時 export SBATCH_EXCLUDE → 即使您未來忘了用這隻 script，直接 sbatch 也有保底
# ═══════════════════════════════════════════════════════════════════════════
LIVE_BAD=$(sinfo -h -R -o "%n" 2>/dev/null | sort -u | paste -sd,)
LOCAL_BAD=$(cat .bad_nodes 2>/dev/null | grep -v '^[[:space:]]*$' | paste -sd,)
GLOBAL_BAD=$(cat ~/.bad_nodes_global 2>/dev/null | grep -v '^[[:space:]]*$' | paste -sd,)
MERGED_BAD=$(
    { echo "$LIVE_BAD"; echo "$LOCAL_BAD"; echo "$GLOBAL_BAD"; } \
        | tr ',' '\n' | grep -v '^[[:space:]]*$' | sort -u | paste -sd,
)
EXCLUDE_ARG=""
if [ -n "$MERGED_BAD" ]; then
    EXCLUDE_ARG="--exclude=$MERGED_BAD"
    export SBATCH_EXCLUDE="$MERGED_BAD"
    echo "[submit] 自動排除壞節點: $MERGED_BAD"
    echo "         (sinfo -R: ${LIVE_BAD:-none}; .bad_nodes: ${LOCAL_BAD:-none}; global: ${GLOBAL_BAD:-none})"
else
    echo "[submit] 叢集健康，無需排除任何節點"
fi

sbatch $EXCLUDE_ARG jobscript_chain.slurm

# Optional NaN monitor (only if script exists)
if [ -f nan_monitor.py ]; then
    nohup python3 nan_monitor.py . > nan_monitor_log.txt 2>&1 &
    echo "NaN monitor started (PID: $!, log: nan_monitor_log.txt)"
else
    echo "[INFO] nan_monitor.py not found — skipping NaN watchdog."
fi
