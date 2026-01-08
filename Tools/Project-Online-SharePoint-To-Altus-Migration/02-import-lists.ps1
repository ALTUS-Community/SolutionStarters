<#
.SYNOPSIS
    Imports SharePoint project data into Dynamics 365.

.DESCRIPTION
    Iterates through project folders containing Data.xml files and imports them
    into Dynamics 365 using the Sensei.DevOps.D365.DataMigration console app.

.PARAMETER D365Url
    The URL of your Dynamics 365 environment (e.g., https://orgname.crm.dynamics.com)

.PARAMETER SchemaPath
    Path to the CMT schema.xml file

.PARAMETER DataFolder
    Root folder containing project subfolders with Data.xml files

.PARAMETER MigrationExePath
    Path to the Sensei.DevOps.D365.DataMigration.exe executable

.PARAMETER Force
    If true, updates existing records. Default is false (insert only)

.PARAMETER ParallelRequests
    Number of parallel requests for faster import. Default is 4

.PARAMETER EnableDisablingOfPlugins
    If true, bypasses plugins during migration. Default is false

.PARAMETER ProjectFilter
    Optional wildcard pattern(s) to filter project folders by name. Supports multiple patterns.
    Examples: "Project_A", "*2024*", "Project*", @("ProjectA", "ProjectB")

.PARAMETER POLExportPath
    Optional path to Project Online export folder containing *_reporting.json files.
    If provided, project names are sourced from the JSON export instead of folder names.
    Example: "C:\exports\POL\VNext"

.EXAMPLE
    .\02-import.ps1 -D365Url "https://orgname.crm.dynamics.com" -SchemaPath ".\data_schema.xml" -DataFolder ".\ExportedData"

.EXAMPLE
    .\02-import.ps1 -D365Url "https://orgname.crm.dynamics.com" -SchemaPath ".\data_schema.xml" -DataFolder ".\ExportedData" -Force $true -ParallelRequests 8

.EXAMPLE
    .\02-import.ps1 -D365Url "https://orgname.crm.dynamics.com" -SchemaPath ".\data_schema.xml" -DataFolder ".\ExportedData" -ProjectFilter "*2024*"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$D365Url = "https://senseijumpstart.crm.dynamics.com",
    
    [Parameter(Mandatory = $false)]
    [string]$SchemaPath = (Join-Path $PSScriptRoot "data_schema.xml"),
    
    [Parameter(Mandatory = $false)]
    [string]$DataFolder = (Join-Path $PSScriptRoot "Output"),
    
    [Parameter(Mandatory = $false)]
    [string]$MigrationExePath = ".\Sensei.DevOps.D365.DataMigration\bin\Debug\net8.0\win-x64\Sensei.DevOps.D365.DataMigration.exe",
    
    [Parameter(Mandatory = $false)]
    [bool]$Force = $false,
    
    [Parameter(Mandatory = $false)]
    [int]$ParallelRequests = 4,
    
    [Parameter(Mandatory = $false)]
    [bool]$EnableDisablingOfPlugins = $false,
    
    [Parameter(Mandatory = $false)]
    [string[]]$ProjectFilter = @(),

    [Parameter(Mandatory = $false)]
    [string]$POLExportPath
)

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Import migration helpers
$migrationHelpersPath = Join-Path $PSScriptRoot "Migration-Helpers.ps1"
if (-not (Test-Path $migrationHelpersPath)) {
    Write-Error "Migration helpers script not found: $migrationHelpersPath"
    exit 1
}
. $migrationHelpersPath

# Ensure paths are absolute
$SchemaPath = Resolve-Path $SchemaPath -ErrorAction Stop
$DataFolder = Resolve-Path $DataFolder -ErrorAction Stop
$MigrationExePath = Resolve-Path $MigrationExePath -ErrorAction Stop

Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "Dynamics 365 Data Import - Project Data Migration" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  D365 URL:              $D365Url"
Write-Host "  Schema Path:           $SchemaPath"
Write-Host "  Data Folder:           $DataFolder"
Write-Host "  Migration Tool:        $MigrationExePath"
Write-Host "  Force Update:          $Force"
Write-Host "  Parallel Requests:     $ParallelRequests"
Write-Host "  Disable Plugins:       $EnableDisablingOfPlugins"
if ($ProjectFilter -and $ProjectFilter.Count -gt 0) {
    Write-Host "  Project Filter:        $($ProjectFilter -join ', ')" -ForegroundColor Yellow
}
if ($POLExportPath) {
    Write-Host "  POL Export Path:       $POLExportPath" -ForegroundColor Yellow
}
Write-Host ""

# Build project map from POL export if provided
$projectMap = @{}  # Map of data folder name → POL ProjectName
if ($POLExportPath) {
    $projectMap = Build-ProjectMap -ExportPath $POLExportPath
    Write-Host ""
}

# Verify schema file exists
if (-not (Test-Path $SchemaPath)) {
    Write-Error "Schema file not found: $SchemaPath"
    exit 1
}

# Verify migration executable exists
if (-not (Test-Path $MigrationExePath)) {
    Write-Error "Migration executable not found: $MigrationExePath"
    exit 1
}

# Find all Data.xml files in subdirectories
$dataFiles = Get-ChildItem -Path $DataFolder -Filter "Data.xml" -Recurse -File

