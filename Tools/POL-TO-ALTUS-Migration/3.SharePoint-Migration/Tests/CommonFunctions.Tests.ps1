<#
.SYNOPSIS
Pester unit tests for CommonFunctions.ps1
.DESCRIPTION
Tests logging functions, schema functions, field converters (especially DateTime), CMT XML functions, and item conversion.
#>

# Setup - Load CommonFunctions.ps1
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:CommonHelpersPath = Join-Path $ProjectRoot "CommonFunctions.ps1"

if (-not (Test-Path $script:CommonHelpersPath)) {
    throw "CommonFunctions.ps1 not found at $script:CommonHelpersPath"
}

. $script:CommonHelpersPath

Describe "Logging Functions" {
    BeforeEach {
        $script:logContent = @()
    }

    It "Write-LogMessage should create log entry" {
        Write-LogMessage -Message "Test message"
        $script:logContent.Count | Should BeGreaterThan 0
        $script:logContent[0] | Should Match "Test message"
    }

    It "Write-LogWarning should prefix with [WARNING]" {
        Write-LogWarning -Message "Test warning"
        $script:logContent[0] | Should Match "\[WARNING\]"
    }

    It "Write-LogError should prefix with [ERROR]" {
        Write-LogError -Message "Test error"
        $script:logContent[0] | Should Match "\[ERROR\]"
    }

    It "Write-LogError should log exception details" {
        Write-LogError -Message "Test error" -Exception "Test exception details"
        $script:logContent[1] | Should Match "Test exception details"
    }
}

Describe "New-HashGuid" {
    It "Should generate deterministic GUID from string" {
        $guid1 = New-HashGuid -InputString "test-input"
        $guid2 = New-HashGuid -InputString "test-input"
        $guid1 | Should Be $guid2
    }

    It "Should generate different GUIDs for different inputs" {
        $guid1 = New-HashGuid -InputString "input1"
        $guid2 = New-HashGuid -InputString "input2"
        $guid1 | Should Not Be $guid2
    }
}

Describe "Schema Functions" {
    It "New-SchemaLookup should build entity field map" {
        [xml]$testSchema = @"
<?xml version="1.0" encoding="utf-8"?>
<entities>
    <entity name="sensei_risk">
        <fields>
            <field name="sensei_name" type="string"/>
            <field name="sensei_description" type="string"/>
            <field name="statuscode" type="int"/>
        </fields>
    </entity>
    <entity name="sensei_issue">
        <fields>
            <field name="sensei_name" type="string"/>
            <field name="sensei_project" type="lookup"/>
        </fields>
    </entity>
</entities>
"@
        
        $lookup = New-SchemaLookup -Schema $testSchema
        $lookup.Keys.Count | Should Be 2
        $lookup["sensei_risk"] -contains "sensei_name" | Should Be $true
        $lookup["sensei_risk"] -contains "statuscode" | Should Be $true
        $lookup["sensei_issue"] -contains "sensei_project" | Should Be $true
    }
}

