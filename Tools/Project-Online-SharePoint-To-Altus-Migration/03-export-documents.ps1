<#
.SYNOPSIS
  Export documents from SharePoint project sites with metadata and version history.

.DESCRIPTION
  Recursively exports all documents from project site document libraries,
  preserving metadata (created/modified dates, authors, etc.) and capturing
  version history for each document.

.PARAMETER SiteCollectionUrl
  The PWA site collection URL (e.g., https://tenant.sharepoint.com/sites/PWA)

.PARAMETER OutputFolder
  Folder to write exported documents and manifests

.PARAMETER ProjectFilter
  Optional wildcard pattern(s) to filter project sites by title. Supports multiple patterns.
  Examples: "Project A", "*2024*", "Project*", @("ProjectA", "ProjectB")

.PARAMETER ClientId
  Optional Entra ID Client ID for authentication. Defaults to Sensei app client ID.

.PARAMETER ExcludeVersionHistory
  If $true, only exports current version of documents. Default is $false (includes history).

.PARAMETER ExcludeLibraries
  Comma-separated list of library names to skip (e.g., "Style Library,Preservation Hold Library")

.PARAMETER ExcludeFilePatterns
    Optional file name patterns to exclude from download (wildcards supported).
    Defaults to skipping SharePoint pages: "*.aspx".

.PARAMETER IncludeRootWeb
    When true, includes the root site web in project discovery.
    Default is false.

.PARAMETER POLExportPath
  Optional path to Project Online export folder containing *_reporting.json files.
  If provided, project names and UIDs are sourced from the JSON export instead of SharePoint.
  Example: "C:\exports\POL\VNext"
#>

param(
    [Parameter(Mandatory = $false)]
    [string] $SiteCollectionUrl = "https://senseijumpstart.sharepoint.com/sites/pwa",

    [Parameter(Mandatory = $false)]
    [string] $OutputFolder = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Output\Documents\Default"),

    [Parameter(Mandatory = $false)]
    [string[]] $ProjectFilter = @(),

    [Parameter(Mandatory = $false)]
    [string] $ClientId = "30b4ad0b-d939-4cd4-bb6d-fa2d39fb4694",

    [Parameter(Mandatory = $false)]
    [switch] $ExcludeVersionHistory,

    [Parameter(Mandatory = $false)]
    [string] $ExcludeLibraries = "Style Library,Preservation Hold Library,Form Templates,Recycle Bin"
    ,
    [Parameter(Mandatory = $false)]
    [string[]] $ExcludeFilePatterns = @("*.aspx")
    ,
    [Parameter(Mandatory = $false)]
    [switch] $IncludeRootWeb
    ,
    [Parameter(Mandatory = $false)]
    [string] $POLExportPath
)

# Import migration helpers
$migrationHelpersPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Migration-Helpers.ps1"
if (-not (Test-Path $migrationHelpersPath)) {
    Write-Error "Migration helpers script not found: $migrationHelpersPath"
    exit 1
}
. $migrationHelpersPath

# ==============================================================================
# INITIALIZATION
# ==============================================================================

Write-Host "`nDocument Export Parameters:" -ForegroundColor Cyan
Write-Host "============================" -ForegroundColor Cyan
Write-Host "SiteCollectionUrl:        $SiteCollectionUrl" -ForegroundColor Gray
Write-Host "OutputFolder:             $OutputFolder" -ForegroundColor Gray
if ($ProjectFilter -and $ProjectFilter.Count -gt 0) {
    Write-Host "ProjectFilter:            $($ProjectFilter -join ', ')" -ForegroundColor Gray
}
Write-Host "ExcludeVersionHistory:    $ExcludeVersionHistory" -ForegroundColor Gray
Write-Host "ExcludeLibraries:         $ExcludeLibraries" -ForegroundColor Gray
if ($ExcludeFilePatterns -and $ExcludeFilePatterns.Count -gt 0) {
    Write-Host "ExcludeFilePatterns:     $($ExcludeFilePatterns -join ', ')" -ForegroundColor Gray
}
Write-Host "IncludeRootWeb:          $IncludeRootWeb" -ForegroundColor Gray
if ($POLExportPath) {
    Write-Host "POLExportPath:           $POLExportPath" -ForegroundColor Gray
}
Write-Host ""

# Create output folder
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    Write-Host "Created output folder: $OutputFolder`n" -ForegroundColor Green
}

