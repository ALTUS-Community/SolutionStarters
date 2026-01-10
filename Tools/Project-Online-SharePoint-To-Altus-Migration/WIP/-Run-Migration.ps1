<#
.SYNOPSIS
  Run SharePoint export, import, or full migration for multiple site collections

.DESCRIPTION
  This script orchestrates the migration process for multiple SharePoint site collections.
  Supports three modes:
  - Export: Extract data from SharePoint to XML files
  - Import: Load XML files into Dynamics 365
  - Full: Export from SharePoint and immediately import to D365
  
  Each site collection gets its own output folder: ./Output/<SiteName>/<ProjectName>/
#>

# ==============================================================================
# CONFIGURATION - CUSTOMIZE THESE SETTINGS
# ==============================================================================

# ------------------------------------------------------------------------------
# Site Collections to Migrate
# ------------------------------------------------------------------------------
# Define the SharePoint site collections to process.
# Each entry creates a separate output folder: Output/<FolderName>/<ProjectName>/
$SiteCollections = @(
  # @{
  #   Url           = "https://senseijumpstart.sharepoint.com/sites/pwa"
  #   FolderName    = "PWA_Main"      # Folder name for output
  #   ProjectFilter = @()     # Export all projects, or use patterns like @("*Paul*", "Project*")
  # }
  @{
    Url           = "https://senseijumpstart.sharepoint.com/sites/pwadev"
    FolderName    = "PWA_Dev"      # Folder name for output
    ProjectFilter = @()     # Export all projects, or use patterns like @("*Paul*", "Project*")
  }
  # @{
  #   Url           = "https://senseicloud.sharepoint.com/sites/vNext/"
  #   FolderName    = "vNext"         # Folder name for output
  #   ProjectFilter = @()              # Export all projects
  # }
  # @{
  #   Url           = "https://senseicloud.sharepoint.com/sites/PWASensei"
  #   FolderName    = "PWASensei"      # Folder name for output
  #   ProjectFilter = @()              # Export all projects
  # }
  # @{
  #   Url           = "https://senseicloud.sharepoint.com/sites/MigrationTest1"
  #   FolderName    = "Migration1"    # Folder name for output
  #   ProjectFilter = @()              # Export all projects
  # }
)

# ------------------------------------------------------------------------------
# Dynamics 365 Settings (for Import Operations)
# ------------------------------------------------------------------------------
$D365Url = "https://senseijumpstart.crm.dynamics.com"  # Your D365 environment URL
$ImportParallelRequests = 4                             # Number of parallel import threads (1-10)
$ImportForce = $false                                   # $true = update existing records, $false = insert only

# ------------------------------------------------------------------------------
# Document Import Settings
# ------------------------------------------------------------------------------
$TargetSiteCollectionUrl = "https://senseijumpstart.sharepoint.com/sites/altusdocuments"                           # Target SharePoint site collection for document import (e.g., https://tenant.sharepoint.com/sites/target)

# ------------------------------------------------------------------------------
# Authentication Settings
# ------------------------------------------------------------------------------
$ClientId = "30b4ad0b-d939-4cd4-bb6d-fa2d39fb4694"  # Entra ID Client ID (defaults to Sensei app)

# NOTE: For initial setup, grant admin consent to the application:
# https://login.microsoftonline.com/common/adminconsent?client_id=30b4ad0b-d939-4cd4-bb6d-fa2d39fb4694&redirect_uri=https%3A%2F%2Faltus.pro%2Fcontent%2FConsentSuccess.html

# ==============================================================================
# END CONFIGURATION - Do not modify below this line unless you know what you're doing
# ==============================================================================

# Set up file paths relative to this script's location
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MappingJsonPath = Join-Path $ScriptDir "export.config.json"
$CmtSchemaPath = Join-Path $ScriptDir "data_schema.xml"
$BaseOutputFolder = Join-Path $ScriptDir "Output"

# ==============================================================================
# PROMPT USER FOR OPERATION MODE
# ==============================================================================

Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "SharePoint to Altus Migration Tool" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

# Display configured site collections
Write-Host "Configured Site Collections:" -ForegroundColor Yellow
foreach ($site in $SiteCollections) {
  Write-Host "  - $($site.FolderName): " -NoNewline -ForegroundColor White
  Write-Host "$($site.Url)" -ForegroundColor Gray
  if ($site.ProjectFilter -and $site.ProjectFilter.Count -gt 0) {
    Write-Host "    Filter: $($site.ProjectFilter -join ', ')" -ForegroundColor DarkGray
  }
}
Write-Host ""

