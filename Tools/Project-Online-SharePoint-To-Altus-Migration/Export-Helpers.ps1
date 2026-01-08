<#
.SYNOPSIS
Helper functions for SharePoint to CMT export operations.
#>

# ==============================================================================
# Logging Functions
# ==============================================================================

function Write-LogMessage {
    param([string]$Message)
    $script:logContent += $Message
}

function Write-LogWarning {
    param([string]$Message)
    $script:logContent += "[WARNING] $Message"
}

function Write-LogError {
    param([string]$Message)
    $script:logContent += "[ERROR] $Message"
}

# ==============================================================================
# Schema Functions
# ==============================================================================

function New-SchemaLookup {
    <#
    .SYNOPSIS
    Builds a lookup hash of entity names to field names from CMT schema.
    #>
    param([xml]$Schema)
    $lookup = @{}
    foreach ($entity in $Schema.entities.entity) {
        $entityName = $entity.name
        $fieldNames = @()
        foreach ($field in $entity.fields.field) {
            $fieldNames += $field.name
        }
        $lookup[$entityName] = $fieldNames
    }
    return $lookup
}

# ==============================================================================
# SharePoint Functions
# ==============================================================================

function Get-ProjectWebs {
    <#
    .SYNOPSIS
    Retrieves all project webs recursively with WebTemplate info.
    #>
    Get-PnPSubWeb -Recurse -Includes "WebTemplate"
}

function Get-ProjectIdFromWeb {
    <#
    .SYNOPSIS
    Extracts ProjectId or MSPWAPROJUID from the current web's property bag.
    #>
    try {
        $props = Get-PnPPropertyBag
        $dict = @{}
        foreach ($p in $props) { 
            if ($p -and $p.Key) { $dict[$p.Key] = $p.Value } 
        }
        if ($dict.ContainsKey("MSPWAPROJUID")) { return $dict["MSPWAPROJUID"] }
    }
    catch { 
        $msg = "Error retrieving property bag for web: $($_.Exception.Message)"
        Write-Error $msg
        Write-LogError $msg
    }
    return $null
}

# ==============================================================================
# CMT XML Functions
# ==============================================================================

function New-CmtDataXml {
    <#
    .SYNOPSIS
    Creates a new, empty CMT-compliant XML document structure.
    #>
    [xml]$doc = New-Object System.Xml.XmlDocument
    $decl = $doc.CreateXmlDeclaration("1.0", "utf-8", $null)
    $doc.AppendChild($decl) | Out-Null
    $root = $doc.CreateElement("entities")
    $doc.AppendChild($root) | Out-Null
    return $doc
}

function Get-Or-Create-EntityNode {
    <#
    .SYNOPSIS
    Gets or creates an entity node in the CMT XML document.
    #>
    param([xml]$Doc, [string]$EntityLogicalName)
    $root = $Doc.SelectSingleNode("/entities")
    $entityNode = $root.SelectSingleNode("entity[@name='$EntityLogicalName']")
    if (-not $entityNode) {
        $entityNode = $Doc.CreateElement("entity")
        $entityNode.SetAttribute("name", $EntityLogicalName)
        $recordsNode = $Doc.CreateElement("records")
        $entityNode.AppendChild($recordsNode) | Out-Null
        $root.AppendChild($entityNode) | Out-Null
    }
    return $entityNode
}

function Add-CmtEntityRecord {
    <#
    .SYNOPSIS
    Adds a new record (with field attributes) to the CMT XML document.
    #>
    param(
        [xml]$Doc,
        [string]$EntityLogicalName,
        [hashtable]$Attributes
    )
    $entityNode = Get-Or-Create-EntityNode -Doc $Doc -EntityLogicalName $EntityLogicalName
    $recordsNode = $entityNode.SelectSingleNode("records")
    $recordNode = $Doc.CreateElement("record")
    
    # Handle record ID
    if ($Attributes.ContainsKey("_recordId")) {
        $idAttr = $Doc.CreateAttribute("id")
        $idAttr.Value = $Attributes["_recordId"]
        $recordNode.Attributes.Append($idAttr) | Out-Null
        $Attributes.Remove("_recordId")
    }
    else {
        $idAttr = $Doc.CreateAttribute("id")
        $idAttr.Value = [System.Guid]::NewGuid().ToString()
        $recordNode.Attributes.Append($idAttr) | Out-Null
    }
    
    # Add field elements
    foreach ($key in $Attributes.Keys) {
        $field = $Attributes[$key]
        $attrNode = $Doc.CreateElement("field")
        $attrNode.SetAttribute("name", $key)
        
        if ($field -is [hashtable] -and $field.ContainsKey("value")) {
            $attrNode.SetAttribute("value", $field.value)
            if ($field.ContainsKey("lookupentity")) { 
                $attrNode.SetAttribute("lookupentity", $field.lookupentity) 
            }
            if ($field.ContainsKey("lookupentityname")) { 
                $attrNode.SetAttribute("lookupentityname", $field.lookupentityname) 
            }
        }
        else {
            $attrNode.SetAttribute("value", [string]$field)
        }
        $recordNode.AppendChild($attrNode) | Out-Null
    }
    
    $recordsNode.AppendChild($recordNode) | Out-Null
    # Rebind XML to ensure attributes are accessible in tests
    $Doc.LoadXml($Doc.OuterXml)
}

