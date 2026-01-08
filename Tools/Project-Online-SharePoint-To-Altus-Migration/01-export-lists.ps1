
<#
.SYNOPSIS
  Export SharePoint project-site lists to a CMT-compliant Data.xml using PnP.PowerShell, with correct lookup handling.

.DESCRIPTION
  Extracts project data from SharePoint project sites and converts to CMT-compliant XML format.
  
  IMPORTANT: Your user account must be a Site Collection Administrator on the target site collection.
  If you receive "Access is denied" errors, verify your Site Collection Admin role.

.PARAMETER SiteCollectionUrl
  The PWA site collection URL (e.g., https://tenant.sharepoint.com/sites/PWA)

.PARAMETER MappingJsonPath
  Path to JSON mapping file

.PARAMETER CmtSchemaPath
  Path to the CMT Schema.xml exported from the target Altus environment

.PARAMETER OutputFolder
  Folder to write Data.xml (and logs)

.PARAMETER ProjectFilter
  Optional wildcard pattern(s) to filter project sites by title. Supports multiple patterns.
  Examples: "Project A", "*2024*", "Project*", @("ProjectA", "ProjectB")

.PARAMETER ClientId
  Optional Entra ID Client ID for authentication. Defaults to Sensei app client ID.

.PARAMETER POLExportPath
  Optional path to Project Online export folder containing *_reporting.json files.
  If provided, project names and UIDs are sourced from the JSON export instead of SharePoint.
  Example: "C:\exports\POL\VNext"
#>

param(
    [Parameter(Mandatory = $false)]
    [string] $SiteCollectionUrl = "https://senseijumpstart.sharepoint.com/sites/pwa",

    [Parameter(Mandatory = $false)]
    [string] $MappingJsonPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "export.config.json"),

    [Parameter(Mandatory = $false)]
    [string] $CmtSchemaPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "data_schema.xml"),

    [Parameter(Mandatory = $false)]
    [string] $OutputFolder = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Output"),

    [Parameter(Mandatory = $false)]
    [string] $TargetSiteCollectionUrl,

    [Parameter(Mandatory = $false)]
    [string[]] $ProjectFilter = @(),

    [Parameter(Mandatory = $false)]
    [string] $ClientId = "30b4ad0b-d939-4cd4-bb6d-fa2d39fb4694",

    [Parameter(Mandatory = $false)]
    [switch] $SkipProjectIdCheck,

    [Parameter(Mandatory = $true)]
    [string] $POLExportPath
)

# Import helper functions
$helperPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Export-Helpers.ps1"
if (-not (Test-Path $helperPath)) {
    Write-Error "Helper script not found: $helperPath"
    exit 1
}
. $helperPath

$migrationHelpersPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Migration-Helpers.ps1"
if (-not (Test-Path $migrationHelpersPath)) {
    Write-Error "Migration helpers script not found: $migrationHelpersPath"
    exit 1
}
. $migrationHelpersPath

# ==============================================================================
# INITIALIZATION
# ==============================================================================

Write-Host "`nExport Parameters:" -ForegroundColor Cyan
Write-Host "==================" -ForegroundColor Cyan
Write-Host "SiteCollectionUrl:        $SiteCollectionUrl" -ForegroundColor Gray
Write-Host "MappingJsonPath:          $MappingJsonPath" -ForegroundColor Gray
Write-Host "CmtSchemaPath:            $CmtSchemaPath" -ForegroundColor Gray
Write-Host "OutputFolder:             $OutputFolder" -ForegroundColor Gray
if ($TargetSiteCollectionUrl) {
    Write-Host "TargetSiteCollectionUrl:  $TargetSiteCollectionUrl" -ForegroundColor Gray
}
if ($ProjectFilter -and $ProjectFilter.Count -gt 0) {
    Write-Host "ProjectFilter:            $($ProjectFilter -join ', ')" -ForegroundColor Gray
}
Write-Host "ClientId:                 $ClientId" -ForegroundColor Gray
if ($SkipProjectIdCheck) {
    Write-Host "SkipProjectIdCheck:       True" -ForegroundColor Gray
}
if ($POLExportPath) {
    Write-Host "POLExportPath:            $POLExportPath" -ForegroundColor Gray
}
Write-Host ""

# ==============================================================================
# PREREQUISITES
# ==============================================================================

Write-Host "Checking prerequisites..." -ForegroundColor Cyan
Test-PnPModule

if (-not (Test-Path $OutputFolder)) { 
    New-Item -Path $OutputFolder -ItemType Directory | Out-Null 
}

# ==============================================================================
# LOAD CONFIGURATION
# ==============================================================================

