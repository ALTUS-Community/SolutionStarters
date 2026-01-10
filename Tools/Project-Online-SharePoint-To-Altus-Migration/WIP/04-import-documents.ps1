<#
.SYNOPSIS
  Import documents exported from SharePoint to matching project sites in target SharePoint collection

.DESCRIPTION
  Imports documents that were previously exported with 03-export-documents.ps1
  into corresponding project web sites in a target SharePoint site collection.
  
  Automatically matches source projects to target webs and uploads documents,
  preserving folder structure and metadata from export.

.PARAMETER SourceFolder
  Folder containing exported documents from 03-export-documents.ps1
  (typically Output/<SiteName>/)

.PARAMETER TargetSiteCollectionUrl
  Target SharePoint site collection URL where documents will be imported
  (e.g., https://tenant.sharepoint.com/sites/target)

.PARAMETER ProjectFilter
  Optional wildcard pattern(s) to filter which projects to import.
  Examples: "Project A", "*2024*", "Project*", @("ProjectA", "ProjectB")

.PARAMETER ClientId
  Optional Entra ID Client ID for authentication. Defaults to Sensei app client ID.

.PARAMETER MatchingMode
  How to match source projects to target webs:
  - "Exact" (default): Match by exact name
  - "Contains": Match if target web title contains source project name
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $SourceFolder,

    [Parameter(Mandatory = $true)]
    [string] $TargetSiteCollectionUrl,

    [Parameter(Mandatory = $false)]
    [string[]] $ProjectFilter = @(),

    [Parameter(Mandatory = $false)]
    [string] $ClientId = "30b4ad0b-d939-4cd4-bb6d-fa2d39fb4694",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Exact", "Contains")]
    [string] $MatchingMode = "Exact",

    [Parameter(Mandatory = $false)]
    [switch] $CreateMissingLibraries,

    [Parameter(Mandatory = $false)]
    [switch] $CreateMissingWebs,

    [Parameter(Mandatory = $false)]
    [string] $WebTemplate = "STS#3"
)

# Import common helpers
$commonHelpersPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Common-Helpers.ps1"
if (-not (Test-Path $commonHelpersPath)) {
    Write-Error "Common helpers script not found: $commonHelpersPath"
    exit 1
}
. $commonHelpersPath

# ==============================================================================
# INITIALIZATION
# ==============================================================================

Write-Host "`nDocument Import Parameters:" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host "SourceFolder:              $SourceFolder" -ForegroundColor Gray
Write-Host "TargetSiteCollectionUrl:   $TargetSiteCollectionUrl" -ForegroundColor Gray
Write-Host "MatchingMode:              $MatchingMode" -ForegroundColor Gray
Write-Host "CreateMissingLibraries:    $CreateMissingLibraries" -ForegroundColor Gray
Write-Host "CreateMissingWebs:         $CreateMissingWebs" -ForegroundColor Gray
Write-Host "WebTemplate:               $WebTemplate" -ForegroundColor Gray
if ($ProjectFilter -and $ProjectFilter.Count -gt 0) {
    Write-Host "ProjectFilter:             $($ProjectFilter -join ', ')" -ForegroundColor Gray
}
Write-Host ""

# Verify source folder exists
if (-not (Test-Path $SourceFolder)) {
    Write-Host "ERROR: Source folder not found: $SourceFolder" -ForegroundColor Red
    exit 1
}

# Initialize logging
$script:logContent = @()

# Tracking
$statsProjects = 0
$statsLibraries = 0
$statsDocuments = 0
$statsVersions = 0
$statsMatches = 0

