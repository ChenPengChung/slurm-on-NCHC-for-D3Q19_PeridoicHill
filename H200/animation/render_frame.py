# -*- coding: utf-8 -*-
"""
pvpython 離線渲染：YZ 中間剖面 Contour (+ optional streamlines for U_mean)
===========================================================================
用法：
  pvpython render_frame.py [vtk_file] [--outdir gif_frames] [--step 1000]

  若不指定 vtk_file，自動搜尋 result/ 中最新的 velocity_merged_*.vtk

功能：
  Path A (GIF frame):  u_streamwise 瞬時等值面, 無流線, 白底, 帶尺規 → PNG
  Path B (Mean field):  若 VTK 含 U_mean, 用平均速度向量畫流線 → 另一 PNG

色標、色階、字體、尺規完全沿用 7.paraview_contour.py 設定。
"""
import os, sys, glob, math

# ═══════════════════════════════════════════════════════════════════
# §0  引數解析
# ═══════════════════════════════════════════════════════════════════
VTK_FILE = None
OUTDIR = "gif_frames"
STEP_NUM = None

args = sys.argv[1:]
i = 0
while i < len(args):
    if args[i] == "--outdir" and i+1 < len(args):
        OUTDIR = args[i+1]; i += 2
    elif args[i] == "--step" and i+1 < len(args):
        STEP_NUM = int(args[i+1].rstrip('.')); i += 2
    elif not args[i].startswith("--"):
        VTK_FILE = os.path.abspath(args[i]); i += 1
    else:
        i += 1

if VTK_FILE is None:
    # 自動搜尋最新 VTK 檔案
    search_dirs = ["result", "../result", "."]
    for d in search_dirs:
        pattern = os.path.join(d, "velocity_merged_*.vtk")
        matches = sorted(glob.glob(pattern))
        if matches:
            VTK_FILE = os.path.abspath(matches[-1])
            print("Auto-detected latest VTK: " + VTK_FILE)
            break
    if VTK_FILE is None:
        print("ERROR: No VTK file specified and none found in result/.")
        print("Usage: pvpython render_frame.py [vtk_file]")
        sys.exit(1)

if not os.path.isfile(VTK_FILE):
    print("ERROR: VTK file not found: " + VTK_FILE)
    sys.exit(1)

if not os.path.isdir(OUTDIR):
    os.makedirs(OUTDIR)

if STEP_NUM is not None:
    OUT_INST      = os.path.join(OUTDIR, "frame_%06d.png" % STEP_NUM)
    OUT_INST_CONT = os.path.join(OUTDIR, "frame_%06d_cont.png" % STEP_NUM)
    OUT_MEAN      = os.path.join(OUTDIR, "Umean_%06d.png" % STEP_NUM)
    OUT_MEAN_CONT = os.path.join(OUTDIR, "Umean_%06d_cont.png" % STEP_NUM)
    OUT_TKE_CONT  = os.path.join(OUTDIR, "TKE_%06d_cont.png" % STEP_NUM)
    OUT_QCRIT     = os.path.join(OUTDIR, "Qcrit_%06d.png" % STEP_NUM)
else:
    base = os.path.splitext(os.path.basename(VTK_FILE))[0]
    OUT_INST      = os.path.join(OUTDIR, base + "_inst.png")
    OUT_INST_CONT = os.path.join(OUTDIR, base + "_inst_cont.png")
    OUT_MEAN      = os.path.join(OUTDIR, base + "_Umean.png")
    OUT_MEAN_CONT = os.path.join(OUTDIR, base + "_Umean_cont.png")
    OUT_TKE_CONT  = os.path.join(OUTDIR, base + "_TKE_cont.png")
    OUT_QCRIT     = os.path.join(OUTDIR, base + "_Qcrit.png")

# ═══════════════════════════════════════════════════════════════════
# §1  渲染參數（完全沿用 7.paraview_contour.py）
# ═══════════════════════════════════════════════════════════════════
IMAGE_W, IMAGE_H = 2800, 800      # 排版尺寸（決定元素位置，不要改）
SAVE_SCALE = 2                     # 輸出倍率：2x → 5600×1600 實際像素
SAVE_W, SAVE_H = IMAGE_W * SAVE_SCALE, IMAGE_H * SAVE_SCALE

NUM_MAIN_SEEDS = 10
VORTEX_LOW_PERCENTILE = 12
MAX_VORTEX_SEEDS = 50
MAX_STREAMLINE_LEN = 20.0
SEED_STEP = 0.015
MAX_STEPS = 6000
STREAMLINE_WIDTH_MAIN = 2.8
STREAMLINE_WIDTH_VORTEX = 1.5

# ── Q-criterion 參數（對齊 4.Q-criterion_Animation.py 參考範本）──
Q_AUTO_FRACTION = 0.05            # 初始 Q_threshold = Qmax * 5%
Q_CELLS_TARGET_LO = 20000         # 目標下限（參考範本 TARGET_CELLS_MIN）
Q_CELLS_TARGET_HI = 80000         # 目標上限（參考範本 TARGET_CELLS_MAX）
Q_IMG_W, Q_IMG_H = 1920, 1080     # 與參考範本 IMG_SIZE 一致 (16:9)
Q_OPACITY = 0.8                   # 與參考範本 OPACITY 一致
W_RANGE = [-0.02, 0.02]           # 與參考範本 W_RANGE 一致（固定範圍，不做對稱重縮）

