#!/bin/bash
#SBATCH --job-name=H200_Edit11
#SBATCH --account=MST114348
#SBATCH --partition=dev
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --cpus-per-task=1
#SBATCH --time=1:00:00
#SBATCH --output=slurm_%j.log
#SBATCH --error=slurm_%j.err
#SBATCH --open-mode=append
# SIGUSR1 送達時間:walltime 結束前 120s,讓程式完成最終 checkpoint
#SBATCH --signal=USR1@120
# 壞節點 exclude 改為「提交時動態注入」:
#   (1) build_and_submit.sh 會自動查 sinfo -R + .bad_nodes + ~/.bad_nodes_global
#       → 加 --exclude=... 到 sbatch 命令列
#   (2) shell env var SBATCH_EXCLUDE 也會被 Slurm 自動讀取（雙保險）
#   (3) 續鏈時（見文末 sbatch 區塊）會再查一次最新 sinfo -R
#
# ==============================================================================
# jobscript_chain.slurm — 3.Re2800_129x257x129 自動續鏈 jobscript
#
# Round 1      → ./a.out --cold
# Round >= 2   → ./a.out --restart=checkpoint/step_<latest>
# 全部 checkpoint 失效 → FATAL, chain 停 (絕不靜默冷啟動)
#
# Exit code 語意 (stop_control.h):
#   0   = 自然停止 (converged / diverged / FTT_STOP / STOP_CHAIN sentinel) → 停鏈
#   124 = SIGUSR1 walltime 救援 / bash timeout(1) SIGKILL                  → 續鏈
#   其他非 0 = crash / node failure                                         → 續鏈
# ==============================================================================

export PATH=$HOME/bin:$PATH
module purge
module load cuda/13.0

export CUDA_HOME=/opt/nvidia/hpc_sdk/Linux_x86_64/25.9/cuda/13.0
export MATH_LIBS=/opt/nvidia/hpc_sdk/Linux_x86_64/25.9/math_libs/13.0/targets/x86_64-linux
export HPCX_HOME=/opt/nvidia/hpc_sdk/Linux_x86_64/25.9/comm_libs/13.0/hpcx/hpcx-2.24
source $HPCX_HOME/hpcx-init.sh
hpcx_load
export OMPI_MCA_coll_hcoll_enable=0

CHAIN_LOG=chain.log
log() { echo "[$(date '+%F %T')] [job=$SLURM_JOB_ID] $*" | tee -a "$CHAIN_LOG"; }

# ===== 1. Chain ID =====
if [ ! -f .chain_jobid ]; then
    echo "$SLURM_JOB_ID" > .chain_jobid
    echo "1" > .chain_count
fi
CHAIN_JOB_ID=$(cat .chain_jobid)
CHAIN_COUNT=$(cat .chain_count 2>/dev/null || echo 1)

log "=== Chain $CHAIN_JOB_ID round $CHAIN_COUNT on $SLURM_NODELIST ==="
nvidia-smi --query-gpu=name,memory.total --format=csv | tee -a "$CHAIN_LOG"

# ===== 1.5 使用者強制停鏈 sentinel =====
if [ -f STOP_CHAIN ]; then
    log "STOP_CHAIN sentinel found → chain stops (user request)."
    exit 0
fi

# ===== Animation deps check =====
log "=== Animation deps check ==="
{
    echo "which ffmpeg : $(which ffmpeg 2>&1)"
    echo "ffmpeg ver   : $(ffmpeg -version 2>&1 | head -1)"
    echo "which pvpython: $(which pvpython 2>&1)"
    echo "Pillow       : $(python3 -c 'from PIL import Image; print(Image.__version__)' 2>&1)"
} | tee -a "$CHAIN_LOG"
if ! command -v ffmpeg >/dev/null 2>&1; then
    log "WARN: ffmpeg NOT found on compute node — animation MP4 will fail."
fi

# ===== 2. Restart 上限 =====
MAX_RESTARTS=500
if [ "$CHAIN_COUNT" -gt "$MAX_RESTARTS" ]; then
    log "ABORT: chain count $CHAIN_COUNT > MAX_RESTARTS=$MAX_RESTARTS. Chain stops."
    exit 0
