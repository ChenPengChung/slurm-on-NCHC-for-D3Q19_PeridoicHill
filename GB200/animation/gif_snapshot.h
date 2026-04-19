#ifndef GIF_SNAPSHOT_H
#define GIF_SNAPSHOT_H

// ════════════════════════════════════════════════════════════════════════════
// animation/gif_snapshot.h — 模擬自動渲染動畫模組 (v2: 4K GIF streaming append)
// ════════════════════════════════════════════════════════════════════════════
//
// 功能：每次 VTK 輸出後，背景呼叫 animation/pipeline.py —
//       渲染 2 張 PNG → append 到 2 個 4K GIF → 銷毀 PNG（節省磁碟）
//
// 輸出動畫（incremental：每幀直接加到既有 GIF，不重做整支影片）：
//   animation/flow_cont.gif   — 瞬時 u_streamwise KEY_COLORS 連續色階
//   animation/flow_RD.gif     — 瞬時 u_streamwise Rainbow Desaturated step 33
//
// 每個 GIF 旁邊會有 `<gif>.state.json` 追蹤已加入的 step 清單（續跑安全）
//
// ════════════════════════════════════════════════════════════════════════════
//
//  可調參數（在 main.cu 的 #include 之前 #define 即可覆蓋預設值）：
//
//    ANIM_ENABLE       — 總開關：1=啟用, 0=完全關閉（預設 1）
//
//    ANIM_EVERY_N_VTK  — 每 N 次 VTK 輸出渲染一幀（預設 1 = 每次都渲染）
//                        例：NDTVTK=1000, ANIM_EVERY_N_VTK=3
//                        → 每 3000 步渲染一幀
//
//    ANIM_FPS          — GIF 播放幀率（預設 4）
//
//    ANIM_WIDTH        — GIF 解析度寬度（預設 3840 = 4K，高度依比例自動算）
//
//    ANIM_MAX_FRAMES   — Rolling window 上限（預設 10000，超過丟最舊幀）
//
//    ANIM_REBUILD_EVERY — 每 N 幀做一次 palette rebuild 標記（預設 50）
//
//    ANIM_LOG          — log 檔名（預設 "animation/anim_log.txt"）
//
//  範例：
//    #define ANIM_ENABLE       1
//    #define ANIM_EVERY_N_VTK  2     // 每 2 次 VTK 輸出 = 1 幀
//    #define ANIM_FPS          6
//    #define ANIM_MAX_FRAMES   500   // 只保留最後 500 幀
//    #include "animation/gif_snapshot.h"
//
// ════════════════════════════════════════════════════════════════════════════
//
// 整合方式 (main.cu):
//
//   // （可選）在 include 之前覆蓋預設參數
//   #define ANIM_EVERY_N_VTK  2
//   #define ANIM_FPS          4
//   #include "animation/gif_snapshot.h"
//
//   在 VTK 輸出段 fileIO_velocity_vtk_merged(step) 之後:
//     AnimRenderAndRebuild(step);
//
//   模擬結束後（final VTK 之後）:
//     AnimFinalize(step);
//
// 依賴：pvbatch (ParaView 5.12+), python3, PIL (Pillow)
//       檔案：animation/render_frame.py, animation/video_append.py,
//            animation/pipeline.py
// ════════════════════════════════════════════════════════════════════════════

#include <cstdio>
#include <cstdlib>
#include <sys/stat.h>

// ── 可調參數（用戶可在 #include 之前 #define 覆蓋）──

#ifndef ANIM_ENABLE
#define ANIM_ENABLE        1      // 總開關：1=啟用動畫輸出, 0=完全關閉
#endif

#ifndef ANIM_EVERY_N_VTK
#define ANIM_EVERY_N_VTK   1      // 每 N 次 VTK 輸出渲染一幀（1=每次）
#endif

#ifndef ANIM_FPS
#define ANIM_FPS           4      // GIF 播放幀率
#endif

#ifndef ANIM_WIDTH
#define ANIM_WIDTH         3840   // GIF 寬度（像素），4K 預設
#endif

#ifndef ANIM_MAX_FRAMES
#define ANIM_MAX_FRAMES    10000  // Rolling window 上限
#endif

#ifndef ANIM_REBUILD_EVERY
#define ANIM_REBUILD_EVERY 50     // 每 N 幀做一次 palette rebuild 標記
#endif

#ifndef ANIM_LOG
#define ANIM_LOG           "animation/anim_log.txt"
#endif