# Display Dynamics 365 target
Write-Host "Dynamics 365 Target:" -ForegroundColor Yellow
Write-Host "  - Environment: " -NoNewline -ForegroundColor White
Write-Host "$D365Url" -ForegroundColor Gray
Write-Host "  - Parallel Requests: $ImportParallelRequests" -ForegroundColor Gray
Write-Host "  - Force Update: $ImportForce" -ForegroundColor Gray
Write-Host ""

Write-Host "Select operation mode:" -ForegroundColor Yellow
Write-Host "  [1] Export Lists - Extract data from SharePoint to XML files" -ForegroundColor White
Write-Host "  [2] Import Lists - Load existing XML files into Dynamics 365" -ForegroundColor White
# Write-Host "  [3] Export Documents - Export documents, metadata, and version history" -ForegroundColor White
# Write-Host "  [4] Import Documents - Import documents to target SharePoint site collection" -ForegroundColor White
Write-Host "  [Q] Quit" -ForegroundColor Gray
Write-Host ""

do {
  $choice = Read-Host "Enter your choice (1, 2, or Q)"
  $validChoice = $choice -match '^[12Qq]$'
  if (-not $validChoice) {
    Write-Host "Invalid choice. Please enter 1, 2, or Q" -ForegroundColor Red
  }
} while (-not $validChoice)

if ($choice -match '^[Qq]$') {
  Write-Host "Operation cancelled." -ForegroundColor Yellow
  exit 0
}

$operationMode = switch ($choice) {
  "1" { "ExportData" }
  "2" { "ImportData" }
  "3" { "ExportDocuments" }
  "4" { "ImportDocuments" }
}

Write-Host "`nSelected mode: $operationMode" -ForegroundColor Green
Write-Host ""

