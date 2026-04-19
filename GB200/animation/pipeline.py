#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pipeline.py — 單步影片生成 orchestrator
==========================================

流程：
  1. pvbatch render_frame.py <vtk> --video-mode
     → 產生 frame_NNNNNN_cont.png + frame_NNNNNN_RD.png（僅 2 張）
  2. video_append.py 把兩張 PNG 加進各自的 GIF
  3. 刪除本步產生的所有 PNG（含 Umean/TKE/Qcrit 殘留，保險起見）

Usage:
  python3 pipeline.py <vtk_file> <step>
  python3 pipeline.py ../result/velocity_merged_10356001.vtk 10356001

Env / args:
  --pvbatch PATH       指定 pvbatch（預設 auto-detect）
  --width N            GIF 寬 (3840 = 4K)
  --fps F              播放 fps
  --max-frames N       滾動視窗
  --rebuild-every N    palette 重建頻率
"""
import os
import sys
import glob
import shutil
import argparse
import subprocess


def find_pvbatch():
    """找 pvbatch，依序：PATH / 常見安裝位置。"""
    env = os.environ.get("PVBATCH")
    if env and os.path.isfile(env):
        return env
    w = shutil.which("pvbatch")
    if w:
        return w
    for cand in [
        r"C:\Program Files\ParaView 5.13.3\bin\pvbatch.exe",
        r"C:\Program Files\ParaView 5.13.0\bin\pvbatch.exe",
        r"C:\Program Files\ParaView 5.12.0\bin\pvbatch.exe",
        "/usr/bin/pvbatch",
        "/usr/local/bin/pvbatch",
        "/opt/paraview/bin/pvbatch",
    ]:
        if os.path.isfile(cand):
            return cand
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vtk", help="VTK file path")
    ap.add_argument("step", type=int, help="Step number")
    ap.add_argument("--frames-dir", default=None,
                    help="PNG temp dir (default: <script_dir>/gif_frames)")
    ap.add_argument("--gif-cont", default=None,
                    help="Output GIF for frame_cont series (default: <script_dir>/flow_cont.gif)")
    ap.add_argument("--gif-rd", default=None,
                    help="Output GIF for frame_RD series   (default: <script_dir>/flow_RD.gif)")
    ap.add_argument("--width", type=int, default=3840)
    ap.add_argument("--fps", type=float, default=4)
    ap.add_argument("--last-pause-ms", type=int, default=2000)
    ap.add_argument("--max-frames", type=int, default=10000)
    ap.add_argument("--rebuild-every", type=int, default=50)
    ap.add_argument("--pvbatch", default=None)
    ap.add_argument("--keep-pngs", action="store_true",
                    help="Do NOT delete PNGs after GIF append (debug).")
    args = ap.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    frames_dir = args.frames_dir or os.path.join(script_dir, "gif_frames")
    gif_cont = args.gif_cont or os.path.join(script_dir, "flow_cont.gif")
    gif_rd = args.gif_rd or os.path.join(script_dir, "flow_RD.gif")

    os.makedirs(frames_dir, exist_ok=True)

    pvbatch = args.pvbatch or find_pvbatch()
    if pvbatch is None:
        print("[pipeline] ERROR: pvbatch not found. Set --pvbatch or $PVBATCH.",
              flush=True)
        sys.exit(1)
    print("[pipeline] pvbatch: %s" % pvbatch, flush=True)

    if not os.path.isfile(args.vtk):
        print("[pipeline] ERROR: VTK not found: %s" % args.vtk, flush=True)
        sys.exit(1)

    # ── Step 1: 渲染（video-mode 只吐 2 張）──
    print("[pipeline] rendering: step=%d  vtk=%s" % (args.step, args.vtk), flush=True)
    render_script = os.path.join(script_dir, "render_frame.py")
    cmd = [pvbatch, render_script, args.vtk,
           "--outdir", frames_dir, "--step", str(args.step), "--video-mode"]
    r = subprocess.run(cmd)
    if r.returncode != 0:
        print("[pipeline] ERROR: render_frame.py failed (rc=%d)" % r.returncode,
              flush=True)
        sys.exit(2)

    # ── Step 2: Append 到兩個 GIF ──
    png_cont = os.path.join(frames_dir, "frame_%06d_cont.png" % args.step)
    png_rd = os.path.join(frames_dir, "frame_%06d_RD.png" % args.step)

    for name, png, gif in [("cont", png_cont, gif_cont),
                           ("RD",   png_rd,   gif_rd)]:
        if not os.path.isfile(png):
            print("[pipeline] ERROR: %s not produced by render" % png, flush=True)
            sys.exit(3)

        print("[pipeline] append %s -> %s" % (name, gif), flush=True)
        append_script = os.path.join(script_dir, "video_append.py")
        cmd = [sys.executable, append_script,
               "--gif", gif,
               "--frame", png,
               "--step", str(args.step),
               "--width", str(args.width),
               "--fps", str(args.fps),
               "--last-pause-ms", str(args.last_pause_ms),
               "--max-frames", str(args.max_frames),
               "--rebuild-interval", str(args.rebuild_every)]
        r = subprocess.run(cmd)
        if r.returncode != 0:
            print("[pipeline] ERROR: video_append failed for %s (rc=%d)"
                  % (gif, r.returncode), flush=True)
            sys.exit(4)

    # ── Step 3: 清除本步所有 PNG（保留 GIF 即可）──
    if not args.keep_pngs:
        patterns = [
            "frame_%06d*.png" % args.step,
            "Umean_%06d*.png" % args.step,
            "TKE_%06d*.png"   % args.step,
            "Qcrit_%06d*.png" % args.step,
        ]
        n_removed = 0
        for p in patterns:
            for f in glob.glob(os.path.join(frames_dir, p)):
                try:
                    os.remove(f); n_removed += 1
                except OSError:
                    pass
        print("[pipeline] cleanup: removed %d PNG" % n_removed, flush=True)

    print("[pipeline] step=%d done" % args.step, flush=True)


if __name__ == "__main__":
    main()
