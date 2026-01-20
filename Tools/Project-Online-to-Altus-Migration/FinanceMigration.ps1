# PowerShell Script: Migrate Project Financials to Dataverse (Interactive Login)
# Supports -DryRun for testing without making changes
# New: -Directory to process multiple projects from a folder

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [string]$ProjectName,

    [string]$TasksFile,
    [string]$BaselinesFile,
    [string]$PublishedFile,

    [string]$Directory,

    [switch]$DryRun,

    [string]$LogFile = "migration_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
)

function Write-LogMessage {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Get-AccessToken-Interactive {
    param ([string]$EnvironmentUrl)
    $scope = "$EnvironmentUrl/.default"
    Write-LogMessage "Initiating interactive login..."
    try {
        $tokenResult = Get-MsalToken `
            -ClientId "1950a258-227b-4e31-a9cf-717495945fc2" `
            -TenantId "common" `
            -Scopes $scope `
            -Interactive `
            -ErrorAction Stop
        Write-LogMessage "Authentication successful."
        return $tokenResult.AccessToken
    }
    catch {
        Write-LogMessage "Login failed: $($_.Exception.Message)" "ERROR"
        throw
    }
}

function Search-ProjectByName {
    param (
        [string]$BaseUrl,
        [string]$ProjectName,
        [string]$Token
    )

    $headers = @{
        Authorization  = "Bearer $Token"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
    }

    $filter = "name eq '$([uri]::EscapeDataString($ProjectName))'"
    $queryUrl = "$BaseUrl/api/data/v9.2/projects?`$filter=$filter&`$select=projectid,name,description&`$top=10"

    try {
        $response = Invoke-RestMethod -Method Get -Uri $queryUrl -Headers $headers -ErrorAction Stop
        return $response.value
    } catch {
        Write-LogMessage "Project search failed: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-ExistingFinancialRecords {
    param (
        [string]$BaseUrl,
        [string]$ProjectUid,
        [string]$Token
    )

    $headers = @{
        Authorization  = "Bearer $Token"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
    }

    $filter = "_sensei_project_value eq $ProjectUid"

    $itemUrl = "$BaseUrl/api/data/v9.2/sensei_financialitems?`$filter=$filter&`$top=1"
    $itemsResp = Invoke-RestMethod -Method Get -Uri $itemUrl -Headers $headers
    $itemCount = $itemsResp.value.Count

    $transUrl = "$BaseUrl/api/data/v9.2/sensei_financialtransactions?`$filter=$filter&`$top=1"
    $transResp = Invoke-RestMethod -Method Get -Uri $transUrl -Headers $headers
    $transCount = $transResp.value.Count

    return @{
        ItemCount  = $itemCount
        TransCount = $transCount
        HasRecords = ($itemCount -gt 0 -or $transCount -gt 0)
    }
}

function Invoke-RecordUpsert {
    param (
        [string]$EntitySetName,
        [hashtable]$Data,
        [string]$ExternalId,
        [string]$ProjectUid,
        [string]$Token,
        [string]$BaseUrl,
        [switch]$DryRun
    )

    $action = if ($DryRun) { "DRY-RUN WOULD " } else { "" }

    # Simulate lookup
    Write-LogMessage "$action Checking for existing $EntitySetName with externalid '$ExternalId' on project $ProjectUid"

    if ($DryRun) {
        Write-LogMessage "$action Would upsert $EntitySetName (name: $($Data.sensei_name), type: $($Data.sensei_type), amount: $(if ($Data.sensei_amount) { $Data.sensei_amount } else { 'N/A' }))"
        return "DRYRUN-$([guid]::NewGuid().ToString())"  # fake ID for dry-run chaining
    }

    $headers = @{
        Authorization  = "Bearer $Token"
        "Content-Type" = "application/json"
        Prefer         = "return=representation"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
    }
    
    $filter = "sensei_externalid eq '$ExternalId' and _sensei_project_value eq $ProjectUid"
    $queryUrl = "$BaseUrl/api/data/v9.2/$EntitySetName`?`$filter=$([uri]::EscapeDataString($filter))&`$select=sensei_${EntitySetName -replace 's$',''}id"

    $existing = Invoke-RestMethod -Method Get -Uri $queryUrl -Headers $headers
    if ($existing.value.Count -gt 0) {
        $id = $existing.value[0]."sensei_$($EntitySetName -replace 's$','')id"
        $url = "$BaseUrl/api/data/v9.2/$EntitySetName($id)"
        Invoke-RestMethod -Method Patch -Uri $url -Headers $headers -Body ($Data | ConvertTo-Json -Depth 10 -Compress)
        Write-LogMessage "Updated $EntitySetName (id: $id)"
        return $id
    }

    $url = "$BaseUrl/api/data/v9.2/$EntitySetName"
    $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body ($Data | ConvertTo-Json -Depth 10 -Compress)
    $id = $response."sensei_$($EntitySetName -replace 's$','')id"
    Write-LogMessage "Created $EntitySetName (id: $id)"
    return $id
}

function Process-Project {
    param (
        [string]$TasksFile,
        [string]$BaselinesFile,
        [string]$PublishedFile,
        [string]$DataverseUrl,
        [string]$Token,
        [switch]$DryRun
    )

    # Load JSON
    $tasksJson     = Get-Content $TasksFile     -Raw | ConvertFrom-Json
    $baselinesJson = Get-Content $BaselinesFile -Raw | ConvertFrom-Json
    $publishedJson = Get-Content $PublishedFile -Raw | ConvertFrom-Json

    $exportProjectName = $publishedJson.NewDataSet.Project.ProjectName
    $projectStartUtc   = [DateTime]::Parse($publishedJson.NewDataSet.Project.ProjectStartDate).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    Write-LogMessage "Processing project: $exportProjectName | Start UTC: $projectStartUtc"

    # Search for project in Dataverse
    Write-LogMessage "Searching Dataverse projects for '$exportProjectName'..."
    $matches = Search-ProjectByName -BaseUrl $DataverseUrl -ProjectName $exportProjectName -Token $Token

    $projectUid = $null
    if ($matches.Count -eq 0) {
        Write-LogMessage "No matching project found." "WARN"
        $projectUid = Read-Host "Enter correct project GUID manually (or Enter to skip)"
        if (-not $projectUid) {
            Write-LogMessage "Skipping project $exportProjectName"
            return
        }
    } elseif ($matches.Count -eq 1) {
        $projectUid = $matches[0].projectid
        Write-LogMessage "Found match: $($matches[0].name) (ID: $projectUid)"
        $confirm = Read-Host "Use this project? (y/n)"
        if ($confirm -notmatch '^[yY]$') {
            Write-LogMessage "Skipping project $exportProjectName"
            return
        }
    } else {
        Write-LogMessage "Multiple matches found:"
        $i = 1
        foreach ($m in $matches) {
            Write-LogMessage "  [$i] $($m.name) (ID: $($m.projectid))"
            $i++
        }
        $sel = Read-Host "Select number (or Enter to skip)"
        if (-not $sel -or $sel -notmatch '^\d+$') {
            Write-LogMessage "Skipping project $exportProjectName"
            return
        }
        $projectUid = $matches[[int]$sel - 1].projectid
    }

    Write-LogMessage "Using project GUID: $projectUid"

    # Check existing
    $check = Get-ExistingFinancialRecords -BaseUrl $DataverseUrl -ProjectUid $projectUid -Token $Token
    if ($check.HasRecords) {
        Write-LogMessage "Found $($check.ItemCount) items and $($check.TransCount) transactions."
        $confirm = Read-Host "Proceed (will overwrite if -DryRun not used)? (y/n)"
        if ($confirm -notmatch '^[yY]$') {
            Write-LogMessage "Skipping project $exportProjectName"
            return
        }
    }

    # Build task map
    $taskIsSummary = @{}
    foreach ($t in $tasksJson.ReportingProjectTasksData.Tasks) {
        $taskIsSummary[$t.TaskUID] = ($t.TaskIsSummary -eq "true" -or $t.TaskIsSummary -eq $true)
    }

    # Calculate aggregates
    $budgetTotal = 0
    foreach ($b in $baselinesJson.ReportingProjectBaselinesData.TaskBaseline) {
        if ($b.BaselineNumber -eq "0" -and -not $taskIsSummary[$b.TaskUID]) {
            $budgetTotal += [decimal]$b.TaskBaselineCost
        }
    }

    $costTotal = 0
    $actualTotal = 0
    foreach ($t in $tasksJson.ReportingProjectTasksData.Tasks) {
        if (-not $taskIsSummary[$t.TaskUID]) {
            $costTotal += [decimal]$t.TaskCost
            $actualTotal += [decimal]$t.TaskActualCost
        }
    }

    Write-LogMessage "Calculated: Budget=$budgetTotal, Cost=$costTotal, Actual=$actualTotal"

    # Prepare items
    $items = @(
        @{ Type=955000000; Name="$exportProjectName Budget"; ItemExtId="$projectUid`_BUDGET_ITEM"; TransExtId="$projectUid`_BUDGET_TRANS"; Amount=$budgetTotal; TransType=955000000 },
        @{ Type=955000001; Name="$exportProjectName Cost";   ItemExtId="$projectUid`_COST_ITEM";   TransExtId="$projectUid`_COST_TRANS";   Amount=$costTotal;   TransType=955000001 },
        @{ Type=955000001; Name="$exportProjectName Actual"; ItemExtId="$projectUid`_ACTUAL_ITEM"; TransExtId="$projectUid`_ACTUAL_TRANS"; Amount=$actualTotal; TransType=955000001 }
    )

    $increment = 1
    foreach ($entry in $items) {
        if ($entry.Amount -eq 0) { continue }

        $itemData = @{
            sensei_name        = $entry.Name
            sensei_type        = $entry.Type
            sensei_externalid  = $entry.ItemExtId
            "sensei_project@odata.bind" = "/projects($projectUid)"
        }

        $itemId = Invoke-RecordUpsert -EntitySetName "sensei_financialitems" -Data $itemData -ExternalId $entry.ItemExtId -ProjectUid $projectUid -Token $Token -BaseUrl $DataverseUrl -DryRun:$DryRun

        $transName = "FT-{0:D4}" -f $increment++
        $transData = @{
            sensei_name                 = $transName
            sensei_type                 = $entry.TransType
            sensei_amount               = $entry.Amount
            sensei_date                 = $projectStartUtc
            sensei_externalid           = $entry.TransExtId
            "sensei_project@odata.bind"       = "/projects($projectUid)"
            "sensei_financialitem@odata.bind" = "/sensei_financialitems($itemId)"
        }

        $null = Invoke-RecordUpsert -EntitySetName "sensei_financialtransactions" -Data $transData -ExternalId $entry.TransExtId -ProjectUid $projectUid -Token $Token -BaseUrl $DataverseUrl -DryRun:$DryRun
    }

    Write-LogMessage "Finished processing project $exportProjectName"
}

# ────────────────────────────────────────────────────────────────
# Main logic
# ────────────────────────────────────────────────────────────────

Write-LogMessage "Project Financials Migration - Interactive Mode" "INFO"
if ($DryRun) { Write-LogMessage "DRY-RUN MODE: No changes will be made to Dataverse" "WARN" }

# Login (once, even for multiple projects)
$dataverseUrl = Read-Host "Enter Dataverse URL (https://yourorg.crm.dynamics.com)"
$token = Get-AccessToken-Interactive -EnvironmentUrl $dataverseUrl

# Determine mode: single or directory
$projectSets = @()

if ($Directory) {
    if (-not (Test-Path $Directory -PathType Container)) {
        Write-LogMessage "ERROR: Directory '$Directory' not found." "ERROR"
        exit 1
    }

    Write-LogMessage "Scanning directory '$Directory' for project JSON files..."

    $allJson = Get-ChildItem -Path $Directory -Filter "*.json" -File

    # Group by project name (extract from filename: Project_<name>_<suffix>.json)
    $projectGroups = @{}

    foreach ($file in $allJson) {
        if ($file.Name -match '^Project_(.*?)_(reporting_Tasks|reporting_Baselines|published)\.json$') {
            $projName = $matches[1] -replace '_', ' '  # Restore spaces if needed
            if (-not $projectGroups.ContainsKey($projName)) {
                $projectGroups[$projName] = @{}
            }
            $suffix = $matches[2]
            switch ($suffix) {
                "reporting_Tasks"     { $projectGroups[$projName]['Tasks'] = $file.FullName }
                "reporting_Baselines" { $projectGroups[$projName]['Baselines'] = $file.FullName }
                "published"           { $projectGroups[$projName]['Published'] = $file.FullName }
            }
        }
    }

    # Validate complete sets
    foreach ($proj in $projectGroups.Keys) {
        $group = $projectGroups[$proj]
        if ($group['Tasks'] -and $group['Baselines'] -and $group['Published']) {
            $projectSets += @{
                Tasks     = $group['Tasks']
                Baselines = $group['Baselines']
                Published = $group['Published']
                Name      = $proj
            }
            Write-LogMessage "Found complete set for project: $proj"
        } else {
            Write-LogMessage "Incomplete set for '$proj' — skipping." "WARN"
        }
    }

    if ($projectSets.Count -eq 0) {
        Write-LogMessage "No complete project sets found in directory." "ERROR"
        exit 1
    }
} else {
    # Single mode
    $usingAutoFiles = $false
    if ($ProjectName -and -not $TasksFile -and -not $BaselinesFile -and -not $PublishedFile) {
        $fileSafeName = $ProjectName -replace '\s+', '_'
        $TasksFile     = "Project_${fileSafeName}_reporting_Tasks.json"
        $BaselinesFile = "Project_${fileSafeName}_reporting_Baselines.json"
        $PublishedFile = "Project_${fileSafeName}_published.json"
        $usingAutoFiles = $true
        Write-LogMessage "Auto-detecting files for project: '$ProjectName'"
    }

    if (-not ($TasksFile -and $BaselinesFile -and $PublishedFile)) {
        Write-LogMessage "ERROR: Must provide -ProjectName OR all three file parameters (or use -Directory)" "ERROR"
        exit 1
    }

    # Validate single files
    $missing = @()
    if (-not (Test-Path $TasksFile))     { $missing += $TasksFile }
    if (-not (Test-Path $BaselinesFile)) { $missing += $BaselinesFile }
    if (-not (Test-Path $PublishedFile)) { $missing += $PublishedFile }

    if ($missing.Count -gt 0) {
        Write-LogMessage "ERROR: Missing file(s): $($missing -join ', ')" "ERROR"
        exit 1
    }

    $projectSets += @{
        Tasks     = $TasksFile
        Baselines = $BaselinesFile
        Published = $PublishedFile
        Name      = $ProjectName
    }
}

Write-LogMessage "Found $($projectSets.Count) project set(s) to process."

# Process each
foreach ($set in $projectSets) {
    Process-Project -TasksFile $set.Tasks -BaselinesFile $set.Baselines -PublishedFile $set.Published -DataverseUrl $dataverseUrl -Token $token -DryRun:$DryRun
}

Write-LogMessage "All processing complete." "INFO"
if ($DryRun) { Write-LogMessage "Dry-run complete — no changes were made." "INFO" }