# Summary tracking
$totalSites = $SiteCollections.Count
$processedSites = 0
$results = @()

Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "$operationMode - Multi-Site Collection Migration" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Processing $totalSites site collection(s)`n" -ForegroundColor White

# Process each site collection
foreach ($site in $SiteCollections) {
  $processedSites++
  $siteUrl = $site.Url
  $folderName = $site.FolderName
  $projectFilter = $site.ProjectFilter
  
  # Build POL export path based on configured folder name
  $polExportRoot = Join-Path $ScriptDir "POLExports"
  $polExportPath = Join-Path $polExportRoot $folderName
  Write-Host "  POL Export Path: $polExportPath" -ForegroundColor Gray
    
  Write-Host "`n[$processedSites/$totalSites] Processing: $folderName" -ForegroundColor Yellow
  Write-Host "  URL: $siteUrl" -ForegroundColor Gray
    
  # Create site-specific output folder
  $siteOutputFolder = Join-Path $BaseOutputFolder $folderName
  if (-not (Test-Path $siteOutputFolder)) {
    New-Item -Path $siteOutputFolder -ItemType Directory -Force | Out-Null
    Write-Host "  Created output folder: $siteOutputFolder" -ForegroundColor Gray
  }
    
  # Track overall success for this site
  $siteSuccess = $true
  $siteStartTime = Get-Date
  
  # ==============================================================================
  # EXPORT DATA PHASE
  # ==============================================================================
  
  if ($operationMode -eq "ExportData") {
    # Build parameters for export script
    $exportParams = @{
      SiteCollectionUrl = $siteUrl
      MappingJsonPath   = $MappingJsonPath
      CmtSchemaPath     = $CmtSchemaPath
      OutputFolder      = $siteOutputFolder
      ClientId          = $ClientId
      POLExportPath     = $polExportPath
    }
    
    if ($projectFilter -and $projectFilter.Count -gt 0) {
      $exportParams.ProjectFilter = $projectFilter
      Write-Host "  Project Filter: $($projectFilter -join ', ')" -ForegroundColor Gray
    }
    
    # Run the export
    try {
      Write-Host "  Starting export..." -ForegroundColor Cyan
      $exportStartTime = Get-Date
        
      & (Join-Path $ScriptDir "01-export-lists.ps1") @exportParams
        
      $exportDuration = (Get-Date) - $exportStartTime
      
      if ($LASTEXITCODE -ne 0) {
        $siteSuccess = $false
        Write-Host "  Export failed!" -ForegroundColor Red
      }
      else {
        Write-Host "  Export completed in $($exportDuration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
      }
    }
    catch {
      Write-Host "  ERROR during export: $($_.Exception.Message)" -ForegroundColor Red
      $siteSuccess = $false
    }
  }
  
  # ==============================================================================
  # IMPORT DATA PHASE
  # ==============================================================================
  
  if ($operationMode -eq "ImportData" -and $siteSuccess) {
    # Build parameters for import script
    $importParams = @{
      D365Url          = $D365Url
      SchemaPath       = $CmtSchemaPath
      DataFolder       = $siteOutputFolder
      ParallelRequests = $ImportParallelRequests
      Force            = $ImportForce
      POLExportPath    = $polExportPath
    }
    
    if ($projectFilter -and $projectFilter.Count -gt 0) {
      $importParams.ProjectFilter = $projectFilter
    }
    
    # Run the import
    try {
      Write-Host "  Starting import to D365..." -ForegroundColor Cyan
      $importStartTime = Get-Date
        
      & (Join-Path $ScriptDir "02-import-lists.ps1") @importParams
        
      $importDuration = (Get-Date) - $importStartTime
      
      if ($LASTEXITCODE -ne 0) {
        $siteSuccess = $false
        Write-Host "  Import failed!" -ForegroundColor Red
      }
      else {
        Write-Host "  Import completed in $($importDuration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
      }
    }
    catch {
      Write-Host "  ERROR during import: $($_.Exception.Message)" -ForegroundColor Red
      $siteSuccess = $false
    }
  }
  elseif ($operationMode -eq "ImportData" -and -not $siteSuccess) {
    Write-Host "  Skipping import due to export failure" -ForegroundColor Yellow
  }
  
  # ==============================================================================
  # DOCUMENT EXPORT PHASE
  # ==============================================================================
  
  if ($operationMode -eq "ExportDocuments") {
    # Build parameters for document export script
    $docExportParams = @{
      SiteCollectionUrl = $siteUrl
      OutputFolder      = $siteOutputFolder
      ClientId          = $ClientId
      POLExportPath     = $polExportPath
    }
    
    if ($projectFilter -and $projectFilter.Count -gt 0) {
      $docExportParams.ProjectFilter = $projectFilter
    }
    
    # Run the document export
    try {
      Write-Host "  Starting document export..." -ForegroundColor Cyan
      $docExportStartTime = Get-Date
        
      & (Join-Path $ScriptDir "03-export-documents.ps1") @docExportParams
        
      $docExportDuration = (Get-Date) - $docExportStartTime
      
      if ($LASTEXITCODE -ne 0) {
        Write-Host "  Document export failed!" -ForegroundColor Red
      }
      else {
        Write-Host "  Document export completed in $($docExportDuration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
      }
    }
    catch {
      Write-Host "  ERROR during document export: $($_.Exception.Message)" -ForegroundColor Red
    }
  }
  
  # ==============================================================================
  # IMPORT DOCUMENTS PHASE
  # ==============================================================================
  
  if ($operationMode -eq "ImportDocuments") {
    # Build parameters for document import script
    $docImportParams = @{
      SourceFolder            = $siteOutputFolder
      TargetSiteCollectionUrl = $TargetSiteCollectionUrl
      ClientId                = $ClientId
      POLExportPath           = $polExportPath
    }
    
    if ($projectFilter -and $projectFilter.Count -gt 0) {
      $docImportParams.ProjectFilter = $projectFilter
    }
    
    # Run the document import
    try {
      Write-Host "  Starting document import..." -ForegroundColor Cyan
      $docImportStartTime = Get-Date
        
      & (Join-Path $ScriptDir "04-import-documents.ps1") @docImportParams
        
      $docImportDuration = (Get-Date) - $docImportStartTime
      
      if ($LASTEXITCODE -ne 0) {
        Write-Host "  Document import failed!" -ForegroundColor Red
      }
      else {
        Write-Host "  Document import completed in $($docImportDuration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
      }
    }
    catch {
      Write-Host "  ERROR during document import: $($_.Exception.Message)" -ForegroundColor Red
    }
  }
  
  # Record results
  $siteDuration = (Get-Date) - $siteStartTime
  $status = if ($siteSuccess) { "Success" } else { "Failed" }
  
  $results += [PSCustomObject]@{
    SiteName     = $folderName
    Url          = $siteUrl
    Operation    = $operationMode
    Status       = $status
    Duration     = $siteDuration.ToString("hh\:mm\:ss")
    OutputFolder = $siteOutputFolder
  }
  
  Write-Host "  Total time: $($siteDuration.ToString('hh\:mm\:ss'))" -ForegroundColor $(if ($siteSuccess) { "Green" } else { "Red" })
}

# Display summary
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Migration Summary" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

$results | Format-Table -AutoSize

$successCount = ($results | Where-Object { $_.Status -eq "Success" }).Count
$failedCount = ($results | Where-Object { $_.Status -ne "Success" }).Count

Write-Host "Total Sites:     $totalSites" -ForegroundColor White
Write-Host "Successful:      $successCount" -ForegroundColor Green
Write-Host "Failed:          $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "Gray" })
Write-Host ""

# Export summary to JSON
$summaryPath = Join-Path $BaseOutputFolder "migration-summary.json"
$results | ConvertTo-Json -Depth 5 | Out-File -FilePath $summaryPath -Encoding UTF8
Write-Host "Summary exported to: $summaryPath" -ForegroundColor Gray

