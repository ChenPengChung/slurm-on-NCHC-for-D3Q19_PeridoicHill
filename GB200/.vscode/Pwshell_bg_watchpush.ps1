# WatchPush Daemon - Standalone background process (upload + delete remote extras)
# Uploads to remote AND deletes remote files not present locally (mirrors local exactly)
param(
    [string]$LocalPath,
    [string]$RemotePath,
    [string]$ServersJson,
    [string]$PlinkPath,
    [string]$PscpPath,
    [string]$LogPath,
    [int]$Interval = 10,
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

$servers = $ServersJson | ConvertFrom-Json
# 排除規則：程式碼輸出檔案不上傳（避免覆蓋遠端正在寫入的檔案）
$excludePatterns = @(
    ".git/*", ".vscode/*", ".claude/*", # 系統資料夾
    "a.out", "*.o", "*.exe",         # 編譯產物
    "*.dat", "*.DAT",                # 輸出資料檔
    "log*",                          # log 檔案
    "*.plt",                         # 繪圖檔案
    "result/*", "backup/*", "statistics/*"  # 輸出資料夾
)
$lastHashes = @{}

# Helper function to append log with proper encoding (UTF-8 without BOM)
function Write-Log {
    param([string]$Message)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($LogPath, "$Message`r`n", $utf8NoBom)
}

# Write startup message
Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] DAEMON STARTED (Interval: ${Interval}s, WITH DELETE)"

while ($true) {
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        # Get all local files (build current local set)
        $changedFiles = @()
        $localSet = @{}
        Get-ChildItem -Path $LocalPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $relativePath = $_.FullName.Substring($LocalPath.Length + 1).Replace("\", "/")
            
            # Check exclusions
            $exclude = $false
            foreach ($pattern in $excludePatterns) {
                if ($relativePath -like $pattern) { $exclude = $true; break }
            }
            
            if (-not $exclude) {
                $localSet[$relativePath] = $true
                try {
                    $currentHash = (Get-FileHash $_.FullName -Algorithm MD5 -ErrorAction Stop).Hash
                    if (-not $lastHashes.ContainsKey($relativePath) -or $lastHashes[$relativePath] -ne $currentHash) {
                        $changedFiles += @{ Path = $relativePath; FullPath = $_.FullName }
                        $lastHashes[$relativePath] = $currentHash
                    }
                }
                catch { }
            }
        }
        
        # Upload changed files
        if ($changedFiles.Count -gt 0) {
            foreach ($file in $changedFiles) {
                foreach ($server in $servers) {
                    $remoteFile = "$RemotePath/$($file.Path)"
                    $remoteUri = "$($server.User)@$($server.Host):$remoteFile"
                    
                    # Create remote directory if needed
                    $remoteDir = [System.IO.Path]::GetDirectoryName($remoteFile).Replace("\", "/")
                    $mkdirCmd = "mkdir -p '$remoteDir' 2>/dev/null"
                    $null = Invoke-DaemonSsh -User $server.User -Pass $server.Password -Host_ $server.Host -Command $mkdirCmd
                    
                    # Upload file
                    Invoke-DaemonScp -Pass $server.Password -Source $file.FullPath -Dest $remoteUri
                }
                
                Write-Log "[$timestamp] UPLOADED: $($file.Path)"
            }
        }
        
        # Push: Delete remote files not present locally (mirror local exactly)
        foreach ($server in $servers) {
            # Get remote file list (source code files only, matching exclude patterns)
            $findCmd = "find $RemotePath -type f ! -path '*/.git/*' ! -path '*/.vscode/*' ! -path '*/result/*' ! -path '*/backup/*' ! -path '*/statistics/*' ! -name '*.dat' ! -name '*.DAT' ! -name '*.o' ! -name '*.exe' ! -name '*.plt' ! -name '*.bin' ! -name '*.vtk' ! -name '*.vtu' ! -name 'a.out' ! -name 'log*' ! -name '*.swp' ! -name '*.swo' ! -name '*~' ! -name '*.pyc' ! -name '.DS_Store' 2>/dev/null"
            $remoteFiles = Invoke-DaemonSsh -User $server.User -Pass $server.Password -Host_ $server.Host -Command $findCmd
            
            if ($remoteFiles) {
                foreach ($remotefile in $remoteFiles) {
                    if (-not $remotefile) { continue }
                    $relativePath = $remotefile.Replace("$RemotePath/", "")
                    # If remote file not in local set, delete it from remote
                    if (-not $localSet.ContainsKey($relativePath)) {
                        $rmCmd = "rm -f '$remotefile' 2>/dev/null"
                        $null = Invoke-DaemonSsh -User $server.User -Pass $server.Password -Host_ $server.Host -Command $rmCmd
                        Write-Log "[$timestamp] DELETED on $($server.Host): $relativePath (not in local)"
                    }
                }
                
                # Clean up empty directories
                $cleanupCmd = "find $RemotePath -type d -empty ! -path '*/.git/*' -delete 2>/dev/null"
                $null = Invoke-DaemonSsh -User $server.User -Pass $server.Password -Host_ $server.Host -Command $cleanupCmd
            }
        }
    }
    catch {
        Write-Log "[$timestamp] ERROR: $_"
    }
    
    Start-Sleep -Seconds $Interval
}
