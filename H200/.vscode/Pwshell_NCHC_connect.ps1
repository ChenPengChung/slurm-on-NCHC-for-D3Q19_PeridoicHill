<#
.SYNOPSIS
    NCHC (國網中心) 全功能操作腳本 — SSH / 上傳 / 下載 / 編譯 / 提交 / 監控
.DESCRIPTION
    所有操作透過 SSH_ASKPASS 自動填入 2FA + 密碼，使用者只需在手機上確認推播。
    每個 Action 只觸發一次 2FA 推播。

    Action 一覽:
      ssh        互動式登入 (Ctrl+Shift+N)
      upload     上傳原始碼 (Ctrl+Shift+U)
      download   下載 VTK/結果 (Ctrl+Shift+D)
      compile    遠端編譯 main.cu
      submit     編譯 + sbatch 提交
      jobs       查看 Slurm 佇列
      cancel     取消全部 Slurm 工作
      status     查看最新 log (tail)
      tail       即時追蹤 chain.log
      syncstatus 比對本地 vs 遠端檔案
.EXAMPLE
    ./Pwshell_NCHC_connect.ps1 -Action ssh
    ./Pwshell_NCHC_connect.ps1 -Action upload
    ./Pwshell_NCHC_connect.ps1 -Action submit
#>

param(
    [Parameter(Position=0)]
    [ValidateSet("ssh", "upload", "download", "compile", "submit", "jobs", "cancel", "status", "tail", "syncstatus")]
    [string]$Action = "ssh"
)

# ================================================================
# 設定
# ================================================================
$_scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$_workspaceDir   = Split-Path -Parent $_scriptDir
$_localFolderName = Split-Path -Leaf $_workspaceDir

$NCHC = @{
    Host       = "nano4.nchc.org.tw"
    User       = "s8313697"
    Password   = "Ssss125663429"
    TwoFA      = "2"                    # 2 = Mobile APP PUSH
    RemotePath = "/home/s8313697/$_localFolderName"
    SshExe     = "C:\WINDOWS\System32\OpenSSH\ssh.exe"
}

# tar 上傳排除清單 (對應 sftp.json ignore)
$_uploadExcludes = @(
    "--exclude=.vscode", "--exclude=.git", "--exclude=.claude",
    "--exclude=*.exe", "--exclude=*.o", "--exclude=a.out",
    "--exclude=result", "--exclude=backup", "--exclude=statistics",
    "--exclude=*.dat", "--exclude=*.DAT",
    "--exclude=animation/*.gif", "--exclude=checkpoint"
)

# ================================================================
# Helper: 非互動遠端指令 (SSH_ASKPASS, 單次 2FA)
# ================================================================
function Invoke-NCHC-Cmd {
    param(
        [string]$Command,
        [string]$Label = "NCHC",
        [switch]$Interactive
    )
    $user  = $NCHC.User
    $host_ = $NCHC.Host
    $rpath = $NCHC.RemotePath

    Write-Host "  [等待] 📱 手機推播確認..." -ForegroundColor Yellow
    Set-AskpassEnv

    $fullCmd = "cd $rpath && $Command"
    if ($Interactive) {
        & $NCHC.SshExe -t "$user@$host_" $fullCmd
    } else {
        & $NCHC.SshExe "$user@$host_" $fullCmd
    }
    $rc = $LASTEXITCODE
    Clear-AskpassEnv
    return $rc
}

# ================================================================
# Helper: 顯示 banner
# ================================================================
function Show-Banner {
    param([string]$Title)
    Write-Host ""
    Write-Host (" " + "=" * 50) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host (" " + "=" * 50) -ForegroundColor Cyan
    Write-Host "  Server : $($NCHC.Host)" -ForegroundColor White
    Write-Host "  Remote : $($NCHC.RemotePath)" -ForegroundColor White
    Write-Host ""
}

