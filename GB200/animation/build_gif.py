#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_gif.py — 組裝 pvpython 渲染的 PNG 幀為動畫
=================================================

用法:
  python3 build_gif.py                                    # MP4 (預設，全彩無損)
  python3 build_gif.py --format gif                       # 強制 GIF
  python3 build_gif.py --frames gif_frames --fps 4        # 指定目錄和幀率
  python3 build_gif.py -o flow_animation.mp4              # 指定輸出檔名

優先順序：ffmpeg MP4 → Pillow GIF → ImageMagick GIF
  MP4：全彩、高解析度、檔案小（推薦）
  GIF：256 色限制，大檔案會有色階壓縮
"""

import os
import sys
import glob
import argparse
import subprocess
import shutil


def build_mp4_ffmpeg(files, output, fps, last_pause_ms):
    """用 ffmpeg 組裝 MP4 — 全彩無損，檔案小"""
    if not shutil.which("ffmpeg"):
        return False

    # 建立暫時的檔案列表（ffmpeg concat demuxer 格式）
    listfile = output + ".filelist.txt"
    frame_dur = 1.0 / fps
    last_dur = frame_dur + last_pause_ms / 1000.0

    with open(listfile, "w") as f:
        for i, path in enumerate(files):
            abspath = os.path.abspath(path)
            dur = last_dur if i == len(files) - 1 else frame_dur
            f.write("file '%s'\n" % abspath)
            f.write("duration %.4f\n" % dur)
        # ffmpeg concat 需要最後一幀重複一次
        f.write("file '%s'\n" % os.path.abspath(files[-1]))

    cmd = [
        "ffmpeg", "-y",
        "-f", "concat", "-safe", "0", "-i", listfile,
        "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",  # 確保偶數解析度
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
        "-crf", "18",          # 高品質 (0=lossless, 23=default, 18=visually lossless)
        "-preset", "slow",     # 壓縮效率
        "-movflags", "+faststart",
        output
    ]
    print("[build_gif] Running ffmpeg: %s" % " ".join(cmd[:6]))
    ret = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    # 清理暫存
    try:
        os.remove(listfile)
    except:
        pass

    if ret.returncode == 0:
        fsize = os.path.getsize(output) / (1024 * 1024)
        print("[build_gif] MP4 saved: %s (%d frames, %.1f MB, %d fps)"
              % (output, len(files), fsize, fps))
        return True
    else:
        err = ret.stderr.decode("utf-8", errors="replace")[-500:] if ret.stderr else "unknown"
        print("[build_gif] ffmpeg failed: %s" % err)
        return False


def build_gif_pillow(files, output, fps, last_pause_ms):
    """用 Pillow 組裝 GIF"""
    try:
        from PIL import Image
    except ImportError:
        return False

    frame_duration = int(1000.0 / fps)
    images = []
    for f in files:
        img = Image.open(f).convert("RGBA")
        bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
        bg.paste(img, mask=img.split()[3])
        rgb = bg.convert("RGB")
        # 用較好的量化方法保留色階細節
        images.append(rgb.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG))

    if not images:
        return False

    durations = [frame_duration] * len(images)
    durations[-1] = frame_duration + last_pause_ms

    images[0].save(
        output,
        save_all=True,
        append_images=images[1:],
        duration=durations,
        loop=0,
        optimize=False
    )
    fsize = os.path.getsize(output) / (1024 * 1024)
    print("[build_gif] GIF saved: %s (%d frames, %.1f MB, %d ms/frame)"
          % (output, len(images), fsize, frame_duration))
    return True


def build_gif_imagemagick(files, output, fps, last_pause_ms):
    """用 ImageMagick 組裝 GIF"""
    if not shutil.which("convert"):
        return False
    delay_cs = max(1, int(100.0 / fps))
    cmd = "convert -delay %d -loop 0 %s %s" % (delay_cs, " ".join(files), output)
    ret = os.system(cmd)
    if ret == 0:
        fsize = os.path.getsize(output) / (1024 * 1024)
        print("[build_gif] GIF saved (ImageMagick): %s (%.1f MB)" % (output, fsize))
        return True
    return False


def main():
    parser = argparse.ArgumentParser(description="Assemble PNG frames into animation")
    parser.add_argument("--frames", default="gif_frames",
                        help="Directory containing frame_XXXXXX.png files")
    parser.add_argument("-o", "--output", default=None,
                        help="Output filename (auto-detected extension)")
    parser.add_argument("--fps", type=float, default=4,
                        help="Frames per second (default: 4)")
    parser.add_argument("--format", choices=["mp4", "gif", "auto"], default="auto",
                        help="Output format: mp4 (推薦), gif, or auto (default: auto)")
    parser.add_argument("--pattern", default="frame_*.png",
                        help="Glob pattern for PNG files (default: frame_*.png)")
    parser.add_argument("--last-frame-pause", type=int, default=2000,
                        help="Extra pause on last frame in ms (default: 2000)")
    args = parser.parse_args()

    # 搜尋 PNG 幀
    pattern = os.path.join(args.frames, args.pattern)
    files = sorted(glob.glob(pattern))
    if not files:
        print("[build_gif] No PNG frames found in %s" % args.frames)
        sys.exit(0)

    print("[build_gif] Found %d frames in %s" % (len(files), args.frames))

    # 決定輸出格式和檔名
    fmt = args.format
    if fmt == "auto":
        fmt = "mp4" if shutil.which("ffmpeg") else "gif"

    if args.output:
        output = args.output
    else:
        output = "flow_animation.mp4" if fmt == "mp4" else "flow_animation.gif"

    # 執行
    if fmt == "mp4":
        if build_mp4_ffmpeg(files, output, args.fps, args.last_frame_pause):
            return
        print("[build_gif] MP4 failed, falling back to GIF...")
        output = output.replace(".mp4", ".gif")

    if build_gif_pillow(files, output, args.fps, args.last_frame_pause):
        return

    if build_gif_imagemagick(files, output, args.fps, args.last_frame_pause):
        return

    print("[build_gif] ERROR: All methods failed.")
    print("[build_gif] Install ffmpeg (推薦) or Pillow: pip install Pillow")
    sys.exit(1)


if __name__ == "__main__":
    main()