Describe "CMT XML Functions" {
    It "New-CmtDataXml should create valid XML structure" {
        $xml = New-CmtDataXml
        $xml.entities -ne $null | Should Be $true
    }

    It "Get-Or-Create-EntityNode should create new entity" {
        $xml = New-CmtDataXml
        $entityNode = Get-Or-Create-EntityNode -Doc $xml -EntityLogicalName "sensei_risk"
        $entityNode.name | Should Be "sensei_risk"
        $entityNode.records -ne $null | Should Be $true
    }

    It "Get-Or-Create-EntityNode should return existing entity" {
        $xml = New-CmtDataXml
        $entity1 = Get-Or-Create-EntityNode -Doc $xml -EntityLogicalName "sensei_risk"
        $entity2 = Get-Or-Create-EntityNode -Doc $xml -EntityLogicalName "sensei_risk"
        $xml.entities.entity.Count | Should Be 1
    }

    It "Add-CmtEntityRecord should add record with fields" {
        $xml = New-CmtDataXml
        $attrs = @{
            sensei_name = "Test Risk"
            statuscode  = "1"
        }
        Add-CmtEntityRecord -Doc $xml -EntityLogicalName "sensei_risk" -Attributes $attrs
        
        $record = $xml.entities.entity.records.record
        $record | Should Not BeNullOrEmpty
        $record.id | Should Not BeNullOrEmpty
        
        $nameField = $record.field | Where-Object { $_.name -eq "sensei_name" }
        $nameField.value | Should Be "Test Risk"
    }

    It "Add-CmtEntityRecord should use provided _recordId" {
        $xml = New-CmtDataXml
        $testGuid = [System.Guid]::NewGuid().ToString()
        $attrs = @{
            _recordId   = $testGuid
            sensei_name = "Test"
        }
        Add-CmtEntityRecord -Doc $xml -EntityLogicalName "sensei_risk" -Attributes $attrs
        
        $record = $xml.entities.entity.records.record
        $record.id | Should Be $testGuid
    }
}

