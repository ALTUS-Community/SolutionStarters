<#
.SYNOPSIS
Publishes MPPs to Altus from a specified root folder.

.DESCRIPTION
Given a root folder, this script finds files to publish.
- If -All is supplied, it publishes **all files** (takes precedence over -NamePattern).
- Otherwise, it publishes files matching -NamePattern (default: Project_*_published.mpp).

.PARAMETER Root
(Required) The root path where the script runs and searches for files.

.PARAMETER All
(Optional) Switch. If present, publish **all .mpp files** under -Root. This overrides -NamePattern.

.PARAMETER NamePattern
(Optional) A name pattern (wildcards supported) of files to publish when -All is not provided.
Defaults to 'Project_*_published.mpp'.

.EXAMPLE
.\Publish-MPPsToAltus.ps1 -Root 'D:\Exports'
Search D:\Exports recursively for 'Project_*_published.mpp' and publish matches.

.EXAMPLE
.\Publish-MPPsToAltus.ps1 -Root 'D:\Exports' -All
Publish **all .mpp files** under D:\Exports (overrides -NamePattern).

.EXAMPLE
.\Publish-MPPsToAltus.ps1 -Root 'D:\Exports' -NamePattern '*.mpp'
Only publish *.mpp files under D:\Exports.

.NOTES
Run:
  Get-Help .\Publish-MPPsToAltus.ps1 -Full
  Get-Help .\Publish-MPPsToAltus.ps1 -Examples
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Publish all .mpp files (overrides -NamePattern).")]
    [switch]$All,

    [Parameter(HelpMessage = "Wildcard pattern of files to publish when -All is not set.")]
    [string]$NamePattern = 'Project_*_published.mpp'
)

$ErrorActionPreference = 'Stop';

# Validate Common.ps1 exists before dot-sourcing
$commonPath = "$PSScriptRoot\Common.ps1"
if (-not (Test-Path $commonPath)) {
    throw "Required file not found: $commonPath"
}
. $commonPath

if ($PSVersionTable.PSVersion.Major -gt 5) {
    Write-Host "This script does not support PowerShell versions greater than 5.0. Exiting." -ForegroundColor Red
    exit 1
}

$effectivePattern = if ($All) { '*.mpp' } else { $NamePattern }

Write-Verbose "All: $All"
Write-Verbose "Effective pattern: $effectivePattern"

$filesPath = Join-Path $PSScriptRoot "Files"
$files = Get-ChildItem -Path $filesPath -File -Recurse -Filter $effectivePattern -ErrorAction Stop

if (-not $files) {
    Write-Host "No files found matching '$effectivePattern' under '$filesPath'."
    exit 0
}

Open-WinProj

$automation = Get-AltusAutomationObject

$successArray = @()
$failArray = @()

# Start logging to file
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$logsFolder = Join-Path $PSScriptRoot "Logs"
$logsFolder = Join-Path $logsFolder "Publish-MPPsToAltus_$timestamp"
# Create Logs folder if it doesn't exist
if (-not (Test-Path $logsFolder)) {
    New-Item -Path $logsFolder -ItemType Directory | Out-Null
}

foreach ($f in $files) {
    try {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Publishing: $($f.FullName)"
        $result = Invoke-AltusPublishProject -projectPath $f.FullName -automation $automation
        if ($result.Success) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($f.FullName) - Publish succeeded." -ForegroundColor Green
            $successArray += $f.FullName
        } else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($f.FullName) - Publish failed." -ForegroundColor Yellow
            Write-Host "Error Message: $($result.Error)" -ForegroundColor Yellow
            $failArray += [PSCustomObject]@{
                Path = $f.FullName
                Error = $result.Error
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        $array = $result.Logs
        $resourceConfig = $result.ResourceConfig
        $projectName = Split-Path -Path $f.FullName -Leaf
        $array | Out-File -FilePath "$logsFolder\$projectName-publish-log.txt" -Encoding utf8
        $resourceConfig | Out-File -FilePath "$logsFolder\$projectName-resource-config.json" -Encoding utf8
        if (-not [String]::IsNullOrEmpty($result.Error)) {
            if ($result.Success) {
                $result.Error | Out-File -FilePath "$logsFolder\$projectName-errors.json" -Encoding utf8
                Write-Warning "Publish completed with errors. See: '$logsFolder\$projectName-errors.json'";
            } else {
                $result.Error | Out-File -FilePath "$logsFolder\$projectName-errors.txt" -Encoding utf8
            }
        }
    }
    catch {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Failed to publish: $($f.FullName)" -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        $failArray += [PSCustomObject]@{
            Path = $f.FullName
            Error = $_.ToString()
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
}

# Only write files if there's content
if ($successArray.Count -gt 0) {
    $successArray | Out-File -FilePath "$logsFolder\successes.txt" -Encoding utf8
}
if ($failArray.Count -gt 0) {
    $failArray | Format-Table -AutoSize | Out-File -FilePath "$logsFolder\failures.txt" -Encoding utf8
    $failArray | Export-Csv -Path "$logsFolder\failures.csv" -NoTypeInformation -Encoding utf8
}

Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Completed. Attempted to publish $($files.Count) file(s). Succeeded: $($successArray.Count), Failed: $($failArray.Count)." -ForegroundColor Cyan

Close-WinProj