# ================================================================
# Action: ssh — 互動式 2FA 連線
# ================================================================
if ($Action -eq "ssh") {
    $host_ = $NCHC.Host
    $user  = $NCHC.User
    $pass  = $NCHC.Password
    $rpath = $NCHC.RemotePath
    $askpassCmd = Join-Path $_scriptDir "nchc_askpass.cmd"

    Show-Banner "NCHC 國網中心 — 全自動連線 (2FA PUSH)"

    # ── SSH_ASKPASS 自動認證策略 ──
    # OpenSSH 8.4+ 支援 SSH_ASKPASS_REQUIRE=force
    # SSH 對每個 keyboard-interactive prompt 呼叫 SSH_ASKPASS 程式:
    #   prompt 含 "password" → 回傳密碼
    #   其他 (2FA 選單)      → 回傳 "2" (Mobile APP PUSH)

    # 偵測 SSH 版本
    $verOutput = & $NCHC.SshExe -V 2>&1 | Out-String
    $verMatch  = [regex]::Match($verOutput, 'OpenSSH[\w_]*[\s_](\d+)\.(\d+)')
    $useAskpass = $false
    if ($verMatch.Success) {
        $major = [int]$verMatch.Groups[1].Value
        $minor = [int]$verMatch.Groups[2].Value
        $useAskpass = ($major -gt 8) -or ($major -eq 8 -and $minor -ge 4)
        Write-Host " [INFO] OpenSSH $major.$minor — " -NoNewline -ForegroundColor DarkGray
        if ($useAskpass) {
            Write-Host "SSH_ASKPASS 自動認證啟用" -ForegroundColor Green
        } else {
            Write-Host "版本 < 8.4, 改用手動模式" -ForegroundColor Yellow
        }
    }

    if ($useAskpass -and (Test-Path $askpassCmd)) {
        Write-Host ""
        Write-Host " [自動] 2FA + 密碼 → SSH_ASKPASS 自動填入" -ForegroundColor Green
        Write-Host " [等待] 📱 請在手機上點選 [確認]" -ForegroundColor Yellow
        Write-Host ""

        Set-AskpassEnv

        & $NCHC.SshExe -t "$user@$host_" "cd $rpath 2>/dev/null && echo '[成功登入] 目錄: $rpath' && exec bash --login || echo '[警告] 目錄不存在: $rpath — 請先上傳' && exec bash --login"
        $rc = $LASTEXITCODE

        Clear-AskpassEnv
    } else {
        Write-Host " [流程] 請依序操作:" -ForegroundColor Yellow
        Write-Host "   ① 2FA 選單 → 輸入 [2]" -ForegroundColor Green
        Write-Host "   ② Password → 貼上密碼 (已複製)" -ForegroundColor Green
        Write-Host "   ③ 手機推播 → 確認" -ForegroundColor Green
        Write-Host ""
        try { Set-Clipboard -Value $pass } catch {}

        & $NCHC.SshExe -t "$user@$host_" "cd $rpath 2>/dev/null && echo '[成功登入] 目錄: $rpath' && exec bash --login || echo '[警告] 目錄不存在: $rpath — 請先上傳' && exec bash --login"
        $rc = $LASTEXITCODE
    }

    Write-Host ""
    if ($rc -eq 0) {
        Write-Host " [結束] NCHC 連線已關閉 (正常)" -ForegroundColor Green
    } else {
        Write-Host " [錯誤] SSH 退出碼: $rc" -ForegroundColor Red
        Write-Host "  重試: Ctrl+Shift+N 或 Alt+F → 選 NCHC" -ForegroundColor Gray
    }
    exit $rc
}

# ================================================================
# Helper: SSH_ASKPASS 環境設定 (upload/download/remote-cmd 共用)
# ================================================================
function Set-AskpassEnv {
    $script:askpassCmd = Join-Path $_scriptDir "nchc_askpass.cmd"
    $stateFile = Join-Path $env:TEMP "nchc_askpass_step"
    if (Test-Path $stateFile) { Remove-Item $stateFile -Force }
    $env:NCHC_TWOFA          = $NCHC.TwoFA
    $env:NCHC_PASS            = $NCHC.Password
    $env:SSH_ASKPASS          = $script:askpassCmd
    $env:SSH_ASKPASS_REQUIRE  = "force"
}
function Clear-AskpassEnv {
    $stateFile = Join-Path $env:TEMP "nchc_askpass_step"
    Remove-Item Env:NCHC_TWOFA         -ErrorAction SilentlyContinue
    Remove-Item Env:NCHC_PASS           -ErrorAction SilentlyContinue
    Remove-Item Env:SSH_ASKPASS         -ErrorAction SilentlyContinue
    Remove-Item Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
    if (Test-Path $stateFile) { Remove-Item $stateFile -Force }
}