fi

# ===== 3. Pre-flight =====
if [ ! -x ./a.out ]; then
    log "FATAL: ./a.out not found/executable. Chain stops."
    exit 1
fi

# ===== 3.5 節點健康預檢 (首次手動 sbatch 也會走這裡) =====
# 若當前分配到已知壞節點 (live sinfo / .bad_nodes / ~/.bad_nodes_global),
# 不跑 mpirun, 直接以 --exclude requeue 換節點. 避免:
#   (a) 撞到歷史上 fast-fail 過的節點, 浪費啟動時間
#   (b) 第一次手動 sbatch 沒經 build_and_submit.sh 的 --exclude 注入
# 注: 此階段不累計 .fast_fail_count (非 solver fast-fail)
PRE_LOCAL_BAD=$(cat .bad_nodes 2>/dev/null | grep -v '^[[:space:]]*$')
PRE_GLOBAL_BAD=$(cat ~/.bad_nodes_global 2>/dev/null | grep -v '^[[:space:]]*$')
PRE_LIVE_BAD=$(sinfo -h -R -o "%n" 2>/dev/null | sort -u)
PRE_BAD_ALL=$(printf '%s\n%s\n%s\n' "$PRE_LOCAL_BAD" "$PRE_GLOBAL_BAD" "$PRE_LIVE_BAD" \
              | grep -v '^[[:space:]]*$' | sort -u)

CURRENT_NODES=$(scontrol show hostnames "$SLURM_NODELIST" 2>/dev/null)
MATCHED_BAD=""
for node in $CURRENT_NODES; do
    if echo "$PRE_BAD_ALL" | grep -qxF "$node"; then
        MATCHED_BAD="$MATCHED_BAD $node"
    fi
done

if [ -n "$MATCHED_BAD" ]; then
    log "PRE-FLIGHT BAD NODE detected:$MATCHED_BAD -> requeue without running mpirun"
    touch .bad_nodes
    for node in $MATCHED_BAD; do
        grep -qxF "$node" .bad_nodes || echo "$node" >> .bad_nodes
    done
    LIVE_BAD_C=$(sinfo -h -R -o "%n" 2>/dev/null | sort -u | paste -sd,)
    LOCAL_BAD_C=$(cat .bad_nodes 2>/dev/null | grep -v '^[[:space:]]*$' | paste -sd,)
    GLOBAL_BAD_C=$(cat ~/.bad_nodes_global 2>/dev/null | grep -v '^[[:space:]]*$' | paste -sd,)
    EX_LIST=$(
        { echo "$LIVE_BAD_C"; echo "$LOCAL_BAD_C"; echo "$GLOBAL_BAD_C"; } \
            | tr ',' '\n' | grep -v '^[[:space:]]*$' | sort -u | paste -sd,
    )
    EXCLUDE_ARG=""
    [ -n "$EX_LIST" ] && EXCLUDE_ARG="--exclude=$EX_LIST"
    log "Pre-flight requeue exclude: ${EX_LIST:-(empty)}"
    NEXT_ID=$(sbatch --parsable $EXCLUDE_ARG jobscript_chain.slurm 2>&1)
    if [[ "$NEXT_ID" =~ ^[0-9]+$ ]]; then
        log "Pre-flight requeued: job=$NEXT_ID"
        exit 0
    else
        log "FATAL: pre-flight requeue failed: $NEXT_ID"
        exit 1
    fi
fi

# ===== 4. Checkpoint 驗證 =====
NP=${SLURM_NTASKS:-8}

STAT_NAMES=(
    sum_u sum_v sum_w
    sum_uu sum_uv sum_uw sum_vv sum_vw sum_ww
    sum_uuu sum_uuv sum_uuw sum_uvv sum_uvw sum_uww sum_vvv sum_vvw sum_vww sum_www
    sum_P sum_PP sum_Pu sum_Pv sum_Pw
    sum_dudx2 sum_dudy2 sum_dudz2
    sum_dvdx2 sum_dvdy2 sum_dvdz2
    sum_dwdx2 sum_dwdy2 sum_dwdz2
    sum_ox sum_oy sum_oz
)

