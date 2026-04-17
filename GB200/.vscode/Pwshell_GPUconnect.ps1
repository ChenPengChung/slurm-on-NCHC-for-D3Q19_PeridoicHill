# SSH Connect Script
# Usage: ./Pwshell_GPUconnect.ps1 -ServerCombo "87:3"
#        ./Pwshell_GPUconnect.ps1 -Interactive           (GPU 即時狀態互動選單)
#        ./Pwshell_GPUconnect.ps1 -QuickPick "87:3"      (VS Code QuickPick 選擇後直接連線)
#        ./Pwshell_GPUconnect.ps1 -QuickPick "gpus"      (先查 GPU 再進入終端選單)

param(
    [string]$ServerCombo,
    [switch]$Interactive,
    [string]$QuickPick
)

$_scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$_workspaceDir = Split-Path -Parent $_scriptDir
$_localFolderName = Split-Path -Leaf $_workspaceDir
$_isWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)

$Config = @{
    IsWindows = $_isWindows
    PlinkPath = if ($_isWindows) { "C:\Program Files\PuTTY\plink.exe" } else { $null }
    Password = "1256"
    Username = "chenpengchung"
    RemotePath = "/home/chenpengchung/$_localFolderName"
    SshOpts = "-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
    Servers = @{
        "87"  = "140.114.58.87"
        "89"  = "140.114.58.89"
        "154" = "140.114.58.154"
    }
}

# Cross-platform SSH wrapper
function Invoke-SshCmd {
    param([string]$User, [string]$Pass, [string]$Host_, [string]$Command, [switch]$Tty)
    if ($Config.IsWindows) {
        if ($Tty) {
            & $Config.PlinkPath -ssh -pw $Pass "$User@$Host_" -t $Command
        } else {
            & $Config.PlinkPath -ssh -pw $Pass -batch "$User@$Host_" $Command 2>$null
        }
    } else {
        if ($Tty) {
            sshpass -p $Pass ssh $Config.SshOpts.Split(' ') -tt "$User@$Host_" $Command
        } else {
            sshpass -p $Pass ssh $Config.SshOpts.Split(' ') -o BatchMode=no "$User@$Host_" $Command 2>$null
        }
    }
}

# ── 解析 nvidia-smi 輸出 → 每顆 GPU 圓點 + free/total ──
function Parse-GpuDots {
    param([string]$RawOutput)
    if (-not $RawOutput -or $RawOutput -eq "OFFLINE") {
        return @{ Dots = @(); Free = 0; Total = 0; Offline = $true }
    }
    $dots = @(); $free = 0; $total = 0
    foreach ($line in $RawOutput -split "`n") {
        $line = $line.Trim()
        if (-not $line) { continue }
        $parts = $line -split ","
        if ($parts.Count -lt 4) { continue }
        $memUsed = ($parts[1].Trim() -replace '[^0-9]','')
        $util    = ($parts[3].Trim() -replace '[^0-9]','')
        if (-not $util) { continue }
        $total++
        if ([int]$util -lt 10 -and [int]$memUsed -lt 100) {
            $free++
            $dots += "G"   # Green = free
        } else {
            $dots += "R"   # Red = busy
        }
    }
    if ($total -eq 0) { return @{ Dots = @(); Free = 0; Total = 0; Offline = $true } }
    return @{ Dots = $dots; Free = $free; Total = $total; Offline = $false }
}

# ══════════════════════════════════════════════════
#  VS Code QuickPick 模式：從 tasks.json input:sshNodePicker 接收選擇
# ══════════════════════════════════════════════════
if ($QuickPick) {
    if ($QuickPick -eq "gpus") {
        # 使用者選了「先查 GPU 再選」→ 顯示 GPU 狀態 → 進入終端互動選單
        $Interactive = $true
    } else {
        # 使用者在 QuickPick 直接選了節點 → 直接連線
        $ServerCombo = $QuickPick
    }
}

