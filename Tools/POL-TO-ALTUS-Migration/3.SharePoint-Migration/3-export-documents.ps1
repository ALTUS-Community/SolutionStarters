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
  If $true, only exports current version of documents. Default is $true (simple mode).

.PARAMETER DetailedMetadata
  If $true, exports extended metadata (ETag, ContentType, UniqueId, all FieldValues).
  Default is $false (simple mode with basic metadata only).

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
    [switch] $ExcludeVersionHistory = $true,

    [Parameter(Mandatory = $false)]
    [switch] $DetailedMetadata,

    [Parameter(Mandatory = $false)]
    [string] $ExcludeLibraries = "Style Library,Preservation Hold Library,Form Templates,Recycle Bin,Site Assets"
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

# Import common helpers
$commonHelpersPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "CommonFunctions.ps1"
if (-not (Test-Path $commonHelpersPath)) {
    Write-Error "Common helpers script not found: $commonHelpersPath"
    $global:LASTEXITCODE = 1
    return
}
. $commonHelpersPath

# ==============================================================================
# INITIALIZATION
# ==============================================================================

Write-LogMessage "`nDocument Export Parameters:" -ForegroundColor Cyan
Write-LogMessage "============================" -ForegroundColor Cyan
Write-LogMessage "SiteCollectionUrl:        $SiteCollectionUrl" -ForegroundColor Gray
Write-LogMessage "OutputFolder:             $OutputFolder" -ForegroundColor Gray
if ($ProjectFilter -and $ProjectFilter.Count -gt 0) {
    Write-LogMessage "ProjectFilter:            $($ProjectFilter -join ', ')" -ForegroundColor Gray
}
Write-LogMessage "ExcludeVersionHistory:    $ExcludeVersionHistory" -ForegroundColor Gray
Write-LogMessage "DetailedMetadata:         $DetailedMetadata" -ForegroundColor Gray
Write-LogMessage "ExcludeLibraries:         $ExcludeLibraries" -ForegroundColor Gray
if ($ExcludeFilePatterns -and $ExcludeFilePatterns.Count -gt 0) {
    Write-LogMessage "ExcludeFilePatterns:     $($ExcludeFilePatterns -join ', ')" -ForegroundColor Gray
}
Write-LogMessage "IncludeRootWeb:          $IncludeRootWeb" -ForegroundColor Gray
if ($POLExportPath) {
    Write-LogMessage "POLExportPath:           $POLExportPath" -ForegroundColor Gray
}
Write-LogMessage ""

# ==============================================================================
# DISPLAY WARNING
# ==============================================================================

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Yellow
Write-Host "WARNING: DOCUMENT EXPORT SCOPE AND LIMITATIONS" -ForegroundColor Yellow
Write-Host ("=" * 80) -ForegroundColor Yellow
Write-Host ""
Write-Host "This tool extracts DOCUMENTS ONLY from SharePoint project sites." -ForegroundColor Yellow
Write-Host ""
Write-Host "What IS exported:" -ForegroundColor White
Write-Host "  ✓ Documents and folder hierarchy from document libraries" -ForegroundColor Gray
Write-Host "  ✓ Basic file metadata (Name, Path, Size, Created, Modified, etc.)" -ForegroundColor Gray
Write-Host "  ✓ Version history for each document" -ForegroundColor Gray
Write-Host ""
Write-Host "What IS NOT exported:" -ForegroundColor White
Write-Host "  ✗ Lists and list items (Risks, Issues, Tasks, etc.)" -ForegroundColor DarkGray
Write-Host "  ✗ Web part pages, modern site pages, wiki pages" -ForegroundColor DarkGray
Write-Host "  ✗ Picture libraries" -ForegroundColor DarkGray
Write-Host "  ✗ Custom lists" -ForegroundColor DarkGray
Write-Host "  ✗ Workflows and workflow approval history" -ForegroundColor DarkGray
Write-Host "  ✗ Site settings, permissions, and configurations" -ForegroundColor DarkGray
Write-Host "  ✗ Versions of pages" -ForegroundColor DarkGray
Write-Host "  ✗ Custom metadata beyond basic file properties" -ForegroundColor DarkGray
Write-Host ""
Write-Host "NOTE: For complete SharePoint migration including lists, pages, workflows," -ForegroundColor Cyan
Write-Host "      and full site structure, use dedicated migration tools (e.g., ShareGate)." -ForegroundColor Cyan
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Yellow
Write-Host ""

