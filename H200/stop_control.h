#ifndef STOP_CONTROL_H
#define STOP_CONTROL_H

// ================================================================
// Phase 7 + G3: 實時停止控制 (Real-Time Stop Control)
// ----------------------------------------------------------------
// 兩類停止語意,對應不同 exit code:
//
//   [A] 自然/使用者主動結束 (exit 0 → jobscript 停鏈):
//     #1 Converged     : g_conv_status == 2
//     #2 Diverged      : Force_h[0] 出現 NaN/Inf
//     #3 FTT_STOP      : FTT >= FTT_STOP 或 step >= loop 上限
//     #4 User kill     : STOP_CHAIN 檔 / SIGUSR2 / SIGTERM (使用者明確要停)
//
//   [B] walltime 救援 (exit 124 → jobscript 繼續 resubmit):
//     #5 SIGUSR1       : Slurm 在 walltime 到期前 120s 送來, 程式存完
//                        最後一份 checkpoint 後以 124 退出, 表達「還沒跑完」
//
// 這個區分是工業等級續跑鏈的核心 — 否則 60 分鐘 walltime 到就會被 jobscript
// 的 `if [ $RC -eq 0 ]` 誤判為自然結束,整條鏈停掉,永遠跑不到 FTT_STOP=200.
//
// 任一停止條件觸發後, 主迴圈 break, 隨後執行最終 checkpoint (main.cu
// 第 ~1760 行起) 再 MPI_Finalize, 最後 return StopReasonExitCode(g_stop_reason)。
//
// 設計要點:
//   - 所有條件必須「集體同步」: 使用 MPI_Allreduce(MAX) 讓全體 rank
//     在同一步決定停止, 避免 deadlock (例: rank 0 停了, 其他 rank
//     還在等 MPI_Wait)。
//   - 每步 Allreduce 1 int = ~10-50 μs, 佔 iter(~5 ms) < 1%, 可接受。
//   - STOP_CHAIN 檔 I/O 每 100 步檢查一次即可 (不需 sub-second 反應)。
//   - Signal handler 只設 flag, 絕不做 I/O (async-signal-safe)。
//
// 依賴:
//   - common.h (CHECK_MPI), variables.h (FTT_STOP)
//   - 全域: g_conv_status (from convergence.h), Force_h (main.cu)
// ================================================================

#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cmath>
#include <cstdio>
#include <mpi.h>

// ================================================================
// 停止原因列舉 (退出後印在 log / Timing summary)
// ================================================================
enum StopReason {
    STOP_NONE             = 0,
    STOP_SIGNAL           = 1,  // SIGUSR2/SIGTERM (使用者主動) → exit 0
    STOP_FILE             = 2,  // STOP_CHAIN 檔存在 → exit 0
    STOP_CONVERGED        = 3,  // g_conv_status == 2 → exit 0
    STOP_DIVERGED         = 4,  // Force NaN/Inf → exit 0
    STOP_FTT_STOP         = 5,  // FTT >= FTT_STOP → exit 0
    STOP_LOOP_LIMIT       = 6,  // step >= loop_start + loop → exit 0
    STOP_SIGNAL_WALLTIME  = 7   // SIGUSR1 (Slurm walltime 救援) → exit 124, resubmit
};

// ================================================================
// G3: Exit code 決策 — 分辨「停鏈」與「續鏈」
// ----------------------------------------------------------------
// jobscript_v3_59min.slurm 第 210-213 行的判斷:
//     if [ $RC -eq 0 ]; then exit 0 (停鏈); fi
//     else submit next (續鏈)
//
// 只有 SIGUSR1 (walltime 救援) 回 124, 其他一律 0.
// timeout(1) 本身也回 124, 所以這裡的 124 與 bash timeout 語意一致.
// ================================================================
inline int StopReasonExitCode(int reason) {
    switch (reason) {
        case STOP_SIGNAL_WALLTIME: return 124;   // Slurm SIGUSR1 → 還沒跑完, resubmit
        default:                   return 0;     // 四大自然/使用者停止 → 停鏈
    }
}

// ================================================================
// 全域 flag (signal handler 專用, 只讀/只寫這一個)
// async-signal-safe: sig_atomic_t + volatile
// ================================================================
extern volatile sig_atomic_t g_signal_received;   // 0 / 1 / 2 / 15 (實際 signo)
extern int                   g_stop_reason;        // StopReason enum

// ================================================================
// Signal handler: 只設 flag, 不做 I/O
// ================================================================
inline void StopSignalHandler(int signo) {
    g_signal_received = (sig_atomic_t)signo;
    // ← 禁止在這裡呼叫 printf/fprintf/MPI/cuda*, 非 async-signal-safe
}

