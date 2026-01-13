<#
.SYNOPSIS
Combined helper functions for SharePoint to CMT export/import operations.
.DESCRIPTION
Includes logging, project mapping, prerequisite checks, schema helpers, SharePoint helpers, CMT XML builders, field converters, and item conversion utilities.
#>

# Prevent re-definition when sourced multiple times
if ($script:CommonHelpersLoaded) { return }
$script:CommonHelpersLoaded = $true

# ==============================================================================
# LOGGING FUNCTIONS
# ==============================================================================

function Write-LogMessage {
    param(
        [string]$Message,
        [string]$ForegroundColor = "Gray"
    )

    if (-not $script:logContent) { $script:logContent = @() }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    $script:logContent += $logEntry
    Write-Host $Message -ForegroundColor $ForegroundColor
}

function Write-LogWarning {
    param(
        [string]$Message,
        [string]$ForegroundColor = "Yellow"
    )

    if (-not $script:logContent) { $script:logContent = @() }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [WARNING] $Message"
    $script:logContent += $logEntry
    Write-Host "[WARNING] $Message" -ForegroundColor $ForegroundColor
}

function Write-LogError {
    param(
        [string]$Message,
        [string]$Exception = "",
        [string]$ForegroundColor = "Red"
    )

    if (-not $script:logContent) { $script:logContent = @() }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [ERROR] $Message"
    $script:logContent += $logEntry
    Write-Host "[ERROR] $Message" -ForegroundColor $ForegroundColor

    if ($Exception) {
        $script:logContent += "  Exception: $Exception"
        Write-Host "  Exception: $Exception" -ForegroundColor $ForegroundColor
    }
}

# ==============================================================================
# PROJECT MAP / PREREQS / GUID
# ==============================================================================

function Build-ProjectMap {
    param([string]$ExportPath)

    $map = @{}

    if (-not (Test-Path $ExportPath)) {
        Write-LogMessage "POL export path not found: $ExportPath"
        return $map
    }

    $jsonFiles = Get-ChildItem -Path $ExportPath -Filter "*_reporting.json" -Recurse

    foreach ($file in $jsonFiles) {
        try {
            $json = Get-Content -Path $file.FullName -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $project = $json.ReportingProjectData.Project

            if ($project) {
                $projectName = $project.ProjectName
                $projectUID = $project.ProjectUID
                $hrefUrl = $project.ProjectWorkspaceInternalHRef

                if ($hrefUrl -and $projectName) {
                    $urlParts = $hrefUrl -split '/'
                    $projectWebName = [uri]::UnescapeDataString($urlParts[-1])

                    $map[$projectWebName] = @{
                        Name = $projectName
                        UID  = $projectUID
                    }
                    Write-Verbose "Mapped POL project '$projectName' (URL: $projectWebName, UID: $projectUID)"
                }
            }
        }
        catch {
            Write-LogMessage "Failed to parse JSON file '$($file.Name)': $($_.Exception.Message)"
        }
    }

    Write-LogMessage "Loaded $($map.Count) projects from POL export"
    return $map
}

function Test-PnPModule {
    if (-not (Get-Module -ListAvailable -Name "PnP.PowerShell")) {
        Write-Host "PnP.PowerShell module not found. Installing..." -ForegroundColor Yellow
        try {
            Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Host "PnP.PowerShell module installed successfully" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to install PnP.PowerShell module: $($_.Exception.Message)"
            Write-Host "Please run manually: Install-Module PnP.PowerShell -Scope CurrentUser" -ForegroundColor Yellow
            exit 1
        }
    }
    else {
        Write-Host "PnP.PowerShell module is installed" -ForegroundColor Green
    }
}

function New-HashGuid {
    param([Parameter(Mandatory)][string]$InputString)

    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hash = $md5.ComputeHash($bytes)
    $md5.Dispose()

    return [Guid]::new($hash)
}

# ==============================================================================
# SCHEMA FUNCTIONS
# ==============================================================================