$confirmation = Read-Host "Do you understand the scope and wish to continue? (Y/N)"
if ($confirmation -notmatch '^[Yy]') {
    Write-Host "Operation cancelled by user." -ForegroundColor Yellow
    exit 0
}
Write-Host ""

# Create output folder
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    Write-LogMessage "Created output folder: $OutputFolder`n" -ForegroundColor Green
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
$statsErrors = 0
$hasErrors = $false
$manifest = @()
$libraryManifests = @{}  # Key: "ProjectTitle|LibraryName", Value: Array of manifest entries

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Get-DocumentVersionHistory {
    <#
    .SYNOPSIS
    Exports version history for a document including metadata and file downloads.
    #>
    param(
        [string]$FileRelUrl,
        [string]$FileName,
        [string]$DocFolder
    )
    
    $versions = @()
    
    try {
        $Ctx = Get-PnPContext
        $pnpFile = Get-PnPFile -Url $FileRelUrl
        $fileVersionItem = Get-PnPFile -Url $FileRelUrl -AsListItem
        $versionObjects = Get-PnPProperty -ClientObject $pnpFile -Property Versions
        
        foreach ($version in $versionObjects) {
            $script:statsVersions++
            
            # Build version info with core fields
            $versionInfo = [ordered]@{
                VersionId      = $version.VersionId
                VersionLabel   = $version.VersionLabel
                Created        = $version.Created
                CreatedBy      = $version.CreatedBy.LoginName
                CheckInComment = $version.CheckInComment
                IsCurrent      = $version.IsCurrent
                Url            = $version.Url
                FieldValues    = $fileVersionItem.FieldValues
            }
            
            $versions += $versionInfo
            
            # Download version file if not current
            if (-not $version.IsCurrent) {
                try {
                    $fileExt = [System.IO.Path]::GetExtension($FileName)
                    $fileNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
                    $versionFileName = "$fileNameNoExt`_v$($version.VersionLabel)$fileExt"
                    $versionOutputPath = Join-Path $DocFolder $versionFileName
                    
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
                    Write-Verbose "      Version '$($version.VersionLabel)' not available"
                }
            }
        }
    }
    catch {
        $script:logContent += "[WARNING]     Error reading version history for '$FileName': $($_.Exception.Message)"
        $script:logContent += "    Exception: $($_.Exception.ToString())"
        Write-Host "[WARNING]     Error reading version history for '$FileName': $($_.Exception.Message)" -ForegroundColor Yellow
        $script:statsErrors++
    }
    
    return $versions
}

