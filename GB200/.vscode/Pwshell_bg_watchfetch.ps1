# WatchFetch Daemon - Standalone background process (download only, no delete)
# Downloads from remote WITHOUT deleting local files (preserves local-only files)
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

# Patterns for files to sync
$includePatterns = @("*.dat", "log*", "*.plt", "*.bin", "*.vtk")

# Write startup message
Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $ServerName WATCHFETCH DAEMON STARTED (Interval: ${Interval}s, NO DELETE)"

while ($true) {
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        # Get remote files (main directory)
        $cmd = "find $RemotePath -maxdepth 1 -type f \( -name '*.dat' -o -name 'log*' -o -name '*.plt' -o -name '*.bin' -o -name '*.vtk' \) 2>/dev/null"
        $result = Invoke-DaemonSsh -User $ServerUser -Pass $ServerPass -Host_ $ServerHost -Command $cmd
        
        # Get files in result/statistics directories
        $resultCmd = "find $RemotePath/result $RemotePath/statistics -type f \( -name '*.dat' -o -name '*.plt' -o -name '*.bin' -o -name '*.vtk' -o -name 'log*' \) 2>/dev/null"
        $resultFiles = Invoke-DaemonSsh -User $ServerUser -Pass $ServerPass -Host_ $ServerHost -Command $resultCmd
        
        $allRemoteFiles = @()
        if ($result) { $allRemoteFiles += $result }
        if ($resultFiles) { $allRemoteFiles += $resultFiles }
        $allRemoteFiles = $allRemoteFiles | Sort-Object -Unique
        
        # Build set of remote relative paths
        $remoteSet = @{}
        foreach ($remotefile in $allRemoteFiles) {
            if (-not $remotefile -or $remotefile -match '\.git/' -or $remotefile -match '\.vscode/') { continue }
            $relativePath = $remotefile.Replace("$RemotePath/", "")
            $remoteSet[$relativePath] = $remotefile
        }
        
        # Download new/modified files from remote
        foreach ($relativePath in $remoteSet.Keys) {
            $remotefile = $remoteSet[$relativePath]
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
                
                # Download file
                $remoteUri = "$ServerUser@${ServerHost}:$remotefile"
                Invoke-DaemonScp -Pass $ServerPass -Source $remoteUri -Dest $localFile
                
                Write-Log "[$timestamp] $ServerName DOWNLOADED: $relativePath"
            }
        }
        
        # Fetch: NO deletion of local-only files (preserve local extras)
    }
    catch {
        Write-Log "[$timestamp] $ServerName ERROR: $_"
    }
    
    Start-Sleep -Seconds $Interval
}