Write-Host "Loading JSON mapping and CMT schema..." -ForegroundColor Cyan
if (-not (Test-Path $MappingJsonPath)) { 
    Write-Error "Mapping JSON not found."
    exit 1 
}
if (-not (Test-Path $CmtSchemaPath)) { 
    Write-Error "CMT Schema.xml not found."
    exit 1 
}

$Mapping = Get-Content -Raw -Path $MappingJsonPath | ConvertFrom-Json
[xml]$CmtSchema = Get-Content -Path $CmtSchemaPath

# Build project map from POL export if provided
$projectMap = @{}  # Map of project URL → @{Name, UID}
if ($POLExportPath) {
    $projectMap = Build-ProjectMap -ExportPath $POLExportPath
}

# Initialize counters and logging
$script:totalProjectsProcessed = 0
$script:totalItemsExported = 0
$script:timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:logPath = Join-Path $OutputFolder "Export_$script:timestamp.log"
$script:logContent = @()

Write-LogMessage "Export started at $(Get-Date -Format o)"

$SchemaLookup = New-SchemaLookup -Schema $CmtSchema

# ==============================================================================
# SHAREPOINT CONNECTIVITY
# ==============================================================================

Write-Host "Connecting to SharePoint (interactive as Site Collection Admin)..." -ForegroundColor Cyan
Connect-PnPOnline -Url $SiteCollectionUrl -Interactive -ClientId $ClientId

# ==============================================================================
# WEB PROCESSING
# ==============================================================================

