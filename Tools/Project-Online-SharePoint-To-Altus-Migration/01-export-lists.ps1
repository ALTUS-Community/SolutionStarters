
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

.PARAMETER BacklinkFieldName
  Optional field name to store backlink to SharePoint item URL in the Dynamics 365 record.
  If provided and the field exists in the schema, the backlink will be added to the exported data.
  This is useful for post-migration reference to original SharePoint items.
  Example: "alt_SharePointItemUrl"
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $SiteCollectionUrl,

    [Parameter(Mandatory = $false)]
    [string] $MappingJsonPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "export.config.json"),

    [Parameter(Mandatory = $false)]
    [string] $CmtSchemaPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "data_schema.xml"),

    [Parameter(Mandatory = $true)]
    [string] $OutputFolder,

    [Parameter(Mandatory = $false)]
    [string] $BacklinkFieldName,

    [Parameter(Mandatory = $false)]
    [string[]] $ProjectFilter = @(),

    [Parameter(Mandatory = $false)]
    [string] $ClientId = "30b4ad0b-d939-4cd4-bb6d-fa2d39fb4694",

    [Parameter(Mandatory = $true)]
    [string] $POLExportPath
)

# Import helper functions
$commonHelpersPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Common-Helpers.ps1"
if (-not (Test-Path $commonHelpersPath)) {
    Write-Error "Common helpers script not found: $commonHelpersPath"
    $global:LASTEXITCODE = 1
    return
}
. $commonHelpersPath

$script:hadError = $false

# ==============================================================================
# INITIALIZATION
# ==============================================================================

Write-Host "`nExport Parameters:" -ForegroundColor Cyan
Write-Host "==================" -ForegroundColor Cyan
Write-Host "SiteCollectionUrl:        $SiteCollectionUrl" -ForegroundColor Gray
Write-Host "MappingJsonPath:          $MappingJsonPath" -ForegroundColor Gray
Write-Host "CmtSchemaPath:            $CmtSchemaPath" -ForegroundColor Gray
Write-Host "OutputFolder:             $OutputFolder" -ForegroundColor Gray
if ($BacklinkFieldName) {
    Write-Host "BacklinkFieldName:        $BacklinkFieldName" -ForegroundColor Gray
}
if ($ProjectFilter -and $ProjectFilter.Count -gt 0) {
    Write-Host "ProjectFilter:            $($ProjectFilter -join ', ')" -ForegroundColor Gray
}
Write-Host "ClientId:                 $ClientId" -ForegroundColor Gray
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
    Write-LogMessage "Found $($webs.Count) sub webs." -ForegroundColor Green

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
        Write-LogMessage "Filtered to $($webs.Count) project(s) matching: $($ProjectFilter -join ', ')" -ForegroundColor Yellow
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

        Write-Host ""
        Write-Host "Processing web: $projectName ($($web.Url))" -ForegroundColor Cyan

        # ==============================================================================
        # GET PROJECT METADATA
        # ==============================================================================

        Connect-PnPOnline -Url $web.Url -ClientId $ClientId

        $projectItemCount = 0
        
        # ProjectId must come from POL map; we don't fall back to SharePoint
        if (-not $projectId) {            
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
        
        # Extract scheme and domain from web URL (e.g., https://tenant.sharepoint.com)
        $uri = [System.Uri]$web.Url
        $rootUrl = "$($uri.Scheme)://$($uri.Authority)"

        foreach ($l in $Mapping.lists) {
            $spListTitle = $l.spListTitle
            $entityLogicalName = $l.entityLogicalName
            $projectLookupAttribute = $l.projectLookupAttribute
            $backlinkAttribute = $l.backlinkAttribute
            $columnMap = @($l.columnMap)

            # Get list
            try {
                $listUrl = "Lists/$spListTitle"
                $list = Get-PnPList -Identity $listUrl -Includes "DefaultDisplayFormUrl" -ErrorAction Stop 
                Write-LogMessage "  Found list: $spListTitle" -ForegroundColor Green
            }
            catch {
                Write-Warning "List '$spListTitle' not found. Skipping."
                Write-LogWarning "List '$spListTitle' not found in project '$projectSiteName' ($($web.Url))."
                $script:hadError = $true
                continue
            }

            # Get items
            try {
                $items = Get-PnPListItem -List $list -PageSize 5000 -ErrorAction Stop
                $itemCount = @($items).Count
                Write-LogMessage "  List '$spListTitle': $itemCount items" -ForegroundColor Cyan
                $projectItemCount += $itemCount
            }
            catch {
                Write-Warning "Error retrieving items from list '$spListTitle': $($_.Exception.Message)"
                Write-LogWarning "Error retrieving items from list '$spListTitle' in project '$projectSiteName': $($_.Exception.Message)"
                $script:hadError = $true
                continue
            }

            # ==============================================================================
            # ITEM CONVERSION
            # ==============================================================================

            foreach ($item in $items) {
                # Build item URL using root domain + server-relative form URL + item ID
                # DefaultDisplayFormUrl is server-relative (e.g., "/sites/pwadev/Pauls Test/Lists/Risks/DispForm.aspx")
                $itemUrl = "$($rootUrl)$($list.DefaultDisplayFormUrl)?ID=$($item.Id)"

                # Convert item to entity attributes
                $ctx = @{
                    columnMap              = $columnMap
                    backlinkAttribute      = $backlinkAttribute
                    projectLookupAttribute = $projectLookupAttribute
                    ProjectId              = $projectId
                    ItemUrl                = $itemUrl
                    BacklinkFieldName      = $BacklinkFieldName
                }
                
                $schemaFields = $SchemaLookup[$entityLogicalName]
                $attrs = Convert-SpItemToEntity -Item $item.FieldValues -Ctx $ctx `
                    -ProjectGuid $projectId -ProjectName $projectName `
                    -EntityLogicalName $entityLogicalName -SchemaFieldLookup $schemaFields
            
                # Create deterministic GUID from SharePoint List ID and Item ID to ensure consistency across multiple exports
                # $deterministicId = New-HashGuid -InputString "$($list.Id)|$($item.Id)"
                # $attrs["_recordId"] = $deterministicId.ToString()
                $attrs["_recordId"] = $item.FieldValues["GUID"];
            
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

    Write-Host ""
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
    
    $global:LASTEXITCODE = if ($script:hadError) { 1 } else { 0 }
}