# ── FTT / Ma 文字標註用常數（對齊參考範本）──
Q_U_REF       = 0.0583
Q_LY          = 9.0
Q_CS          = 1.0 / 1.732050807568877
Q_DT_GLOBAL   = 2.397914e-03

KEY_COLORS = [
    (0.0, 0.0, 0.0, 0.5), (0.125, 0.0, 0.0, 1.0), (0.25, 0.0, 0.5, 1.0),
    (0.375, 0.0, 1.0, 1.0), (0.5, 0.5, 1.0, 0.5), (0.625, 1.0, 1.0, 0.0),
    (0.75, 1.0, 0.5, 0.0), (0.875, 1.0, 0.0, 0.0), (1.0, 0.5, 0.0, 0.0),
]

def log(msg):
    print(msg, flush=True)


# ═══════════════════════════════════════════════════════════════════
# §2  共用函數
# ═══════════════════════════════════════════════════════════════════
from paraview.simple import *

def build_rgb_points(lo, hi, key_colors):
    """33-step colormap interpolation → RGBPoints list"""
    rgb_pts = []
    for i in range(33):
        t = i / 32.0
        for j in range(len(key_colors) - 1):
            if key_colors[j][0] <= t <= key_colors[j+1][0]:
                t0, r0, g0, b0 = key_colors[j]
                t1, r1, g1, b1 = key_colors[j+1]
                s = (t - t0) / (t1 - t0) if t1 > t0 else 0
                r = r0 + (r1 - r0) * s
                g = g0 + (g1 - g0) * s
                b = b0 + (b1 - b0) * s
                rgb_pts.extend([lo + (hi - lo) * t, r, g, b])
                break
        else:
            r, g, b = key_colors[-1][1], key_colors[-1][2], key_colors[-1][3]
            rgb_pts.extend([hi, r, g, b])
    return rgb_pts


def setup_view(ren):
    """白底 + 隱藏 XYZ widget"""
    ren.Background = [1.0, 1.0, 1.0]
    ren.Background2 = [1.0, 1.0, 1.0]
    try: ren.UseColorPaletteForBackground = 0
    except: pass
    try: ren.BackgroundColorMode = "Single Color"
    except: pass
    try: LoadPalette(paletteName='WhiteBackground')
    except: pass
    ren.OrientationAxesVisibility = 0


def setup_axes_grid(ren, bounds):
    """座標尺規 — 如參考圖：x/H [-] (streamwise) + y/H [-] (wall-normal)"""
    ag = ren.AxesGrid
    ag.Visibility = 1

    # 軸標題：對應參考圖格式（MathText 排版）
    ag.XTitle = ""
    ag.YTitle = r"$x/H$"
    ag.ZTitle = r"$y/H$"

    black = [0.0, 0.0, 0.0]
    ag.XTitleColor = black
    ag.YTitleColor = black
    ag.ZTitleColor = black
    ag.XLabelColor = black
    ag.YLabelColor = black
    ag.ZLabelColor = black
    ag.GridColor = black

    # Times New Roman Bold
    ag.XTitleFontFamily = "Times"
    ag.YTitleFontFamily = "Times"
    ag.ZTitleFontFamily = "Times"
    ag.XLabelFontFamily = "Times"
    ag.YLabelFontFamily = "Times"
    ag.ZLabelFontFamily = "Times"
    ag.XTitleBold = 1
    ag.YTitleBold = 1
    ag.ZTitleBold = 1
    ag.XLabelBold = 1
    ag.YLabelBold = 1
    ag.ZLabelBold = 1

    # 標題（x/H, y/H）放大；刻度數字保持適中（已 OK）
    ag.XTitleFontSize = 48
    ag.YTitleFontSize = 48
    ag.ZTitleFontSize = 48
    ag.XLabelFontSize = 36
    ag.YLabelFontSize = 36
    ag.ZLabelFontSize = 36

    # 整數刻度
    ag.XAxisNotation = "Fixed"
    ag.YAxisNotation = "Fixed"
    ag.ZAxisNotation = "Fixed"
    ag.XAxisPrecision = 0
    ag.YAxisPrecision = 0
    ag.ZAxisPrecision = 0

    # 自訂 tick 標籤：只顯示整數 0, 1, 2, ...
    ymin_b, ymax_b = bounds[2], bounds[3]
    zmin_b, zmax_b = bounds[4], bounds[5]
    y_labels = [float(v) for v in range(int(math.ceil(ymin_b)), int(math.floor(ymax_b)) + 1)]
    z_labels = [float(v) for v in range(int(math.ceil(zmin_b)), int(math.floor(zmax_b)) + 1)]

    # ParaView 5.12 custom labels API（嘗試多種寫法）
    try:
        ag.YAxisUseCustomLabels = 1
        ag.ZAxisUseCustomLabels = 1
        ag.YAxisLabels = y_labels
        ag.ZAxisLabels = z_labels
        log("Custom labels (per-axis API): Y=%s, Z=%s" % (y_labels, z_labels))
    except Exception:
        try:
            ag.UseCustomLabels = [0, 1, 1]
            ag.YAxisLabels = y_labels
            ag.ZAxisLabels = z_labels
            log("Custom labels (vector API): Y=%s, Z=%s" % (y_labels, z_labels))
        except Exception as e:
            log("Custom labels not supported: %s" % str(e))