try {
    $webs = Get-ProjectWebs
    Write-Host "Found $($webs.Count) project webs." -ForegroundColor Green
    Write-LogMessage "Found $($webs.Count) project webs."

    # Apply project filter if specified
    if ($ProjectFilter -and $ProjectFilter.Count -gt 0) {
        $filteredWebs = @()
        foreach ($web in $webs) {
            $matched = $false
            # Try to match against POL name if available; otherwise use web title
            # Extract last segment of web URL for lookup
            $webUrlSegment = [uri]::UnescapeDataString(($web.Url -split '/')[-1])
            $matchNameToTest = if ($projectMap.ContainsKey($webUrlSegment)) {
                $projectMap[$webUrlSegment].Name
            }
            else {
                $web.Title
            }
            
            foreach ($pattern in $ProjectFilter) {
                if ($matchNameToTest -like $pattern) {
                    $matched = $true
                    break
                }
            }
            if ($matched) {
                $filteredWebs += $web
            }
        }
        $webs = $filteredWebs
        Write-Host "Filtered to $($webs.Count) project(s) matching: $($ProjectFilter -join ', ')" -ForegroundColor Yellow
        Write-LogMessage "Filtered to $($webs.Count) project(s) matching: $($ProjectFilter -join ', ')"
    }

    foreach ($web in $webs) {
        # ==============================================================================
        # SKIP HIDDEN/APP WEBS
        # ==============================================================================

        if ($web.WebTemplate -like "APP*") {
            Write-LogWarning "Skipping app web (template=$($web.WebTemplate)): $($web.Url)"
            continue
        }

        if ($web.Hidden) {
            Write-LogWarning "Skipping hidden web: $($web.Url)"
            continue
        }

        # Use POL project name if available; otherwise use web title
        # Extract last segment of web URL for lookup
        $webUrlSegment = [uri]::UnescapeDataString(($web.Url -split '/')[-1])
        $projectName = $web.Title
        $projectId = $null
        if ($projectMap.ContainsKey($webUrlSegment)) {
            $projectName = $projectMap[$webUrlSegment].Name
            $projectId = $projectMap[$webUrlSegment].UID
        }

        Write-Host "Processing web: $projectName ($($web.Url))" -ForegroundColor Cyan
        if ($projectId) {
            Write-Host "  ProjectId: $projectId" -ForegroundColor Gray
        }

        # ==============================================================================
        # GET PROJECT METADATA
        # ==============================================================================

        Connect-PnPOnline -Url $web.Url -ClientId $ClientId

        $projectItemCount = 0
        
        # ProjectId must come from POL map; we don't fall back to SharePoint
        if (-not $projectId) {
            Write-Host "  SKIPPING: Project not found in POL export map: $($web.Url)" -ForegroundColor Yellow
            Write-LogWarning "Project '$projectName' ($($web.Url)) not found in POL export. Skipping."
            continue
        }
        
        Write-LogMessage "Using ProjectId from POL export: $projectId"
        
        Write-LogMessage "Project: $projectName ($($web.Url))"

        # ==============================================================================
        # CREATE OUTPUT
        # ==============================================================================

        $dataXml = New-CmtDataXml
        $safeFolderName = $projectName -replace '[\\/:*?"<>|]', '_'
        $projectOutputFolder = Join-Path $OutputFolder $safeFolderName
        
        if (-not (Test-Path $projectOutputFolder)) { 
            New-Item -Path $projectOutputFolder -ItemType Directory | Out-Null 
        }

        # ==============================================================================
        # LIST PROCESSING
        # ==============================================================================

        foreach ($l in $Mapping.lists) {
            $spListTitle = $l.spListTitle
            $entityLogicalName = $l.entityLogicalName
            $projectLookupAttribute = $l.projectLookupAttribute
            $backlinkAttribute = $l.backlinkAttribute
            $columnMap = @($l.columnMap)

            # Get list
            try {
                $listUrl = "Lists/$spListTitle"
                $list = Get-PnPList -Identity $listUrl -ErrorAction Stop
                Write-Host "  Found list: $spListTitle" -ForegroundColor Yellow
                Write-LogMessage "  Found list: $spListTitle"
            }
            catch {
                Write-Warning "List '$spListTitle' not found. Skipping."
                Write-LogWarning "List '$spListTitle' not found in project '$projectSiteName' ($($web.Url))."
                continue
            }

            # Get items
            try {
                $items = Get-PnPListItem -List $list -PageSize 5000 -ErrorAction Stop
                Write-Host ("  {0} items from '{1}'" -f $items.Count, $spListTitle)
                Write-LogMessage "  List '$spListTitle': $($items.Count) items"
                $projectItemCount += $items.Count
            }
            catch {
                Write-Warning "Error retrieving items from list '$spListTitle': $($_.Exception.Message)"
                Write-LogWarning "Error retrieving items from list '$spListTitle' in project '$projectSiteName': $($_.Exception.Message)"
                continue
            }

            # ==============================================================================
            # ITEM CONVERSION
            # ==============================================================================

            foreach ($item in $items) {
                # Build source URL
                $sourceItemUrl = "$($web.Url)/Lists/$($list.Title)/DispForm.aspx?ID=$($item.Id)"
                $itemUrl = $sourceItemUrl

                # Remap to target site collection if specified
                if ($TargetSiteCollectionUrl) {
                    $sourceBase = $SiteCollectionUrl.TrimEnd('/')
                    $targetBase = $TargetSiteCollectionUrl.TrimEnd('/')
                    if ($web.Url.StartsWith($sourceBase, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $targetWebUrl = $web.Url -replace [regex]::Escape($sourceBase), $targetBase
                        $itemUrl = "$targetWebUrl/Lists/$($list.Title)/DispForm.aspx?ID=$($item.Id)"
                    }
                    else {
                        Write-LogWarning "Could not map web URL $($web.Url) to target site collection $TargetSiteCollectionUrl; using source URL for backlink."
                    }
                }

                # Convert item to entity attributes
                $ctx = @{
                    columnMap              = $columnMap
                    backlinkAttribute      = $backlinkAttribute
                    projectLookupAttribute = $projectLookupAttribute
                    ProjectId              = $projectId
                    ItemUrl                = $itemUrl
                }
                
                $schemaFields = $SchemaLookup[$entityLogicalName]
                $attrs = Convert-SpItemToEntity -Item $item.FieldValues -Ctx $ctx `
                    -ProjectGuid $projectId -ProjectName $projectName `
                    -EntityLogicalName $entityLogicalName -SchemaFieldLookup $schemaFields
            
                $guid = [System.Guid]::NewGuid().ToString()
                $attrs["_recordId"] = $guid
            
                Add-CmtEntityRecord -Doc $dataXml -EntityLogicalName $entityLogicalName -Attributes $attrs
            }
        }
    
        # ==============================================================================
        # SAVE PROJECT DATA
        # ==============================================================================

        $dataPath = Join-Path $projectOutputFolder "Data.xml"
        $dataXml.Save($dataPath)
        Write-Host "  Data.xml saved to: $dataPath" -ForegroundColor Green

        $script:totalProjectsProcessed++
        $script:totalItemsExported += $projectItemCount
    }

    # ==============================================================================
    # SUMMARY
    # ==============================================================================

    Write-Host "`nExport complete!" -ForegroundColor Green
    Write-Host "Projects processed: $script:totalProjectsProcessed" -ForegroundColor Cyan
    Write-Host "Total items exported: $script:totalItemsExported" -ForegroundColor Cyan
}
finally {
    # ==============================================================================
    # FINALIZATION
    # ==============================================================================

    $script:logContent += "Summary: Projects processed=$script:totalProjectsProcessed, Items exported=$script:totalItemsExported"
    $script:logContent += "Export finished at $(Get-Date -Format o)"
    $script:logContent | Out-File -FilePath $script:logPath -Encoding UTF8
    Write-Host "Log saved to: $script:logPath" -ForegroundColor Cyan
}