# Initialize logging
$script:logContent = @()

# Parse exclude list
$ExcludeList = @()
if ($ExcludeLibraries) {
    $ExcludeList = $ExcludeLibraries -split ',' | ForEach-Object { $_.Trim() }
}

# Build project map from POL export if provided
$projectMap = @{}  # Map of project URL → @{Name, UID}
if ($POLExportPath) {
    $projectMap = Build-ProjectMap -ExportPath $POLExportPath
    Write-Host ""
}

# Tracking
$statsProjects = 0
$statsLibraries = 0
$statsDocuments = 0
$statsVersions = 0
$manifest = @()

# ==============================================================================
# RECURSIVE DOCUMENT PROCESSING FUNCTION
# ==============================================================================

function Export-DocumentsRecursive {
    <#
    .SYNOPSIS
    Recursively exports documents from a folder and all subfolders in a document library.
    #>
    param(
        [string]$FolderUrl,
        [string]$OutputPath,
        [string]$LibraryName,
        [string]$ProjectTitle
    )
    
    try {
        # Get all items in current folder
        $folder = Get-PnPFolder -Url $FolderUrl -Includes Files
        $items = $folder.Files
        
        foreach ($item in $items) {
            $fileName = $item.Name
            $fileRelUrl = $item.ServerRelativeUrl

            # Skip files matching blacklist patterns (e.g., *.aspx)
            $skipFile = $false
            if ($ExcludeFilePatterns -and $ExcludeFilePatterns.Count -gt 0) {
                foreach ($pattern in $ExcludeFilePatterns) {
                    if ($fileName -like $pattern) { $skipFile = $true; break }
                }
            }
            if ($skipFile) {
                Write-Log "    Skipping (blacklist): $fileName"
                continue
            }
            
            # Get full file item for metadata
            $fileItem = Get-PnPFile -Url $fileRelUrl -AsListItem
            
            if ($fileItem) {
                $created = $fileItem["Created"]
                $modified = $fileItem["Modified"]
                $createdBy = $fileItem["Author"]
                $modifiedBy = $fileItem["Editor"]
                $fileSize = $fileItem["File_x0020_Size"]
                
                $script:statsDocuments++
                
                # Create document folder with name and extension preserved
                $docFolder = Join-Path $OutputPath $fileName
                if (-not (Test-Path $docFolder)) {
                    New-Item -Path $docFolder -ItemType Directory -Force | Out-Null
                }
                
                # Download current version
                try {
                    Show-DownloadSpinner -Message "Downloading: $fileName" -Action {
                        Get-PnPFile -Url $fileRelUrl -AsFile -Path $docFolder -FileName $fileName -Force | Out-Null
                    }
                    $script:logContent += "    Downloaded: $fileRelUrl"
                }
                catch {
                    $script:logContent += "[WARNING]     Failed to download '$fileRelUrl': $($_.Exception.Message)"
                    $script:logContent += "    Exception: $($_.Exception.ToString())"
                    Write-Host "[WARNING]     Failed to download '$fileRelUrl': $($_.Exception.Message)" -ForegroundColor Yellow
                    continue
                }
                
                # Export version history if requested
                $versions = @()
                if (-not $ExcludeVersionHistory) {
                    try {
                        $Ctx = Get-PnPContext
                        $pnpFile = Get-PnPFile -Url $fileRelUrl
                        $versionObjects = Get-PnPProperty -ClientObject $pnpFile -Property Versions
                        
                        foreach ($version in $versionObjects) {
                            $script:statsVersions++
                            
                            $versionInfo = @{
                                VersionId      = $version.VersionId
                                VersionLabel   = $version.VersionLabel
                                Created        = $version.Created
                                CreatedBy      = $version.CreatedBy.LoginName
                                CheckInComment = $version.CheckInComment
                                IsCurrent      = $version.IsCurrent
                                Url            = $version.Url
                            }
                            $versions += $versionInfo
                            
                            # Download version file using binary stream (robust for historic versions)
                            if (-not $version.IsCurrent) {
                                try {
                                    $fileExt = [System.IO.Path]::GetExtension($fileName)
                                    $fileNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                                    $versionFileName = "$fileNameNoExt`_v$($version.VersionLabel)$fileExt"
                                    $versionOutputPath = Join-Path $docFolder $versionFileName
                                    
                                    Show-DownloadSpinner -Message "Downloading version: $($version.VersionLabel)" -Action {
                                        $versionStreamResult = $version.OpenBinaryStream()
                                        $Ctx.ExecuteQuery()
                                        $fileStream = [System.IO.File]::Open($versionOutputPath, [System.IO.FileMode]::Create)
                                        $versionStreamResult.Value.CopyTo($fileStream)
                                        $fileStream.Close()
                                    }
                                    $script:logContent += "      Downloaded version: $($version.VersionLabel)"
                                }
                                catch {
                                    # Silently skip version downloads that fail (common with cleaned up history)
                                    Write-Verbose "      Version '$($version.VersionLabel)' not available"
                                }
                            }
                        }
                    }
                    catch {
                        $script:logContent += "[WARNING]     Error reading version history for '$fileName': $($_.Exception.Message)"
                        $script:logContent += "    Exception: $($_.Exception.ToString())"
                        Write-Host "[WARNING]     Error reading version history for '$fileName': $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }
                
                # Create metadata file
                $metadata = [PSCustomObject]@{
                    FileName     = $fileName
                    FilePath     = $fileRelUrl
                    FileSize     = $fileSize
                    Created      = $created
                    CreatedBy    = $createdBy
                    Modified     = $modified
                    ModifiedBy   = $modifiedBy
                    Library      = $LibraryName
                    Project      = $ProjectTitle
                    VersionCount = $versions.Count
                    Versions     = $versions
                }
                
                # Save metadata as JSON
                $metadataPath = Join-Path $docFolder "metadata.json"
                $metadata | ConvertTo-Json -Depth 5 | Out-File -FilePath $metadataPath -Encoding UTF8
                
                # Add to manifest
                $script:manifest += [PSCustomObject]@{
                    Project      = $ProjectTitle
                    Library      = $LibraryName
                    FileName     = $fileName
                    FileSize     = $fileSize
                    Created      = $created
                    CreatedBy    = $createdBy
                    Modified     = $modified
                    ModifiedBy   = $modifiedBy
                    VersionCount = $versions.Count
                    OutputPath   = $docFolder
                }
            }
        }
        
        # Recursively process subfolders
        $folder = Get-PnPFolder -Url $FolderUrl -Includes Folders
        $subfolders = $folder.Folders
        
        foreach ($subfolder in $subfolders) {
            $subfolderName = $subfolder.Name
            $subfolderUrl = $subfolder.ServerRelativeUrl
            
            # Skip Forms folder (system files)
            if ($subfolderName -eq "Forms") {
                Write-Verbose "    Skipping Forms folder"
                continue
            }
            
            # Plan subfolder output path (created lazily when a file is exported)
            $subfolderOutput = Join-Path $OutputPath $subfolderName
            Write-Log "    Descending into folder: $subfolderName"
            
            # Recurse into subfolder (will only create directories if files are exported)
            Export-DocumentsRecursive -FolderUrl $subfolderUrl -OutputPath $subfolderOutput `
                -LibraryName $LibraryName -ProjectTitle $ProjectTitle
        }
    }
    catch {
        $script:logContent += "[WARNING] Error processing folder '$FolderUrl': $($_.Exception.Message)"
        $script:logContent += "  Exception: $($_.Exception.ToString())"
        Write-Host "[WARNING] Error processing folder '$FolderUrl': $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ==============================================================================
# PREREQUISITES
# ==============================================================================

Write-Host "Checking prerequisites..." -ForegroundColor Cyan

if (-not (Get-Command Get-PnPConnection -ErrorAction SilentlyContinue)) {
    Write-LogError "PnP.PowerShell module is not installed."
    Write-Host "Install with: Install-Module PnP.PowerShell -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

Write-Log "PnP.PowerShell module is installed"
Write-Host ""

# ==============================================================================
# GLOBAL TRY-FINALLY TO GUARANTEE LOG SAVE
# ==============================================================================
try {

    # ==============================================================================
    # CONNECT TO SHAREPOINT
    # ==============================================================================

    Write-Host "Connecting to SharePoint (interactive)..." -ForegroundColor Cyan
    try {
        Connect-PnPOnline -Url $SiteCollectionUrl -ClientId $ClientId -Interactive -ErrorAction Stop
        Write-Log "Connected to: $SiteCollectionUrl"
        Write-Host ""
    }
    catch {
        Write-LogError "Failed to connect: $($_.Exception.Message)" -Exception $_.Exception.ToString()
        exit 1
    }

    # ==============================================================================
    # GET PROJECT WEBS
    # ==============================================================================

    Write-Host "Discovering project webs..." -ForegroundColor Cyan
    $rootWeb = Get-PnPWeb -Includes "WebTemplate"
    $projectWebs = @(Get-PnPSubWeb -Recurse -Includes "WebTemplate")
    if ($IncludeRootWeb) {
        $projectWebs = @($rootWeb) + $projectWebs
    }
    $filteredWebs = @()

    foreach ($web in $projectWebs) {
        $webTitle = $web.Title
    
        # Skip app webs
        if ($web.WebTemplate -like "APP*") {
            Write-Verbose "Skipping app web: $webTitle"
            continue
        }

        if ($web.Hidden) {
            Write-Verbose "Skipping hidden web: $webTitle"
            continue
        }
    
        # Check project filter
        if ($ProjectFilter -and $ProjectFilter.Count -gt 0) {
            $matchesFilter = $false
            # Try to match against POL name if available; otherwise use web title
            $matchNameToTest = if ($projectMap.ContainsKey($webTitle)) {
                $projectMap[$webTitle].Name
            }
            else {
                $webTitle
            }
            
            foreach ($filter in $ProjectFilter) {
                if ($matchNameToTest -like $filter) {
                    $matchesFilter = $true
                    break
                }
            }
            if (-not $matchesFilter) {
                continue
            }
        }
    
        $filteredWebs += $web
    }

    $totalWebs = $filteredWebs.Count
    Write-Log "Found $totalWebs matching project webs.`n"

    # ==============================================================================
    # PROCESS EACH PROJECT WEB
    # ==============================================================================

    foreach ($web in $filteredWebs) {
        $webTitle = $web.Title
        $webUrl = $web.Url
        $statsProjects++
    
        Write-Host "Processing web: $webTitle" -ForegroundColor Yellow
        Write-Host "  URL: $webUrl" -ForegroundColor Gray
    
        try {
            # Connect to specific web
            Connect-PnPOnline -Url $webUrl -ClientId $ClientId -Interactive
        
            # Get all lists
            $lists = Get-PnPList
            $documentLists = $lists | Where-Object { 
                $_.BaseTemplate -eq 101 -or $_.EntityTypeName -like "*Document*"
            }
        
            Write-Log "  Found $($documentLists.Count) document libraries"
        
            foreach ($library in $documentLists) {
                $libName = $library.Title
            
                # Skip excluded libraries
                if ($ExcludeList -contains $libName) {
                    Write-Log "  Skipping library: $libName (excluded)"
                    continue
                }
            
                $statsLibraries++
                Write-Log "  Processing library: $libName"
            
                # Prepare library output path (created lazily when files are exported)
                $libFolder = Join-Path $OutputFolder $webTitle $libName
            
                # Recursively export documents starting from library root
                Write-Log "    Scanning folders and documents..."
                Export-DocumentsRecursive -FolderUrl $library.RootFolder.ServerRelativeUrl -OutputPath $libFolder `
                    -LibraryName $libName -ProjectTitle $webTitle
            }
        }
        catch {
            Write-LogError "Error processing web '$webTitle': $($_.Exception.Message)" -Exception $_.Exception.ToString()
        }
    
        Write-Host ""
    }

    # ==============================================================================
    # EXPORT MANIFEST
    # ==============================================================================

    Write-Host "Exporting manifest..." -ForegroundColor Cyan

    # CSV manifest
    $csvPath = Join-Path $OutputFolder "documents-manifest.csv"
    $manifest | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Log "Manifest exported to: $csvPath"

    # JSON manifest
    $jsonPath = Join-Path $OutputFolder "documents-manifest.json"
    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
    Write-Log "Manifest exported to: $jsonPath"

}
finally {
    # Always save the log, even if the script fails earlier
    Save-ExportLog
}

# ==============================================================================
# SUMMARY
# ==============================================================================

Write-Host "`n" + ("=" * 80) -ForegroundColor Cyan
Write-Host "Document Export Complete!" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""
Write-Host "Projects processed:  $statsProjects" -ForegroundColor White
Write-Host "Libraries exported:  $statsLibraries" -ForegroundColor White
Write-Host "Documents exported:  $statsDocuments" -ForegroundColor White
Write-Host "Versions exported:   $statsVersions" -ForegroundColor White
Write-Host ""
Write-Host "Output location: $OutputFolder" -ForegroundColor Green
Write-Host ""