validate_checkpoint() {
    local dir="$1"
    if [ ! -f "$dir/metadata.dat" ];  then echo "no metadata.dat"; return 1; fi
    if [ ! -s "$dir/metadata.dat" ];  then echo "metadata.dat empty"; return 1; fi

    local need_f=$((19 * NP)) got_f got_f00 got_rho
    got_f=$(ls "$dir"/f[01][0-9]_*.bin 2>/dev/null | wc -l)
    if [ "$got_f" -ne "$need_f" ];   then echo "f files $got_f / $need_f"; return 1; fi
    got_f00=$(ls "$dir"/f00_*.bin 2>/dev/null | wc -l)
    if [ "$got_f00" -ne "$NP" ];     then echo "f00 ranks $got_f00 / $NP"; return 1; fi
    got_rho=$(ls "$dir"/rho_*.bin 2>/dev/null | wc -l)
    if [ "$got_rho" -ne "$NP" ];     then echo "rho $got_rho / $NP"; return 1; fi

    local accu cv
    accu=$(grep -E '^accu_count=' "$dir/metadata.dat" | head -1 | cut -d= -f2)
    cv=$(  grep -E '^cv_count='   "$dir/metadata.dat" | head -1 | cut -d= -f2)
    accu=${accu:-0}; cv=${cv:-0}

    if [ "$accu" -gt 0 ]; then
        local name got
        for name in "${STAT_NAMES[@]}"; do
            got=$(ls "$dir"/${name}_*.bin 2>/dev/null | wc -l)
            if [ "$got" -ne "$NP" ]; then
                echo "stat $name: $got / $NP (accu_count=$accu)"; return 1
            fi
        done
    fi

    if [ "$cv" -gt 0 ]; then
        for fn in cv_uu_history.bin cv_k_history.bin cv_ftt_history.bin; do
            if [ ! -s "$dir/$fn" ]; then
                echo "missing/empty $fn (cv_count=$cv)"; return 1
            fi
        done
    fi

    echo "OK accu=$accu cv=$cv"
    return 0
}

ARGS=""
if [ "$CHAIN_COUNT" -eq 1 ]; then
    # ---- Cold-start 安全閘 ----
    # 防誤觸: chain_count=1 但 checkpoint/ 已有資料 -> 拒絕冷啟動 (會覆寫 checkrho.dat 等)
    # 明確從頭跑時: export LBM_ALLOW_COLD_START=1
    HAS_CKPT=$(ls -1d checkpoint/step_*/ 2>/dev/null | head -1)
    if [ -n "$HAS_CKPT" ] && [ "${LBM_ALLOW_COLD_START:-0}" != "1" ]; then
        log "FATAL: chain_count=1 但 checkpoint/ 已有資料 ($HAS_CKPT)"
        log "       拒絕冷啟動以防 checkrho.dat / Ustar_Force_record.dat 被覆寫"
        log "       -> 續跑: echo <round> > .chain_count; sbatch jobscript_chain.slurm"
        log "       -> 確定從頭跑: export LBM_ALLOW_COLD_START=1; sbatch jobscript_chain.slurm"
        exit 1
    fi
    ARGS="--cold"
    log "Round 1 → ARGS=\"$ARGS\""
