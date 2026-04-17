# WatchPull Daemon - Standalone background process (download + delete local extras)
# Downloads from remote AND deletes local files not on remote (mirrors remote exactly)
param(
    [string]$LocalPath,
    [string]$RemotePath,
    [string]$ServerName,
    [string]$ServerHost,
    [string]$ServerUser,
    [string]$ServerPass,
    [string]$PlinkPath,
    [string]$PscpPath,
    [string]$LogPath,
    [int]$Interval = 30,
    [switch]$IsWindows,
    [string]$SshOpts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
)

# ── Cross-platform SSH/SCP helpers ──────────────────────────────
function Invoke-DaemonSsh {
    param([string]$User, [string]$Pass, [string]$Host_, [string]$Command)
    if ($IsWindows) {
        return (& $PlinkPath -ssh -pw $Pass -batch "$User@$Host_" $Command 2>$null)
    } else {
        return (sshpass -p $Pass ssh $SshOpts.Split(' ') -o BatchMode=no "$User@$Host_" $Command 2>$null)
    }
}
function Invoke-DaemonScp {
    param([string]$Pass, [string]$Source, [string]$Dest)
    if ($IsWindows) {
        $null = & $PscpPath -pw $Pass -batch $Source $Dest 2>&1
    } else {
        $null = sshpass -p $Pass scp $SshOpts.Split(' ') $Source $Dest 2>&1
    }
}

# Helper function to append log with proper encoding (UTF-8 without BOM)
function Write-Log {
    param([string]$Message)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($LogPath, "$Message`r`n", $utf8NoBom)
}

# Write startup message
Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $ServerName DAEMON STARTED (Interval: ${Interval}s, WITH DELETE)"

while ($true) {
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        # Find all .dat, log*, .plt, .bin, .vtk files in main directory (no marker logic - pure hash comparison)
        $cmd = "find $RemotePath -maxdepth 1 -type f \( -name '*.dat' -o -name 'log*' -o -name '*.plt' -o -name '*.bin' -o -name '*.vtk' \) 2>/dev/null"
        $result = Invoke-DaemonSsh -User $ServerUser -Pass $ServerPass -Host_ $ServerHost -Command $cmd
        
        # Also get files in result/statistics directories (include .bin and .vtk)
        $resultCmd = "find $RemotePath/result $RemotePath/statistics -type f \( -name '*.dat' -o -name '*.plt' -o -name '*.bin' -o -name '*.vtk' -o -name 'log*' \) 2>/dev/null"
        $resultFiles = Invoke-DaemonSsh -User $ServerUser -Pass $ServerPass -Host_ $ServerHost -Command $resultCmd
        
        $allFiles = @()
        if ($result) { $allFiles += $result }
        if ($resultFiles) { $allFiles += $resultFiles }
        $allFiles = $allFiles | Sort-Object -Unique
        
        # Build set of remote relative paths (for delete comparison)
        $remoteSet = @{}
        foreach ($remotefile in $allFiles) {
            if (-not $remotefile -or $remotefile -match '\.git/' -or $remotefile -match '\.vscode/') { continue }
            $relativePath = $remotefile.Replace("$RemotePath/", "")
            $remoteSet[$relativePath] = $remotefile
        }
        
        foreach ($remotefile in $allFiles) {
            if (-not $remotefile -or $remotefile -match '\.git/' -or $remotefile -match '\.vscode/') { continue }
            
            $relativePath = $remotefile.Replace("$RemotePath/", "")
            $localFile = Join-Path $LocalPath $relativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
            
            # Get remote file hash
            $hashCmd = "md5sum '$remotefile' 2>/dev/null | cut -d' ' -f1"
            $remoteHash = Invoke-DaemonSsh -User $ServerUser -Pass $ServerPass -Host_ $ServerHost -Command $hashCmd
            
            if (-not $remoteHash) { continue }
            
            # Compare with local
            $needDownload = $false
            if (-not (Test-Path $localFile)) {
                $needDownload = $true
            }
            else {
                try {
                    $localHash = (Get-FileHash $localFile -Algorithm MD5).Hash.ToLower()
                    if ($localHash -ne $remoteHash.Trim().ToLower()) {
                        $needDownload = $true
                    }
                }
                catch { $needDownload = $true }
            }
            
            if ($needDownload) {
                # Create directory if needed
                $localDir = Split-Path $localFile -Parent
                if (-not (Test-Path $localDir)) {
                    New-Item -ItemType Directory -Path $localDir -Force | Out-Null
                }
                
                # Download file (suppress all output)
                $remoteUri = "$ServerUser@${ServerHost}:$remotefile"
                Invoke-DaemonScp -Pass $ServerPass -Source $remoteUri -Dest $localFile
                
                Write-Log "[$timestamp] $ServerName DOWNLOADED: $relativePath"
            }
        }
        
        # Pull: Delete local files not on remote (mirror remote exactly)
        # Check main directory
        $localFiles = @()
        $localFiles += Get-ChildItem -Path $LocalPath -File -ErrorAction SilentlyContinue | Where-Object { 
            $_.Name -match '\.(dat|DAT|plt|bin|vtk)$' -or $_.Name -match '^log'
        }
        
        # Check result and statistics directories
        $resultPath = Join-Path $LocalPath "result"
        $statsPath = Join-Path $LocalPath "statistics"
        if (Test-Path $resultPath) {
            $localFiles += Get-ChildItem -Path $resultPath -File -Recurse -ErrorAction SilentlyContinue | Where-Object { 
                $_.Name -match '\.(dat|DAT|plt|bin|vtk)$' -or $_.Name -match '^log'
            }
        }
        if (Test-Path $statsPath) {
            $localFiles += Get-ChildItem -Path $statsPath -File -Recurse -ErrorAction SilentlyContinue | Where-Object { 
                $_.Name -match '\.(dat|DAT|plt|bin|vtk)$' -or $_.Name -match '^log'
            }
        }
        
        foreach ($localFile in $localFiles) {
            $relativePath = $localFile.FullName.Replace($LocalPath, "").TrimStart([System.IO.Path]::DirectorySeparatorChar).Replace("\", "/")
            
            # Skip .git and .vscode
            if ($relativePath -match '\.git/' -or $relativePath -match '\.vscode/') { continue }
            
            # If not in remote set, delete it
            if (-not $remoteSet.ContainsKey($relativePath)) {
                Remove-Item $localFile.FullName -Force
                Write-Log "[$timestamp] $ServerName DELETED: $relativePath (not on remote)"
            }
        }
    }
    catch {
        Write-Log "[$timestamp] $ServerName ERROR: $_"
    }
    
    Start-Sleep -Seconds $Interval
}
