#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
video_append.py — 把單張 PNG 以 streaming 模式加進既有 GIF
===========================================================

設計目標
--------
* **記憶體安全**：用 generator 逐幀讀寫，任何時點 RAM 只持有 1-2 張幀
  （支援 10000 幀 × 4K 而不爆）
* **4K 輸出**：預設寬 3840（高度依原比例自動算，強制偶數）
* **Rolling window**：超過 --max-frames 自動丟最舊幀
* **Palette rebuild**：每 --rebuild-interval 幀做一次全量 palette 重建，
  抵消長 GIF 的調色盤漂移；其他時間也重新量化所有幀（因為 Pillow 寫 GIF
  無真正 in-place append，每次都得重寫整檔）
* **狀態追蹤**：`<gif>.state.json` 記錄已加入的 step list，
  重複呼叫（續跑情境）會自動偵測並 skip

Usage
-----
  python3 video_append.py \\
      --gif   flow_cont.gif \\
      --frame gif_frames/frame_010356001_cont.png \\
      --step  10356001 \\
      [--width 3840] [--fps 4] [--last-pause-ms 2000] \\
      [--max-frames 10000] [--rebuild-interval 50] [--force-rebuild]

Exit codes
----------
  0 成功（含 skip 重複 step）
  1 輸入檔缺失
  2 GIF 寫入失敗