// ================================================================
// 安裝 handlers: SIGUSR1 (SLURM pre-walltime), SIGUSR2 (使用者手動),
//                SIGTERM (scancel 預設).
// SIGINT (Ctrl-C) 不裝 — 讓使用者可以硬中斷。
// 在 MPI_Init 後儘早呼叫。
// ================================================================
inline void InstallStopHandlers() {
    struct sigaction sa;
    sa.sa_handler = StopSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags   = SA_RESTART;   // 不中斷被阻塞的 syscall (保護 MPI)

    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

// ================================================================
// 停止原因字串 (for log)
// ================================================================
inline const char* StopReasonStr(int reason) {
    switch (reason) {
        case STOP_SIGNAL:            return "USER_SIGNAL (SIGUSR2/SIGTERM) → exit 0 (chain stops)";
        case STOP_SIGNAL_WALLTIME:   return "SLURM_WALLTIME_RESCUE (SIGUSR1) → exit 124 (chain continues)";
        case STOP_FILE:              return "USER_STOP_CHAIN file → exit 0 (chain stops)";
        case STOP_CONVERGED:         return "CONVERGED (g_conv_status==2) → exit 0 (chain stops)";
        case STOP_DIVERGED:          return "DIVERGED (NaN/Inf in Force) → exit 0 (chain stops)";
        case STOP_FTT_STOP:          return "FTT_STOP reached → exit 0 (chain stops)";
        case STOP_LOOP_LIMIT:        return "loop limit reached → exit 0 (chain stops)";
        default:                     return "NONE";
    }
}

// ================================================================
// 每步停止檢查 (collective, 全體 rank 同步決策)
//
// 檢查順序 (由便宜到貴):
//   1) FTT_STOP          — 本地純量比較, 無通訊
//   2) Converged         — 本地 int 比較, g_conv_status 已在 Monitor
//                          集體產生, 所有 rank 相同
//   3) Diverged          — 本地 NaN 檢查, Force_h[0] 在 Monitor 後
//                          由 rank 0 廣播, 所有 rank 相同
//   4) Signal            — 本地 sig_atomic_t 讀取, 已由 handler 設
//   5) STOP_CHAIN file   — 每 100 步由 rank 0 stat() 一次
//   6) MPI_Allreduce(MAX)— 同步 reason 到所有 rank
//
// 回傳:
//   StopReason (0=none, 否則對應 enum)
//
// 使用方式 (main.cu 迴圈頂端):
//   int reason = CheckStopConditions(step, FTT_now, myid);
//   if (reason != STOP_NONE) { g_stop_reason = reason; break; }
// ================================================================
inline int CheckStopConditions(int step, double FTT_now, int myid,
                               double Force_val, int conv_status)
{
    int local_reason = STOP_NONE;

    // (1) FTT_STOP — 最常見的自然結束, 便宜先檢查
    if (FTT_now >= (double)FTT_STOP) {
        local_reason = STOP_FTT_STOP;
    }
    // (2) Converged — g_conv_status 由 Monitor 集體計算, 所有 rank 一致
    else if (conv_status == 2) {
        local_reason = STOP_CONVERGED;
    }
    // (3) Diverged — Force_h[0] NaN/Inf
    //     (由 Monitor/Launch_Monitor 集體更新, rank 間一致)
    else if (std::isnan(Force_val) || std::isinf(Force_val)) {
        local_reason = STOP_DIVERGED;
    }
    // (4) Signal — handler 已在 g_signal_received 存下 signo, 這裡做 signo-aware 區分:
    //     SIGUSR1 (10) = Slurm walltime 救援 → STOP_SIGNAL_WALLTIME → exit 124 (resubmit)
    //     SIGUSR2 (12) / SIGTERM (15) = 使用者明確要停 → STOP_SIGNAL → exit 0 (停鏈)
    //     所有 rank 會收到相同 signo (Slurm --signal 送給全體 task), Allreduce MAX
    //     在罕見異質狀況下會選 STOP_SIGNAL_WALLTIME (值 7 > STOP_SIGNAL 值 1),
    //     這是對的 — 因為 walltime 鐵定要發生, 使用者後送的 signal 可下次 session 再處理.
    else if (g_signal_received != 0) {
        int sig = (int)g_signal_received;
        if (sig == SIGUSR1) local_reason = STOP_SIGNAL_WALLTIME;
        else                local_reason = STOP_SIGNAL;
    }
    // (5) STOP_CHAIN file — 每 100 步由 rank 0 檢查
    //     (8 μs stat() × 1/100 = 0.08 μs/step 平均)
    else if (myid == 0 && (step % 100) == 0) {
        struct stat st;
        if (stat("STOP_CHAIN", &st) == 0) {
            local_reason = STOP_FILE;
        }
    }

    // (6) 集體同步 — 只要一個 rank 想停, 全體停
    //     使用 MAX 讓不同 rank 的不同 reason 都能表達
    //     (實務上絕大多數情況各 rank 得到相同 reason)
    int global_reason = STOP_NONE;
    MPI_Allreduce(&local_reason, &global_reason, 1, MPI_INT, MPI_MAX,
                  MPI_COMM_WORLD);

    return global_reason;
}

#endif // STOP_CONTROL_H