Describe "Field Type Handlers" {
    BeforeEach {
        $script:logContent = @()
    }

    Context "Invoke-DateTimeFieldHandler" {
        It "Should convert UTC DateTime to local and output with Z" {
            $utcDate = [DateTime]::Parse("2026-01-08T13:00:00Z").ToUniversalTime()
            $result = Invoke-DateTimeFieldHandler -Value $utcDate
            
            $result | Should Not BeNullOrEmpty
            $result | Should Match "Z$"
            $result | Should Match "2026-01-09T00:00:00"
        }

        It "Should handle local DateTime and output with Z" {
            $localDate = [DateTime]::Parse("2026-01-09T00:00:00")
            $result = Invoke-DateTimeFieldHandler -Value $localDate
            
            $result | Should Not BeNullOrEmpty
            $result | Should Match "Z$"
        }

        It "Should return null for null value" {
            $result = Invoke-DateTimeFieldHandler -Value $null
            $result | Should BeNullOrEmpty
        }
    }

    Context "Invoke-NumericFieldHandler" {
        It "Should convert number to string" {
            $result = Invoke-NumericFieldHandler -Value 12345
            $result | Should Be "12345"
        }

        It "Should apply multiplier when configured" {
            $columnConfig = [PSCustomObject]@{ multiplier = 100 }
            $result = Invoke-NumericFieldHandler -Value 5 -ColumnConfig $columnConfig
            $result | Should Be "500"
        }

        It "Should apply divider when configured" {
            $columnConfig = [PSCustomObject]@{ divider = 10 }
            $result = Invoke-NumericFieldHandler -Value 100 -ColumnConfig $columnConfig
            $result | Should Be "10"
        }

        It "Should handle decimal values" {
            $result = Invoke-NumericFieldHandler -Value 123.45
            $result | Should Be "123.45"
        }

        It "Should return null for null value" {
            $result = Invoke-NumericFieldHandler -Value $null
            $result | Should BeNullOrEmpty
        }

        It "Should return null for empty string" {
            $result = Invoke-NumericFieldHandler -Value ""
            $result | Should BeNullOrEmpty
        }
    }

    Context "Invoke-TextFieldHandler" {
        It "Should convert text" {
            $result = Invoke-TextFieldHandler -Value "Test Text"
            $result | Should Be "Test Text"
        }

        It "Should return null for null value" {
            $result = Invoke-TextFieldHandler -Value $null
            $result | Should BeNullOrEmpty
        }
    }

    Context "Invoke-OptionSetFieldHandler" {
        It "Should use choiceMap when available" {
            $columnConfig = [PSCustomObject]@{
                choiceMap = @{
                    "Active"    = 1
                    "Postponed" = 2
                    "Closed"    = 3
                }
            }
            
            $result = Invoke-OptionSetFieldHandler -Value "Active" -TargetAttribute "statuscode" -ColumnConfig $columnConfig
            $result | Should Be 1
        }

        It "Should use thresholds for numeric values" {
            $columnConfig = [PSCustomObject]@{
                thresholds = @{
                    "0"  = 955000000
                    "25" = 955000001
                    "50" = 955000002
                    "75" = 955000003
                }
            }
            
            $result = Invoke-OptionSetFieldHandler -Value 60 -TargetAttribute "sensei_probability" -ColumnConfig $columnConfig
            $result | Should Be 955000002
        }

        It "Should return default threshold for null value" {
            $columnConfig = [PSCustomObject]@{
                thresholds = @{
                    "0"  = 955000000
                    "50" = 955000001
                }
            }
            
            $result = Invoke-OptionSetFieldHandler -Value $null -TargetAttribute "sensei_probability" -ColumnConfig $columnConfig
            $result | Should Be 955000000
        }
    }

    Context "Invoke-LookupFieldHandler" {
        It "Should create project lookup structure" {
            $ctx = @{ projectLookupAttribute = "sensei_project" }
            $columnConfig = [PSCustomObject]@{ lookupEntity = "sensei_project" }
            
            $result = Invoke-LookupFieldHandler -Value $null -TargetAttribute "sensei_project" `
                -ColumnConfig $columnConfig -Ctx $ctx -ProjectGuid "test-guid-123" -ProjectName "Test Project"
            
            $result | Should BeOfType [hashtable]
            $result.value | Should Be "test-guid-123"
            $result.lookupentity | Should Be "sensei_project"
            $result.lookupentityname | Should Be "Test Project"
        }

        It "Should handle SharePoint lookup value" {
            $ctx = @{ projectLookupAttribute = "sensei_project" }
            $columnConfig = [PSCustomObject]@{ lookupEntity = "sensei_user" }
            $spLookup = [PSCustomObject]@{ LookupValue = "John Doe"; LookupId = 5 }
            
            $result = Invoke-LookupFieldHandler -Value $spLookup -TargetAttribute "sensei_owner" `
                -ColumnConfig $columnConfig -Ctx $ctx -ProjectGuid "test-guid" -ProjectName "Test"
            
            $result | Should BeOfType [hashtable]
            $result.lookupentityname | Should Be "John Doe"
        }
    }

    Context "Invoke-BooleanFieldHandler" {
        It "Should convert boolean true to string 'true'" {
            $result = Invoke-BooleanFieldHandler -Value $true -TargetAttribute "sensei_isactive" -ColumnConfig $null
            $result | Should Be "true"
        }

        It "Should convert boolean false to string 'false'" {
            $result = Invoke-BooleanFieldHandler -Value $false -TargetAttribute "sensei_isactive" -ColumnConfig $null
            $result | Should Be "false"
        }

        It "Should parse string 'True' to 'true'" {
            $result = Invoke-BooleanFieldHandler -Value "True" -TargetAttribute "sensei_isactive" -ColumnConfig $null
            $result | Should Be "true"
        }

        It "Should parse string 'false' to 'false'" {
            $result = Invoke-BooleanFieldHandler -Value "false" -TargetAttribute "sensei_isactive" -ColumnConfig $null
            $result | Should Be "false"
        }

        It "Should return null for null value" {
            $result = Invoke-BooleanFieldHandler -Value $null -TargetAttribute "sensei_isactive" -ColumnConfig $null
            $result | Should BeNullOrEmpty
        }

        It "Should return null for empty string" {
            $result = Invoke-BooleanFieldHandler -Value "" -TargetAttribute "sensei_isactive" -ColumnConfig $null
            $result | Should BeNullOrEmpty
        }
    }

    Context "Invoke-OptionSetCollectionFieldHandler" {
        It "Should map multiple values from array with choiceMap" {
            $columnConfig = [PSCustomObject]@{
                choiceMap = @{
                    "High"   = 1
                    "Medium" = 2
                    "Low"    = 3
                }
            }
            
            $result = Invoke-OptionSetCollectionFieldHandler -Value @("High", "Medium") -TargetAttribute "sensei_priorities" -ColumnConfig $columnConfig
            $result | Should Be "[1,2]"
        }

        It "Should handle pipe-delimited string" {
            $columnConfig = [PSCustomObject]@{
                choiceMap = @{
                    "Risk1" = 100
                    "Risk2" = 200
                    "Risk3" = 300
                }
            }
            
            $result = Invoke-OptionSetCollectionFieldHandler -Value "Risk1|Risk2" -TargetAttribute "sensei_categories" -ColumnConfig $columnConfig
            $result | Should Be "[100,200]"
        }

        It "Should handle semicolon-delimited string" {
            $columnConfig = [PSCustomObject]@{
                choiceMap = @{
                    "Tag1" = 10
                    "Tag2" = 20
                }
            }
            
            $result = Invoke-OptionSetCollectionFieldHandler -Value "Tag1;Tag2" -TargetAttribute "sensei_tags" -ColumnConfig $columnConfig
            $result | Should Be "[10,20]"
        }

        It "Should include sentinel values when configured" {
            $columnConfig = [PSCustomObject]@{
                choiceMap       = @{
                    "Value1" = 1
                    "Value2" = 2
                }
                includeSentinel = $true
            }
            
            $result = Invoke-OptionSetCollectionFieldHandler -Value @("Value1", "Value2") -TargetAttribute "sensei_collection" -ColumnConfig $columnConfig
            $result | Should Be "[-1,1,2,-1]"
        }

        It "Should return null for null value" {
            $columnConfig = [PSCustomObject]@{
                choiceMap = @{ "Test" = 1 }
            }
            
            $result = Invoke-OptionSetCollectionFieldHandler -Value $null -TargetAttribute "sensei_field" -ColumnConfig $columnConfig
            $result | Should BeNullOrEmpty
        }

        It "Should return null for empty string" {
            $columnConfig = [PSCustomObject]@{
                choiceMap = @{ "Test" = 1 }
            }
            
            $result = Invoke-OptionSetCollectionFieldHandler -Value "" -TargetAttribute "sensei_field" -ColumnConfig $columnConfig
            $result | Should BeNullOrEmpty
        }
    }

    Context "Invoke-StatusOrStateFieldHandler" {
        It "Should map status value using choiceMap" {
            $columnConfig = [PSCustomObject]@{
                choiceMap = @{
                    "Active"     = 1
                    "Inactive"   = 2
                    "InProgress" = 3
                }
            }
            
            $result = Invoke-StatusOrStateFieldHandler -Value "InProgress" -TargetAttribute "statuscode" -ColumnConfig $columnConfig
            $result | Should Be 3
        }

        It "Should map state value using choiceMap" {
            $columnConfig = [PSCustomObject]@{
                choiceMap = @{
                    "Open"   = 0
                    "Closed" = 1
                }
            }
            
            $result = Invoke-StatusOrStateFieldHandler -Value "Open" -TargetAttribute "statecode" -ColumnConfig $columnConfig
            $result | Should Be 0
        }

        It "Should return null for null value" {
            $columnConfig = [PSCustomObject]@{
                choiceMap = @{ "Active" = 1 }
            }
            
            $result = Invoke-StatusOrStateFieldHandler -Value $null -TargetAttribute "statuscode" -ColumnConfig $columnConfig
            $result | Should BeNullOrEmpty
        }
    }
}