"""
import os
import sys
import json
import argparse
import tempfile
from PIL import Image

# Pillow 版本相容
try:
    _MEDIANCUT = Image.Quantize.MEDIANCUT
    _DITHER_FS = Image.Dither.FLOYDSTEINBERG
    _RESAMPLE_LANCZOS = Image.Resampling.LANCZOS
except AttributeError:
    _MEDIANCUT = Image.MEDIANCUT
    _DITHER_FS = Image.FLOYDSTEINBERG
    _RESAMPLE_LANCZOS = Image.LANCZOS


def state_path(gif_path):
    return gif_path + ".state.json"


def load_state(gif_path):
    sp = state_path(gif_path)
    if os.path.exists(sp):
        try:
            with open(sp, "r") as f:
                s = json.load(f)
                s.setdefault("steps", [])
                s.setdefault("width", None)
                return s
        except Exception:
            pass
    return {"steps": [], "width": None}


def save_state(gif_path, state):
    sp = state_path(gif_path)
    tmp = sp + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, sp)


def resize_to_width(img, target_width):
    """保持比例縮放到 target_width；高度強制偶數（影片/GIF 友善）。"""
    w, h = img.size
    if w == target_width:
        return img
    target_h = int(round(h * target_width / w))
    if target_h % 2 != 0:
        target_h += 1
    return img.resize((target_width, target_h), _RESAMPLE_LANCZOS)


def quantize(img_rgb):
    """RGB → 256 色 adaptive palette + Floyd-Steinberg dithering。"""
    return img_rgb.quantize(colors=256, method=_MEDIANCUT, dither=_DITHER_FS)


def iter_old_gif_frames(gif_path, target_width, skip_first=0):
    """Stream-read 既有 GIF 的幀；每幀 resize 到 target_width。
    skip_first: rolling window 用 — 跳過最舊的 N 幀。"""
    if not os.path.exists(gif_path):
        return
    try:
        with Image.open(gif_path) as gif:
            i = 0
            while True:
                if i >= skip_first:
                    rgb = gif.convert("RGB")
                    yield resize_to_width(rgb, target_width)
                try:
                    gif.seek(gif.tell() + 1)
                    i += 1
                except EOFError:
                    break
    except Exception as e:
        print("[video_append] WARN: failed reading existing GIF (%s); "
              "treating as new." % str(e), flush=True)
        return


def main():
    ap = argparse.ArgumentParser(description="Append 1 PNG to a GIF (streaming, 4K, rolling window).")
    ap.add_argument("--gif", required=True, help="Target GIF path (created if absent).")
    ap.add_argument("--frame", required=True, help="New PNG frame to append.")
    ap.add_argument("--step", type=int, required=True, help="Step number (for dedup / state).")
    ap.add_argument("--width", type=int, default=3840, help="Output width in px (default 3840 = 4K).")
    ap.add_argument("--fps", type=float, default=4, help="Playback fps (default 4).")
    ap.add_argument("--last-pause-ms", type=int, default=2000, help="Extra pause on last frame (ms).")
    ap.add_argument("--max-frames", type=int, default=10000, help="Rolling window cap (default 10000).")
    ap.add_argument("--rebuild-interval", type=int, default=50,
                    help="Full palette rebuild every N frames (default 50). "
                         "目前實作每次都重寫全檔 — 此參數僅影響 log 標記。")
    ap.add_argument("--force-rebuild", action="store_true",
                    help="Mark this write as REBUILT in log (diagnostic).")
    args = ap.parse_args()

    # 輸入檢查
    if not os.path.isfile(args.frame):
        print("[video_append] ERROR: frame not found: %s" % args.frame, flush=True)
        sys.exit(1)

    # 載入狀態
    state = load_state(args.gif)

    # 重複 step → skip
    if args.step in state["steps"]:
        print("[video_append] step=%d already in %s (frames=%d), skip"
              % (args.step, args.gif, len(state["steps"])), flush=True)
        sys.exit(0)

    # 寬度改變 → 視為重建（state 既有幀數以 state["steps"] 為準，
    # 但檔案內幀數可能對不上，我們一樣以 state 為準）
    prev_width = state.get("width")
    width_changed = (prev_width is not None and prev_width != args.width)

    n_old = len(state["steps"])
    n_total_target = n_old + 1
    # Rolling window：丟掉最舊 N 幀
    skip_old = max(0, n_total_target - args.max_frames)

    n_output = min(n_total_target, args.max_frames)

    # Palette rebuild 標記（僅用於 log；實際每次都重寫）
    mode_tag = "REBUILT_PALETTE" if (args.force_rebuild or
                                     width_changed or
                                     n_output % args.rebuild_interval == 0 or
                                     n_output == 1) else "append"

    # 逐幀 generator：既有 GIF 幀（skip 舊的）+ 新 PNG
    def all_frames_iter():
        for f in iter_old_gif_frames(args.gif, args.width, skip_first=skip_old):
            yield f
        new_img = Image.open(args.frame).convert("RGB")
        yield resize_to_width(new_img, args.width)

    # 取首幀
    gen = all_frames_iter()
    try:
        first_rgb = next(gen)
    except StopIteration:
        print("[video_append] ERROR: no frames available", flush=True)
        sys.exit(2)

    first_q = quantize(first_rgb)

    # 其餘幀：lazy generator 逐幀量化
    rest_q = (quantize(f) for f in gen)

    # Duration：每幀統一，最後一幀延長
    frame_ms = int(round(1000.0 / args.fps))
    durations = [frame_ms] * n_output
    if n_output >= 1:
        durations[-1] = frame_ms + args.last_pause_ms

    # 原子寫：tmp -> rename（明確指定 format='GIF'，因 .tmp 副檔名 Pillow 認不得）
    tmp_path = args.gif + ".tmp"
    try:
        first_q.save(
            tmp_path,
            format='GIF',
            save_all=True,
            append_images=rest_q,
            duration=durations,
            loop=0,
            optimize=True,
            disposal=2,  # 每幀用自身像素覆蓋（避免 transparent 殘影）
        )
    except Exception as e:
        print("[video_append] ERROR writing GIF: %s" % str(e), flush=True)
        try:
            os.remove(tmp_path)
        except Exception:
            pass
        sys.exit(2)

    os.replace(tmp_path, args.gif)

    # 更新 state
    new_steps = list(state["steps"])
    if skip_old > 0:
        new_steps = new_steps[skip_old:]
    new_steps.append(args.step)
    state["steps"] = new_steps
    state["width"] = args.width
    save_state(args.gif, state)

    sz_mb = os.path.getsize(args.gif) / (1024.0 * 1024.0)
    print("[video_append] %s: step=%d, frames=%d, size=%.2f MB, width=%d, mode=%s"
          % (args.gif, args.step, n_output, sz_mb, args.width, mode_tag),
          flush=True)


if __name__ == "__main__":
    main()
