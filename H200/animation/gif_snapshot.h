#ifndef GIF_SNAPSHOT_H
#define GIF_SNAPSHOT_H

// ════════════════════════════════════════════════════════════════════════════
// animation/gif_snapshot.h — 模擬自動渲染動畫模組
// ════════════════════════════════════════════════════════════════════════════
//
// 功能：每次 VTK 輸出後，自動渲染 PNG 幀 + 累積組裝 MP4 動畫
//
// 輸出動畫（每 ANIM_EVERY_N_VTK 次 VTK 輸出覆蓋更新）：
//   animation/flow_animation.mp4   — 瞬時 u_streamwise（Path A，全部幀）
//   animation/Umean_animation.mp4  — 時均 U_mean + 流線（Path B，全部幀）
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
//    ANIM_FPS          — MP4 播放幀率（預設 4）
//
//  範例：
//    #define ANIM_ENABLE       1    // 啟用動畫（0=關閉）
//    #define ANIM_EVERY_N_VTK  2    // 每 2 次 VTK 輸出渲染一幀
//    #define ANIM_FPS          6    // MP4 播放 6 fps
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
// 依賴：pvpython, ffmpeg, animation/render_frame.py, animation/build_gif.py
// ════════════════════════════════════════════════════════════════════════════

#include <cstdio>
#include <cstdlib>
#include <sys/stat.h>

// ── 可調參數（用戶可在 #include 之前 #define 覆蓋）──

#ifndef ANIM_ENABLE
#define ANIM_ENABLE       1     // 總開關：1=啟用動畫輸出, 0=完全關閉（不渲染、不組裝）
#endif

#ifndef ANIM_EVERY_N_VTK
#define ANIM_EVERY_N_VTK  1     // 每 N 次 VTK 輸出渲染一幀（1=每次）
#endif

#ifndef ANIM_FPS
#define ANIM_FPS          4     // MP4 播放幀率
#endif


// ────────────────────────────────────────────────────────────────────────────
// §1  AnimRenderAndRebuild — 渲染 PNG + 累積重建 MP4（背景執行）
// ────────────────────────────────────────────────────────────────────────────
//
//  每次 VTK 輸出後呼叫。內部計數器控制每 ANIM_EVERY_N_VTK 次才真正執行。
//
//  一次執行完成：
//    1. pvpython render_frame.py → Path A (frame_XXXXXX.png) + Path B (Umean_XXXXXX.png)
//    2. build_gif.py → flow_animation.mp4 (所有 frame_*.png 累積覆蓋)
//    3. build_gif.py → Umean_animation.mp4 (所有 Umean_*.png 累積覆蓋)
//
//  全部背景執行（subshell &），不阻塞模擬主迴圈
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

    // 建立輸出目錄
    if (stat("animation/gif_frames", &st) != 0) {
        mkdir("animation/gif_frames", 0755);
    }

    printf("[ANIM] Render + rebuild: step=%d (VTK #%d, every %d)\n",
           step, vtk_anim_counter, ANIM_EVERY_N_VTK);

    // 背景 subshell：渲染完成後立刻重建兩個 MP4
    char cmd[1024];
    sprintf(cmd,
        "( "
        "  pvpython animation/render_frame.py %s "
        "    --outdir animation/gif_frames --step %d "
        "    > /dev/null 2>&1 ; "
        "  python3 animation/build_gif.py "
        "    --frames animation/gif_frames "
        "    --pattern 'frame_*.png' "
        "    -o animation/flow_animation.mp4 --fps %d "
        "    > /dev/null 2>&1 ; "
        "  python3 animation/build_gif.py "
        "    --frames animation/gif_frames "
        "    --pattern 'Umean_*.png' "
        "    -o animation/Umean_animation.mp4 --fps %d "
        "    > /dev/null 2>&1 "
        ") &",
        vtk_path, step, ANIM_FPS, ANIM_FPS);

    system(cmd);
}


// ────────────────────────────────────────────────────────────────────────────
// §2  AnimFinalize — 模擬結束時最終組裝（阻塞，確保動畫完成）
// ────────────────────────────────────────────────────────────────────────────
//
//  等待所有背景渲染完成，再做最終 MP4 組裝（阻塞呼叫）
//  放在 final fileIO_velocity_vtk_merged 之後、MPI_Finalize 之前
//
// ────────────────────────────────────────────────────────────────────────────

void AnimFinalize(int step) {
#if !ANIM_ENABLE
    return;
#endif
    if (myid != 0) return;

    printf("[ANIM] Finalizing: waiting for background renders...\n");
    system("wait 2>/dev/null");

    // 最後一幀同步渲染（阻塞，確保包含最終步）
    char vtk_path[256];
    sprintf(vtk_path, "./result/velocity_merged_%06d.vtk", step);

    struct stat st;
    if (stat(vtk_path, &st) == 0) {
        if (stat("animation/gif_frames", &st) != 0) {
            mkdir("animation/gif_frames", 0755);
        }
        char cmd[512];
        sprintf(cmd,
            "pvpython animation/render_frame.py %s "
            "  --outdir animation/gif_frames --step %d "
            "  > /dev/null 2>&1",
            vtk_path, step);
        system(cmd);
    }

    // 最終組裝 — 阻塞模式
    char cmd1[256], cmd2[256];
    sprintf(cmd1,
        "python3 animation/build_gif.py "
        "  --frames animation/gif_frames "
        "  --pattern 'frame_*.png' "
        "  -o animation/flow_animation.mp4 --fps %d", ANIM_FPS);
    sprintf(cmd2,
        "python3 animation/build_gif.py "
        "  --frames animation/gif_frames "
        "  --pattern 'Umean_*.png' "
        "  -o animation/Umean_animation.mp4 --fps %d", ANIM_FPS);

    int ret1 = system(cmd1);
    int ret2 = system(cmd2);

    if (ret1 == 0)
        printf("[ANIM] Final: animation/flow_animation.mp4\n");
    if (ret2 == 0)
        printf("[ANIM] Final: animation/Umean_animation.mp4\n");
    if (ret1 != 0 && ret2 != 0)
        fprintf(stderr, "[ANIM] WARNING: Final MP4 assembly failed\n");
}

#endif // GIF_SNAPSHOT_H
