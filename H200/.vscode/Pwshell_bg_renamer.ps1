# VTK File Auto-Renamer
# Monitors result directory and renames VTK files to use zero-padding format
param(
    [string]$WatchPath,
    [int]$CheckInterval = 5
)

$logFile = Join-Path $WatchPath ".vscode/vtk-renamer.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    try {
        Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
    } catch {}
    Write-Host $logEntry
}

Write-Log "VTK Renamer started, monitoring: $WatchPath"

# Track processed files to avoid re-processing
$processedFiles = @{}

while ($true) {
    try {
        $resultPath = Join-Path $WatchPath "result"
        if (-not (Test-Path $resultPath)) {
            Start-Sleep -Seconds $CheckInterval
            continue
        }
        
        # Find velocity_merged_*.vtk files that don't have zero-padding
        $vtkFiles = Get-ChildItem -Path $resultPath -Filter "velocity_merged_*.vtk" -File
        
        foreach ($file in $vtkFiles) {
            # Skip if already processed in this session
            if ($processedFiles.ContainsKey($file.FullName)) { continue }
            
            # Extract step number from filename
            if ($file.Name -match '^velocity_merged_(\d+)\.vtk$') {
                $stepNumber = $matches[1]
                
                # Check if already in correct format (6 digits)
                if ($stepNumber.Length -lt 6) {
                    # Need to rename
                    $paddedStep = $stepNumber.PadLeft(6, '0')
                    $newName = "velocity_merged_$paddedStep.vtk"
                    $newPath = Join-Path $resultPath $newName
                    
                    # Rename the file
                    try {
                        if (-not (Test-Path $newPath)) {
                            Rename-Item -Path $file.FullName -NewName $newName -Force
                            Write-Log "RENAMED: $($file.Name) -> $newName"
                            $processedFiles[$newPath] = $true
                        }
                    }
                    catch {
                        Write-Log "ERROR renaming $($file.Name): $_"
                    }
                }
                else {
                    # Already in correct format
                    $processedFiles[$file.FullName] = $true
                }
            }
        }
    }
    catch {
        Write-Log "ERROR in main loop: $_"
    }
    
    Start-Sleep -Seconds $CheckInterval
}