// ────────────────────────────────────────────────────────────────────────────
// §1  AnimRenderAndRebuild — 單步渲染 + append（背景執行，不阻塞主迴圈）
// ────────────────────────────────────────────────────────────────────────────
//
//  每次 VTK 輸出後呼叫。內部計數器控制每 ANIM_EVERY_N_VTK 次才真正執行。
//
//  一次執行完成（由 pipeline.py 包辦）：
//    1. pvbatch render_frame.py --video-mode
//       → gif_frames/frame_NNNNNN_cont.png
//       → gif_frames/frame_NNNNNN_RD.png
//    2. video_append.py → flow_cont.gif 加入新幀（重寫 GIF）
//    3. video_append.py → flow_RD.gif   加入新幀
//    4. rm gif_frames/*.png  (本步驟 PNG 銷毀)
//
//  背景 subshell (&)，不阻塞模擬。輸出重導向至 ANIM_LOG 方便 debug。
//
// ────────────────────────────────────────────────────────────────────────────

void AnimRenderAndRebuild(int step) {
#if !ANIM_ENABLE
    return;
#endif
    if (myid != 0) return;

    // 計數器：每 ANIM_EVERY_N_VTK 次 VTK 輸出才渲染
    static int vtk_anim_counter = 0;
    vtk_anim_counter++;
    if (vtk_anim_counter % ANIM_EVERY_N_VTK != 0) {
        return;  // 跳過此次
    }

    // 確認 VTK 檔案存在
    char vtk_path[256];
    sprintf(vtk_path, "./result/velocity_merged_%06d.vtk", step);

    struct stat st;
    if (stat(vtk_path, &st) != 0) {
        fprintf(stderr, "[ANIM] WARNING: VTK not found: %s (skip)\n", vtk_path);
        return;
    }

    // 建立輸出目錄（pipeline.py 也會建，但這裡先建保險）
    if (stat("animation/gif_frames", &st) != 0) {
        mkdir("animation/gif_frames", 0755);
    }

    printf("[ANIM] Pipeline: step=%d (VTK #%d, every %d)\n",
           step, vtk_anim_counter, ANIM_EVERY_N_VTK);

    // 背景呼叫 pipeline.py（VTK → 2 PNG → append 2 GIF → 清 PNG）
    char cmd[1024];
    sprintf(cmd,
        "( python3 animation/pipeline.py %s %d "
        "    --width %d --fps %d --max-frames %d --rebuild-every %d "
        "    >> %s 2>&1 ) &",
        vtk_path, step,
        ANIM_WIDTH, ANIM_FPS, ANIM_MAX_FRAMES, ANIM_REBUILD_EVERY,
        ANIM_LOG);

    system(cmd);
}


// ────────────────────────────────────────────────────────────────────────────
// §2  AnimFinalize — 模擬結束前等背景任務收尾（阻塞）
// ────────────────────────────────────────────────────────────────────────────
//
//  新架構下，每一步 append 都是 final rebuild（incremental），
//  所以 Finalize 只需：
//    1. 等所有背景 pipeline.py 跑完（避免被 MPI_Finalize 提早 kill）
//    2. 最後一步同步呼叫 pipeline.py（阻塞，確保包含最終 VTK 幀）
//
//  放在 final fileIO_velocity_vtk_merged 之後、MPI_Finalize 之前。
//
// ────────────────────────────────────────────────────────────────────────────

void AnimFinalize(int step) {
#if !ANIM_ENABLE
    return;
#endif
    if (myid != 0) return;

    printf("[ANIM] Finalizing: waiting for background pipelines...\n");
    // wait 是 bash builtin，在 subshell 環境下可能不 portable；改用 sleep 小保險 + wait
    system("wait 2>/dev/null; sleep 2");

    // 最後一幀同步呼叫 pipeline.py（阻塞，不加 & 背景）
    char vtk_path[256];
    sprintf(vtk_path, "./result/velocity_merged_%06d.vtk", step);

    struct stat st;
    if (stat(vtk_path, &st) == 0) {
        char cmd[1024];
        sprintf(cmd,
            "python3 animation/pipeline.py %s %d "
            "  --width %d --fps %d --max-frames %d --rebuild-every %d "
            "  >> %s 2>&1",
            vtk_path, step,
            ANIM_WIDTH, ANIM_FPS, ANIM_MAX_FRAMES, ANIM_REBUILD_EVERY,
            ANIM_LOG);
        int rc = system(cmd);
        if (rc == 0) {
            printf("[ANIM] Final frame appended: step=%d\n", step);
            printf("[ANIM] GIFs:\n");
            printf("         animation/flow_cont.gif\n");
            printf("         animation/flow_RD.gif\n");
        } else {
            fprintf(stderr, "[ANIM] WARNING: Final pipeline.py exit code %d\n", rc);
            fprintf(stderr, "         See %s for details.\n", ANIM_LOG);
        }
    } else {
        fprintf(stderr, "[ANIM] Finalize skip: final VTK not found: %s\n", vtk_path);
    }
}

#endif // GIF_SNAPSHOT_H