# ==============================================================================
# GLOBAL TRY-FINALLY TO GUARANTEE LOG SAVE
# ==============================================================================
try {

    # ==============================================================================
    # CONNECT TO TARGET SHAREPOINT
    # ==============================================================================

    Write-Host "Connecting to target SharePoint (interactive)..." -ForegroundColor Cyan
    try {
        Connect-PnPOnline -Url $TargetSiteCollectionUrl -ClientId $ClientId -Interactive -ErrorAction Stop
        Write-Log "Connected to: $TargetSiteCollectionUrl"
        Write-Host ""
    }
    catch {
        Write-LogError "Failed to connect: $($_.Exception.Message)" -Exception $_.Exception.ToString()
        exit 1
    }

    # ==============================================================================
    # DISCOVER TARGET PROJECT WEBS
    # ==============================================================================

    Write-Host "Discovering target project webs..." -ForegroundColor Cyan
    try {
        $targetWebs = Get-PnPSubWeb -Recurse -Includes "WebTemplate"
    
        # Filter out app webs
        $filteredWebs = @()
        foreach ($web in $targetWebs) {
            if ($web.WebTemplate -like "APP#*") {
                Write-Verbose "Skipping app web: $($web.Title)"
                continue
            }
            $filteredWebs += $web
        }
    
        Write-Log "Found $($filteredWebs.Count) target project webs"
        Write-Host ""
    }
    catch {
        Write-LogError "Error discovering webs: $($_.Exception.Message)" -Exception $_.Exception.ToString()
        exit 1
    }

    # ==============================================================================
    # DISCOVER SOURCE PROJECTS
    # ==============================================================================

    Write-Host "Discovering exported projects..." -ForegroundColor Cyan

    $projectFolders = Get-ChildItem -Path $SourceFolder -Directory | Where-Object { $_.Name -ne "Documents" } | Select-Object -ExpandProperty Name

    if ($projectFolders -is [string]) {
        $projectFolders = @($projectFolders)
    }

    $filteredProjects = @()
    foreach ($project in $projectFolders) {
        # Check project filter
        if ($ProjectFilter -and $ProjectFilter.Count -gt 0) {
            $matches = $false
            foreach ($filter in $ProjectFilter) {
                if ($project -like $filter) {
                    $matches = $true
                    break
                }
            }
            if (-not $matches) {
                continue
            }
        }
        $filteredProjects += $project
    }

    Write-Log "Found $($filteredProjects.Count) matching exported projects`n"

    # ==============================================================================
    # IMPORT DOCUMENTS FOR EACH PROJECT
    # ==============================================================================

    foreach ($projectName in $filteredProjects) {
        $projectPath = Join-Path $SourceFolder $projectName "Documents"
    
        if (-not (Test-Path $projectPath)) {
            Write-LogWarning "Documents folder not found for project: $projectName"
            continue
        }
    
        Write-Host "Processing project: $projectName" -ForegroundColor Yellow
    
        # Find matching target web
        $targetWeb = $null
        foreach ($web in $filteredWebs) {
            $match = if ($MatchingMode -eq "Exact") {
                $web.Title -eq $projectName
            }
            else {
                $web.Title -like "*$projectName*"
            }
        
            if ($match) {
                $targetWeb = $web
                $statsMatches++
                break
            }
        }
    
        if (-not $targetWeb) {
            if ($CreateMissingWebs) {
                Write-Host "  Creating web: $projectName" -ForegroundColor Cyan
                try {
                    $webUrl = "$TargetSiteCollectionUrl/$([uri]::EscapeDataString($projectName))"
                    $newWeb = New-PnPWeb -Title $projectName -Url ([uri]::EscapeDataString($projectName)) -Template $WebTemplate
                    $targetWeb = $newWeb
                    $statsMatches++
                    Write-Log "  Created project web: $projectName at $($newWeb.Url)"
                }
                catch {
                    Write-LogError "  Failed to create web '$projectName': $($_.Exception.Message)" -Exception $_.Exception.ToString()
                    continue
                }
            }
            else {
                Write-LogWarning "  No matching target web found for project: $projectName (mode: $MatchingMode, use -CreateMissingWebs to auto-create)"
                continue
            }
        }
    
        $statsProjects++
        Write-Host "  Matched to: $($targetWeb.Title)" -ForegroundColor Green
    
        # Connect to target web
        try {
            Connect-PnPOnline -Url $targetWeb.Url -ClientId $ClientId -Interactive | Out-Null
            Write-Log "  Connected to target web: $($targetWeb.Title)"
        }
        catch {
            Write-LogError "  Failed to connect to target web: $($_.Exception.Message)" -Exception $_.Exception.ToString()
            continue
        }
    
        # Get document libraries in the project folder
        $libraryFolders = Get-ChildItem -Path $projectPath -Directory | Select-Object -ExpandProperty Name
    
        if ($libraryFolders -is [string]) {
            $libraryFolders = @($libraryFolders)
        }
    
        foreach ($libraryName in $libraryFolders) {
            $libraryPath = Join-Path $projectPath $libraryName
            $statsLibraries++
        
            Write-Host "  Library: $libraryName" -ForegroundColor Cyan
        
            # Get or create library in target web
            try {
                $library = Get-PnPList -Identity $libraryName -ErrorAction SilentlyContinue
                if (-not $library) {
                    if ($CreateMissingLibraries) {
                        Write-Host "    Creating library: $libraryName" -ForegroundColor Cyan
                        $library = New-PnPList -Title $libraryName -Template DocumentLibrary
                        Write-Log "    Created document library: $libraryName"
                    }
                    else {
                        Write-LogWarning "    Library '$libraryName' not found in target web (use -CreateMissingLibraries to auto-create)"
                        continue
                    }
                }
            }
            catch {
                Write-LogWarning "    Error accessing library '$libraryName': $($_.Exception.Message)"
                continue
            }
        
            # Import documents recursively
            try {
                Import-DocumentsRecursive -SourcePath $libraryPath -TargetLibrary $library -ProjectName $projectName -LibraryName $libraryName
            }
            catch {
                Write-LogError "    Error importing documents from library: $($_.Exception.Message)" -Exception $_.Exception.ToString()
            }
        }
    }

    # ==============================================================================
    # HELPER FUNCTION: IMPORT DOCUMENTS RECURSIVELY
    # ==============================================================================

    function Import-DocumentsRecursive {
        param(
            [string]$SourcePath,
            [object]$TargetLibrary,
            [string]$ProjectName,
            [string]$LibraryName
        )
    
        # Get all files in current folder
        $files = Get-ChildItem -Path $SourcePath -File
    
        foreach ($file in $files) {
            # Skip metadata.json files
            if ($file.Name -eq "metadata.json") {
                continue
            }
        
            $filePath = $file.FullName
            $fileName = $file.Name
        
            try {
                Write-Host "    Uploading: $fileName" -NoNewline -ForegroundColor Cyan
            
                # Upload file to root of library
                Add-PnPFile -Path $filePath -Folder $TargetLibrary.RootFolder -Overwrite
            
                $script:statsDocuments++
                Write-Host " `u{2713}" -ForegroundColor Green
                $script:logContent += "    Uploaded: $fileName"
            }
            catch {
                Write-Host " X" -ForegroundColor Red
                $script:logContent += "[WARNING]     Failed to upload '$fileName': $($_.Exception.Message)"
                $script:logContent += "    Exception: $($_.Exception.ToString())"
            }
        }
    
        # Recursively import subfolders
        $subfolders = Get-ChildItem -Path $SourcePath -Directory
    
        foreach ($subfolder in $subfolders) {
            $subfolderName = $subfolder.Name
        
            Write-Log "    Descending into folder: $subfolderName"
        
            # Create folder in target library
            $targetFolder = $null
            try {
                $folders = Get-PnPFolderInPath -FolderSiteRelativeUrl "$($TargetLibrary.RootFolder.ServerRelativeUrl)/$subfolderName"
                if (-not $folders) {
                    $targetFolder = Add-PnPFolder -Name $subfolderName -Folder $TargetLibrary.RootFolder
                }
                else {
                    $targetFolder = $folders[0]
                }
            }
            catch {
                Write-LogWarning "    Could not create/find folder '$subfolderName': $($_.Exception.Message)"
                continue
            }
        
            # Recurse into subfolder
            Import-DocumentsRecursive -SourcePath $subfolder.FullName -TargetLibrary $TargetLibrary -ProjectName $ProjectName -LibraryName $LibraryName
        }
    }

}
finally {
    # Always save the log, even if the script fails earlier
    Save-ImportLog
}

# ==============================================================================
# SUMMARY
# ==============================================================================

Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Document Import Complete!" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""
Write-Host "Projects processed:  $statsProjects" -ForegroundColor White
Write-Host "Web matches found:   $statsMatches" -ForegroundColor White
Write-Host "Libraries imported:  $statsLibraries" -ForegroundColor White
Write-Host "Documents imported:  $statsDocuments" -ForegroundColor White
Write-Host ""