def setup_camera(ren, bounds):
    """正交投影相機 — 加 padding 避免尺規標籤被裁切"""
    xmin, xmax = bounds[0], bounds[1]
    ymin, ymax = bounds[2], bounds[3]
    zmin, zmax = bounds[4], bounds[5]
    xmid = (xmin + xmax) * 0.5

    cam = ren.GetActiveCamera()
    cam.SetPosition(xmid + 20, (ymin+ymax)/2, (zmin+zmax)/2)
    cam.SetFocalPoint(xmid, (ymin+ymax)/2, (zmin+zmax)/2)
    cam.SetViewUp(0, 0, 1)
    cam.SetParallelProjection(True)
    ResetCamera()
    # 0.58: 稍微縮小讓 x/H 標題留在邊界內
    cam.SetParallelScale((zmax - zmin) * 0.58)


def setup_scalar_bar(lut, ren, title="u_streamwise"):
    """色標列 — Times New Roman Bold, fixed-point labels"""
    bar = GetScalarBar(lut, ren)
    bar.Title = title
    bar.ComponentTitle = ""
    # MathText ($...$) 分數/上下標需要較大字才清楚
    bar.TitleFontSize = 24
    bar.LabelFontSize = 16
    bar.Orientation = "Vertical"
    bar.WindowLocation = "Any Location"
    bar.Position = [0.90, 0.12]
    bar.ScalarBarLength = 0.76
    bar.TitleColor = [0, 0, 0]
    bar.LabelColor = [0, 0, 0]
    # Times New Roman Bold
    bar.TitleFontFamily = "Times"
    bar.LabelFontFamily = "Times"
    bar.TitleBold = 1
    bar.LabelBold = 1
    # 固定小數格式，避免科學記號 (1.3e+00 → 1.3)
    try: bar.RangeLabelFormat = "%-#6.1f"
    except: pass
    try: bar.AutomaticLabelFormat = 0
    except: pass
    try: bar.LabelFormat = "%-#6.1f"
    except: pass
    return bar