Describe "Convert-SpItemToEntity" {
    BeforeEach {
        $script:logContent = @()
    }

    It "Should convert SharePoint item with multiple field types to entity attributes" {
        $mockItem = @{
            Title       = "Test Risk"
            Description = "Risk description"
            Status      = "Active"
            DueDate     = [DateTime]::Parse("2026-01-09")
            IsActive    = $true
            Priority    = "75"
            Categories  = "Category1|Category2"
            Owner       = [PSCustomObject]@{ LookupValue = "John Doe"; LookupId = 5 }
        }

        $ctx = @{
            columnMap              = @(
                [PSCustomObject]@{ spFieldInternalName = "Title"; entityAttribute = "sensei_name"; type = "Text" },
                [PSCustomObject]@{ spFieldInternalName = "Description"; entityAttribute = "sensei_description"; type = "Text" },
                [PSCustomObject]@{ spFieldInternalName = "Status"; entityAttribute = "statuscode"; type = "Status"; choiceMap = @{ "Active" = 1; "Closed" = 2 } },
                [PSCustomObject]@{ spFieldInternalName = "DueDate"; entityAttribute = "sensei_duedate"; type = "DateTime" },
                [PSCustomObject]@{ spFieldInternalName = "IsActive"; entityAttribute = "sensei_isactive"; type = "Boolean" },
                [PSCustomObject]@{ spFieldInternalName = "Priority"; entityAttribute = "sensei_priority"; type = "OptionSet"; choiceMap = @{ "25" = 1; "50" = 2; "75" = 3; "100" = 4 } },
                [PSCustomObject]@{ spFieldInternalName = "Categories"; entityAttribute = "sensei_categories"; type = "OptionSetCollection"; choiceMap = @{ "Category1" = 100; "Category2" = 200; "Category3" = 300 } },
                [PSCustomObject]@{ spFieldInternalName = "Owner"; entityAttribute = "sensei_owner"; type = "Lookup"; lookupEntity = "sensei_user" }
            )
            projectLookupAttribute = "sensei_project"
            ItemUrl                = "https://test.sharepoint.com/Lists/Risks/Item.aspx?ID=1"
        }

        $result = Convert-SpItemToEntity -Item $mockItem -Ctx $ctx -ProjectGuid "test-guid" `
            -ProjectName "Test Project" -EntityLogicalName "sensei_risk" -SchemaFieldLookup $null

        # Verify all field types
        $result["sensei_name"] | Should Be "Test Risk"
        $result["sensei_description"] | Should Be "Risk description"
        $result["statuscode"] | Should Be 1
        $result["sensei_duedate"] | Should Match "2026-01-09"
        $result["sensei_isactive"] | Should Be "true"
        $result["sensei_priority"] | Should Be 3
        $result["sensei_categories"] | Should Be "[100,200]"
        $result["sensei_owner"] | Should BeOfType [hashtable]
        $result["sensei_owner"].lookupentityname | Should Be "John Doe"
        $result["sensei_project"].value | Should Be "test-guid"
    }

    It "Should handle null and empty values gracefully" {
        $mockItem = @{
            Title       = "Test Item"
            Description = $null
            IsActive    = ""
            Categories  = ""
        }

        $ctx = @{
            columnMap              = @(
                [PSCustomObject]@{ spFieldInternalName = "Title"; entityAttribute = "sensei_name"; type = "Text" },
                [PSCustomObject]@{ spFieldInternalName = "Description"; entityAttribute = "sensei_description"; type = "Text" },
                [PSCustomObject]@{ spFieldInternalName = "IsActive"; entityAttribute = "sensei_isactive"; type = "Boolean" },
                [PSCustomObject]@{ spFieldInternalName = "Categories"; entityAttribute = "sensei_categories"; type = "OptionSetCollection"; choiceMap = @{ "Cat1" = 1 } }
            )
            projectLookupAttribute = "sensei_project"
            ItemUrl                = "https://test.sharepoint.com/Lists/Items/Item.aspx?ID=1"
        }

        $result = Convert-SpItemToEntity -Item $mockItem -Ctx $ctx -ProjectGuid "test-guid" `
            -ProjectName "Test Project" -EntityLogicalName "sensei_item" -SchemaFieldLookup $null

        $result["sensei_name"] | Should Be "Test Item"
        $result.ContainsKey("sensei_description") | Should Be $false
        $result.ContainsKey("sensei_isactive") | Should Be $false
        $result.ContainsKey("sensei_categories") | Should Be $false
    }
}