# ==============================================================================
# Field Type Handlers
# ==============================================================================

function Invoke-LookupFieldHandler {
    <#
    .SYNOPSIS
    Handles Lookup field type conversion.
    #>
    param(
        $Value,
        [string]$TargetAttribute,
        $ColumnConfig,
        [hashtable]$Ctx,
        [string]$ProjectGuid,
        [string]$ProjectName
    )
    
    if ($TargetAttribute -eq $Ctx.projectLookupAttribute) {
        return @{
            value            = $ProjectGuid
            lookupentity     = $ColumnConfig.lookupEntity
            lookupentityname = $ProjectName
        }
    }
    elseif ($null -ne $Value) {
        return @{
            value            = [System.Guid]::Empty.ToString()
            lookupentity     = $ColumnConfig.lookupEntity
            lookupentityname = $Value.LookupValue
        }
    }
    return $null
}

function Invoke-OptionSetFieldHandler {
    <#
    .SYNOPSIS
    Handles OptionSet field type conversion with threshold and choiceMap support.
    #>
    param(
        $Value,
        [string]$TargetAttribute,
        $ColumnConfig
    )
    
    $handled = $false
    $defaultThresholdValue = $null

    # Try thresholds first
    if ($ColumnConfig.PSObject.Properties.Name -contains "thresholds") {
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $thresholdPairs = @()
        
        # Parse threshold keys into numeric pairs
        if ($ColumnConfig.thresholds -is [hashtable]) {
            foreach ($k in $ColumnConfig.thresholds.Keys) {
                $thresholdValue = $null
                if ([double]::TryParse($k.ToString(), [System.Globalization.NumberStyles]::Float, $culture, [ref]$thresholdValue)) {
                    $thresholdPairs += [pscustomobject]@{ Threshold = $thresholdValue; Value = $ColumnConfig.thresholds[$k] }
                }
                else {
                    Write-LogWarning "Threshold key '$k' for field '$TargetAttribute' is not numeric."
                }
            }
        }
        else {
            foreach ($p in $ColumnConfig.thresholds.PSObject.Properties) {
                $thresholdValue = $null
                if ([double]::TryParse($p.Name, [System.Globalization.NumberStyles]::Float, $culture, [ref]$thresholdValue)) {
                    $thresholdPairs += [pscustomobject]@{ Threshold = $thresholdValue; Value = $p.Value }
                }
                else {
                    Write-LogWarning "Threshold key '$($p.Name)' for field '$TargetAttribute' is not numeric."
                }
            }
        }

        $thresholdPairs = $thresholdPairs | Sort-Object Threshold
        if ($thresholdPairs.Count -gt 0) {
            $defaultThresholdValue = $thresholdPairs[0].Value

            # Handle missing/blank values
            if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
                return $defaultThresholdValue
            }

            # Try to parse numeric value
            $parsed = $null
            if ([double]::TryParse($Value.ToString(), [System.Globalization.NumberStyles]::Float, $culture, [ref]$parsed)) {
                $match = $thresholdPairs | Where-Object { $parsed -ge $_.Threshold } | Select-Object -Last 1
                if (-not $match) { $match = $thresholdPairs[0] }
                return $match.Value
            }
            else {
                Write-LogWarning "Cannot parse numeric value '$Value' for field '$TargetAttribute' with thresholds. Using default."
                return $defaultThresholdValue
            }
        }
        else {
            Write-LogWarning "No usable thresholds configured for field '$TargetAttribute'."
        }
    }

    # Fall back to choiceMap
    if ($ColumnConfig.PSObject.Properties.Name -contains "choiceMap") {
        if ($ColumnConfig.choiceMap -is [hashtable]) {
            if ($ColumnConfig.choiceMap.ContainsKey($Value)) { 
                return $ColumnConfig.choiceMap[$Value]
            }
            else {
                Write-LogWarning "ChoiceMap for field '$TargetAttribute' missing value '$Value'. Available: $($ColumnConfig.choiceMap.Keys -join ', ')"
            }
        }
        else {
            $mapProps = $ColumnConfig.choiceMap.PSObject.Properties.Name
            if ($mapProps -contains $Value) { 
                return $ColumnConfig.choiceMap.$Value
            }
            else {
                Write-LogWarning "ChoiceMap for field '$TargetAttribute' missing value '$Value'. Available: $($mapProps -join ', ')"
            }
        }
    }
    
    return $null
}

