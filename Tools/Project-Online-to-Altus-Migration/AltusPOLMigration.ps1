param(
    [Parameter(Mandatory=$false)]
    [string]$EnvironmentUrl,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('E', 'W', 'Execute', 'WhatIf', IgnoreCase=$true)]
    [string]$ExecutionMode,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('ImportNamedResources', 'ImportNamedAndGenericResources', 'ImportProjects', IgnoreCase=$true)]
    [string]$Action
)

# Check Prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Cyan

# Check PowerShell version (minimum 7.4)
$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -lt 7) {
    # Check if PowerShell 7 is installed
    $pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Path
    
    if (-not $pwshPath) {
        Write-Host "`nERROR: PowerShell 7 is not installed." -ForegroundColor Red
        Write-Host "Current version: $($psVersion.ToString())" -ForegroundColor Yellow
        Write-Host "Please download and install PowerShell 7.4 or later from: https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Yellow
        Write-Host "`nExiting..." -ForegroundColor Red
        exit 1
    }
    
    # Relaunch in PowerShell 7 with same parameters
    Write-Host "Relaunching script in PowerShell 7..." -ForegroundColor Yellow
    
    # Build parameter list to pass to pwsh
    $paramList = @()
    if ($EnvironmentUrl) { $paramList += "-EnvironmentUrl", $EnvironmentUrl }
    if ($ExecutionMode) { $paramList += "-ExecutionMode", $ExecutionMode }
    if ($Action) { $paramList += "-Action", $Action }
    
    & pwsh.exe -File $MyInvocation.MyCommand.Path @paramList
    exit
}
elseif ($psVersion.Major -lt 7 -or ($psVersion.Major -eq 7 -and $psVersion.Minor -lt 4)) {
    Write-Host "`nERROR: PowerShell 7.4 or later is required." -ForegroundColor Red
    Write-Host "Current version: $($psVersion.ToString())" -ForegroundColor Yellow
    Write-Host "Please download and install the latest PowerShell from: https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Yellow
    Write-Host "`nExiting..." -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ PowerShell version $($psVersion.ToString()) meets minimum requirement of 7.4" -ForegroundColor Green

# Check Az module is installed
$azModule = Get-Module -ListAvailable -Name Az.Accounts
if (-not $azModule) {
    Write-Host "`nERROR: Az PowerShell module is not installed." -ForegroundColor Red
    Write-Host "Please install the Az module by running:" -ForegroundColor Yellow
    Write-Host "  Install-Module -Name Az -Repository PSGallery -Force -AllowClobber" -ForegroundColor Cyan
    Write-Host "`nExiting..." -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ Az PowerShell module is installed (version $($azModule[0].Version))" -ForegroundColor Green

Write-Host ""

. $PSScriptRoot\Core.ps1
. $PSScriptRoot\TableOperations.ps1
. $PSScriptRoot\CommonFunctions.ps1
. $PSScriptRoot\ImportResources.ps1
. $PSScriptRoot\ImportProjects.ps1

# Start logging to file
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$logsFolder = Join-Path $PSScriptRoot "Logs"
# Create Logs folder if it doesn't exist
if (-not (Test-Path $logsFolder)) {
    New-Item -Path $logsFolder -ItemType Directory | Out-Null
}
$logFile = Join-Path $logsFolder "AltusPOLMigration_$timestamp.txt"
Start-Transcript -Path $logFile -Append

Write-Host "Logging to: $logFile" -ForegroundColor Cyan
Write-Host ""

Write-Host "       " -ForegroundColor White -BackgroundColor DarkMagenta -NoNewline
Write-Host "`n" -BackgroundColor Black -NoNewline
Write-Host " Ʌ̲LTUS " -ForegroundColor White -BackgroundColor DarkMagenta -NoNewline
Write-Host "`n" -BackgroundColor Black -NoNewline
Write-Host "       " -ForegroundColor White -BackgroundColor DarkMagenta -NoNewline
Write-Host "`n" -BackgroundColor Black -NoNewline

Write-Host "`n--------------------------------------------" -ForegroundColor Cyan
Write-Host "Project Online Migration Script" -ForegroundColor Cyan
Write-Host "--------------------------------------------" -ForegroundColor Cyan

# Use parameter if provided, otherwise prompt user
if ([string]::IsNullOrWhiteSpace($EnvironmentUrl)) {
    $environmentUrl = Read-Host -Prompt "Enter the Dataverse environment URL (e.g., https://yourorg.crm.dynamics.com/)"
}
else {
    $environmentUrl = $EnvironmentUrl
    Write-Host "`nEnvironment URL provided via parameter: $environmentUrl" -ForegroundColor Cyan
}

# Ensure the URL ends with a trailing slash
if (-not $environmentUrl.EndsWith('/')) {
    $environmentUrl += '/'
}

Connect $environmentUrl

# Connection successful, display menu
Write-Host "`nConnection to $environmentUrl successful!" -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT: Please ensure that the files to be imported are located in the 'Files' folder relative to this script." -ForegroundColor Yellow
Write-Host ""

# Use parameter if provided, otherwise prompt user
if ([string]::IsNullOrWhiteSpace($ExecutionMode)) {
    Write-Host "`nPlease select a mode of operation:" -BackgroundColor Gray -ForegroundColor Black
    Write-Host "`nE: Execute (will potentially create records in your Dataverse environment)" -BackgroundColor White -ForegroundColor Black
    Write-Host "W: What-If (simulates actions without actually making changes)" -BackgroundColor White -ForegroundColor Black
    Write-Host "`n"
    $executionMode = Read-Host -Prompt "Enter your choice (E or W)"
}
else {
    $executionMode = $ExecutionMode
    Write-Host "`nExecution mode provided via parameter: $executionMode" -ForegroundColor Cyan
}

switch ($executionMode.ToUpper()) {
    { $_ -in "E", "EXECUTE" } {
        $executeScript = $true
        Write-Host "`n--------------------------------------------" -ForegroundColor Green
        Write-Host "Execution Mode: Execute" -ForegroundColor Green
        Write-Host "Script will make changes to your Dataverse environment." -ForegroundColor Green
        Write-Host "--------------------------------------------" -ForegroundColor Green
    }
    { $_ -in "W", "WHATIF" } {
        $executeScript = $false
        Write-Host "`n--------------------------------------------" -ForegroundColor Magenta
        Write-Host "Execution Mode: What-If" -ForegroundColor Magenta
        Write-Host "Script will simulate actions without making changes." -ForegroundColor Magenta
        Write-Host "--------------------------------------------" -ForegroundColor Magenta
    }
    default {
        Write-Host "`nInvalid selection. Please run the script again and choose a valid option." -ForegroundColor Red
        Stop-Transcript
        exit
    }
}

# Use parameter if provided, otherwise prompt user
if ([string]::IsNullOrWhiteSpace($Action)) {
    Write-Host "`nPlease select an action:" -BackgroundColor Gray -ForegroundColor Black
    Write-Host "`n1: Import Resources (Named only)" -BackgroundColor White -ForegroundColor Black
    Write-Host "2: Import Resources (Named and Generic)" -BackgroundColor White -ForegroundColor Black
    Write-Host "3: Import Projects" -BackgroundColor White -ForegroundColor Black
    Write-Host "Q: Quit" -BackgroundColor White -ForegroundColor Black
    Write-Host "`n"
    $actionChoice = Read-Host -Prompt "Enter your choice (1, 2, 3 or Q)"
}
else {
    $actionChoice = $Action
    Write-Host "`nAction provided via parameter: $actionChoice" -ForegroundColor Cyan
}

switch ($actionChoice.ToUpper()) {
    { $_ -in "1", "IMPORTNAMEDRESOURCES" } {
        Write-Host "`nStarting Import Resources (Named only)..." 
        ImportResources -Mode 'NamedOnly' -ExecutionMode $executeScript
    }
    { $_ -in "2", "IMPORTNAMEDANDGENERICRESOURCES" } {
        Write-Host "`nStarting Import Resources (Named and Generic)..."
        ImportResources -Mode 'NamedAndGeneric' -ExecutionMode $executeScript
    }
    { $_ -in "3", "IMPORTPROJECTS" } {
        Write-Host "`nStarting Import Projects..." 
        ImportProjects -ExecutionMode $executeScript
    }
    "Q" {
        Write-Host "`nExiting..." -ForegroundColor Yellow
        Stop-Transcript
        exit
    }
    default {
        Write-Host "`nInvalid selection. Please run the script again and choose a valid option." -ForegroundColor Red
        Stop-Transcript
        exit
    }
}

# Stop logging
Stop-Transcript
Write-Host "`nLog file saved to: $logFile" 