#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_gif_system.py — GIF 自動化系統單元測試
=============================================

測試流程:
  1. 產生合成 VTK 檔案（模擬 Periodic Hill 流場）
     - test_inst.vtk:  只有瞬時速度 → 測試 Path A
     - test_mean.vtk:  瞬時速度 + U_mean → 測試 Path A + Path B

  2. 對每個 VTK 呼叫 pvpython render_frame.py，檢查輸出 PNG

  3. 呼叫 build_gif.py 組裝 GIF，檢查輸出

用法:
  # 完整測試（需要 pvpython）:
  python3 test_gif_system.py

  # 只產生合成 VTK（不需 pvpython，可先目視檢查）:
  python3 test_gif_system.py --vtk-only

  # 只測試 GIF 組裝（假設 PNG 已存在）:
  python3 test_gif_system.py --gif-only

  # 用既有的真實 VTK 測試渲染:
  python3 test_gif_system.py --real-vtk ./result/velocity_merged_001001.vtk
"""

import os, sys, math, shutil, subprocess

# ════════════════════════════════════════════════════════════════════
# §0  Configuration
# ════════════════════════════════════════════════════════════════════
TEST_DIR = "test_gif"
FRAME_DIR = os.path.join(TEST_DIR, "gif_frames")

# Periodic Hill geometry (simplified Almeida 1993 piecewise polynomial)
# Hill height h = 1.0 (non-dimensional), channel height H = 3.036h
# Domain: y ∈ [0, 9.0], z ∈ [0, H]
LY = 9.0
H_CHANNEL = 3.036   # channel height / hill height
H_HILL = 1.0        # hill height (non-dimensional)

# Grid dimensions matching Edit11: NX=33, NY=129, NZ=65
NX = 33    # spanwise (x in VTK)
NY = 129   # streamwise (y in VTK)
NZ = 65    # wall-normal (z in VTK)

# Spanwise extent
LX = 4.5


def hill_profile(y):
    """
    Periodic Hill 下壁面輪廓 (Almeida et al. 1993, Fröhlich et al. 2005)
    y: streamwise coordinate [0, 9]
    returns: z_wall (wall-normal height of bottom wall)
    """
    # Period = 9.0, hill between y=0..9
    y = y % 9.0

    # Piecewise polynomial (simplified from ERCOFTAC benchmark)
    if y <= 0.0:
        return H_HILL
    elif y <= 0.5 * 9.0 / 8.0:  # ~0.5625 — ascending part near crest
        yy = y / (9.0 / 8.0)
        return H_HILL * min(1.0, max(0, 1.0 - 2.8 * yy * yy))
    elif y <= 1.0 * 9.0 / 8.0:  # ~1.125 — descending slope
        yy = y / (9.0 / 8.0)
        return H_HILL * max(0, 1.0 - 2.8 * yy * yy)
    elif y < 7.0 * 9.0 / 8.0:   # ~7.875 — flat bottom
        return 0.0
    elif y < 8.0 * 9.0 / 8.0:   # ~9.0 — ascending back to hill
        yy = (9.0 - y) / (9.0 / 8.0)
        return H_HILL * max(0, 1.0 - 2.8 * yy * yy)
    else:
        return H_HILL


def generate_synthetic_vtk(filepath, include_Umean=False, step=1000):
    """
    產生合成 Periodic Hill VTK 檔案
    STRUCTURED_GRID ASCII 格式, 與 fileIO.h 輸出結構完全一致
    """
    print("[TEST] Generating: %s (U_mean=%s)" % (filepath, include_Umean))

    npts = NX * NY * NZ
    accu_count = 5000 if include_Umean else 0

    with open(filepath, "w") as f:
        # Header
        f.write("# vtk DataFile Version 3.0\n")
        f.write("LBM Velocity Field (merged) step=%d Force=1.00000000e-04 accu_count=%d\n"
                % (step, accu_count))
        f.write("ASCII\n")
        f.write("DATASET STRUCTURED_GRID\n")
        f.write("DIMENSIONS %d %d %d\n" % (NX, NY, NZ))

        # POINTS (Fröhlich body-fitted grid)
        f.write("POINTS %d double\n" % npts)
        dx = LX / (NX - 1)
        dy = LY / (NY - 1)

        # 建立座標陣列（同時存起來以便後面計算速度場）
        coords = []
        for k in range(NZ):
            for j in range(NY):
                y_val = j * dy
                z_wall = hill_profile(y_val)
                z_top = H_CHANNEL
                # 線性拉伸: z = z_wall + (z_top - z_wall) * k/(NZ-1)
                z_val = z_wall + (z_top - z_wall) * k / (NZ - 1)
                for i in range(NX):
                    x_val = i * dx
                    coords.append((x_val, y_val, z_val))
                    f.write("%.6f %.6f %.6f\n" % (x_val, y_val, z_val))

        # POINT_DATA
        f.write("\nPOINT_DATA %d\n" % npts)

        # VECTORS velocity (u_code/Uref, v_code/Uref, w_code/Uref)
        # 合成 Poiseuille-like profile with hill perturbation
        f.write("VECTORS velocity double\n")
        velocities = []
        for idx in range(npts):
            x, y, z = coords[idx]
            z_wall = hill_profile(y)
            z_top = H_CHANNEL
            # 無因次壁面距離
            eta = (z - z_wall) / (z_top - z_wall) if (z_top - z_wall) > 0.001 else 0

            # 流向速度 (parabolic profile + recirculation behind hill)
            u_stream = 1.5 * 4.0 * eta * (1.0 - eta)
            # 在 hill 背風面 (y ∈ [1, 4]) 加入回流區
            if 1.0 < y < 4.0 and eta < 0.3:
                recir = -0.3 * math.sin(math.pi * (y - 1.0) / 3.0) * (1.0 - eta / 0.3)
                u_stream += recir

            # 法向速度（小擾動）
            w_norm = 0.05 * math.sin(2 * math.pi * y / LY) * math.sin(math.pi * eta)
            # 展向速度（小擾動，紊流模擬）
            v_span = 0.02 * math.sin(4 * math.pi * x / LX) * math.sin(math.pi * eta)

            # VTK velocity = (code_u, code_v, code_w) / Uref
            # code_u = spanwise, code_v = streamwise, code_w = wall-normal
            velocities.append((v_span, u_stream, w_norm))
            f.write("%.15e %.15e %.15e\n" % (v_span, u_stream, w_norm))

        # SCALARS u_inst (streamwise = velocity_Y = code v / Uref)
        f.write("\nSCALARS u_inst double 1\n")
        f.write("LOOKUP_TABLE default\n")
        for idx in range(npts):
            f.write("%.15e\n" % velocities[idx][1])

        # SCALARS v_inst (spanwise = code u / Uref)
        f.write("\nSCALARS v_inst double 1\n")
        f.write("LOOKUP_TABLE default\n")
        for idx in range(npts):
            f.write("%.15e\n" % velocities[idx][0])

        # SCALARS w_inst (wall-normal = code w / Uref)
        f.write("\nSCALARS w_inst double 1\n")
        f.write("LOOKUP_TABLE default\n")
        for idx in range(npts):
            f.write("%.15e\n" % velocities[idx][2])

        # 簡化的渦度 (填零，測試不需要精確渦度)
        for name in ["omega_u", "omega_v", "omega_w"]:
            f.write("\nSCALARS %s double 1\n" % name)
            f.write("LOOKUP_TABLE default\n")
            for idx in range(npts):
                f.write("0.0\n")

        # [C] U_mean, W_mean (only if include_Umean)
        if include_Umean:
            # U_mean: 使用稍微平滑過的流向速度 (模擬時均)
            f.write("\nSCALARS U_mean double 1\n")
            f.write("LOOKUP_TABLE default\n")
            for idx in range(npts):
                x, y, z = coords[idx]
                z_wall = hill_profile(y)
                z_top = H_CHANNEL
                eta = (z - z_wall) / (z_top - z_wall) if (z_top - z_wall) > 0.001 else 0
                u_mean = 1.4 * 4.0 * eta * (1.0 - eta)  # 稍低於瞬時峰值
                if 1.5 < y < 3.5 and eta < 0.2:
                    u_mean += -0.15 * math.sin(math.pi * (y - 1.5) / 2.0) * (1.0 - eta / 0.2)
                f.write("%.15e\n" % u_mean)

            # W_mean
            f.write("\nSCALARS W_mean double 1\n")
            f.write("LOOKUP_TABLE default\n")
            for idx in range(npts):
                x, y, z = coords[idx]
                z_wall = hill_profile(y)
                z_top = H_CHANNEL
                eta = (z - z_wall) / (z_top - z_wall) if (z_top - z_wall) > 0.001 else 0
                w_mean = 0.03 * math.sin(2 * math.pi * y / LY) * math.sin(math.pi * eta)
                f.write("%.15e\n" % w_mean)

    fsize = os.path.getsize(filepath)
    print("[TEST] Written: %s (%.1f MB, %d points)" % (filepath, fsize/1e6, npts))


def check_file(path, label):
    """驗證檔案存在且非空"""
    if os.path.isfile(path) and os.path.getsize(path) > 0:
        size = os.path.getsize(path)
        unit = "KB" if size < 1e6 else "MB"
        val = size/1e3 if size < 1e6 else size/1e6
        print("  [PASS] %s: %s (%.1f %s)" % (label, path, val, unit))
        return True
    else:
        print("  [FAIL] %s: %s NOT FOUND or empty!" % (label, path))
        return False


def find_pvpython():
    """尋找 pvpython 可執行檔"""
    # 嘗試常見路徑
    candidates = ["pvpython", "/usr/bin/pvpython", "/usr/local/bin/pvpython"]
    for c in candidates:
        if shutil.which(c):
            return c
    # 嘗試從 PATH 搜尋
    result = subprocess.run(["which", "pvpython"], capture_output=True, text=True)
    if result.returncode == 0:
        return result.stdout.strip()
    return None


# ════════════════════════════════════════════════════════════════════
# §1  Main Test Runner
# ════════════════════════════════════════════════════════════════════
def main():
    vtk_only = "--vtk-only" in sys.argv
    gif_only = "--gif-only" in sys.argv
    real_vtk = None
    for i, arg in enumerate(sys.argv):
        if arg == "--real-vtk" and i+1 < len(sys.argv):
            real_vtk = sys.argv[i+1]

    all_pass = True

    # ── Setup ──
    if not gif_only:
        if os.path.isdir(TEST_DIR):
            shutil.rmtree(TEST_DIR)
        os.makedirs(FRAME_DIR, exist_ok=True)

    # ════════════════════════════════════════════════════════════════
    # Test 1: 產生合成 VTK
    # ════════════════════════════════════════════════════════════════
    if not gif_only:
        print("\n" + "="*60)
        print("TEST 1: Generate synthetic VTK files")
        print("="*60)

        vtk_inst = os.path.join(TEST_DIR, "velocity_merged_001000.vtk")
        vtk_mean = os.path.join(TEST_DIR, "velocity_merged_002000.vtk")

        generate_synthetic_vtk(vtk_inst, include_Umean=False, step=1000)
        generate_synthetic_vtk(vtk_mean, include_Umean=True,  step=2000)

        all_pass &= check_file(vtk_inst, "Inst-only VTK")
        all_pass &= check_file(vtk_mean, "Inst+Umean VTK")

        if vtk_only:
            print("\n[INFO] --vtk-only: Skipping pvpython and GIF tests.")
            print("[INFO] You can manually test with:")
            print("  pvpython render_frame.py %s --outdir %s --step 1000" % (vtk_inst, FRAME_DIR))
            print("  pvpython render_frame.py %s --outdir %s --step 2000" % (vtk_mean, FRAME_DIR))
            return

    # ════════════════════════════════════════════════════════════════
    # Test 2: pvpython 渲染
    # ════════════════════════════════════════════════════════════════
    if not gif_only:
        print("\n" + "="*60)
        print("TEST 2: pvpython rendering")
        print("="*60)

        pvpython = find_pvpython()
        if pvpython is None:
            print("  [SKIP] pvpython not found on this machine.")
            print("  [INFO] Copy test VTK files to remote server and run:")
            print("    pvpython render_frame.py %s --outdir %s --step 1000" % (vtk_inst, FRAME_DIR))
            print("    pvpython render_frame.py %s --outdir %s --step 2000" % (vtk_mean, FRAME_DIR))
        else:
            print("  pvpython found: %s" % pvpython)

            # 如果指定了真實 VTK，用真實的
            if real_vtk and os.path.isfile(real_vtk):
                vtk_inst = real_vtk
                vtk_mean = real_vtk
                print("  Using real VTK: %s" % real_vtk)

            # Test 2a: Path A only (inst VTK, no U_mean)
            print("\n  --- Test 2a: Path A (instantaneous, no streamlines) ---")
            cmd = [pvpython, "render_frame.py", vtk_inst, "--outdir", FRAME_DIR, "--step", "1000"]
            print("  CMD: " + " ".join(cmd))
            ret = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            print("  stdout:", ret.stdout[-200:] if len(ret.stdout) > 200 else ret.stdout)
            if ret.stderr:
                print("  stderr:", ret.stderr[-200:] if len(ret.stderr) > 200 else ret.stderr)

            png_a = os.path.join(FRAME_DIR, "frame_001000.png")
            all_pass &= check_file(png_a, "Path A PNG (inst)")

            # 確認 Path B 不被產生（inst VTK 無 U_mean）
            png_b_skip = os.path.join(FRAME_DIR, "Umean_001000.png")
            if not os.path.isfile(png_b_skip):
                print("  [PASS] Path B correctly skipped (no U_mean in inst VTK)")
            else:
                print("  [WARN] Path B PNG exists for inst-only VTK — unexpected")

            # Test 2b: Path A + Path B (mean VTK, has U_mean)
            print("\n  --- Test 2b: Path A + B (with U_mean + streamlines) ---")
            cmd = [pvpython, "render_frame.py", vtk_mean, "--outdir", FRAME_DIR, "--step", "2000"]
            print("  CMD: " + " ".join(cmd))
            ret = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
            print("  stdout:", ret.stdout[-300:] if len(ret.stdout) > 300 else ret.stdout)
            if ret.stderr:
                print("  stderr:", ret.stderr[-200:] if len(ret.stderr) > 200 else ret.stderr)

            png_a2 = os.path.join(FRAME_DIR, "frame_002000.png")
            png_b2 = os.path.join(FRAME_DIR, "Umean_002000.png")
            all_pass &= check_file(png_a2, "Path A PNG (mean VTK)")
            all_pass &= check_file(png_b2, "Path B PNG (U_mean + streamlines)")

    # ════════════════════════════════════════════════════════════════
    # Test 3: GIF 組裝
    # ════════════════════════════════════════════════════════════════
    print("\n" + "="*60)
    print("TEST 3: GIF assembly (build_gif.py)")
    print("="*60)

    frame_dir = FRAME_DIR
    if gif_only:
        frame_dir = "gif_frames"  # use existing

    # 檢查是否有 PNG 幀
    import glob
    pngs = sorted(glob.glob(os.path.join(frame_dir, "frame_*.png")))
    if not pngs:
        print("  [SKIP] No PNG frames found in %s" % frame_dir)
        print("  [INFO] Run pvpython first to generate frames")
    else:
        print("  Found %d frames in %s" % (len(pngs), frame_dir))
        gif_out = os.path.join(TEST_DIR, "test_animation.gif")
        cmd = [sys.executable, "build_gif.py",
               "--frames", frame_dir, "-o", gif_out, "--fps", "2"]
        print("  CMD: " + " ".join(cmd))
        ret = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        print("  stdout:", ret.stdout.strip())
        if ret.stderr:
            print("  stderr:", ret.stderr.strip())
        all_pass &= check_file(gif_out, "Animated GIF")

    # ════════════════════════════════════════════════════════════════
    # Summary
    # ════════════════════════════════════════════════════════════════
    print("\n" + "="*60)
    if all_pass:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED — check output above")
    print("="*60)

    # 列出所有產生的檔案
    print("\nGenerated files:")
    for root, dirs, files in os.walk(TEST_DIR):
        for fn in sorted(files):
            fp = os.path.join(root, fn)
            sz = os.path.getsize(fp)
            unit = "KB" if sz < 1e6 else "MB"
            val = sz/1e3 if sz < 1e6 else sz/1e6
            print("  %s  (%.1f %s)" % (fp, val, unit))


if __name__ == "__main__":
    main()