def add_mean_streamlines(reader, ren, bounds):
    """
    Path B 專用：從 U_mean + W_mean 標量場建構平均速度向量，再畫流線
    ─────────────────────────────────────────────────────────────
    VTK 座標映射：
      X = spanwise (code u) → 平均展向速度 ≈ 0
      Y = streamwise (code v) → U_mean
      Z = wall-normal (code w) → W_mean
    平均速度向量 = (0, U_mean, W_mean)
    ─────────────────────────────────────────────────────────────
    """
    xmin, xmax = bounds[0], bounds[1]
    ymin, ymax = bounds[2], bounds[3]
    zmin, zmax = bounds[4], bounds[5]
    xmid = (xmin + xmax) * 0.5

    # ── 建構平均速度向量場 ──
    calcMeanVel = Calculator(Input=reader)
    calcMeanVel.ResultArrayName = "MeanVelocity"
    calcMeanVel.Function = "iHat*0 + jHat*U_mean + kHat*W_mean"
    calcMeanVel.UpdatePipeline()
    log("Mean velocity vector constructed: (0, U_mean, W_mean)")

    # ── 主通道流線：入口垂直線種子 ──
    lineSeed = Line()
    lineSeed.Point1 = [xmid, ymin + 0.01, zmin]
    lineSeed.Point2 = [xmid, ymin + 0.01, zmax]
    lineSeed.Resolution = NUM_MAIN_SEEDS
    log("Seed line: %d points at Y=%.3f" % (NUM_MAIN_SEEDS, ymin + 0.01))

    st1 = StreamTracerWithCustomSource(Input=calcMeanVel, SeedSource=lineSeed)
    st1.Vectors = ["POINTS", "MeanVelocity"]
    st1.MaximumStreamlineLength = MAX_STREAMLINE_LEN
    st1.InitialStepLength = SEED_STEP
    st1.MaximumSteps = MAX_STEPS
    st1.IntegrationDirection = "FORWARD"
    st1.UpdatePipeline()
    log("Main mean streamlines done")

    sd1 = Show(st1, ren)
    sd1.Representation = "Wireframe"
    sd1.LineWidth = STREAMLINE_WIDTH_MAIN
    sd1.AmbientColor = [0.12, 0.12, 0.12]
    sd1.DiffuseColor = [0.12, 0.12, 0.12]
    ColorBy(sd1, None)
    sd1.SetScalarBarVisibility(ren, False)

    # ── 渦流/回流區加密流線（低速區）──
    # 先 Slice + VelMag on mean field
    sliceF_vel = Slice(Input=calcMeanVel)
    sliceF_vel.SliceType.Normal = [1, 0, 0]
    sliceF_vel.SliceType.Origin = [xmid, (ymin+ymax)/2, (zmin+zmax)/2]
    sliceF_vel.UpdatePipeline()

    calcMag_vel = Calculator(Input=sliceF_vel)
    calcMag_vel.ResultArrayName = "MeanVelMag"
    calcMag_vel.Function = "mag(MeanVelocity)"
    calcMag_vel.UpdatePipeline()

    st2 = None
    try:
        from paraview.servermanager import Fetch
        data = Fetch(calcMag_vel)
        arr = data.GetPointData().GetArray("MeanVelMag") if data else None
        if arr:
            npts = arr.GetNumberOfTuples()
            vals = sorted([arr.GetValue(i) for i in range(npts)])
            k_idx = int((npts - 1) * VORTEX_LOW_PERCENTILE / 100.0)
            thresh_lo = vals[k_idx]
            vmin = vals[0]
            log("Mean VelMag: min=%.4f, P%d=%.4f" % (vmin, VORTEX_LOW_PERCENTILE, thresh_lo))
            if thresh_lo > vmin:
                threshF = Threshold(Input=calcMag_vel)
                threshF.Scalars = ["POINTS", "MeanVelMag"]
                threshF.LowerThreshold = vmin
                threshF.UpperThreshold = thresh_lo
                threshF.ThresholdMethod = "Between"
                threshF.UpdatePipeline()
                nv = threshF.GetDataInformation().GetNumberOfPoints()
                if nv > 0:
                    seedSource = threshF
                    if nv > MAX_VORTEX_SEEDS:
                        mask = MaskPoints(Input=threshF)
                        mask.OnRatio = max(2, nv // MAX_VORTEX_SEEDS)
                        mask.RandomSampling = 0
                        mask.UpdatePipeline()
                        seedSource = mask
                        nv = seedSource.GetDataInformation().GetNumberOfPoints()
                    st2 = StreamTracerWithCustomSource(Input=calcMeanVel, SeedSource=seedSource)
                    st2.Vectors = ["POINTS", "MeanVelocity"]
                    st2.MaximumStreamlineLength = MAX_STREAMLINE_LEN * 0.8
                    st2.InitialStepLength = SEED_STEP * 0.3
                    st2.MaximumSteps = MAX_STEPS
                    st2.IntegrationDirection = "BOTH"
                    st2.UpdatePipeline()
                    log("Vortex mean streamlines: %d seeds" % nv)

                    sd2 = Show(st2, ren)
                    sd2.Representation = "Wireframe"
                    sd2.LineWidth = STREAMLINE_WIDTH_VORTEX
                    sd2.AmbientColor = [0.05, 0.05, 0.05]
                    sd2.DiffuseColor = [0.05, 0.05, 0.05]
                    ColorBy(sd2, None)
                    sd2.SetScalarBarVisibility(ren, False)
                else:
                    log("Low-speed mean points=%d, skip vortex seeds" % nv)
            else:
                log("No clear mean recirculation region")
    except Exception as e:
        log("Mean vortex seed fallback: " + str(e))


# ═══════════════════════════════════════════════════════════════════
# §3  讀取 VTK
# ═══════════════════════════════════════════════════════════════════
log("Loading: " + VTK_FILE)
reader = LegacyVTKReader(FileNames=[VTK_FILE])
reader.UpdatePipeline()

bounds = reader.GetDataInformation().GetBounds()
xmin, xmax = bounds[0], bounds[1]
ymin, ymax = bounds[2], bounds[3]
zmin, zmax = bounds[4], bounds[5]
xmid = (xmin + xmax) * 0.5
log("Bounds  X:[%.3f,%.3f]  Y:[%.3f,%.3f]  Z:[%.3f,%.3f]" % (xmin, xmax, ymin, ymax, zmin, zmax))
log("Slice at X = %.3f" % xmid)

pointData = reader.GetDataInformation().GetPointDataInformation()
has_Umean = False
has_Wmean = False
has_TKE = False
has_uu = False
has_vv = False
has_ww = False
has_velocity = False
TKE_name = None
uu_name = None
vv_name = None
ww_name = None
for idx in range(pointData.GetNumberOfArrays()):
    name = pointData.GetArrayInformation(idx).GetName()
    if name == "velocity": has_velocity = True
    if name == "U_mean": has_Umean = True
    if name == "W_mean": has_Wmean = True
    if name in ("TKE", "tke", "k_turb", "k_TKE"):
        has_TKE = True; TKE_name = name
    if name in ("uu_mean", "u_u_mean", "uprime_uprime", "uu_RS"):
        has_uu = True; uu_name = name
    if name in ("vv_mean", "v_v_mean", "vprime_vprime", "vv_RS"):
        has_vv = True; vv_name = name
    if name in ("ww_mean", "w_w_mean", "wprime_wprime", "ww_RS"):
        has_ww = True; ww_name = name
has_TKE_computable = has_TKE or (has_uu and has_vv and has_ww)
log("U_mean: %s, W_mean: %s" % (
    "FOUND" if has_Umean else "not found",
    "FOUND" if has_Wmean else "not found"))
log("TKE: %s (direct=%s, uu=%s, vv=%s, ww=%s)" % (
    "AVAILABLE" if has_TKE_computable else "not available",
    "FOUND" if has_TKE else "-",
    "FOUND" if has_uu else "-",
    "FOUND" if has_vv else "-",
    "FOUND" if has_ww else "-"))


# ═══════════════════════════════════════════════════════════════════
# §4  Path A: 瞬時 u_streamwise — 無流線, 白底, 帶尺規
# ═══════════════════════════════════════════════════════════════════
log("=== Path A: Instantaneous u_streamwise ===")

sliceA = Slice(Input=reader)
sliceA.SliceType.Normal = [1, 0, 0]
sliceA.SliceType.Origin = [xmid, (ymin+ymax)/2, (zmin+zmax)/2]
sliceA.UpdatePipeline()

calcA = Calculator(Input=sliceA)
calcA.ResultArrayName = "u_streamwise"
calcA.Function = "velocity_Y"
calcA.UpdatePipeline()

renA = CreateView("RenderView")
renA.ViewSize = [IMAGE_W, IMAGE_H]
try: renA.UseOffscreenRendering = 1     # 強制 offscreen，避免 X server 依賴
except: pass
setup_view(renA)

dispA = Show(calcA, renA)
dispA.Representation = "Surface"
dispA.ColorArrayName = ["POINTS", "u_streamwise"]

lutA = GetColorTransferFunction("u_streamwise")
infoA = calcA.GetDataInformation().GetPointDataInformation().GetArrayInformation("u_streamwise")
if infoA:
    lo_A = infoA.GetComponentRange(0)[0]
    hi_A = infoA.GetComponentRange(0)[1]
else:
    lo_A, hi_A = 0.0, 1.0
log("u_streamwise range: [%.4f, %.4f]" % (lo_A, hi_A))

lutA.ColorSpace = "Step"
lutA.RGBPoints = build_rgb_points(lo_A, hi_A, KEY_COLORS)
dispA.LookupTable = lutA
dispA.SetScalarBarVisibility(renA, True)
setup_scalar_bar(lutA, renA, r"$u/U_{ref}$")

setup_camera(renA, bounds)
setup_axes_grid(renA, bounds)

Render(renA)
SaveScreenshot(OUT_INST, renA, ImageResolution=[SAVE_W, SAVE_H],
               OverrideColorPalette='WhiteBackground')
log("Path A saved (step):       " + OUT_INST)

# ── 連續色標版本：切到 RGB 空間後重新渲染輸出 ──
lutA.ColorSpace = "RGB"
Render(renA)
SaveScreenshot(OUT_INST_CONT, renA, ImageResolution=[SAVE_W, SAVE_H],
               OverrideColorPalette='WhiteBackground')
log("Path A saved (continuous): " + OUT_INST_CONT)

Delete(renA)
del renA


# ═══════════════════════════════════════════════════════════════════
# §5  Path B: U_mean + 平均流線（需要 U_mean AND W_mean）
# ═══════════════════════════════════════════════════════════════════
if has_Umean and has_Wmean:
    log("=== Path B: U_mean contour + mean velocity streamlines ===")

    sliceB = Slice(Input=reader)
    sliceB.SliceType.Normal = [1, 0, 0]
    sliceB.SliceType.Origin = [xmid, (ymin+ymax)/2, (zmin+zmax)/2]
    sliceB.UpdatePipeline()

    calcB = Calculator(Input=sliceB)
    calcB.ResultArrayName = "U_mean_display"
    calcB.Function = "U_mean"
    calcB.UpdatePipeline()

    renB = CreateView("RenderView")
    renB.ViewSize = [IMAGE_W, IMAGE_H]
    try: renB.UseOffscreenRendering = 1     # 強制 offscreen，避免 X server 依賴
    except: pass
    setup_view(renB)

    dispB = Show(calcB, renB)
    dispB.Representation = "Surface"
    dispB.ColorArrayName = ["POINTS", "U_mean_display"]

    lutB = GetColorTransferFunction("U_mean_display")
    infoB = calcB.GetDataInformation().GetPointDataInformation().GetArrayInformation("U_mean_display")
    if infoB:
        lo_B = infoB.GetComponentRange(0)[0]
        hi_B = infoB.GetComponentRange(0)[1]
    else:
        lo_B, hi_B = 0.0, 1.0
    log("U_mean range: [%.4f, %.4f]" % (lo_B, hi_B))

    lutB.ColorSpace = "Step"
    lutB.RGBPoints = build_rgb_points(lo_B, hi_B, KEY_COLORS)
    dispB.LookupTable = lutB
    dispB.SetScalarBarVisibility(renB, True)
    setup_scalar_bar(lutB, renB, r"$\langle u \rangle / U_{ref}$")

    # ── 用平均速度向量 (0, U_mean, W_mean) 畫流線 ──
    add_mean_streamlines(reader, renB, bounds)

    setup_camera(renB, bounds)
    setup_axes_grid(renB, bounds)

    Render(renB)
    SaveScreenshot(OUT_MEAN, renB, ImageResolution=[SAVE_W, SAVE_H],
                   OverrideColorPalette='WhiteBackground')
    log("Path B saved (step):       " + OUT_MEAN)

    # ── 連續色標版本 ──
    lutB.ColorSpace = "RGB"
    Render(renB)
    SaveScreenshot(OUT_MEAN_CONT, renB, ImageResolution=[SAVE_W, SAVE_H],
                   OverrideColorPalette='WhiteBackground')
    log("Path B saved (continuous): " + OUT_MEAN_CONT)

    Delete(renB)
    del renB
elif has_Umean:
    log("Path B skipped: has U_mean but missing W_mean (need both for mean streamlines)")
else:
    log("Path B skipped (no U_mean in VTK)")


# ═══════════════════════════════════════════════════════════════════
# §6  Path C: TKE（連續色標；若無統計資料則跳過）
# ═══════════════════════════════════════════════════════════════════
if has_TKE_computable:
    log("=== Path C: TKE (continuous colormap) ===")

    sliceC = Slice(Input=reader)
    sliceC.SliceType.Normal = [1, 0, 0]
    sliceC.SliceType.Origin = [xmid, (ymin+ymax)/2, (zmin+zmax)/2]
    sliceC.UpdatePipeline()

    calcC = Calculator(Input=sliceC)
    calcC.ResultArrayName = "TKE"
    if has_TKE:
        calcC.Function = TKE_name
        log("TKE source: direct field '%s'" % TKE_name)
    else:
        calcC.Function = "0.5*(%s + %s + %s)" % (uu_name, vv_name, ww_name)
        log("TKE source: 0.5*(%s + %s + %s)" % (uu_name, vv_name, ww_name))
    calcC.UpdatePipeline()

    renC = CreateView("RenderView")
    renC.ViewSize = [IMAGE_W, IMAGE_H]
    try: renC.UseOffscreenRendering = 1
    except: pass
    setup_view(renC)

    dispC = Show(calcC, renC)
    dispC.Representation = "Surface"
    dispC.ColorArrayName = ["POINTS", "TKE"]

    lutC = GetColorTransferFunction("TKE")
    infoC = calcC.GetDataInformation().GetPointDataInformation().GetArrayInformation("TKE")
    if infoC:
        lo_C = infoC.GetComponentRange(0)[0]
        hi_C = infoC.GetComponentRange(0)[1]
    else:
        lo_C, hi_C = 0.0, 1.0
    # 確保 TKE ≥ 0
    if lo_C < 0.0: lo_C = 0.0
    if hi_C <= lo_C: hi_C = lo_C + 1e-6
    log("TKE range: [%.6f, %.6f]" % (lo_C, hi_C))

    # TKE 預設連續色標
    lutC.ColorSpace = "RGB"
    lutC.RGBPoints = build_rgb_points(lo_C, hi_C, KEY_COLORS)
    dispC.LookupTable = lutC
    dispC.SetScalarBarVisibility(renC, True)
    setup_scalar_bar(lutC, renC, r"$k/U_{ref}^{2}$")

    setup_camera(renC, bounds)
    setup_axes_grid(renC, bounds)

    Render(renC)
    SaveScreenshot(OUT_TKE_CONT, renC, ImageResolution=[SAVE_W, SAVE_H],
                   OverrideColorPalette='WhiteBackground')
    log("Path C saved (continuous): " + OUT_TKE_CONT)

    Delete(renC)
    del renC
else:
    log("Path C skipped (no TKE or Reynolds stress components in VTK)")


# ═══════════════════════════════════════════════════════════════════
# §7  Path D: Q-criterion 3D 等值面（對齊 4.Q-criterion_Animation.py 參考範本）
# ═══════════════════════════════════════════════════════════════════
#  ─ 版本：重寫版，完全對齊 4.Q-criterion_Animation.py 的輸出風格
#  ─ 色階：Rainbow Desaturated（ParaView preset，與參考範本一致）
#  ─ 著色變數：w (velocity_Z 分量)，範圍固定 [-0.02, 0.02]
#  ─ 畫布：1920×1080，相機斜俯視 (18,-8,6.3) → focal (2.25,4.5,1.5)
#  ─ Threshold：Qmax * 5%，再依 20K-80K cells 自適應
#  ─ 標註：上方置中 "Step=... | FTT=... | Ma_max=..." 文字
#
if has_velocity:
    log("=== Path D: Q-criterion isosurface (Rainbow Desaturated, ref-aligned) ===")

    # ── Step 1: 計算 Q-criterion ──
    gradD = Gradient(Input=reader)
    props = gradD.ListProperties()
    log("Gradient filter properties: " + str(props))

    input_set = False
    for prop_name in ['SelectInputScalars', 'InputArray', 'ScalarArray',
                      'SelectInputArray', 'SelectInputVectors']:
        if prop_name in props:
            try:
                setattr(gradD, prop_name, ['POINTS', 'velocity'])
                input_set = True
                log("Gradient using property: " + prop_name)
                break
            except:
                continue
    if not input_set:
        gradD.SetInputArrayToProcess(0, 0, 0, 0, 'velocity')
        log("Gradient using SetInputArrayToProcess fallback")

    gradD.ResultArrayName = 'VelocityGradient'
    gradD.ComputeQCriterion = 1
    gradD.QCriterionArrayName = 'Q'
    gradD.ComputeVorticity = 0
    gradD.ComputeDivergence = 0
    gradD.UpdatePipeline()

    q_info = gradD.GetDataInformation().GetPointDataInformation().GetArrayInformation('Q')
    q_range = q_info.GetComponentRange(0) if q_info else (0.0, 1.0)
    log("Q-criterion range: [%.8f, %.8f]" % (q_range[0], q_range[1]))

    if q_range[1] <= 0.0:
        log("Path D skipped: Qmax <= 0, no vortex structure")
    else:
        # ── Step 2: Q 等值面（自適應 threshold）──
        Q_THRESHOLD = q_range[1] * Q_AUTO_FRACTION
        contourD = Contour(Input=gradD)
        contourD.ContourBy = ['POINTS', 'Q']
        contourD.Isosurfaces = [Q_THRESHOLD]
        contourD.ComputeNormals = 1
        contourD.ComputeScalars = 1
        contourD.UpdatePipeline()

        n_cells = contourD.GetDataInformation().GetNumberOfCells()
        log("Initial Q threshold %.8f (%.1f%% of Qmax) -> %d cells"
            % (Q_THRESHOLD, Q_AUTO_FRACTION*100, n_cells))

        # 自適應目標區間 20K–80K cells（對齊參考範本）
        if n_cells > Q_CELLS_TARGET_HI:
            for fraction in [0.08, 0.10, 0.15, 0.20, 0.30, 0.40, 0.50]:
                Q_THRESHOLD = q_range[1] * fraction
                contourD.Isosurfaces = [Q_THRESHOLD]
                contourD.UpdatePipeline()
                n_cells = contourD.GetDataInformation().GetNumberOfCells()
                log("  ^ %.0f%% of Qmax = %.8f -> %d cells"
                    % (fraction*100, Q_THRESHOLD, n_cells))
                if n_cells <= Q_CELLS_TARGET_HI:
                    break
        elif n_cells < Q_CELLS_TARGET_LO and n_cells > 0:
            for fraction in [0.03, 0.02, 0.01, 0.005, 0.002, 0.001]:
                Q_THRESHOLD = q_range[1] * fraction
                contourD.Isosurfaces = [Q_THRESHOLD]
                contourD.UpdatePipeline()
                n_cells = contourD.GetDataInformation().GetNumberOfCells()
                log("  v %.2f%% of Qmax = %.8f -> %d cells"
                    % (fraction*100, Q_THRESHOLD, n_cells))
                if n_cells >= Q_CELLS_TARGET_LO:
                    break
        log("Final Q threshold: %.8f  (%d cells)" % (Q_THRESHOLD, n_cells))

        # ── Step 3: 直接取 VTK 變數 w_inst，歸一化為 v/U_ref (normal wall velocity) ──
        # 座標慣例：Z = wall-normal，code w = v_physics；除以 U_ref 得到無因次 v/U_ref
        calcD = Calculator(Input=contourD)
        calcD.Function = 'w_inst / %.8f' % Q_U_REF
        calcD.ResultArrayName = 'v_over_Uref'
        calcD.UpdatePipeline()

        # ── Step 4: 1920×1080 渲染視圖（對齊參考範本 IMG_SIZE）──
        renD = CreateView("RenderView")
        renD.ViewSize = [Q_IMG_W, Q_IMG_H]
        try: renD.Background = [1.0, 1.0, 1.0]
        except: pass
        try: renD.UseOffscreenRendering = 1
        except: pass

        dispD = Show(calcD, renD)
        dispD.Representation = "Surface"
        dispD.Opacity = Q_OPACITY

        # normal wall velocity 著色 + Rainbow Desaturated 色階
        ColorBy(dispD, ('POINTS', 'v_over_Uref'))
        lutD = GetColorTransferFunction("v_over_Uref")
        # w_inst ~ [-0.02, 0.02] / U_ref(0.0583) ~ [-0.343, 0.343]
        try: lutD.RescaleTransferFunction(W_RANGE[0] / Q_U_REF, W_RANGE[1] / Q_U_REF)
        except: pass
        try: lutD.ApplyPreset('Rainbow Desaturated', True)
        except: pass

        # Scalar bar — Title='v/U_ref' (MathText), normal wall velocity
        barD = GetScalarBar(lutD, renD)
        barD.Title = r'$v/U_{ref}$'
        barD.ComponentTitle = ''
        barD.Visibility = 1
        # 只放大 label 標題（Title 'w'），其餘維持原本比例
        barD.TitleFontSize = 32
        barD.LabelFontSize = 16
        barD.TitleColor = [0.0, 0.0, 0.0]
        barD.LabelColor = [0.0, 0.0, 0.0]
        try: barD.TitleFontFamily = 'Times'
        except: pass
        try: barD.LabelFontFamily = 'Times'
        except: pass
        try: barD.TitleBold = 1
        except: pass
        try: barD.LabelBold = 1
        except: pass
        try: barD.ScalarBarLength = 0.4
        except: pass
        try: dispD.SetScalarBarVisibility(renD, True)
        except: pass

        # 域 outline 作為參考（與參考範本相同樣式）
        try:
            outlineD = Show(reader, renD)
            outlineD.Representation = "Outline"
            outlineD.AmbientColor = [0.3, 0.3, 0.3]
            outlineD.DiffuseColor = [0.3, 0.3, 0.3]
            outlineD.LineWidth = 1.5 
            
            outlineD.Opacity = 0.3
        except:
            pass

        # ── Step 5: (已移除) 上方文字標註 FTT / Ma_max → 保留純粹瞬間快照 ──

        # ── Step 6: 固定斜俯視相機（完全對齊參考範本）──
        # focal=(2.25, 4.5, 1.5) 域中心, position=(18, -8, 6.3), ViewAngle=21.08
        camD = renD.GetActiveCamera() if hasattr(renD, 'GetActiveCamera') else GetActiveCamera()
        camD.SetFocalPoint(2.25, 4.5, 1.5)
        camD.SetPosition(18.0, -8.0, 6.3)
        camD.SetViewUp(0, 0, 1)
        camD.SetViewAngle(21.080246913580243)
        # Dolly 維持原比例（避免主體超出邊界），頂端空白改用後製剪切處理
        camD.Dolly(1.1)

        # ── Step 7: AxesGrid (對齊 Path A/B/C 樣式：MathText $x/H$ Times Bold 36pt) ──
        try:
            agD = renD.AxesGrid
            agD.Visibility = 1
            # 三軸標題全部移除（底部已有 OrientationAxes 指示方向，避免與刻度數字重疊）
            agD.XTitle = ""
            agD.YTitle = ""
            agD.ZTitle = ""
            # 字體：Times Bold 黑
            try:
                agD.XTitleFontFamily = "Times"
                agD.YTitleFontFamily = "Times"
                agD.ZTitleFontFamily = "Times"
                agD.XLabelFontFamily = "Times"
                agD.YLabelFontFamily = "Times"
                agD.ZLabelFontFamily = "Times"
            except: pass
            try:
                agD.XTitleBold = 1; agD.YTitleBold = 1; agD.ZTitleBold = 1
                agD.XLabelBold = 1; agD.YLabelBold = 1; agD.ZLabelBold = 1
            except: pass
            try:
                agD.XTitleColor = [0,0,0]; agD.YTitleColor = [0,0,0]; agD.ZTitleColor = [0,0,0]
                agD.XLabelColor = [0,0,0]; agD.YLabelColor = [0,0,0]; agD.ZLabelColor = [0,0,0]
                agD.GridColor = [0,0,0]
            except: pass
            # 字級：Title 保持適中，Label 縮小避免與標題重疊（對齊 Path A/B/C 視覺大小）
            agD.XTitleFontSize = 36
            agD.YTitleFontSize = 36
            agD.ZTitleFontSize = 36
            try:
                agD.XLabelFontSize = 20
                agD.YLabelFontSize = 20
                agD.ZLabelFontSize = 20
            except: pass
            # 軸標題 ↔ 刻度數字 固定距離
            # X/Y 維持 65/40；Z 單獨再拉大到 95/60（z/H 與 1.5 數字重疊問題）
            try:
                agD.XAxisLabelOffset = 40
                agD.YAxisLabelOffset = 40
                agD.ZAxisLabelOffset = 60
            except: pass
            try:
                agD.XAxisTitleOffset = 65
                agD.YAxisTitleOffset = 65
                agD.ZAxisTitleOffset = 95
            except: pass
            try:
                agD.XTitleOffset = 65
                agD.YTitleOffset = 65
                agD.ZTitleOffset = 95
            except: pass
            try:
                agD.XLabelOffset = 40
                agD.YLabelOffset = 40
                agD.ZLabelOffset = 60
            except: pass
        except Exception as e:
            log("Q-crit axes grid skipped: " + str(e))

        # ── Step 8: Render + save ──
        Render(renD)
        SaveScreenshot(OUT_QCRIT, renD,
                       ImageResolution=[Q_IMG_W, Q_IMG_H],
                       OverrideColorPalette='WhiteBackground',
                       TransparentBackground=0)
        log("Path D saved: " + OUT_QCRIT)

        # ── Step 9: 後製裁切頂端過大空白（三軸標題已移除，無需貼標籤）──
        try:
            from PIL import Image as _PILImage
            _im = _PILImage.open(OUT_QCRIT)
            _w, _h = _im.size
            _top_cut = int(_h * 0.15)
            _im_crop = _im.crop((0, _top_cut, _w, _h))
            _im_crop.save(OUT_QCRIT)
            log("Path D top-crop: removed top %d px, new size %dx%d"
                % (_top_cut, _w, _h - _top_cut))
        except Exception as _e:
            log("Path D top-crop skipped: " + str(_e))

        Delete(renD)
        del renD
else:
    log("Path D skipped (no 'velocity' vector field in VTK)")