# ══════════════════════════════════════════════════
#  互動模式：① 選單即時顯示 → ② GPU 背景查詢 → ③ 按 Enter 顯示
# ══════════════════════════════════════════════════
if ($Interactive) {
    # 節點定義
    $nodes = @(
        @{ Label=".89  direct"; Server="89";  Node="0"; GT="V100-32G" },
        @{ Label=".87->ib2";    Server="87";  Node="2"; GT="P100-16G" },
        @{ Label=".87->ib3";    Server="87";  Node="3"; GT="P100-16G" },
        @{ Label=".87->ib5";    Server="87";  Node="5"; GT="P100-16G" },
        @{ Label=".87->ib6";    Server="87";  Node="6"; GT="V100-16G" },
        @{ Label=".154->ib1";   Server="154"; Node="1"; GT="P100-16G" },
        @{ Label=".154->ib4";   Server="154"; Node="4"; GT="P100-16G" },
        @{ Label=".154->ib7";   Server="154"; Node="7"; GT="P100-16G" },
        @{ Label=".154->ib9";   Server="154"; Node="9"; GT="P100-16G" },
        @{ Label="NCHC nano4"; Server="nchc"; Node="0"; GT="H200-80G" }
    )

    # ── ① 立即顯示選單 (上方) ──
    Write-Host ""
    Write-Host " +====+============+===========+" -ForegroundColor Cyan
    Write-Host " |        SSH Node Selection   |" -ForegroundColor Cyan
    Write-Host " +----+------------+-----------+" -ForegroundColor Cyan
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $num = $i + 1
        $lbl = $nodes[$i].Label.PadRight(10)
        $gt  = $nodes[$i].GT.PadRight(9)
        Write-Host (" | {0,2} | {1} | {2} |" -f $num, $lbl, $gt) -ForegroundColor White
    }
    Write-Host " +----+------------+-----------+" -ForegroundColor Cyan
    Write-Host (" |  0 | Cancel                 |") -ForegroundColor DarkGray
    Write-Host " +====+============+===========+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Enter a number to connect immediately" -ForegroundColor Yellow
    Write-Host "  Press Enter to view GPU status first" -ForegroundColor Yellow
    Write-Host ""

    # ── ② 背景啟動 GPU 查詢 (不阻塞選單) ──
    $gpuJobs = @()
    foreach ($n in $nodes) {
        $s = $n.Server; $nd = $n.Node
        $gpuJobs += Start-Job -ScriptBlock {
            param($PlinkPath, $User, $Pass, $IP, $NodeNum, $IsWin, $SshOpts)
            try {
                if ($NodeNum -eq "0") {
                    $cmd = "nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader"
                } else {
                    $cmd = "ssh -o ConnectTimeout=5 cfdlab-ib$NodeNum 'nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader'"
                }
                if ($IsWin) {
                    $out = & $PlinkPath -ssh -pw $Pass -batch "$User@$IP" $cmd 2>$null
                } else {
                    $out = sshpass -p $Pass ssh $SshOpts.Split(' ') -o BatchMode=no "$User@$IP" $cmd 2>$null
                }
                if ($out) { return ($out -join "`n") } else { return "OFFLINE" }
            } catch { return "OFFLINE" }
        } -ArgumentList $Config.PlinkPath, $Config.Username, $Config.Password, $Config.Servers[$s], $nd, $Config.IsWindows, $Config.SshOpts
    }

    # ── ③ 等待使用者選擇 ──
    $choice = Read-Host "  Select [1-$($nodes.Count)]"

    # 使用者按 Enter (空白) → 等 GPU 完成 → 顯示狀態 → 再選
    if ([string]::IsNullOrWhiteSpace($choice)) {
        Write-Host ""
        Write-Host "  Querying GPU status..." -ForegroundColor Cyan
        $null = Wait-Job $gpuJobs -Timeout 15

        $results = @()
        for ($i = 0; $i -lt $gpuJobs.Count; $i++) {
            $raw = Receive-Job $gpuJobs[$i] -ErrorAction SilentlyContinue
            if (-not $raw) { $raw = "OFFLINE" }
            $results += $raw
        }

        # 顯示 GPU 狀態 (唯讀，僅供參考)
        Write-Host ""
        Write-Host " -- GPU Status (read-only) ---------------------------" -ForegroundColor Cyan
        Write-Host "  Server      GPU       0 1 2 3 4 5 6 7   Free" -ForegroundColor White
        Write-Host "  ----------- --------  ----------------  ----" -ForegroundColor DarkGray

        for ($i = 0; $i -lt $nodes.Count; $i++) {
            $info = Parse-GpuDots $results[$i]
            $label = $nodes[$i].Label.PadRight(11)
            $gt = $nodes[$i].GT.PadRight(8)

            Write-Host "  " -NoNewline
            Write-Host "$label " -NoNewline -ForegroundColor White
            Write-Host "$gt  " -NoNewline -ForegroundColor DarkGray

            if ($info.Offline) {
                for ($g = 0; $g -lt 8; $g++) { Write-Host "[X]" -NoNewline -ForegroundColor DarkGray }
                Write-Host "  " -NoNewline
                Write-Host "OFFLINE" -ForegroundColor DarkGray
            } else {
                foreach ($d in $info.Dots) {
                    if ($d -eq "G") { Write-Host " O " -NoNewline -ForegroundColor Green }
                    else { Write-Host " X " -NoNewline -ForegroundColor Red }
                }
                for ($g = $info.Dots.Count; $g -lt 8; $g++) { Write-Host " . " -NoNewline -ForegroundColor DarkGray }
                Write-Host "  " -NoNewline
                $freeStr = "$($info.Free)/$($info.Total)"
                if ($info.Free -eq 0) { Write-Host "$freeStr" -ForegroundColor Red }
                elseif ($info.Free -ge 4) { Write-Host "$freeStr" -ForegroundColor Green }
                else { Write-Host "$freeStr" -ForegroundColor Yellow }
            }
        }

        Write-Host "  ----------- --------  ----------------  ----" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host " O=Free  X=Busy  [X]=Offline" -ForegroundColor DarkGray
        Write-Host ""

        $choice = Read-Host "  Refer to menu above, select [1-$($nodes.Count), 0=Cancel]"
    }

    # 清理 Jobs
    $gpuJobs | Remove-Job -Force -ErrorAction SilentlyContinue

    # 處理選擇
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq "0") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }

    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $nodes.Count) {
        Write-Host "[ERROR] Invalid choice: $choice" -ForegroundColor Red
        exit 1
    }

    $selected = $nodes[$idx]
    $ServerCombo = "$($selected.Server):$($selected.Node)"
    Write-Host ""
    Write-Host "Connecting: $ServerCombo" -ForegroundColor Green
    Write-Host ""
}