else
    log "Checkpoint validation: NP=$NP ranks"
    # 過濾 .WRITING 暫存目錄 (SaveBinaryCheckpoint 進行中,內容不完整)
    CAND_LIST=$(ls -1d checkpoint/step_*/ 2>/dev/null | sed 's|/$||' \
                | grep -v '\.WRITING$' \
                | awk -F'_' '{print $0"\t"$NF}' \
                | sort -k2 -n -r \
                | cut -f1)
    N_CAND=$(echo "$CAND_LIST" | grep -c '.')
    log "Found $N_CAND candidate checkpoint directories"

    LATEST=""
    if [ -n "$CAND_LIST" ]; then
        while IFS= read -r dir; do
            [ -z "$dir" ] && continue
            RES=$(validate_checkpoint "$dir")
            RC=$?
            if [ $RC -eq 0 ]; then
                log "OK $dir -- $RES"
                LATEST="$dir"
                break
            else
                log "BAD $dir -- $RES (trying older)"
            fi
        done <<< "$CAND_LIST"
    fi

    if [ -z "$LATEST" ]; then
        log "FATAL: No valid checkpoint among $N_CAND candidates. Chain stops."
        log "       To force cold start: rm .chain_jobid .chain_count; sbatch jobscript_chain.slurm"
        exit 1
    fi

    # 清 .part 殘留 (timeout 在 rename 前被 SIGKILL)
    STALE_PART=$(ls "$LATEST"/*.part 2>/dev/null | wc -l)
    if [ "$STALE_PART" -gt 0 ]; then
        log "Cleaning $STALE_PART stale .part files in $LATEST"
        rm -f "$LATEST"/*.part
    fi

    SEL_STEP=$(grep -E '^step=' "$LATEST/metadata.dat" | head -1 | cut -d= -f2)
    SEL_FTT=$( grep -E '^FTT='  "$LATEST/metadata.dat" | head -1 | cut -d= -f2)
    log "Restart from: $LATEST  (step=$SEL_STEP FTT=$SEL_FTT)"

    ARGS="--restart=$LATEST"
    log "Round $CHAIN_COUNT → ARGS=\"$ARGS\""
fi

# ===== 5. 執行模擬 =====
# ------------------------------------------------------------------------------
# 時序設計 (walltime = 3600s):
#   t = 3480s (58:00)  SLURM --signal=USR1@120 送 SIGUSR1
#                      → handler 設 STOP_SIGNAL_WALLTIME → exit 124 → 續鏈
#   t = 3540s (59:00)  timeout(1) 備援送 SIGUSR1 (若 SLURM 漏發)
#                      → 同路徑 → exit 124 → 續鏈
#   t = 3600s (60:00)  timeout --kill-after=60 送 SIGKILL → bash 回 124 → 續鏈
#
# 關鍵: 必須用 --signal=USR1 (非預設 SIGTERM), 因為 SIGTERM 被
#   stop_control.h 歸類為 STOP_SIGNAL → exit 0 → 誤判停鏈!
# ------------------------------------------------------------------------------
TIMEOUT=3540
KILL_AFTER=60
log "Starting mpirun  TIMEOUT=${TIMEOUT}s  KILL_AFTER=${KILL_AFTER}s  ARGS=\"$ARGS\""
START_TS=$(date +%s)
timeout --signal=USR1 --kill-after=${KILL_AFTER} ${TIMEOUT} \
    mpirun -np 8 --map-by ppr:8:node --bind-to none stdbuf -oL ./a.out $ARGS
RC=$?
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
log "mpirun exit: RC=$RC  elapsed=${ELAPSED}s  node=$SLURM_NODELIST"

# ===== 5.5 Fast-fail 偵測 + 節點黑名單 =====
# 判斷: mpirun 在 60s 內死掉, 且不是 walltime rescue (RC=124)
#       → 極可能是節點 GPU/驅動故障 (如 cudaError 46)
#       → 把節點加進 .bad_nodes, 下一輪 resubmit 自動 exclude
if [ "$ELAPSED" -lt 60 ] && [ "$RC" -ne 0 ] && [ "$RC" -ne 124 ]; then
    log "FAST-FAIL detected: $SLURM_NODELIST died in ${ELAPSED}s (RC=$RC)"
    touch .bad_nodes
    if ! grep -qxF "$SLURM_NODELIST" .bad_nodes; then
        echo "$SLURM_NODELIST" >> .bad_nodes
        log "Blacklisted $SLURM_NODELIST → .bad_nodes (共 $(wc -l < .bad_nodes) 個節點)"
    else
        log "$SLURM_NODELIST 已在 .bad_nodes 中 (Slurm 分配策略問題?)"
    fi
    # 連續 fast-fail 守門: 5 次 → 暫停鏈 (防 solver bug 誤判為節點問題)
    FF=$(cat .fast_fail_count 2>/dev/null || echo 0)
    FF=$((FF + 1))
    echo "$FF" > .fast_fail_count
    if [ "$FF" -ge 5 ]; then
        log "FAST-FAIL GUARD: 連續 $FF 次 fast-fail. Chain 暫停等人檢查."
        log "   恢復: rm .fast_fail_count; sbatch jobscript_chain.slurm"
        touch STOP_CHAIN
        exit 1
    fi
else
    rm -f .fast_fail_count   # 正常跑滿 or walltime rescue → 清零計數
fi

# ===== 6. Exit code 判斷 + 續鏈決策 =====
if [ "$RC" -eq 0 ]; then
    log "RC=0 (natural stop: converged/diverged/FTT_STOP/user). Chain stops."
    exit 0
fi

# 再次檢查 STOP_CHAIN (程式執行期間使用者可能放置)
if [ -f STOP_CHAIN ]; then
    log "STOP_CHAIN sentinel found after mpirun → chain stops."
    exit 0
fi

# ===== 7. 續投下一輪 =====
NEXT_COUNT=$((CHAIN_COUNT + 1))
echo "$NEXT_COUNT" > .chain_count
log "RC=$RC → queuing chain round $NEXT_COUNT"

# ── sbatch 重試機制 ──
# 問題: 4 case 跑在 QOS limit=5 的環境, 兩個 case 同時結束 Round 時,
#   第二個 sbatch 會因 QOSMaxSubmitJobPerUserLimit 失敗 (自己還沒 exit, 佔 1 名額).
# 解法: 等 30s 讓先完成的 job exit 釋出名額, 最多重試 5 次 (共等 ~150s).
MAX_SBATCH_RETRY=5
SBATCH_RETRY_DELAY=30

# 續鏈 exclude 名單（3 來源合併）：
#   (A) Slurm 當下 sinfo -R       — 最新真實壞節點
#   (B) .bad_nodes                — 本專案 fast-fail 自動累積
#   (C) ~/.bad_nodes_global       — 跨專案個人黑名單（手動維護）
LIVE_BAD=$(sinfo -h -R -o "%n" 2>/dev/null | sort -u | paste -sd,)
LOCAL_BAD=$(cat .bad_nodes 2>/dev/null | grep -v '^[[:space:]]*$' | paste -sd,)
GLOBAL_BAD=$(cat ~/.bad_nodes_global 2>/dev/null | grep -v '^[[:space:]]*$' | paste -sd,)
EX_LIST=$(
    { echo "$LIVE_BAD"; echo "$LOCAL_BAD"; echo "$GLOBAL_BAD"; } \
        | tr ',' '\n' | grep -v '^[[:space:]]*$' | sort -u | paste -sd,
)
EXCLUDE_ARG=""
if [ -n "$EX_LIST" ]; then
    EXCLUDE_ARG="--exclude=$EX_LIST"
    log "Resubmit exclude (live+local+global): $EX_LIST"
else
    log "Resubmit exclude: (empty — cluster healthy)"
fi

for ATTEMPT in $(seq 1 $MAX_SBATCH_RETRY); do
    NEXT_ID=$(sbatch --parsable $EXCLUDE_ARG jobscript_chain.slurm 2>&1)
    SBATCH_RC=$?
    if [ $SBATCH_RC -eq 0 ] && [[ "$NEXT_ID" =~ ^[0-9]+$ ]]; then
        log "Submitted next round: job=$NEXT_ID (attempt $ATTEMPT/$MAX_SBATCH_RETRY)"
        exit 0
    fi
    log "sbatch attempt $ATTEMPT/$MAX_SBATCH_RETRY failed: $NEXT_ID"
    if [ "$ATTEMPT" -lt "$MAX_SBATCH_RETRY" ]; then
        log "Retrying in ${SBATCH_RETRY_DELAY}s (waiting for QOS slot)..."
        sleep $SBATCH_RETRY_DELAY
    fi
done

log "FATAL: sbatch failed after $MAX_SBATCH_RETRY attempts. Chain broken."
log "       手動續跑: bash build_and_submit.sh --no-clean"
exit 1
