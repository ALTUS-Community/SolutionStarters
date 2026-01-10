<#
.SYNOPSIS
  Build and package the SharePoint to Dynamics 365 migration tool.

.DESCRIPTION
  Creates a clean build folder with all required scripts, configuration files,
  and necessary folder structure for deployment.

.PARAMETER BuildFolder
  Target folder for the build output. Defaults to .\Build
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$BuildFolder = (Join-Path $PSScriptRoot "Build")
)

$ErrorActionPreference = "Stop"

Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "SharePoint Migration Tool - Build Package" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# CLEAN BUILD FOLDER
# ==============================================================================

if (Test-Path $BuildFolder) {
    Write-Host "Cleaning existing build folder..." -ForegroundColor Yellow
    Remove-Item -Path $BuildFolder -Recurse -Force
}

Write-Host "Creating build folder structure..." -ForegroundColor Cyan
New-Item -Path $BuildFolder -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $BuildFolder "POLExports") -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $BuildFolder "Output") -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $BuildFolder "Tools\DataMigration") -ItemType Directory -Force | Out-Null

Write-Host "  Created: $BuildFolder" -ForegroundColor Gray
Write-Host "  Created: $BuildFolder\POLExports" -ForegroundColor Gray
Write-Host "  Created: $BuildFolder\Output" -ForegroundColor Gray
Write-Host "  Created: $BuildFolder\Tools\DataMigration" -ForegroundColor Gray
Write-Host ""

# ==============================================================================
# COPY TOOLS FOLDER
# ==============================================================================

Write-Host "Copying migration tool binaries..." -ForegroundColor Cyan

$toolsSource = Join-Path $PSScriptRoot "Tools\DataMigration"
$toolsDest = Join-Path $BuildFolder "Tools\DataMigration"

if (Test-Path $toolsSource) {
    Copy-Item -Path "$toolsSource\*" -Destination $toolsDest -Recurse -Force
    $toolFileCount = (Get-ChildItem -Path $toolsDest -Recurse -File).Count
    Write-Host "  ✓ Copied $toolFileCount files from Tools\DataMigration" -ForegroundColor Green
}
else {
    Write-Host "  ✗ Missing: Tools\DataMigration folder" -ForegroundColor Red
}

Write-Host ""

# ==============================================================================
# COPY FILES
# ==============================================================================

Write-Host "Copying migration files..." -ForegroundColor Cyan

$filesToCopy = @(
    "-Run-Migration.ps1",
    "01-export-lists.ps1",
    "02-import-lists.ps1",
    "Common-Helpers.ps1",
    "data_schema.xml",
    "export.config.json"
)

$copiedCount = 0
$missingFiles = @()

foreach ($file in $filesToCopy) {
    $sourcePath = Join-Path $PSScriptRoot $file
    $destPath = Join-Path $BuildFolder $file
    
    if (Test-Path $sourcePath) {
        Copy-Item -Path $sourcePath -Destination $destPath -Force
        Write-Host "  ✓ Copied: $file" -ForegroundColor Green
        $copiedCount++
    }
    else {
        Write-Host "  ✗ Missing: $file" -ForegroundColor Red
        $missingFiles += $file
    }
}

Write-Host ""

# ==============================================================================
# CREATE README
# ==============================================================================

Write-Host "Creating deployment instructions..." -ForegroundColor Cyan

$readmeContent = @"
# SharePoint to Dynamics 365 Migration Tool - Deployment Package

This package contains all files needed to run the migration tool.

## Package Contents

### Core Scripts
- **-Run-Migration.ps1** - Main orchestrator script (start here)
- **01-export-lists.ps1** - SharePoint export script
- **02-import-lists.ps1** - Dynamics 365 import script

### Helper Libraries
- **Common-Helpers.ps1** - Consolidated utilities (logging, project mapping, CMT conversion, field handlers)

### Configuration
- **export.config.json** - Field mapping configuration
- **data_schema.xml** - CMT schema for D365

### Folders
- **POLExports/** - Place Project Online JSON exports here (by site)
  - Example: POLExports/vNext/ (containing *_reporting.json files)
- **Output/** - Migration output files (created automatically per site)

## Quick Start

1. **Configure** your settings in ``-Run-Migration.ps1`` (lines 15-60):
   - Site collection URLs
   - Project filters
   - D365 environment URL

2. **Place POL exports** in the POLExports folder:
   - Create a subfolder matching your site's FolderName
   - Copy *_reporting.json files into that subfolder

3. **Run** the migration:
   ``````powershell
   .\-Run-Migration.ps1
   ``````

4. **Select** operation mode:
   - [1] Export Data
   - [2] Import Data

## Prerequisites

- PowerShell 7+ recommended
- PnP.PowerShell module (auto-installed if missing)
- Site Collection Admin role on source SharePoint sites
- Permissions to import data to target Dynamics 365 environment

## Support

For detailed documentation, see the full README in the source repository.
"@

$readmePath = Join-Path $BuildFolder "ReadMe.md"
$readmeContent | Out-File -FilePath $readmePath -Encoding UTF8
Write-Host "  ✓ Created: ReadMe.md" -ForegroundColor Green
Write-Host ""

# ==============================================================================
# SUMMARY
# ==============================================================================

Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Build Summary" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

if ($missingFiles.Count -gt 0) {
    Write-Host "WARNING: $($missingFiles.Count) file(s) missing:" -ForegroundColor Yellow
    foreach ($file in $missingFiles) {
        Write-Host "  - $file" -ForegroundColor Yellow
    }
    Write-Host ""
}

Write-Host "Files copied:        $copiedCount / $($filesToCopy.Count)" -ForegroundColor $(if ($copiedCount -eq $filesToCopy.Count) { "Green" } else { "Yellow" })
Write-Host "Build location:      $BuildFolder" -ForegroundColor Cyan
Write-Host ""

if ($copiedCount -eq $filesToCopy.Count) {
    Write-Host "✓ Build completed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Copy the build folder to your deployment location" -ForegroundColor Gray
    Write-Host "  2. Place POL exports in POLExports/<SiteName>/" -ForegroundColor Gray
    Write-Host "  3. Configure -Run-Migration.ps1" -ForegroundColor Gray
    Write-Host "  4. Run .\-Run-Migration.ps1" -ForegroundColor Gray
}
else {
    Write-Host "⚠ Build completed with warnings" -ForegroundColor Yellow
}

Write-Host ""

# ==============================================================================
# CREATE ZIP PACKAGE
# ==============================================================================

Write-Host "Creating ZIP package..." -ForegroundColor Cyan

$zipPath = Join-Path (Split-Path $BuildFolder -Parent) "SharePoint-Migration-Tool.zip"

if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

Compress-Archive -Path "$BuildFolder\*" -DestinationPath $zipPath -Force
Write-Host "  ✓ Created: $zipPath" -ForegroundColor Green

$zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Write-Host "  Package size: $zipSize MB" -ForegroundColor Gray
Write-Host ""