# ================================================================
# Action: upload — 上傳原始碼到 NCHC (tar pipe, 單次 2FA)
# ================================================================
if ($Action -eq "upload") {
    Show-Banner "NCHC 上傳 — tar pipe (單次 2FA)"
    Write-Host "  Local  : $_workspaceDir" -ForegroundColor White
    Write-Host ""

    $user  = $NCHC.User
    $host_ = $NCHC.Host
    $rpath = $NCHC.RemotePath
    $tarExcludes = $_uploadExcludes -join " "

    Set-AskpassEnv
    Write-Host "  [等待] 📱 手機推播確認後開始傳輸..." -ForegroundColor Yellow
    Write-Host ""

    cmd /c "cd /d `"$_workspaceDir`" && tar cf - $tarExcludes . | `"$($NCHC.SshExe)`" $user@$host_ `"mkdir -p $rpath && cd $rpath && tar xf -`""
    $rc = $LASTEXITCODE
    Clear-AskpassEnv

    Write-Host ""
    if ($rc -eq 0) {
        Write-Host "  [完成] 上傳成功!" -ForegroundColor Green
    } else {
        Write-Host "  [錯誤] 上傳失敗 (exit=$rc)" -ForegroundColor Red
    }
    exit $rc
}

# ================================================================
# Action: download — 從 NCHC 下載 VTK/結果 (tar pipe, 單次 2FA)
# ================================================================
if ($Action -eq "download") {
    Show-Banner "NCHC 下載 — VTK/結果 (單次 2FA)"

    $user  = $NCHC.User
    $host_ = $NCHC.Host
    $rpath = $NCHC.RemotePath
    $localDest = Join-Path $_workspaceDir "result"

    Write-Host "  Local  : $localDest" -ForegroundColor White
    Write-Host ""

    if (!(Test-Path $localDest)) { New-Item -ItemType Directory -Path $localDest -Force | Out-Null }

    Set-AskpassEnv
    Write-Host "  [等待] 📱 手機推播確認後開始下載..." -ForegroundColor Yellow
    Write-Host ""

    $remoteCmd = "cd $rpath && tar cf - *.vtk *.VTK *.dat *.DAT slurm_*.log slurm_*.err chain.log Ustar_Force_record.dat 2>/dev/null"
    cmd /c "`"$($NCHC.SshExe)`" $user@$host_ `"$remoteCmd`" | tar xf - -C `"$localDest`""
    $rc = $LASTEXITCODE
    Clear-AskpassEnv

    Write-Host ""
    if ($rc -eq 0) {
        $count = (Get-ChildItem $localDest -Filter "*.vtk" -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host "  [完成] 下載成功! ($count 個 VTK 檔案)" -ForegroundColor Green
    } else {
        Write-Host "  [錯誤] 下載失敗 (exit=$rc)" -ForegroundColor Red
    }
    exit $rc
}

# ================================================================
# Action: compile — 遠端編譯 (單次 2FA)
# ================================================================
if ($Action -eq "compile") {
    Show-Banner "NCHC 遠端編譯 (單次 2FA)"

    $compileCmd = "bash build_and_submit.sh --build-only"
    $rc = Invoke-NCHC-Cmd -Command $compileCmd -Label "Compile"

    Write-Host ""
    if ($rc -eq 0) {
        Write-Host "  [完成] 編譯成功!" -ForegroundColor Green
    } else {
        Write-Host "  [錯誤] 編譯失敗 (exit=$rc)" -ForegroundColor Red
    }
    exit $rc
}

# ================================================================
# Action: submit — 編譯 + sbatch 提交 (單次 2FA)
# ================================================================
if ($Action -eq "submit") {
    Show-Banner "NCHC 編譯 + 提交 Slurm (單次 2FA)"

    $rc = Invoke-NCHC-Cmd -Command "bash build_and_submit.sh" -Label "Submit"

    Write-Host ""
    if ($rc -eq 0) {
        Write-Host "  [完成] 提交成功!" -ForegroundColor Green
    } else {
        Write-Host "  [錯誤] 提交失敗 (exit=$rc)" -ForegroundColor Red
    }
    exit $rc
}

# ================================================================
# Action: jobs — 查看 Slurm 佇列 (單次 2FA)
# ================================================================
if ($Action -eq "jobs") {
    Show-Banner "NCHC Slurm 佇列 (單次 2FA)"

    $jobsCmd = "squeue -u $($NCHC.User) -o '%.8i %.12P %.30j %.8u %.2t %.10M %.4D %.20R' && echo '---' && echo `"Active jobs: `$(squeue -u $($NCHC.User) -h | wc -l)`""
    $rc = Invoke-NCHC-Cmd -Command $jobsCmd -Label "Jobs"
    exit $rc
}

# ================================================================
# Action: cancel — 取消全部 Slurm 工作 (單次 2FA)
# ================================================================
if ($Action -eq "cancel") {
    Show-Banner "NCHC 取消全部 Slurm 工作 (單次 2FA)"

    $cancelCmd = "scancel -u $($NCHC.User) && echo '[完成] 全部工作已取消' && squeue -u $($NCHC.User)"
    $rc = Invoke-NCHC-Cmd -Command $cancelCmd -Label "Cancel"
    exit $rc
}

# ================================================================
# Action: status — 查看最新 log + 佇列 (單次 2FA)
# ================================================================
if ($Action -eq "status") {
    Show-Banner "NCHC 狀態總覽 (單次 2FA)"

    $statusCmd = "echo '=== chain.log (last 20) ===' && tail -20 chain.log 2>/dev/null; echo '' && echo '=== Latest slurm log (last 30) ===' && LATEST=`$(ls -t slurm_*.log 2>/dev/null | head -1) && [ -n `"`$LATEST`" ] && tail -30 `"`$LATEST`" || echo 'No slurm logs found'; echo '' && echo '=== Slurm queue ===' && squeue -u $($NCHC.User) -o '%.8i %.12P %.30j %.2t %.10M %.20R'"
    $rc = Invoke-NCHC-Cmd -Command $statusCmd -Label "Status"
    exit $rc
}

# ================================================================
# Action: tail — 即時追蹤 chain.log (互動式, Ctrl+C 停止)
# ================================================================
if ($Action -eq "tail") {
    Show-Banner "NCHC tail -f chain.log (Ctrl+C 停止)"

    $rc = Invoke-NCHC-Cmd -Command "tail -f chain.log" -Label "Tail" -Interactive
    exit $rc
}

# ================================================================
# Action: syncstatus — 比對本地 vs 遠端檔案 (單次 2FA)
# ================================================================
if ($Action -eq "syncstatus") {
    Show-Banner "NCHC 同步狀態比對 (單次 2FA)"
    Write-Host "  Local  : $_workspaceDir" -ForegroundColor White
    Write-Host ""

    $syncCmd = "echo '=== Source files ===' && ls -la *.cu *.h *.slurm *.sh 2>/dev/null && echo '' && echo '=== a.out ===' && ls -la a.out 2>/dev/null || echo 'a.out not found' && echo '' && echo '=== Checkpoint ===' && ls -d checkpoint/step_*/ 2>/dev/null | tail -3 || echo 'No checkpoints' && echo '' && echo '=== VTK count ===' && echo `"`$(ls *.vtk 2>/dev/null | wc -l) VTK files`" && echo '' && echo '=== Disk usage ===' && du -sh . 2>/dev/null"
    $rc = Invoke-NCHC-Cmd -Command $syncCmd -Label "SyncStatus"
    exit $rc
}

# ================================================================
# Action: cancel — 取消工作
# ================================================================
if ($Action -eq "cancel") {
    Invoke-NCHC-Batch "scancel -u $($NCHC.User)"
    exit 0
}

# ================================================================
# Action: status — 查看最新 log
# ================================================================
if ($Action -eq "status") {
    Invoke-NCHC-Batch "cd $($NCHC.RemotePath) && tail -30 slurm_*.log chain.log 2>/dev/null | tail -50"
    exit 0
}

# ================================================================
# Action: tail — 即時追蹤 log
# ================================================================
if ($Action -eq "tail") {
    Invoke-NCHC-Batch "cd $($NCHC.RemotePath) && tail -f chain.log"
    exit 0
}