function Test-AccessDeniedError {
    <#
    .SYNOPSIS
    Checks if an exception is an access denied error and displays appropriate message.
    #>
    param([string]$ExceptionMessage)
    
    if ($ExceptionMessage -match "Access.*denied|Unauthorized|403") {
        Write-Host "[ERROR] Access denied. Please verify you have Site Collection Administrator" -ForegroundColor Red
        Write-Host "        permissions for this site collection." -ForegroundColor Red
        return $true
    }
    return $false
}

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
                Write-LogMessage "    Skipping (blacklist): $fileName"
                continue
            }
            
            # Get full file item for metadata
            $fileItem = Get-PnPFile -Url $fileRelUrl -AsListItem
            
            if ($fileItem) {
                # Basic metadata (always collected)
                $created = $fileItem["Created"]
                $modified = $fileItem["Modified"]
                $createdBy = $fileItem["Author"]
                $modifiedBy = $fileItem["Editor"]
                $fileSize = $fileItem["File_x0020_Size"]
                
                # Extended metadata (only if DetailedMetadata is enabled)
                $eTag = $null
                $uniqueId = $null
                $contentType = $null
                
                if ($DetailedMetadata) {
                    $eTag = $item.ETag                
                    $uniqueId = $item.UniqueId
                    
                    try {                    
                        # Get ContentType
                        if ($fileItem["ContentType"]) {
                            $contentType = $fileItem["ContentType"].Name
                        }
                    }
                    catch {
                        Write-LogMessage "Could not retrieve extended metadata for $fileName"
                    }
                }
                
                $script:statsDocuments++
                
                # Determine download location based on mode
                if ($DetailedMetadata) {
                    # Detailed mode: Create folder per file for metadata
                    $docFolder = Join-Path $OutputPath $fileName
                    if (-not (Test-Path $docFolder)) {
                        New-Item -Path $docFolder -ItemType Directory -Force | Out-Null
                    }
                    $downloadPath = $docFolder
                }
                else {
                    # Simple mode: Download files directly to the library folder
                    $docFolder = $OutputPath
                    $downloadPath = $OutputPath
                    
                    # Ensure the library folder exists
                    if (-not (Test-Path $downloadPath)) {
                        New-Item -Path $downloadPath -ItemType Directory -Force | Out-Null
                    }
                }
                
                # Download current version
                try {
                    Show-DownloadSpinner -Message "Downloading: $fileName" -Action {
                        Get-PnPFile -Url $fileRelUrl -AsFile -Path $downloadPath -FileName $fileName -Force | Out-Null
                    }
                    $script:logContent += "    Downloaded: $fileRelUrl"
                }
                catch {
                    $script:logContent += "[WARNING]     Failed to download '$fileRelUrl': $($_.Exception.Message)"
                    $script:logContent += "    Exception: $($_.Exception.ToString())"
                    Write-Host "[WARNING]     Failed to download '$fileRelUrl': $($_.Exception.Message)" -ForegroundColor Yellow
                    $script:statsErrors++
                    $script:hasErrors = $true
                    
                    # Check for access denied errors
                    Test-AccessDeniedError -ExceptionMessage $_.Exception.Message
                    continue
                }
                
                # Export version history if requested (only in detailed mode)
                $versions = @()
                if ($DetailedMetadata -and -not $ExcludeVersionHistory) {
                    $versions = Get-DocumentVersionHistory -FileRelUrl $fileRelUrl -FileName $fileName -DocFolder $docFolder
                }
                
                # Create metadata file - start with core fields
                $metadata = [ordered]@{
                    FileName   = $fileName
                    FilePath   = $fileRelUrl
                    FileSize   = $fileSize
                    Created    = $created
                    CreatedBy  = $createdBy
                    Modified   = $modified
                    ModifiedBy = $modifiedBy
                    Library    = $LibraryName
                    Project    = $ProjectTitle
                }
                
                # Add extended metadata if DetailedMetadata is enabled
                if ($DetailedMetadata) {
                    $metadata["ETag"] = $eTag
                    $metadata["ContentType"] = $contentType
                    $metadata["UniqueId"] = $uniqueId
                }
                
                # Add version info
                $metadata["VersionCount"] = $versions.Count
                if (-not $ExcludeVersionHistory) {
                    $metadata["Versions"] = $versions
                }
                
                # Add all FieldValues if DetailedMetadata is enabled
                if ($DetailedMetadata) {
                    $metadata["FieldValues"] = $fileItem.FieldValues
                }
                
                # Convert to PSCustomObject for JSON serialization
                $metadata = [PSCustomObject]$metadata
                
                # Save metadata as JSON (only in detailed mode)
                if ($DetailedMetadata) {
                    $metadataPath = Join-Path $docFolder "metadata.json"
                    $metadata | ConvertTo-Json -Depth 5 | Out-File -FilePath $metadataPath -Encoding UTF8
                }
                
                # Create manifest entry
                $manifestEntry = [PSCustomObject]@{
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
                
                # Add extended fields to manifest if DetailedMetadata is enabled
                if ($DetailedMetadata) {
                    $manifestEntry | Add-Member -NotePropertyName "ETag" -NotePropertyValue $eTag
                    $manifestEntry | Add-Member -NotePropertyName "ContentType" -NotePropertyValue $contentType
                    $manifestEntry | Add-Member -NotePropertyName "UniqueId" -NotePropertyValue $uniqueId
                }
                
                # Add to global manifest
                $script:manifest += $manifestEntry
                
                # Add to per-library manifest
                $libKey = "$ProjectTitle|$LibraryName"
                if (-not $script:libraryManifests.ContainsKey($libKey)) {
                    $script:libraryManifests[$libKey] = @()
                }
                $script:libraryManifests[$libKey] += $manifestEntry
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
            Write-LogMessage "    Descending into folder: $subfolderName"
            
            # Recurse into subfolder (will only create directories if files are exported)
            Export-DocumentsRecursive -FolderUrl $subfolderUrl -OutputPath $subfolderOutput `
                -LibraryName $LibraryName -ProjectTitle $ProjectTitle
        }
    }
    catch {
        $script:logContent += "[WARNING] Error processing folder '$FolderUrl': $($_.Exception.Message)"
        $script:logContent += "  Exception: $($_.Exception.ToString())"
        Write-Host "[WARNING] Error processing folder '$FolderUrl': $($_.Exception.Message)" -ForegroundColor Yellow
        $script:statsErrors++
        $script:hasErrors = $true
        
        # Check for access denied errors
        Test-AccessDeniedError -ExceptionMessage $_.Exception.Message
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

Write-LogMessage "PnP.PowerShell module is installed"
Write-LogMessage ""

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
        Write-LogMessage "Connected to: $SiteCollectionUrl"
        Write-LogMessage ""
    }
    catch {
        Write-LogError "Failed to connect: $($_.Exception.Message)" -Exception $_.Exception.ToString()
        
        # Check for access denied errors
        if (Test-AccessDeniedError -ExceptionMessage $_.Exception.Message) {
            Write-LogMessage "" -ForegroundColor Red
            Write-LogMessage "Please verify that you have Site Collection Administrator permissions" -ForegroundColor Red
            Write-LogMessage "for this site collection: $SiteCollectionUrl" -ForegroundColor Red
            Write-LogMessage "" -ForegroundColor Red
        }
        exit 1
    }

    # ==============================================================================
    # GET PROJECT WEBS
    # ==============================================================================

    $filteredWebs = Get-FilteredProjectWebs -ProjectFilter $ProjectFilter -IncludeRootWeb $IncludeRootWeb -ProjectMap $projectMap

    # ==============================================================================
    # PROCESS EACH PROJECT WEB
    # ==============================================================================

    foreach ($web in $filteredWebs) {
        $webTitle = $web.Title
        $webUrl = $web.Url
        $statsProjects++
    
        Write-LogMessage "Processing web: $webTitle" -ForegroundColor Yellow
        Write-LogMessage "  URL: $webUrl" -ForegroundColor Gray
    
        try {
            # Connect to specific web
            Connect-PnPOnline -Url $webUrl -ClientId $ClientId -Interactive
        
            # Get all lists
            $lists = Get-PnPList
            $documentLists = $lists | Where-Object { 
                $_.BaseTemplate -eq 101 -or $_.EntityTypeName -like "*Document*"
            }
        
            Write-LogMessage "  Found $($documentLists.Count) document libraries"
        
            foreach ($library in $documentLists) {
                $libName = $library.Title
            
                # Skip excluded libraries
                if ($ExcludeList -contains $libName) {
                    Write-LogMessage "  Skipping library: $libName (excluded)"
                    continue
                }
            
                $statsLibraries++
                Write-LogMessage "  Processing library: $libName"
            
                # Prepare library output path (created lazily when files are exported)
                $libFolder = Join-Path $OutputFolder $webTitle $libName
            
                # Recursively export documents starting from library root
                Write-LogMessage "    Scanning folders and documents..."
                Export-DocumentsRecursive -FolderUrl $library.RootFolder.ServerRelativeUrl -OutputPath $libFolder `
                    -LibraryName $libName -ProjectTitle $webTitle
                
                # Export per-library manifest
                $libKey = "$webTitle|$libName"
                if ($libraryManifests.ContainsKey($libKey)) {
                    $libManifest = $libraryManifests[$libKey]
                    
                    # CSV manifest for this library
                    $libCsvPath = Join-Path $libFolder "manifest.csv"
                    $libManifest | Export-Csv -Path $libCsvPath -NoTypeInformation -Encoding UTF8
                    Write-LogMessage "    Library manifest: $libCsvPath" -ForegroundColor Gray
                    
                    # JSON manifest for this library
                    $libJsonPath = Join-Path $libFolder "manifest.json"
                    $libManifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $libJsonPath -Encoding UTF8
                }
            }
        }
        catch {
            Write-LogError "Error processing web '$webTitle': $($_.Exception.Message)" -Exception $_.Exception.ToString()
            $script:statsErrors++
            $script:hasErrors = $true
            
            # Check for access denied errors
            if (Test-AccessDeniedError -ExceptionMessage $_.Exception.Message) {
                Write-LogMessage "        [Note] Error accessing web '$webTitle'." -ForegroundColor Red
            }
        }
    
        Write-LogMessage ""
    }

    # ==============================================================================
    # EXPORT MANIFEST
    # ==============================================================================

    Write-LogMessage "Exporting manifest..." -ForegroundColor Cyan

    # CSV manifest
    $csvPath = Join-Path $OutputFolder "documents-manifest.csv"
    $manifest | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-LogMessage "Manifest exported to: $csvPath"

    # JSON manifest
    $jsonPath = Join-Path $OutputFolder "documents-manifest.json"
    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
    Write-LogMessage "Manifest exported to: $jsonPath"

}
finally {   

    # ==============================================================================
    # SUMMARY
    # ==============================================================================

    Write-LogMessage ""
    Write-LogMessage ("=" * 80) -ForegroundColor Cyan
    Write-LogMessage "Document Export Complete!" -ForegroundColor Cyan
    Write-LogMessage ("=" * 80) -ForegroundColor Cyan
    Write-LogMessage ""
    Write-LogMessage "Projects processed:  $statsProjects" -ForegroundColor White
    Write-LogMessage "Libraries exported:  $statsLibraries" -ForegroundColor White
    Write-LogMessage "Documents exported:  $statsDocuments" -ForegroundColor White
    Write-LogMessage "Versions exported:   $statsVersions" -ForegroundColor White
    if ($statsErrors -gt 0) {
        Write-LogMessage "Errors encountered:  $statsErrors" -ForegroundColor Yellow
    }
    Write-LogMessage ""
    Write-LogMessage "Output location: $OutputFolder" -ForegroundColor Green
    Write-LogMessage ""

    # Return appropriate exit code
    if ($hasErrors) {
        Write-LogMessage "Script completed with errors. Review log file for details." -ForegroundColor Yellow
        exit 2  # Exit code 2 = completed with errors
    }
    else {
        Write-LogMessage "Script completed successfully." -ForegroundColor Green
        exit 0  # Exit code 0 = success
    }

    # Always save the log, even if the script fails earlier
    Save-ExportLog
}
