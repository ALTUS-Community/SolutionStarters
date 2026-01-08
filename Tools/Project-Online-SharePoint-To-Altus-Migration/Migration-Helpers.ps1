<#
.SYNOPSIS
  Shared helper functions for SharePoint to Dynamics 365 migration scripts.

.DESCRIPTION
  Provides common utilities used across export/import scripts:
  - Project mapping from POL exports
  - Logging functions
  - Module prerequisites checks
#>

# ==============================================================================
# LOGGING FUNCTIONS
# ==============================================================================

<#
.SYNOPSIS
  Write a standard log message and accumulate in $script:logContent array.
#>
function Write-LogMessage {
    param([string]$Message)
    
    # Initialize if not already done
    if (-not $script:logContent) {
        $script:logContent = @()
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    $script:logContent += $logEntry
    Write-Host $Message -ForegroundColor Gray
}

<#
.SYNOPSIS
  Write a warning message with yellow coloring.
#>
function Write-LogWarning {
    param([string]$Message)
    
    if (-not $script:logContent) {
        $script:logContent = @()
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [WARNING] $Message"
    $script:logContent += $logEntry
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

<#
.SYNOPSIS
  Write an error message with red coloring and optional exception details.
#>
function Write-LogError {
    param(
        [string]$Message,
        [string]$Exception = ""
    )
    
    if (-not $script:logContent) {
        $script:logContent = @()
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [ERROR] $Message"
    $script:logContent += $logEntry
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    
    if ($Exception) {
        $script:logContent += "  Exception: $Exception"
        Write-Host "  Exception: $Exception" -ForegroundColor Red
    }
}

# ==============================================================================
# PROJECT MAP FUNCTION
# ==============================================================================

<#
.SYNOPSIS
  Build a map of SharePoint project webs to POL project metadata.

.DESCRIPTION
  Scans POL export JSON files (*_reporting.json) and builds a hashtable
  mapping project web URL segments to project names and UIDs.
  
  URL segments are extracted from ProjectWorkspaceInternalHRef and decoded.
  
.PARAMETER ExportPath
  Path to the POL export folder containing *_reporting.json files.
  
.OUTPUTS
  Hashtable with keys = URL segment, values = @{Name, UID}
#>
function Build-ProjectMap {
    param([string]$ExportPath)
    
    $map = @{}
    
    if (-not (Test-Path $ExportPath)) {
        Write-LogMessage "POL export path not found: $ExportPath"
        return $map
    }
    
    $jsonFiles = Get-ChildItem -Path $ExportPath -Filter "*_reporting.json" -Recurse
    
    foreach ($file in $jsonFiles) {
        try {
            $json = Get-Content -Path $file.FullName -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $project = $json.ReportingProjectData.Project
            
            if ($project) {
                $projectName = $project.ProjectName
                $projectUID = $project.ProjectUID
                $hrefUrl = $project.ProjectWorkspaceInternalHRef
                
                if ($hrefUrl -and $projectName) {
                    # Extract the last part of the URL (project web name)
                    $urlParts = $hrefUrl -split '/'
                    $projectWebName = [uri]::UnescapeDataString($urlParts[-1])
                    
                    $map[$projectWebName] = @{
                        Name = $projectName
                        UID  = $projectUID
                    }
                    Write-Verbose "Mapped POL project '$projectName' (URL: $projectWebName, UID: $projectUID)"
                }
            }
        }
        catch {
            Write-LogMessage "Failed to parse JSON file '$($file.Name)': $($_.Exception.Message)"
        }
    }
    
    Write-LogMessage "Loaded $($map.Count) projects from POL export"
    return $map
}

# ==============================================================================
# MODULE PREREQUISITES
# ==============================================================================

<#
.SYNOPSIS
  Ensure PnP.PowerShell module is installed; install if missing.
#>
function Test-PnPModule {
    if (-not (Get-Module -ListAvailable -Name "PnP.PowerShell")) {
        Write-Host "PnP.PowerShell module not found. Installing..." -ForegroundColor Yellow
        try {
            Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Host "PnP.PowerShell module installed successfully" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to install PnP.PowerShell module: $($_.Exception.Message)"
            Write-Host "Please run manually: Install-Module PnP.PowerShell -Scope CurrentUser" -ForegroundColor Yellow
            exit 1
        }
    }
    else {
        Write-Host "PnP.PowerShell module is installed" -ForegroundColor Green
    }
}