# ══════════════════════════════════════════════════
#  正常連線（原有邏輯 + .89 直連支援）
# ══════════════════════════════════════════════════
if (-not $ServerCombo) {
    Write-Host "[ERROR] No server specified. Use -ServerCombo '87:3' or -Interactive" -ForegroundColor Red
    exit 1
}

# Parse serverCombo (e.g., "87:3" -> server=87, node=3)
$parts = $ServerCombo -split ":"
if ($parts.Count -ne 2) {
    Write-Host "[ERROR] Invalid format. Use: 87:3 or 154:4 or 89:0" -ForegroundColor Red
    exit 1
}

$serverKey = $parts[0]
$nodeNum = $parts[1]

# ── NCHC 分流: 委派給 NCHC 專用腳本 ──
if ($serverKey -eq "nchc") {
    $nchcScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Pwshell_NCHC_connect.ps1"
    & $nchcScript -Action ssh
    exit $LASTEXITCODE
}

if (-not $Config.Servers.ContainsKey($serverKey)) {
    Write-Host "[ERROR] Unknown server: $serverKey. Use 87, 89 or 154." -ForegroundColor Red
    exit 1
}

$masterIP = $Config.Servers[$serverKey]

if ($nodeNum -eq "0") {
    # 直連模式 (如 .89)
    Write-Host "[SSH] Connecting directly to .$serverKey ($masterIP)..." -ForegroundColor Cyan
    Invoke-SshCmd -User $Config.Username -Pass $Config.Password -Host_ $masterIP -Command "cd $($Config.RemotePath); exec bash" -Tty
} else {
    # 跳板模式 (如 .87 ib3)
    $childNode = "cfdlab-ib$nodeNum"
    Write-Host "[SSH] Connecting via .$serverKey ($masterIP) to $childNode..." -ForegroundColor Cyan
    Invoke-SshCmd -User $Config.Username -Pass $Config.Password -Host_ $masterIP -Command "ssh -t $childNode 'cd $($Config.RemotePath); exec bash'" -Tty
}