function New-SchemaLookup {
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
# SHAREPOINT FUNCTIONS
# ==============================================================================

function Get-ProjectWebs {
    Get-PnPSubWeb -Recurse -Includes "WebTemplate"
}

function Get-ProjectIdFromWeb {
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
# CMT XML FUNCTIONS
# ==============================================================================

function New-CmtDataXml {
    [xml]$doc = New-Object System.Xml.XmlDocument
    $decl = $doc.CreateXmlDeclaration("1.0", "utf-8", $null)
    $doc.AppendChild($decl) | Out-Null
    $root = $doc.CreateElement("entities")
    $doc.AppendChild($root) | Out-Null
    return $doc
}

function Get-Or-Create-EntityNode {
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
    param(
        [xml]$Doc,
        [string]$EntityLogicalName,
        [hashtable]$Attributes
    )
    $entityNode = Get-Or-Create-EntityNode -Doc $Doc -EntityLogicalName $EntityLogicalName
    $recordsNode = $entityNode.SelectSingleNode("records")
    $recordNode = $Doc.CreateElement("record")

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

    foreach ($key in $Attributes.Keys) {
        $field = $Attributes[$key]
        $attrNode = $Doc.CreateElement("field")
        $attrNode.SetAttribute("name", $key)

        if ($field -is [hashtable] -and $field.ContainsKey("value")) {
            $attrNode.SetAttribute("value", $field.value)
            if ($field.ContainsKey("lookupentity")) { $attrNode.SetAttribute("lookupentity", $field.lookupentity) }
            if ($field.ContainsKey("lookupentityname")) { $attrNode.SetAttribute("lookupentityname", $field.lookupentityname) }
        }
        else {
            $attrNode.SetAttribute("value", [string]$field)
        }
        $recordNode.AppendChild($attrNode) | Out-Null
    }

    $recordsNode.AppendChild($recordNode) | Out-Null
    $Doc.LoadXml($Doc.OuterXml)
}

# ==============================================================================
# FIELD TYPE HANDLERS
# ==============================================================================

function Invoke-LookupFieldHandler {
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

function Invoke-BooleanFieldHandler {
    param(
        $Value,
        [string]$TargetAttribute,
        $ColumnConfig
    )
    
    if ($null -eq $Value -or $Value -eq "") { return $null }

    # Convert boolean or string representation to boolean
    $boolValue = $false
    if ($Value -is [bool]) {
        $boolValue = $Value
    }
    else {
        if ([bool]::TryParse($Value.ToString(), [ref]$boolValue)) {
            # Successfully parsed
        }
        else {
            Write-LogWarning "Cannot parse boolean value '$Value' for field '$TargetAttribute'."
            return $null
        }
    }

    # Return as lowercase string "true" or "false" for XML serialization
    if ($boolValue) {
        return "true"
    }
    else {
        return "false"
    }
}

function Invoke-OptionSetCollectionFieldHandler {
    param(
        $Value,
        [string]$TargetAttribute,
        $ColumnConfig
    )

    if ($null -eq $Value -or $Value -eq "") { return $null }

    # Handle array or pipe-delimited string
    $values = $null
    if ($Value -is [array]) {
        $values = $Value
    }
    else {
        # Split on pipe or semicolon (common delimiters for multi-value fields)
        $values = @($Value -split '[;|]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    if ($values.Count -eq 0) { return $null }

    $mappedValues = @()
    foreach ($v in $values) {
        if ($ColumnConfig.choiceMap -is [hashtable]) {
            if ($ColumnConfig.choiceMap.ContainsKey($v)) {
                $mappedValues += $ColumnConfig.choiceMap[$v]
            }
            else {
                Write-LogWarning "ChoiceMap for field '$TargetAttribute' missing value '$v'. Available: $($ColumnConfig.choiceMap.Keys -join ', ')"
            }
        }
        else {
            $mapProps = $ColumnConfig.choiceMap.PSObject.Properties.Name
            if ($mapProps -contains $v) {
                $mappedValues += $ColumnConfig.choiceMap.$v
            }
            else {
                Write-LogWarning "ChoiceMap for field '$TargetAttribute' missing value '$v'. Available: $($mapProps -join ', ')"
            }
        }
    }

    if ($mappedValues.Count -gt 0) {
        $outValues = $mappedValues
        if ($ColumnConfig.includeSentinel) { $outValues = @(-1) + $outValues + @(-1) }
        return "[" + ($outValues -join ",") + "]"
    }

    return $null
}

function Invoke-OptionSetFieldHandler {
    param(
        $Value,
        [string]$TargetAttribute,
        $ColumnConfig
    )

    $defaultThresholdValue = $null

    if ($ColumnConfig.PSObject.Properties.Name -contains "thresholds") {
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $thresholdPairs = @()

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

            if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
                return $defaultThresholdValue
            }

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

    if ($ColumnConfig.PSObject.Properties.Name -contains "choiceMap") {
        if ($ColumnConfig.choiceMap -is [hashtable]) {
            if ($ColumnConfig.choiceMap.ContainsKey($Value)) { return $ColumnConfig.choiceMap[$Value] }
            else { Write-LogWarning "ChoiceMap for field '$TargetAttribute' missing value '$Value'. Available: $($ColumnConfig.choiceMap.Keys -join ', ')" }
        }
        else {
            $mapProps = $ColumnConfig.choiceMap.PSObject.Properties.Name
            if ($mapProps -contains $Value) { return $ColumnConfig.choiceMap.$Value }
            else { Write-LogWarning "ChoiceMap for field '$TargetAttribute' missing value '$Value'. Available: $($mapProps -join ', ')" }
        }
    }

    return $null
}

function Invoke-StatusOrStateFieldHandler {
    param(
        $Value,
        [string]$TargetAttribute,
        $ColumnConfig
    )

    if ($null -eq $Value) { return $null }

    if ($ColumnConfig.choiceMap -is [hashtable]) {
        if ($ColumnConfig.choiceMap.ContainsKey($Value)) { return $ColumnConfig.choiceMap[$Value] }
        else { Write-LogWarning "ChoiceMap for field '$TargetAttribute' missing value '$Value'. Available: $($ColumnConfig.choiceMap.Keys -join ', ')" }
    }
    else {
        $mapProps = $ColumnConfig.choiceMap.PSObject.Properties.Name
        if ($mapProps -contains $Value) { return $ColumnConfig.choiceMap.$Value }
        else { Write-LogWarning "ChoiceMap for field '$TargetAttribute' missing value '$Value'. Available: $($mapProps -join ', ')" }
    }

    return $null
}

function Invoke-DateTimeFieldHandler {
    param($Value)

    if ($Value) {
        $dt = $Value
        if (-not ($dt -is [datetime])) { $dt = [datetime]$Value }
        if ($dt.Kind -eq [System.DateTimeKind]::Utc) { $dt = $dt.ToLocalTime() }
        $dtUtc = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
        return $dtUtc.ToString("o")
    }
    return $null
}

function Invoke-NumericFieldHandler {
    param(
        $Value,
        $ColumnConfig
    )
    if ($null -eq $Value -or $Value -eq "") { return $null }
    
    $numValue = [double]$Value
    
    # Apply multiplier if specified
    if ($ColumnConfig -and $ColumnConfig.multiplier) {
        $numValue = $numValue * [double]$ColumnConfig.multiplier
    }
    
    # Apply divider if specified
    if ($ColumnConfig -and $ColumnConfig.divider) {
        if ([double]$ColumnConfig.divider -ne 0) {
            $numValue = $numValue / [double]$ColumnConfig.divider
        }
    }
    
    return [string]$numValue
}

function Invoke-TextFieldHandler {
    param($Value)
    if ($Value) { return [string]$Value }
    return $null
}

# ==============================================================================
# ITEM CONVERSION
# ==============================================================================

function Convert-SpItemToEntity {
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

        if ($null -ne $SchemaFieldLookup -and $SchemaFieldLookup -notcontains $target) {
            Write-LogWarning "Field '$target' (from SP column '$spName') not found in schema for entity '$EntityLogicalName'. Skipping."
            continue
        }

        $convertedValue = $null

        switch ($type) {
            "Lookup" {
                $convertedValue = Invoke-LookupFieldHandler -Value $val -TargetAttribute $target `
                    -ColumnConfig $c -Ctx $Ctx -ProjectGuid $ProjectGuid -ProjectName $ProjectName
            }
            "Boolean" {
                $convertedValue = Invoke-BooleanFieldHandler -Value $val -TargetAttribute $target -ColumnConfig $c
            }
            "OptionSet" {
                $convertedValue = Invoke-OptionSetFieldHandler -Value $val -TargetAttribute $target -ColumnConfig $c
            }
            "OptionSetCollection" {
                $convertedValue = Invoke-OptionSetCollectionFieldHandler -Value $val -TargetAttribute $target -ColumnConfig $c
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
                $convertedValue = Invoke-NumericFieldHandler -Value $val -ColumnConfig $c
            }
            default {
                $convertedValue = Invoke-TextFieldHandler -Value $val
            }
        }

        if ($null -ne $convertedValue) {
            $attributes[$target] = $convertedValue
        }
    }

    if ($Ctx.BacklinkFieldName -and $Ctx.ItemUrl) {
        if ($null -ne $SchemaFieldLookup -and $SchemaFieldLookup -contains $Ctx.BacklinkFieldName) {
            $attributes[$Ctx.BacklinkFieldName] = $Ctx.ItemUrl
        }
        elseif ($null -eq $SchemaFieldLookup) {
            $attributes[$Ctx.BacklinkFieldName] = $Ctx.ItemUrl
        }
    }
    elseif ($Ctx.backlinkAttribute -and $Ctx.ItemUrl) {
        $attributes[$Ctx.backlinkAttribute] = $Ctx.ItemUrl
    }

    if ($Ctx.projectLookupAttribute -and $ProjectGuid) {
        $attributes[$Ctx.projectLookupAttribute] = @{
            value            = $ProjectGuid
            lookupentity     = "sensei_project"
            lookupentityname = $ProjectName
        }
    }

    return $attributes
}
