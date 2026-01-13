<#
.SYNOPSIS
    Unit test script for validating export configuration and output structure

.DESCRIPTION
    This script performs validation tests on:
    1. Export configuration JSON structure
    2. Generated Data.xml structure against sample
    3. Field mapping completeness
    4. Data type conversions
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "..\export.config.json",
    
    [Parameter(Mandatory = $false)]
    [string]$GeneratedDataPath = ""  # Optional: path to generated Data.xml to validate
)

Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Export Configuration & Output Validation Tests" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

# Load PnP.PowerShell to make SharePoint types available for testing
Write-Host "Loading PnP.PowerShell module..." -ForegroundColor Yellow
try {
    Import-Module PnP.PowerShell -ErrorAction Stop
    Write-Host "PnP.PowerShell loaded successfully" -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Warning "Failed to load PnP.PowerShell: $($_.Exception.Message)"
    Write-Warning "Conversion tests requiring SharePoint types will fail"
    Write-Host ""
}

# Ensure consolidated Results folder under Tests exists
$ResultsDir = Join-Path $PSScriptRoot "Results"
if (-not (Test-Path $ResultsDir)) {
    New-Item -Path $ResultsDir -ItemType Directory -Force | Out-Null
}

$testResults = @{
    Passed   = 0
    Failed   = 0
    Warnings = 0
    Tests    = @()
}

function Test-Result {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = "",
        [string]$Severity = "Error"  # Error or Warning
    )
    
    $result = [PSCustomObject]@{
        Test     = $TestName
        Passed   = $Passed
        Message  = $Message
        Severity = $Severity
    }
    
    if ($Passed) {
        Write-Host "PASS: $TestName" -ForegroundColor Green
        $script:testResults.Passed++
    }
    elseif ($Severity -eq "Warning") {
        Write-Host "WARN: $TestName - $Message" -ForegroundColor Yellow
        $script:testResults.Warnings++
    }
    else {
        Write-Host "FAIL: $TestName - $Message" -ForegroundColor Red
        $script:testResults.Failed++
    }
    
    $script:testResults.Tests += $result
}

# Test 1: Configuration File Exists
Write-Host "`n--- Test 1: Configuration Validation ---" -ForegroundColor Yellow
$configExists = Test-Path $ConfigPath
Test-Result -TestName "Config file exists" -Passed $configExists -Message "File not found: $ConfigPath"

