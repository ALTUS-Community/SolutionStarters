. $PSScriptRoot\ExtendedTableOperations.ps1
. $PSScriptRoot\Defaults.ps1

<#
.SYNOPSIS
Imports resources into Dataverse.

.DESCRIPTION
The ImportResources function handles the import of resources from JSON files into Dataverse.

.PARAMETER Mode
The type of resources to import. Valid values are 'NamedOnly' or 'NamedAndGeneric'. Default is 'NamedOnly'.

.PARAMETER ExecutionMode
Controls whether to actually execute the import or run in test mode. When $true, records are created. When $false, runs in test mode. Default is $false.

.EXAMPLE
ImportResources -Mode 'NamedOnly' -ExecutionMode $false
This example imports only named resources into Altus in test mode (no actual writes).

.EXAMPLE
ImportResources -Mode 'NamedAndGeneric' -ExecutionMode $true
This example imports named and generic resources into Altus and actually creates the records.
#>

function ImportResources {
    param(
        [Parameter(Mandatory=$false)]
        [ValidateSet('NamedOnly', 'NamedAndGeneric')]
        [string]$Mode = 'NamedOnly',
        
        [Parameter(Mandatory=$false)]
        [bool]$ExecutionMode = $false
    )
    
    $executionModeText = if ($ExecutionMode) { "Execute" } else { "What-If" }
    Write-Host "Import Resources (Mode: $Mode, ExecutionMode: $executionModeText)" -ForegroundColor Green
    
    Invoke-DataverseCommands {
        $nProjectOnlineFiles = 0
        $nProjectOnlineResources = 0
        $nProjectOnlineUniqueNamedResources = 0
        $nProjectOnlineUniqueGenericResources = 0
        $nExistingNamedBookableResourcesSkipped = 0
        $nNoMatchingSystemUsers = 0
        $nNamedBookableResourcesCreated = 0
        $nExistingGenericBookableResourcesSkipped = 0
        $nGenericBookableResourcesCreated = 0

        Write-Host "`n--------------------------------------------" -ForegroundColor Cyan
        Write-Host "Reading Bookable Resources..." -ForegroundColor Cyan
        Write-Host "--------------------------------------------" -ForegroundColor Cyan

        # Read all Bookable Resources from the Dataverse environment
        $bookableResources = Get-BookableResources
        Write-Host "Retrieved $($bookableResources.Count) Named Bookable Resources from Dataverse." 
        
        # Flatten the structure - copy domainname from nested sensei_user to top level
        foreach ($resource in $bookableResources) {
            if ($resource.sensei_user) {
                $resource | Add-Member -NotePropertyName 'domainname' -NotePropertyValue $resource.sensei_user.domainname -Force
            }
        }
#        $bookableResources | Format-Table -AutoSize | Out-String | Write-Host
        
        Write-Host "`n--------------------------------------------" -ForegroundColor Cyan
        Write-Host "Reading System Users..." -ForegroundColor Cyan
        Write-Host "--------------------------------------------" -ForegroundColor Cyan
        # Read all System Users from the Dataverse environment
        $systemUsers = Get-SystemUsers
        Write-Host "Retrieved $($systemUsers.Count) System Users from Dataverse."
        #        $systemUsers | Format-Table -AutoSize | Out-String | Write-Host
        
        Write-Host "`n--------------------------------------------" -ForegroundColor Cyan
        Write-Host "Reading Project Online Resource Data..." -ForegroundColor Cyan
        Write-Host "--------------------------------------------" -ForegroundColor Cyan
        # Read exported Project Online resource files from the Files directory
        $filesPath = Join-Path $PSScriptRoot "Files"
        $resourceFiles = Get-ChildItem -Path $filesPath -Filter "Project_*_reporting_Resources.json"
        $nProjectOnlineFiles = $resourceFiles.Count
        Write-Host "Found $($resourceFiles.Count) Project Online resource files."
        
        $allProjectResources = @()
        foreach ($file in $resourceFiles) {
            Write-Host "Reading file: $($file.Name)" -ForegroundColor Gray
            $fileContent = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            $allProjectResources += $fileContent.ReportingProjectResourcesData.Resources
        }
        Write-Host "Loaded $($allProjectResources.Count) resources from Project Online files."
        $nProjectOnlineResources = $allProjectResources.Count

        # Deduplicate Project Resources based on ResourceUID
        $allProjectResources = $allProjectResources | Sort-Object -Property ResourceUID -Unique
        #Filter to only include ResourceType = 2 (Named Resources) and 20 (Generic Resources) [will only use Generic if that mode is selected]
        $allProjectResources = $allProjectResources | Where-Object { $_.ResourceType -eq 2 -or $_.ResourceType -eq 20 }
        # Sort by ResourceName
        $allProjectResources = $allProjectResources | Sort-Object -Property ResourceName
        
        $allNamedResources = $allProjectResources | Where-Object { $null -ne $_.ResourceNTAccount -and $_.ResourceNTAccount.Trim() -ne '' -and $_.ResourceType -eq 2 }
        $allGenericResources = $allProjectResources | Where-Object { $null -eq $_.ResourceNTAccount -or $_.ResourceNTAccount.Trim() -eq '' -and $_.ResourceType -eq 20 }        

        # Extract email from ResourceNTAccount (format: 'i:0#.f|membership|email@domain.com')
        foreach ($resource in $allNamedResources) {
            $ntAccountParts = $resource.ResourceNTAccount.Split('|')
            if ($ntAccountParts.Count -ge 3) {
                $resource | Add-Member -NotePropertyName 'ExtractedEmail' -NotePropertyValue $ntAccountParts[2] -Force
            }
        }
        
        # Remove any where we couldn't extract a login
        $allNamedResources = $allNamedResources | Where-Object { $null -ne $_.ExtractedEmail -and $_.ExtractedEmail.Trim() -ne '' }
        Write-Host "After deduplication, $($allNamedResources.Count) unique Named resources remain." 
        $nProjectOnlineUniqueNamedResources = $allNamedResources.Count

        if ($Mode -eq 'NamedAndGeneric') {
            Write-Host "After deduplication, $($allGenericResources.Count) unique Generic resources remain."
            $nProjectOnlineUniqueGenericResources = $allGenericResources.Count
        }

        Write-Host "`n--------------------------------------------" -ForegroundColor Cyan
        Write-Host "Processing Named Resources..." -ForegroundColor Cyan
        Write-Host "--------------------------------------------" -ForegroundColor Cyan

        foreach ($projectResource in $allNamedResources) {
            Write-Host "`n-- Processing Resource '$($projectResource.ResourceName)' with login '$($projectResource.ExtractedEmail)'..." -ForegroundColor Cyan
            # If there is an existing matching Bookable Resource, log this and skip to the next Resource
            $matchingBookableResource = $bookableResources | Where-Object { 
                $_.domainname -and $projectResource.ExtractedEmail -and 
                $_.domainname.ToLower() -eq $projectResource.ExtractedEmail.ToLower()
            }
            if ($matchingBookableResource) {
                Write-Host "Bookable Resource '$($projectResource.ResourceName)' with login '$($projectResource.ExtractedEmail)' already exists in Dataverse. Skipping." -ForegroundColor Gray
                $nExistingNamedBookableResourcesSkipped++
                continue
            }
            
            # If there is no existing matching System User, log this and skip to the next Resource
            $matchingSystemUser = $systemUsers | Where-Object { 
                $_.domainname -and $projectResource.ExtractedEmail -and 
                $_.domainname.ToLower() -eq $projectResource.ExtractedEmail.ToLower()
            }
            if (-not $matchingSystemUser) {
                $nNoMatchingSystemUsers++
                Write-Host "No matching System User found for Resource '$($projectResource.ResourceName)' with login '$($projectResource.ExtractedEmail)'. Skipping." -ForegroundColor DarkYellow
                continue
            }
            
            $nNamedBookableResourcesCreated++
            if (-not $ExecutionMode) {
                # In What-If mode, just log the intended creation
                Write-Host "[What-If] Would create Bookable Resource for '$($projectResource.ResourceName)' with login '$($projectResource.ExtractedEmail)'" -ForegroundColor Magenta
                continue
            } else {
                # Create a new Bookable Resource in Dataverse and log the creation
                Write-Host "Creating Bookable Resource for '$($projectResource.ResourceName)' with login '$($projectResource.ExtractedEmail)'." -ForegroundColor Green

                # Create new Bookable Resource
                $newBookableResource = @{
                    'sensei_name' = $projectResource.ResourceName
                    'sensei_resourcetype' = 955000001  # Named Resource
                    'sensei_user@odata.bind' = "/systemusers($($matchingSystemUser.systemuserid))"
                    'sensei_targetutilization' = $DefaultTargetUtilisation
                    'sensei_primaryrole@odata.bind' = "/sensei_bookableresources($($DefaultPrimaryRoleId))"
                    'sensei_enterprisecalendar@odata.bind' = "/sensei_enterprisecalendars($($DefaultEnterpriseCalendarId))"
                }

                $newResource = New-Record -setName 'sensei_bookableresources' -body $newBookableResource
                Write-Host "Created Named Bookable Resource '$($projectResource.ResourceName)'." -ForegroundColor Green
            }
       }

        if ($Mode -eq 'NamedAndGeneric') {
            
            Write-Host "`n--------------------------------------------" -ForegroundColor Cyan
            Write-Host "Processing Generic Resources..." -ForegroundColor Cyan
            Write-Host "--------------------------------------------" -ForegroundColor Cyan

            foreach ($genericResource in $allGenericResources) {
                Write-Host "`n-- Processing Generic Resource '$($genericResource.ResourceName)'..." -ForegroundColor Cyan
                # If there is an existing matching Bookable Resource, log this and skip to the next Resource
                $matchingBookableResource = $bookableResources | Where-Object { 
                    $_.sensei_name -and $genericResource.ResourceName -and 
                    $_.sensei_name.ToLower() -eq $genericResource.ResourceName.ToLower()
                }
                if ($matchingBookableResource) {
                    $nExistingGenericBookableResourcesSkipped++
                    Write-Host "Generic Bookable Resource '$($genericResource.ResourceName)' already exists in Dataverse. Skipping." -ForegroundColor Gray
                    continue
                }

                $nGenericBookableResourcesCreated++
                if (-not $ExecutionMode) {
                    # In What-If mode, just log the intended creation
                    Write-Host "[What-If] Would create Generic Bookable Resource for '$($genericResource.ResourceName)'" -ForegroundColor Magenta
                    continue
                } else {
                    # Create a new Generic Bookable Resource in Dataverse and log the creation
                    Write-Host "Creating Generic Bookable Resource for '$($genericResource.ResourceName)'." -ForegroundColor Green

                    # Create new Generic Bookable Resource
                    $newBookableResource = @{
                        'sensei_name' = $genericResource.ResourceName
                        'sensei_resourcetype' = 955000000  # Generic Resource
                    }
                    $newBookableResource = New-Record -setName 'sensei_bookableresources' -body $newBookableResource
                    Write-Host "Created Generic Bookable Resource '$($genericResource.ResourceName)'." -ForegroundColor Green
                }
            }
        }

        Write-Host "`n--------------------------------------------" -ForegroundColor Cyan
        Write-Host "Import Resources Summary" -ForegroundColor Cyan
        Write-Host "--------------------------------------------" -ForegroundColor Cyan
        Write-Host "Execution Mode:                                        $executionModeText" -ForegroundColor Cyan
        Write-Host "Project Online Resource Files Processed:               $nProjectOnlineFiles" -ForegroundColor Cyan
        Write-Host "Project Online Resources Processed:                    $nProjectOnlineResources" -ForegroundColor Cyan
        Write-Host "Unique Named Resources Identified:                     $nProjectOnlineUniqueNamedResources" -ForegroundColor Cyan
        Write-Host "Existing Named Bookable Resources Skipped:             $nExistingNamedBookableResourcesSkipped" -ForegroundColor Cyan
        Write-Host "Named Bookable Resources with No Matching System User: $nNoMatchingSystemUsers" -ForegroundColor Cyan
        Write-Host "Named Bookable Resources Created:                      $nNamedBookableResourcesCreated" -ForegroundColor Cyan
        if ($Mode -eq 'NamedAndGeneric') {
            Write-Host "Unique Named Resources Identified:                     $nProjectOnlineUniqueGenericResources" -ForegroundColor Cyan
            Write-Host "Existing Generic Bookable Resources Skipped:           $nExistingGenericBookableResourcesSkipped" -ForegroundColor Cyan
            Write-Host "Generic Bookable Resources Created:                    $nGenericBookableResourcesCreated" -ForegroundColor Cyan
        }
    }

    Write-Host "Import Resources completed" -ForegroundColor Green
}

function Get-BookableResources {
    Write-Host  '--Retrieving Bookable Resources from Dataverse--'

    $bookableResources = Get-AllRecords `
        -setName 'sensei_bookableresources' `
        -query '?$select=sensei_name&$expand=sensei_user($select=domainname)&$filter=sensei_resourcetype%20eq%20955000001%20or%20sensei_resourcetype%20eq%20955000000'
    
    return $bookableResources
}

function Get-SystemUsers {
    Write-Host  '--Retrieving System Users from Dataverse--'

    $systemUsers = Get-AllRecords `
        -setName 'systemusers' `
        -query '?$select=fullname,domainname&$filter=applicationid eq null and domainname ne null'

    return $systemUsers
}
