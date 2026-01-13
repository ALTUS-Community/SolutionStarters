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
    [Parameter(Mandatory = $true)]
    [string]$D365Url,
    
    [Parameter(Mandatory = $false)]
    [string]$SchemaPath = (Join-Path $PSScriptRoot "data_schema.xml"),
    
    [Parameter(Mandatory = $true)]
    [string] $DataFolder,
    
    [Parameter(Mandatory = $false)]
    [string]$MigrationExePath = (Join-Path $PSScriptRoot "Tools\DataMigration\Sensei.DevOps.D365.DataMigration.exe"),
    
    [Parameter(Mandatory = $false)]
    [bool]$Force = $true,
    
    [Parameter(Mandatory = $false)]
    [int]$ParallelRequests = 4,
    
    [Parameter(Mandatory = $false)]
    [bool]$EnableDisablingOfPlugins = $false,
    
    [Parameter(Mandatory = $false)]
    [string[]]$ProjectFilter = @(),

    [Parameter(Mandatory = $true)]
    [string] $POLExportPath
)

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

## Consolidation: always enabled
$ConsolidatedOutput = Join-Path $PSScriptRoot "Output\Data_merged.xml"

# Import common helpers
$commonHelpersPath = Join-Path $PSScriptRoot "Common-Helpers.ps1"
if (-not (Test-Path $commonHelpersPath)) {
    Write-Error "Common helpers script not found: $commonHelpersPath"
    $global:LASTEXITCODE = 1
    return
}
. $commonHelpersPath

function Merge-DataFiles {
    param(
        [Parameter(Mandatory = $true)] [System.IO.FileInfo[]]$Files,
        [Parameter(Mandatory = $true)] [string]$OutputPath
    )

    if (-not $Files -or $Files.Count -eq 0) { return $null }

    # Load first file as base
    [xml]$baseDoc = Get-Content -Raw -Path $Files[0].FullName
    $baseRoot = $baseDoc.SelectSingleNode("/entities")

    # Merge remaining files
    if ($Files.Count -gt 1) {
        for ($i = 1; $i -lt $Files.Count; $i++) {
            [xml]$doc = Get-Content -Raw -Path $Files[$i].FullName
            $docRoot = $doc.SelectSingleNode("/entities")
            
            if (-not $docRoot) { continue }
            
            # Iterate through entities in source document
            foreach ($sourceEntity in $docRoot.SelectNodes("entity")) {
                $entityName = $sourceEntity.GetAttribute("name")
                $targetEntity = $baseRoot.SelectSingleNode("entity[@name='$entityName']")
                
                if (-not $targetEntity) {
                    # Entity doesn't exist in target; import entire entity
                    $cloned = $baseDoc.ImportNode($sourceEntity, $true)
                    [void]$baseRoot.AppendChild($cloned)
                    continue
                }

                # Entity exists; merge records and m2m relationships
                $targetRecords = $targetEntity.SelectSingleNode("records")
                $sourceRecords = $sourceEntity.SelectSingleNode("records")
                
                if ($sourceRecords) {
                    if (-not $targetRecords) {
                        $targetRecords = $baseDoc.CreateElement("records")
                        [void]$targetEntity.AppendChild($targetRecords)
                    }
                    
                    foreach ($rec in $sourceRecords.SelectNodes("record")) {
                        $clonedRec = $baseDoc.ImportNode($rec, $true)
                        [void]$targetRecords.AppendChild($clonedRec)
                    }
                }

                # Merge m2m relationships
                $targetM2m = $targetEntity.SelectSingleNode("m2mrelationships")
                $sourceM2m = $sourceEntity.SelectSingleNode("m2mrelationships")
                
                if ($sourceM2m) {
                    if (-not $targetM2m) {
                        $targetM2m = $baseDoc.CreateElement("m2mrelationships")
                        [void]$targetEntity.AppendChild($targetM2m)
                    }
                    
                    foreach ($rel in $sourceM2m.SelectNodes("relationship")) {
                        $clonedRel = $baseDoc.ImportNode($rel, $true)
                        [void]$targetM2m.AppendChild($clonedRel)
                    }
                }
            }
        }
    }

    # Refresh timestamp
    $rootNode = $baseDoc.DocumentElement
    if ($rootNode.timestamp) {
        $rootNode.SetAttribute("timestamp", (Get-Date).ToString('o'))
    }

    $baseDoc.Save($OutputPath)
    return (Get-Item $OutputPath)
}

# Ensure paths are absolute
$SchemaPath = Resolve-Path $SchemaPath -ErrorAction Stop
$DataFolder = Resolve-Path $DataFolder -ErrorAction Stop
$MigrationExePath = Resolve-Path $MigrationExePath -ErrorAction Stop

Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Dynamics 365 Data Import - Project Data Migration" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
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
    $global:LASTEXITCODE = 1
    return
}

# Verify migration executable exists
if (-not (Test-Path $MigrationExePath)) {
    Write-Error "Migration executable not found: $MigrationExePath"
    $global:LASTEXITCODE = 1
    return
}

# Find all Data.xml files in subdirectories
$dataFiles = Get-ChildItem -Path $DataFolder -Filter "Data.xml" -Recurse -File

if ($dataFiles.Count -eq 0) {
    Write-Warning "No Data.xml files found in $DataFolder"
    $global:LASTEXITCODE = 0
    return
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
        $global:LASTEXITCODE = 0
        return
    }
}

Write-Host "Found $($dataFiles.Count) Data.xml file(s) to import" -ForegroundColor Green
Write-Host ""

# Always consolidate to a single Data.xml
Write-Host "Consolidating $($dataFiles.Count) Data.xml file(s) into: $ConsolidatedOutput" -ForegroundColor Yellow
$merged = Merge-DataFiles -Files $dataFiles -OutputPath $ConsolidatedOutput
if (-not $merged) {
    Write-Warning "Consolidation produced no output; aborting import."
    $global:LASTEXITCODE = 1
    return
}
$dataFiles = @($merged)
Write-Host "Consolidation complete. Running single import for merged file." -ForegroundColor Green

# Reminder: target project webs must exist before importing lists
Write-Host ""
Write-Host "  IMPORTANT: Ensure the projects already exist." -ForegroundColor Yellow
Write-Host "      Projects must be created/imported before running the list import." -ForegroundColor Yellow
Write-Host "      If the project web is missing, run the project import step first." -ForegroundColor Yellow
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
        "-Force", "`"$($Force.ToString().ToLower())`"",
        "-ParallelRequests", $ParallelRequests.ToString(),
        "-EnableDisablingOfPlugins", "`"$($EnableDisablingOfPlugins.ToString().ToLower())`""
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
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Import Summary" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
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
    $global:LASTEXITCODE = 1
}
else {
    Write-Host "All imports completed successfully!" -ForegroundColor Green
    $global:LASTEXITCODE = 0
}
return