if ($configExists) {
    # Test 2: Valid JSON
    try {
        $config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
        Test-Result -TestName "Config is valid JSON" -Passed $true
    }
    catch {
        Test-Result -TestName "Config is valid JSON" -Passed $false -Message $_.Exception.Message
        exit 1
    }
    
    # Test 3: Required configuration sections
    $hasVersion = $null -ne $config.version
    Test-Result -TestName "Config has version" -Passed $hasVersion -Message "Missing 'version' property"
    
    $hasProjects = $null -ne $config.projects
    Test-Result -TestName "Config has projects section" -Passed $hasProjects -Message "Missing 'projects' property"
    
    $hasLists = $null -ne $config.lists -and $config.lists.Count -gt 0
    Test-Result -TestName "Config has lists array" -Passed $hasLists -Message "Missing or empty 'lists' array"
    
    # Test 4: Project configuration fields
    if ($hasProjects) {
        $hasProjectIdField = $null -ne $config.projects.projectIdField
        Test-Result -TestName "Projects has projectIdField" -Passed $hasProjectIdField
        
        $hasWorkspaceUrlField = $null -ne $config.projects.workspaceUrlField
        Test-Result -TestName "Projects has workspaceUrlField" -Passed $hasWorkspaceUrlField
        
        $hasProjectNameField = $null -ne $config.projects.projectNameField
        Test-Result -TestName "Projects has projectNameField" -Passed $hasProjectNameField
    }
    
    # Test 5: List configurations
    Write-Host "`n--- Test 2: List Configuration Validation ---" -ForegroundColor Yellow
    foreach ($list in $config.lists) {
        $listName = $list.spListTitle
        Write-Host "`nValidating list: $listName" -ForegroundColor Cyan
        
        $hasEntityName = $null -ne $list.entityLogicalName
        Test-Result -TestName "  [$listName] Has entityLogicalName" -Passed $hasEntityName
        
        $hasProjectLookup = $null -ne $list.projectLookupAttribute
        Test-Result -TestName "  [$listName] Has projectLookupAttribute" -Passed $hasProjectLookup
        
        $hasColumnMap = $null -ne $list.columnMap -and $list.columnMap.Count -gt 0
        Test-Result -TestName "  [$listName] Has columnMap array" -Passed $hasColumnMap
        
        if ($hasColumnMap) {
            # Test 6: Column mappings
            foreach ($col in $list.columnMap) {
                $hasSpField = $null -ne $col.spFieldInternalName
                $hasEntityAttr = $null -ne $col.entityAttribute
                $hasType = $null -ne $col.type
                
                if (-not $hasSpField -or -not $hasEntityAttr -or -not $hasType) {
                    Test-Result -TestName "  [$listName] Column mapping incomplete" -Passed $false `
                        -Message "Column missing required properties: spFieldInternalName, entityAttribute, or type"
                }
                
                # Validate choice maps for OptionSet/Status types
                if ($col.type -in @("OptionSet", "Status", "State")) {
                    $hasChoiceMapOrThresholds = ($null -ne $col.choiceMap) -or ($null -ne $col.thresholds)
                    if (-not $hasChoiceMapOrThresholds) {
                        Test-Result -TestName "  [$listName] $($col.spFieldInternalName) has choiceMap or thresholds" -Passed $false `
                            -Message "Type '$($col.type)' requires choiceMap or thresholds"
                    }
                }
                
                # Validate lookup entities
                if ($col.type -eq "Lookup") {
                    $hasLookupEntity = $null -ne $col.lookupEntity
                    if (-not $hasLookupEntity) {
                        Test-Result -TestName "  [$listName] $($col.spFieldInternalName) has lookupEntity" -Passed $false `
                            -Message "Type 'Lookup' requires lookupEntity"
                    }
                }
            }
            
            Test-Result -TestName "  [$listName] Has $($list.columnMap.Count) column mappings" -Passed $true
        }
    }
}

# Test 8: Generated data validation (if provided)
if ($GeneratedDataPath -and (Test-Path $GeneratedDataPath)) {
    Write-Host "`n--- Test 4: Generated Data Validation ---" -ForegroundColor Yellow
    
    try {
        [xml]$generatedXml = Get-Content -Path $GeneratedDataPath
        Test-Result -TestName "Generated data is valid XML" -Passed $true
        
        # Compare structure with sample
        $hasEntitiesRoot = $null -ne $generatedXml.entities
        Test-Result -TestName "Generated has entities root" -Passed $hasEntitiesRoot
        
        if ($hasEntitiesRoot) {
            $entities = $generatedXml.entities.entity
            
            foreach ($entity in $entities) {
                $entityName = $entity.name
                Write-Host "`n  Validating entity: $entityName" -ForegroundColor Cyan
                
                $hasRecords = $null -ne $entity.records -and $entity.records.record.Count -gt 0
                Test-Result -TestName "  [$entityName] Has records" -Passed $hasRecords `
                    -Message "Found $($entity.records.record.Count) records"
                
                if ($hasRecords) {
                    $firstRecord = $entity.records.record[0]
                    $hasIdAttr = $null -ne $firstRecord.id
                    Test-Result -TestName "  [$entityName] Record has id attribute" -Passed $hasIdAttr
                    
                    # Check for project lookup if configured
                    $configList = $config.lists | Where-Object { $_.entityLogicalName -eq $entityName }
                    if ($configList -and $configList.projectLookupAttribute) {
                        $projectLookup = $firstRecord.field | Where-Object { $_.name -eq $configList.projectLookupAttribute }
                        $hasProjectLookup = $null -ne $projectLookup
                        Test-Result -TestName "  [$entityName] Has project lookup field" -Passed $hasProjectLookup
                        
                        if ($hasProjectLookup) {
                            $hasLookupAttrs = ($null -ne $projectLookup.value) -and ($null -ne $projectLookup.lookupentity)
                            Test-Result -TestName "  [$entityName] Project lookup has required attributes" -Passed $hasLookupAttrs
                        }
                    }
                    
                    # Check for backlink if configured
                    if ($configList -and $configList.backlinkAttribute) {
                        $backlink = $firstRecord.field | Where-Object { $_.name -eq $configList.backlinkAttribute }
                        Test-Result -TestName "  [$entityName] Has backlink field" -Passed ($null -ne $backlink) -Severity "Warning"
                    }
                }
            }
        }
    }
    catch {
        Test-Result -TestName "Generated data is valid XML" -Passed $false -Message $_.Exception.Message
    }
}

# Test 9: Mock Data Unit Tests
Write-Host "`n--- Test 5: Mock Data Unit Tests ---" -ForegroundColor Yellow

# Load schema and build lookup
$schemaPath = "..\data_schema.xml"
if (-not (Test-Path $schemaPath)) {
    Write-Host "  Warning: Schema file not found. Skipping schema validation in tests." -ForegroundColor Yellow
    $schemaLookup = $null
}
else {
    [xml]$schemaXml = Get-Content -Path $schemaPath
    # Build schema field lookup per entity
    $schemaLookup = @{}
    foreach ($entity in $schemaXml.entities.entity) {
        $entityName = $entity.name
        $fieldNames = @()
        foreach ($field in $entity.fields.field) {
            $fieldNames += $field.name
        }
        $schemaLookup[$entityName] = $fieldNamesfieldNames
    }
}

# Load helper functions
$helpersPath = "..\CommonFunctions.ps1"
if (-not (Test-Path $helpersPath)) {
    Test-Result -TestName "Helper script found" -Passed $false -Message "Cannot find CommonFunctions.ps1"
}
else {
    Test-Result -TestName "Helper script found" -Passed $true
    
    # Dot-source the helper functions
    try {
        try {
            . $helpersPath
            Test-Result -TestName "Helper functions loaded" -Passed $trueest-Result -TestName "Helper functions loaded" -Passed $true
        }
        catch {
            Test-Result -TestName "Helper functions loaded" -Passed $false -Message $_.Exception.Message   Test-Result -TestName "Helper functions loaded" -Passed $false -Message $_.Exception.Message
        }
    
        # Initialize script-scoped logging (required by helper functions) Initialize script-scoped logging (required by helper functions)
        $script:logContent = @()$script:logContent = @()
    
        # Create mock SharePoint list item data list item data
        Write-Host "`n  Creating mock Risk item..." -ForegroundColor CyanWrite-Host "`n  Creating mock Risk item..." -ForegroundColor Cyan
        $mockRiskItem = @{
            Id          = 123
            Title       = "Test Risk - Competitive Environment"
            Description = "New entries into our marketplace are threatening our market share"into our marketplace are threatening our market share"
            "Due Date" = [DateTime]::Parse("2024-12-17")
            Status = "(1) Active"
            Category = "Resource"
            Probability = 75
            Impact = 60
            Exposure = 45
            Cost = 50000
            "Cost Exposure" = 22500
            "Mitigation Plan" = "Introduce new product models"
            "Contingency Plan" = "Retrench focus on strategic products"
            "Trigger Description" = "Market share at end of Q4"
            Trigger = "Date"
            "Assigned To" = @{ LookupId = 5; LookupValue = "John Doe" }n Doe" 
        }
        Owner = @{ LookupId = 5; LookupValue = "John Doe" }pValue = "John Doe" 
    }
    Created = [DateTime]::Parse("2024-01-15")
    Modified = [DateTime]::Parse("2024-01-20")
    "Created By" = @{ LookupId = 1; LookupValue = "System Admin" }dmin" 
        }
        "Modified By" = @{ LookupId = 5; LookupValue = "John Doe" }e" 
}
}
    
# Create mock Issue item Create mock Issue item
Write-Host "  Creating mock Issue item..." -ForegroundColor Cyan
$mockIssueItem = @{
    Id            = 456
    Title         = "Test Issue - Budget Overrun"
    Description   = "Project is exceeding budget allocation"
    "Due Date"    = [DateTime]::Parse("2024-11-30")
    Status        = "(2) Postponed"
    Category      = "Management Escalation"
    Priority      = "(1) High"
    "Assigned To" = @{ LookupId = 7; LookupValue = "Jane Smith" }
    Owner         = @{ LookupId = 7; LookupValue = "Jane Smith" }
    "Cost Impact" = 15000
    Resolution    = "Request additional funding from steering committee"
    Created       = [DateTime]::Parse("2024-02-01")
    Modified      = [DateTime]::Parse("2024-02-05")
    "Created By"  = @{ LookupId = 7; LookupValue = "Jane Smith" }
    "Modified By" = @{ LookupId = 7; LookupValue = "Jane Smith" }"Jane Smith" }
}

# Test 9a: Create Data.xml structure Test 9a: Create Data.xml structure
Write-Host "`n  Testing XML creation..." -ForegroundColor CyanWrite-Host "`n  Testing XML creation..." -ForegroundColor Cyan
try {
    $testDataXml = New-CmtDataXml
    Test-Result -TestName "  Create new CMT Data XML" -Passed $trueest-Result -TestName "  Create new CMT Data XML" -Passed $true
    
    $hasRoot = $null -ne $testDataXml.entities
    Test-Result -TestName "  XML has entities root" -Passed $hasRootTest-Result -TestName "  XML has entities root" -Passed $hasRoot
}
catch {
    Test-Result -TestName "  Create new CMT Data XML" -Passed $false -Message $_.Exception.Message   Test-Result -TestName "  Create new CMT Data XML" -Passed $false -Message $_.Exception.Message
}

# Test 9b: Convert Risk item Test 9b: Convert Risk item
Write-Host "`n  Testing Risk conversion..." -ForegroundColor CyanWrite-Host "`n  Testing Risk conversion..." -ForegroundColor Cyan
try {
    $riskListConfig = $config.lists | Where-Object { $_.spListTitle -eq "Risks" }le -eq "Risks" }
    
$riskCtx = @{
    columnMap              = @($riskListConfig.columnMap)
    backlinkAttribute      = $riskListConfig.backlinkAttribute
    projectLookupAttribute = $riskListConfig.projectLookupAttribute
    ProjectId              = "test-project-guid-123"
    ItemUrl                = "https://test.sharepoint.com/sites/TestProject/Lists/Risks/DispForm.aspx?ID=123"
}
    
$riskAttrs = Convert-SpItemToEntity -Item $mockRiskItem -Ctx $riskCtx -ProjectGuid "test-project-guid-123" `
    -ProjectSiteName "Test Project" -EntityLogicalName "sensei_risk" -SchemaFieldLookup $schemaLookup["sensei_risk"]
        
# Validate key fields
$hasName = $riskAttrs.ContainsKey("sensei_name").ContainsKey("sensei_name")
Test-Result -TestName "  Risk has sensei_name field" -Passed $hasName
    
$hasDescription = $riskAttrs.ContainsKey("sensei_description")
Test-Result -TestName "  Risk has sensei_description field" -Passed $hasDescription
    
$hasStatus = $riskAttrs.ContainsKey("statuscode")$hasStatus = $riskAttrs.ContainsKey("statuscode")
Test-Result -TestName "  Risk has statuscode field" -Passed $hasStatusd" -Passed $hasStatus
    
if ($hasStatus) {
    if ($hasStatus) {
        $statusValue = $riskAttrs["statuscode"] = $riskAttrs["statuscode"]
        $correctStatusValue = ($statusValue -eq 1)  "(1) Active" should map to 1"
Test-Result -TestName "  Risk statuscode mapped correctly" -Passed $correctStatusValue -Message "Expected 1,    z got $statusValue"
}
    
$hasCategory = $riskAttrs.ContainsKey("sensei_category")$hasCategory = $riskAttrs.ContainsKey("sensei_category")
Test-Result -TestName "  Risk has sensei_category field" -Passed $hasCategory -Passed $hasCategory
    
if ($hasCategory) {
    if ($hasCategory) {
        $categoryValue = $riskAttrs["sensei_category"] = $riskAttrs["sensei_category"]
        $correctCategoryValue = ($categoryValue -eq 955000000)  # "Resource" should map to 9550000005000000)  # "Resource" should map to 955000000
        Test-Result -TestName "  Risk category mapped correctly" -Passed $correctCategoryValue -Message "Expected 955000000, got $categoryValue"age "Expected 955000000, got $categoryValue"
    }
    
    $hasProjectLookup = $riskAttrs.ContainsKey("sensei_project")$hasProjectLookup = $riskAttrs.ContainsKey("sensei_project")
    Test-Result -TestName "  Risk has project lookup field" -Passed $hasProjectLookupsed $hasProjectLookup
    
    if ($hasProjectLookup) {
        if ($hasProjectLookup) {
            $projectLookup = $riskAttrs["sensei_project"]skAttrs["sensei_project"]
            $isHashtable = $projectLookup -is [hashtable]
            Test-Result -TestName "  Risk project lookup is hashtable" -Passed $isHashtableis hashtable" -Passed $isHashtable
        
if ($isHashtable) {
    if ($isHashtable) {
        $hasLookupValue = $projectLookup.ContainsKey("value") = $projectLookup.ContainsKey("value")
        $hasLookupEntity = $projectLookup.ContainsKey("lookupentity")entity")
        $hasLookupEntityName = $projectLookup.ContainsKey("lookupentityname")tyname")
            
    Test-Result -TestName "  Risk project lookup has value" -Passed $hasLookupValueTest-Result -TestName "  Risk project lookup has value" -Passed $hasLookupValue
    Test-Result -TestName "  Risk project lookup has lookupentity" -Passed $hasLookupEntityEntity
    Test-Result -TestName "  Risk project lookup has lookupentityname" -Passed $hasLookupEntityNametyName
}
}
    
$hasBacklink = $riskAttrs.ContainsKey("sensei_sourceitemurl")$hasBacklink = $riskAttrs.ContainsKey("sensei_sourceitemurl")
Test-Result -TestName "  Risk has backlink URL field" -Passed $hasBacklink $hasBacklink
    
# Test 9c: Add Risk to XML# Test 9c: Add Risk to XML
Write-Host "`n  Testing adding Risk to XML..." -ForegroundColor Cyanding Risk to XML..." -ForegroundColor Cyan
        $riskAttrs["_recordId"] = [System.Guid]::NewGuid().ToString()
        Add-CmtEntityRecord -Doc $testDataXml -EntityLogicalName "sensei_risk" -Attributes $riskAttrssei_risk" -Attributes $riskAttrs
    
$riskEntity = $testDataXml.entities.entity | Where-Object { $_.name -eq "sensei_risk" }$riskEntity = $testDataXml.entities.entity | Where-Object { $_.name -eq "sensei_risk" }
Test-Result -TestName "  XML contains sensei_risk entity" -Passed ($null -ne $riskEntity)y)
    
if ($riskEntity) {
    if ($riskEntity) {
        $hasRecordsNode = $null -ne $riskEntity.recordse = $null -ne $riskEntity.records
        Test-Result -TestName "  Risk entity has records node" -Passed $hasRecordsNodes node" -Passed $hasRecordsNode
        if ($hasRecordsNode) {
            $recordCount = @($riskEntity.records.record).CountriskEntity.records.record).Count
        Test-Result -TestName "  Risk entity has 1 record" -Passed ($recordCount -eq 1) -Message "Found $recordCount records" -Passed ($recordCount -eq 1) -Message "Found $recordCount records"
            
        if ($recordCount -gt 0) {
            if ($recordCount -gt 0) {
                $firstRecord = @($riskEntity.records.record)[0]kEntity.records.record)[0]
            $hasRecordId = $null -ne $firstRecord.Attributes["id"]s["id"]
            Test-Result -TestName "  Risk record has id attribute" -Passed $hasRecordId -Passed $hasRecordId
                
            $fieldCount = @($firstRecord.field).Count$fieldCount = @($firstRecord.field).Count
            Test-Result -TestName "  Risk record has fields" -Passed ($fieldCount -gt 0) -Message "Found $fieldCount fields"fields" -Passed ($fieldCount -gt 0) -Message "Found $fieldCount fields"
                
        # Check specific field format# Check specific field format
        $nameField = $firstRecord.field | Where-Object { $_.name -eq "sensei_name" }ld | Where-Object { $_.name -eq "sensei_name" }
        if ($nameField) {
            $hasNameValue = $null -ne $nameField.value = $null -ne $nameField.value
            Test-Result -TestName "  Risk name field has value attribute" -Passed $hasNameValueas value attribute" -Passed $hasNameValue
        }
                
        $projectField = $firstRecord.field | Where-Object { $_.name -eq "sensei_project" }$projectField = $firstRecord.field | Where-Object { $_.name -eq "sensei_project" }
        if ($projectField) {
            $hasLookupAttrs = ($null -ne $projectField.value) -and ($null -ne $projectField.lookupentity) -and ($null -ne $projectField.lookupentityname) = ($null -ne $projectField.value) -and ($null -ne $projectField.lookupentity) -and ($null -ne $projectField.lookupentityname)
            Test-Result -TestName "  Risk project field has lookup attributes" -Passed $hasLookupAttrs
        }
    }
}
}
}
catch { atch {
        Test-Result -TestName "  Convert and add Risk item" -Passed $false -Message $_.Exception.Messaget-Result -TestName "  Convert and add Risk item" -Passed $false -Message $_.Exception.Message
        Write-Host "    Error details: $($_.Exception)" -ForegroundColor Red
    }

    # Test 9d: Convert and add Issue item# Test 9d: Convert and add Issue item
    Write-Host "`n  Testing Issue conversion..." -ForegroundColor Cyanion..." -ForegroundColor Cyan
            try {
                $issueListConfig = $config.lists | Where-Object { $_.spListTitle -eq "Issues" }issueListConfig = $config.lists | Where-Object { $_.spListTitle -eq "Issues" }
    
                $issueCtx = @{$issueCtx = @{
                        columnMap              = @($issueListConfig.columnMap) = @($issueListConfig.columnMap)
                        backlinkAttribute      = $issueListConfig.backlinkAttributeibute
                        projectLookupAttribute = $issueListConfig.projectLookupAttributeibute
                        ProjectId              = "test-project-guid-123"
                        ItemUrl                = "https://test.sharepoint.com/sites/TestProject/Lists/Issues/DispForm.aspx?ID=456"t.com/sites/TestProject/Lists/Issues/DispForm.aspx?ID=456"
}
    
$issueAttrs = Convert-SpItemToEntity -Item $mockIssueItem -Ctx $issueCtx -ProjectGuid "test-project-guid-123" `$issueAttrs = Convert-SpItemToEntity -Item $mockIssueItem -Ctx $issueCtx -ProjectGuid "test-project-guid-123" `
    -ProjectSiteName "Test Project" -EntityLogicalName "sensei_issue" -SchemaFieldLookup $schemaLookup["sensei_issue"]
        
$hasPriority = $issueAttrs.ContainsKey("sensei_priority")
Test-Result -TestName "  Issue has sensei_priority field" -Passed $hasPriority
    
if ($hasPriority) {
    $priorityValue = $issueAttrs["sensei_priority"]
    $correctPriorityValue = ($priorityValue -eq 1)  # "(1) High" should map to 1
    Test-Result -TestName "  Issue priority mapped correctly" -Passed $correctPriorityValue -Message "Expected 1, got $priorityValue"
}
    
# Add Issue to XML
$issueAttrs["_recordId"] = [System.Guid]::NewGuid().ToString()
Add-CmtEntityRecord -Doc $testDataXml -EntityLogicalName "sensei_issue" -Attributes $issueAttrs
    
$issueEntity = $testDataXml.entities.entity | Where-Object { $_.name -eq "sensei_issue" }
Test-Result -TestName "  XML contains sensei_issue entity" -Passed ($null -ne $issueEntity)
}
catch {
    Test-Result -TestName "  Convert and add Issue item" -Passed $false -Message $_.Exception.Message
    Write-Host "    Error details: $($_.Exception)" -ForegroundColor Red
}

# Test 9e: Save and validate complete XML
Write-Host "`n  Testing XML save..." -ForegroundColor Cyan
try {
    $testOutputPath = Join-Path $ResultsDir ("test-mock-data_{ 0 }.xml" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $testDataXml.Save($testOutputPath)
    
    $fileSaved = Test-Path $testOutputPath
    Test-Result -TestName "  Save XML to file" -Passed $fileSaved -Message "Saved to $testOutputPath"
    
    if ($fileSaved) {
        # Re-load and validate
        [xml]$reloadedXml = Get-Content -Path $testOutputPath
        $reloadedValid = $null -ne $reloadedXml.entities
        Test-Result -TestName "  Reloaded XML is valid" -Passed $reloadedValid
        
        $entityCount = @($reloadedXml.entities.entity).Count
        Test-Result -TestName "  XML has 2 entity types" -Passed ($entityCount -eq 2) -Message "Found $entityCount entities"
        
        Write-Host "`n  Generated test file: $testOutputPath" -ForegroundColor Green
    }
}
catch {
    Test-Result -TestName "  Save XML to file" -Passed $false -Message $_.Exception.Message
}
}

# Summary
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""
Write-Host "Total Tests:    $($testResults.Passed + $testResults.Failed + $testResults.Warnings)" -ForegroundColor White
Write-Host "Passed:         $($testResults.Passed)" -ForegroundColor Green
Write-Host "Failed:         $($testResults.Failed)" -ForegroundColor $(if ($testResults.Failed -gt 0) { "Red" } else { "Gray" })
Write-Host "Warnings:       $($testResults.Warnings)" -ForegroundColor $(if ($testResults.Warnings -gt 0) { "Yellow" } else { "Gray" })
Write-Host ""

# Export detailed results
$resultsPath = Join-Path $ResultsDir ("test-results_ { 0 }.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$testResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $resultsPath -Encoding UTF8
Write-Host "Detailed results exported to: $resultsPath" -ForegroundColor Gray
Write-Host ""

# Exit code
if ($testResults.Failed -gt 0) {
    Write-Host "Tests FAILED" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "All tests PASSED" -ForegroundColor Green
    exit 0
}

