<#
.SYNOPSIS
    Setup 'mobaxterm' command alias for PowerShell (Windows & macOS/Linux)
.DESCRIPTION
    Run this script once to add 'mobaxterm' function to your PowerShell profile.
    - Windows: mobaxterm calls Pwshell_mainsystem.ps1 (PuTTY backend)
    - macOS/Linux: mobaxterm calls Zsh_mainsystem.sh (ssh/rsync backend)
    After setup, you can use: mobaxterm <command> [arguments]
.EXAMPLE
    .\Pwshell_turnmoba.ps1
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$_isWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)

if ($_isWindows) {
    $TargetScript = Join-Path $ScriptDir "Pwshell_mainsystem.ps1"
    $FunctionCode = @"

# ========== MobaXterm Alias ==========
function mobaxterm {
    & '$TargetScript' @args
}
# ========== End MobaXterm Alias ==========
"@
} else {
    $TargetScript = Join-Path $ScriptDir "Zsh_mainsystem.sh"
    # On macOS/Linux pwsh, call the bash script
    $FunctionCode = @"

# ========== MobaXterm Alias ==========
function mobaxterm {
    & bash '$TargetScript' @args
}
# ========== End MobaXterm Alias ==========
"@
}

# 檢查是否已經添加過
# 確保 Profile 目錄及檔案存在
$ProfileDir = Split-Path -Parent $PROFILE
if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
}
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$ProfileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if ($ProfileContent -and $ProfileContent.Contains("MobaXterm Alias")) {
    Write-Host "[INFO] 'mobaxterm' alias already exists in your profile. Updating..." -ForegroundColor Yellow
    # Remove old block and re-add
    $ProfileContent = $ProfileContent -replace '(?s)# ========== MobaXterm Alias ==========.*?# ========== End MobaXterm Alias ==========\r?\n?', ''
    Set-Content -Path $PROFILE -Value $ProfileContent -NoNewline
    Add-Content -Path $PROFILE -Value $FunctionCode
    Write-Host "[UPDATED] 'mobaxterm' function updated in $PROFILE" -ForegroundColor Green
} else {
    Add-Content -Path $PROFILE -Value $FunctionCode
    Write-Host "[SUCCESS] 'mobaxterm' alias added to your PowerShell profile!" -ForegroundColor Green
}

Write-Host "          Profile: $PROFILE" -ForegroundColor Gray
Write-Host "          Backend: $TargetScript" -ForegroundColor Gray

Write-Host ""
Write-Host "To activate now, run:" -ForegroundColor Cyan
Write-Host "  . `$PROFILE" -ForegroundColor White
Write-Host ""
Write-Host "Or restart PowerShell, then you can use:" -ForegroundColor Cyan
Write-Host "  mobaxterm gpus" -ForegroundColor White
Write-Host "  mobaxterm ssh 87:3" -ForegroundColor White
Write-Host "  mobaxterm watchpull .89" -ForegroundColor White
Write-Host "  mobaxterm push" -ForegroundColor White
Write-Host ""