function Invoke-StatusOrStateFieldHandler {
    <#
    .SYNOPSIS
    Handles Status and State field type conversion via choiceMap.
    #>
    param(
        $Value,
        [string]$TargetAttribute,
        $ColumnConfig
    )
    
    if ($null -eq $Value) { return $null }
    
    if ($ColumnConfig.choiceMap -is [hashtable]) {
        if ($ColumnConfig.choiceMap.ContainsKey($Value)) { 
            return $ColumnConfig.choiceMap[$Value]
        }
        else {
            Write-LogWarning "ChoiceMap for field '$TargetAttribute' missing value '$Value'. Available: $($ColumnConfig.choiceMap.Keys -join ', ')"
        }
    }
    else {
        $mapProps = $ColumnConfig.choiceMap.PSObject.Properties.Name
        if ($mapProps -contains $Value) { 
            return $ColumnConfig.choiceMap.$Value
        }
        else {
            Write-LogWarning "ChoiceMap for field '$TargetAttribute' missing value '$Value'. Available: $($mapProps -join ', ')"
        }
    }
    
    return $null
}

function Invoke-DateTimeFieldHandler {
    <#
    .SYNOPSIS
    Handles DateTime field type conversion to ISO 8601 format.
    #>
    param($Value)
    
    if ($Value) { 
        return ([datetime]$Value).ToString("o") 
    }
    return $null
}

function Invoke-NumericFieldHandler {
    <#
    .SYNOPSIS
    Handles Money and Number field type conversion to string.
    #>
    param($Value)
    
    if ($Value) { 
        return [string]$Value 
    }
    return $null
}

function Invoke-TextFieldHandler {
    <#
    .SYNOPSIS
    Handles Text field type conversion.
    #>
    param($Value)
    
    if ($Value) { 
        return [string]$Value 
    }
    return $null
}

# ==============================================================================
# Item Conversion
# ==============================================================================

function Convert-SpItemToEntity {
    <#
    .SYNOPSIS
    Converts a SharePoint list item to Dynamics entity attributes using column mapping.
    #>
    param(
        $Item,
        [hashtable]$Ctx,
        [string]$ProjectGuid,
        [string]$ProjectName,
        [string]$EntityLogicalName,
        $SchemaFieldLookup
    )
    $attributes = @{}

    foreach ($c in $Ctx.columnMap) {
        $spName = $c.spFieldInternalName
        $target = $c.entityAttribute
        $type = $c.type
        $val = $Item[$spName]        

        # Validate field exists in schema
        if ($null -ne $SchemaFieldLookup -and $SchemaFieldLookup -notcontains $target) {
            Write-LogWarning "Field '$target' (from SP column '$spName') not found in schema for entity '$EntityLogicalName'. Skipping."
            continue
        }

        $convertedValue = $null

        # Route to appropriate handler
        switch ($type) {
            "Lookup" {
                $convertedValue = Invoke-LookupFieldHandler -Value $val -TargetAttribute $target `
                    -ColumnConfig $c -Ctx $Ctx -ProjectGuid $ProjectGuid -ProjectName $ProjectName
            }
            "OptionSet" {
                $convertedValue = Invoke-OptionSetFieldHandler -Value $val -TargetAttribute $target -ColumnConfig $c
            }
            "Status" {
                $convertedValue = Invoke-StatusOrStateFieldHandler -Value $val -TargetAttribute $target -ColumnConfig $c
            }
            "State" {
                $convertedValue = Invoke-StatusOrStateFieldHandler -Value $val -TargetAttribute $target -ColumnConfig $c
            }
            "DateTime" {
                $convertedValue = Invoke-DateTimeFieldHandler -Value $val
            }
            { $_ -eq "Money" -or $_ -eq "Number" } {
                $convertedValue = Invoke-NumericFieldHandler -Value $val
            }
            default {
                $convertedValue = Invoke-TextFieldHandler -Value $val
            }
        }

        if ($null -ne $convertedValue) {
            $attributes[$target] = $convertedValue
        }
    }

    # Add backlink URL
    if ($Ctx.backlinkAttribute -and $Ctx.ItemUrl) {
        $attributes[$Ctx.backlinkAttribute] = $Ctx.ItemUrl
    }

    # Ensure project lookup is set
    if ($Ctx.projectLookupAttribute -and $ProjectGuid) {
        $attributes[$Ctx.projectLookupAttribute] = @{
            value            = $ProjectGuid
            lookupentity     = "sensei_project"
            lookupentityname = $ProjectName
        }
    }

    return $attributes
}
