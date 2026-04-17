#ifndef RUNTIME_ARGS_H
#define RUNTIME_ARGS_H

// ================================================================
// Phase 8: Runtime argv flags for restart / cold-start control
// ----------------------------------------------------------------
// Pre-Phase 8 (deprecated):
//   jobscript 以 sed 修改 variables.h 的 INIT / RESTART_BIN_DIR,
//   接著 nvcc 全量重編 (5-10 s overhead, sed 依賴 exact line format).
//
// Phase 8 (current):
//   binary 只編一次, 所有 restart 狀態由 argv 傳入:
//     ./a.out --restart=checkpoint/step_1000    (warm restart)
//     ./a.out --cold                            (explicit cold start)
//     ./a.out                                   (使用 variables.h 的 INIT)
//
// 優先順序:
//   1) --restart=<dir> 與 --cold 互斥 → FATAL
//   2) --restart=<dir>: 覆蓋 INIT=3, g_restart_bin_dir = <dir>
//   3) --cold         : 覆蓋 INIT=0
//   4) 無 flag        : 使用 compile-time INIT (backward compat)
//
// 失敗策略:
//   - 未知 flag  → FATAL (抓 typo, 不默默忽略)
//   - --restart= 空值 → FATAL
//   - 同時 --cold --restart → FATAL
//
// 依賴:
//   - variables.h 的 INIT, RESTART_BIN_DIR (作為預設)
//   - mpi.h 的 MPI_Abort / MPI_Barrier
// ================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mpi.h>

// 全域: 由 main.cu 定義, 在 MPI_Init 後用 ParseRuntimeArgs 解析 argv 更新。
// 所有 main.cu 的 init dispatch 應該使用這兩個 runtime 變數, 不再直接用 #define。
extern int         g_init_runtime;
extern const char *g_restart_bin_dir;

// ----------------------------------------------------------------
// 解析 argv, 必要時 abort。rank 0 負責 printf/fprintf, 所有 rank 看到
// 相同 argv (MPI_Init 已廣播), 故各 rank 的 parse 結果一致。
// 但 abort 必須 collective → MPI_Barrier + MPI_Abort。
// ----------------------------------------------------------------
inline void ParseRuntimeArgs(int argc, char *argv[], int myid) {
    bool got_cold        = false;
    bool got_restart     = false;
    const char *rsrc_arg = NULL;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];

        if (strcmp(a, "--cold") == 0) {
            got_cold = true;
        }
        else if (strncmp(a, "--restart=", 10) == 0) {
            got_restart = true;
            rsrc_arg    = a + 10;     // 指向 argv 字串內部, 生命期 == 程式執行期
        }
        else if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
            if (myid == 0) {
                fprintf(stderr,
                    "Usage: %s [--cold | --restart=<checkpoint_dir>]\n"
                    "  --cold              Force cold start (runtime INIT=0)\n"
                    "  --restart=<dir>     Warm-restart from binary checkpoint dir\n"
                    "                      (runtime INIT=3, g_restart_bin_dir=<dir>)\n"
                    "  (no flag)           Use compile-time INIT from variables.h\n",
                    argv[0]);
            }
            CHECK_MPI( MPI_Barrier(MPI_COMM_WORLD) );
            MPI_Abort(MPI_COMM_WORLD, 0);
        }
        else {
            if (myid == 0) {
                fprintf(stderr,
                    "\n[FATAL][Phase8] Unknown argv: \"%s\"\n"
                    "  Valid flags: --cold | --restart=<dir> | --help\n", a);
            }
            CHECK_MPI( MPI_Barrier(MPI_COMM_WORLD) );
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    }

    // 互斥檢查
    if (got_cold && got_restart) {
        if (myid == 0) {
            fprintf(stderr,
                "\n[FATAL][Phase8] --cold and --restart=<dir> are mutually exclusive.\n");
        }
        CHECK_MPI( MPI_Barrier(MPI_COMM_WORLD) );
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    // Apply
    if (got_restart) {
        if (rsrc_arg == NULL || rsrc_arg[0] == '\0') {
            if (myid == 0) {
                fprintf(stderr,
                    "\n[FATAL][Phase8] --restart=<dir> has empty value.\n"
                    "  Example: --restart=checkpoint/step_1000\n");
            }
            CHECK_MPI( MPI_Barrier(MPI_COMM_WORLD) );
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        g_init_runtime    = 3;
        g_restart_bin_dir = rsrc_arg;
        if (myid == 0) {
            printf("[Phase8] argv override: INIT=3, RESTART_BIN_DIR=\"%s\"\n",
                   g_restart_bin_dir);
        }
    }
    else if (got_cold) {
        g_init_runtime = 0;
        if (myid == 0) {
            printf("[Phase8] argv override: --cold → INIT=0 (cold start)\n");
        }
    }
    else {
        if (myid == 0) {
            printf("[Phase8] No argv flag; using compile-time INIT=%d from variables.h\n",
                   g_init_runtime);
            if (g_init_runtime == 3) {
                printf("[Phase8]   compile-time RESTART_BIN_DIR=\"%s\"\n",
                       g_restart_bin_dir);
            }
        }
    }
}

#endif // RUNTIME_ARGS_H