if ($dataFiles.Count -eq 0) {
    Write-Warning "No Data.xml files found in $DataFolder"
    exit 0
}

# Apply project filter if specified
if ($ProjectFilter -and $ProjectFilter.Count -gt 0) {
    $filteredFiles = @()
    foreach ($dataFile in $dataFiles) {
        $projectFolder = $dataFile.Directory.Name
        # Try to match against POL name if available; otherwise use folder name
        $matchNameToTest = if ($projectMap.ContainsKey($projectFolder)) {
            $projectMap[$projectFolder].Name
        }
        else {
            $projectFolder
        }
        
        $matched = $false
        foreach ($pattern in $ProjectFilter) {
            if ($matchNameToTest -like $pattern) {
                $matched = $true
                break
            }
        }
        if ($matched) {
            $filteredFiles += $dataFile
        }
    }
    $dataFiles = $filteredFiles
    Write-Host "Filtered to $($dataFiles.Count) project(s) matching: $($ProjectFilter -join ', ')" -ForegroundColor Yellow
    
    if ($dataFiles.Count -eq 0) {
        Write-Warning "No projects match the filter: $($ProjectFilter -join ', ')"
        exit 0
    }
}

Write-Host "Found $($dataFiles.Count) Data.xml file(s) to import" -ForegroundColor Green
Write-Host ""

# Track results
$results = @()
$successCount = 0
$failureCount = 0

# Process each data file
foreach ($dataFile in $dataFiles) {
    $projectFolder = $dataFile.Directory.Name
    $dataPath = $dataFile.FullName
    
    # Use POL project name if available; otherwise use folder name
    $displayName = $projectFolder
    $projectUID = $null
    if ($projectMap.ContainsKey($projectFolder)) {
        $displayName = $projectMap[$projectFolder].Name
        $projectUID = $projectMap[$projectFolder].UID
    }
    
    Write-Host ("-" * 80) -ForegroundColor Gray
    Write-Host "Processing: $displayName" -ForegroundColor Cyan
    if ($projectUID) {
        Write-Host "  ProjectUID: $projectUID" -ForegroundColor Gray
    }
    Write-Host "  Data File: $dataPath"
    Write-Host ""
    
    # Build arguments for migration tool
    $arguments = @(
        "-UseInteractive", "true",
        "-D365Url", "`"$D365Url`"",
        "-SchemaPath", "`"$SchemaPath`"",
        "-DataPath", "`"$dataPath`"",
        "-Force", $Force.ToString().ToLower(),
        "-ParallelRequests", $ParallelRequests.ToString(),
        "-EnableDisablingOfPlugins", $EnableDisablingOfPlugins.ToString().ToLower()
    )
    
    # Execute migration
    $startTime = Get-Date
    Write-Host "Starting import at $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
    
    try {
        $process = Start-Process -FilePath $MigrationExePath `
            -ArgumentList $arguments `
            -Wait `
            -PassThru `
            -NoNewWindow
        
        $endTime = Get-Date
        $duration = $endTime - $startTime
        
        if ($process.ExitCode -eq 0) {
            Write-Host "✓ SUCCESS: $displayName imported successfully" -ForegroundColor Green
            Write-Host "  Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
            $successCount++
            
            $results += [PSCustomObject]@{
                Project  = $displayName
                Status   = "Success"
                ExitCode = $process.ExitCode
                Duration = $duration
                DataPath = $dataPath
            }
        }
        else {
            Write-Host "✗ FAILED: $displayName import failed with exit code $($process.ExitCode)" -ForegroundColor Red
            Write-Host "  Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
            $failureCount++
            
            $results += [PSCustomObject]@{
                Project  = $displayName
                Status   = "Failed"
                ExitCode = $process.ExitCode
                Duration = $duration
                DataPath = $dataPath
            }
        }
    }
    catch {
        $endTime = Get-Date
        $duration = $endTime - $startTime
        
        Write-Host "✗ ERROR: $displayName - $($_.Exception.Message)" -ForegroundColor Red
        $failureCount++
        
        $results += [PSCustomObject]@{
            Project  = $displayName
            Status   = "Error"
            ExitCode = -1
            Duration = $duration
            DataPath = $dataPath
            Error    = $_.Exception.Message
        }
    }
    
    Write-Host ""
}

# Summary
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "Import Summary" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host ""
Write-Host "Total Projects:        $($dataFiles.Count)"
Write-Host "Successful Imports:    $successCount" -ForegroundColor Green
Write-Host "Failed Imports:        $failureCount" -ForegroundColor $(if ($failureCount -gt 0) { "Red" } else { "Gray" })
Write-Host ""

# Detailed results table
$results | Format-Table -Property Project, Status, ExitCode, @{Label = "Duration"; Expression = { $_.Duration.ToString('hh\:mm\:ss') } } -AutoSize

# Export results to CSV
$resultsPath = Join-Path $DataFolder "import-results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $resultsPath -NoTypeInformation
Write-Host "Results exported to: $resultsPath" -ForegroundColor Gray
Write-Host ""

# Exit with appropriate code
if ($failureCount -gt 0) {
    Write-Host "Import completed with errors" -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host "All imports completed successfully!" -ForegroundColor Green
    exit 0
}
