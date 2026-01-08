. $PSScriptRoot\Defaults.ps1

# Load Windows Forms for DoEvents support in COM automation
Add-Type -AssemblyName System.Windows.Forms

# ------------------------------
# USER CONFIGURATION (EDIT HERE)
# ------------------------------

function Get-ReportingCustomFieldTextValue {
    param(
        [Parameter(Mandatory = $false)]
        $ReportingProject,

        [Parameter(Mandatory = $true)]
        [string]$CustomFieldName
    )

    if (-not $ReportingProject) { return $null }
    if (-not ($ReportingProject.PSObject.Properties.Name -contains 'CustomFields')) { return $null }
    if (-not $ReportingProject.CustomFields) { return $null }

    $cf = $ReportingProject.CustomFields | Where-Object { $_.CustomFieldName -eq $CustomFieldName } | Select-Object -First 1
    if (-not $cf) { return $null }
    if (-not ($cf.PSObject.Properties.Name -contains 'CFValue')) { return $null }
    if (-not $cf.CFValue) { return $null }

    return $cf.CFValue.'#text'
}

function Add-ProjectDataverseFieldMappings {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Project,

        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$ProjectGuid,

        [Parameter(Mandatory = $false)]
        $ReportingProject
    )

    # Add Project -> Dataverse column mappings here.
    # Use Dataverse logical column names (lowercase). Columns must already exist.

    # --- OOTB fields (from $ReportingProject or $ProjectName) ---
    # $Project['cr_project_text_ootb'] = $ProjectName
    # $Project['cr_project_date_ootb'] = ($ReportingProject.ProjectStartDate -as [datetime])
    # $Project['cr_project_whole_ootb'] = ($ReportingProject.ProjectIdentifier -as [int])
    # $Project['cr_project_decimal_ootb'] = ($ReportingProject.ProjectCalendarDuration -as [decimal])

    # --- Enterprise Custom Fields (from $ReportingProject.CustomFields[]) ---
    # $textValue = Get-ReportingCustomFieldTextValue -ReportingProject $ReportingProject -CustomFieldName 'Your Text Field'
    # if ($textValue) { $Project['cr_project_text_custom'] = [string]$textValue }
    #
    # $dateValue = Get-ReportingCustomFieldTextValue -ReportingProject $ReportingProject -CustomFieldName 'Your Date Field'
    # if ($dateValue) { $Project['cr_project_date_custom'] = ($dateValue -as [datetime]) }
}

function New-ProjectDataverseBody {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$ProjectGuid,

        [Parameter(Mandatory = $true)]
        [string]$DefaultProjectTypeId,

        [Parameter(Mandatory = $false)]
        $ReportingProject
    )

    $project = @{
        'sensei_name' = $ProjectName
        'sensei_projecttype@odata.bind' = "/sensei_enterpriseprojecttypes($DefaultProjectTypeId)"
        'sensei_externalprojectid' = "ProjectDesktop_$ProjectGuid"
    }

    Add-ProjectDataverseFieldMappings -Project $project -ProjectName $ProjectName -ProjectGuid $ProjectGuid -ReportingProject $ReportingProject
    return $project
}

function Get-ProjectDataverseUpdateBody {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$ProjectGuid,

        [Parameter(Mandatory = $false)]
        $ReportingProject
    )

    $updateBody = @{}

    # Optional: if you want to PATCH fields onto existing/orphaned project records, add the same mappings here.
    # Example:
    # $textValue = Get-ReportingCustomFieldTextValue -ReportingProject $ReportingProject -CustomFieldName 'Your Text Field'
    # if ($textValue) { $updateBody['cr_project_text_custom'] = [string]$textValue }

    return $updateBody
}

# ====== Don't edit below this line ======

<#
.SYNOPSIS
Imports projects into Dataverse.

.DESCRIPTION
The ImportProjects function handles the import of projects from JSON files into Dataverse.

.PARAMETER ExecutionMode
Controls whether to actually execute the import or run in test mode. When $true, records are created. When $false, runs in test mode. Default is $false.

.EXAMPLE
ImportProjects -ExecutionMode $true
This example imports projects into Dataverse, creating records.
#>

function ImportProjects {
    param(
        [Parameter(Mandatory=$false)]
        [bool]$ExecutionMode = $false
    )

    $executionModeText = if ($ExecutionMode) { "Execute" } else { "What-If" }
    Write-Host "Import Projects (ExecutionMode: $executionModeText)" -ForegroundColor Green    
    
    Invoke-DataverseCommands {
        $nMPPsProcessed = 0
        $nExistingProjectsSkipped = 0
        $nProjectsCreated = 0
        $nExternalProjectsCreated = 0
        $nMPPsUpdated = 0
        $nMPPsNotRequiringUpdate = 0
        $nErrored = 0

        # Read all Projects from Altus with a sensei_externalprojectid set
        $projectsWithExternalId = Get-ProjectsWithExternalId
        Write-Host "Retrieved $($projectsWithExternalId.Count) Projects with External IDs from Dataverse."

        $projectDesktopProjects = $projectsWithExternalId | Where-Object {
            $null -ne $_.sensei_externalproject_project_sensei_pro -and 
            $_.sensei_externalproject_project_sensei_pro.Count -gt 0 -and 
            $_.sensei_externalproject_project_sensei_pro._sensei_externalsystem_value -eq $ProjectDesktopExternalSystemId
        }

        $projectsWithExternalIdButNoExternalProjectReference = $projectsWithExternalId | Where-Object {
            $null -eq $_.sensei_externalproject_project_sensei_pro -or
            $_.sensei_externalproject_project_sensei_pro.Count -eq 0
        }

        Write-Host "Retrieved $($projectDesktopProjects.Count) Project Desktop Projects from Dataverse."
        Write-Host "Retrieved $($projectsWithExternalIdButNoExternalProjectReference.Count) Projects with External IDs but no External Project reference from Dataverse."
        
        #Read Solution version from Altus
        $solutionVersion = Get-SolutionVersion
        if ($solutionVersion) {
            Write-Host "Altus Solution Version: $solutionVersion"
        } else {
            Write-Host "Altus Solution: Not found" -ForegroundColor Red
            return
        }

        #Read Organization info from environment
        $orgName = Get-OrgName
        if ($orgName) {
            Write-Host "Organization Name: $orgName"
        } else {
            Write-Host "Organization Name: Not found" -ForegroundColor Red
            return
        }

        #Get EnvironmentId for this environment (optional)
        $envId = Get-EnvironmentId
        if ($envId) {
            Write-Host "Environment ID: $envId"
        }
        else {
            Write-Host "Environment ID: Not found" -ForegroundColor Red
            return
        }

        $filesPath = Join-Path $PSScriptRoot "Files"
        $mppsInFolder = Get-ChildItem -Path $filesPath -Filter "Project_*_published.mpp"

        if ($mppsInFolder.Count -eq 0) {
            Write-Host "No MPP files found in 'Files' folder. Please ensure the files are present." -ForegroundColor Red
            return
        }

        Write-Host "`n--------------------------------------------" -ForegroundColor Cyan
        Write-Host "Processing Projects..." -ForegroundColor Cyan
        Write-Host "--------------------------------------------" -ForegroundColor Cyan

        foreach ($mpp in $mppsInFolder) {
            $nMPPsProcessed++
            Write-Host "`n-- Processing MPP file: $($mpp.Name)..." -ForegroundColor Cyan
            
            try {
                # Read the corresponding JSON file with the same name
                $jsonFileName = [System.IO.Path]::GetFileNameWithoutExtension($mpp.Name) + ".json"
                $jsonFilePath = Join-Path $filesPath $jsonFileName
                
                if (Test-Path $jsonFilePath) {
                    Write-Host "Reading JSON file: $jsonFileName" -ForegroundColor Gray
                    $projectData = Get-Content -Path $jsonFilePath -Raw | ConvertFrom-Json
                    $projectGuid = $projectData.NewDataSet.Project.ProjectUId
                    $projectName = $projectData.NewDataSet.Project.ProjectName
                    Write-Host "Project: $projectName ($projectGuid)" -ForegroundColor Gray

                    # --- Load Additional Metadata (Required for Custom Field Mapping) ---
                    # The _published.json has limited metadata. The _reporting.json contains project-level
                    # reporting fields (including custom fields) useful for mapping into Dataverse.
                    $reportingProject = $null
                    $reportingJsonFileName = $mpp.Name.Replace("_published.mpp", "_reporting.json")
                    $reportingJsonPath = Join-Path $filesPath $reportingJsonFileName
                    if (Test-Path $reportingJsonPath) {
                        Write-Host "Reading Reporting JSON file: $reportingJsonFileName" -ForegroundColor Gray
                        try {
                            $reportingData = Get-Content -Path $reportingJsonPath -Raw | ConvertFrom-Json

                            if ($reportingData -and $reportingData.PSObject.Properties.Name -contains 'ReportingProjectData') {
                                $rpd = $reportingData.ReportingProjectData

                                if ($rpd -and $rpd.PSObject.Properties.Name -contains 'Project') {
                                    $projectNode = $rpd.Project
                                    if ($projectNode -is [System.Array]) {
                                        $reportingProject = $projectNode | Where-Object {
                                            ($_.ProjectUID -eq $projectGuid) -or ($_.ProjectUId -eq $projectGuid)
                                        } | Select-Object -First 1
                                    }
                                    else {
                                        if (($projectNode.ProjectUID -eq $projectGuid) -or ($projectNode.ProjectUId -eq $projectGuid)) {
                                            $reportingProject = $projectNode
                                        }
                                    }
                                }
                                elseif ($rpd -is [System.Array]) {
                                    $reportingProject = $rpd | Where-Object {
                                        ($_.ProjectUID -eq $projectGuid) -or ($_.ProjectUId -eq $projectGuid)
                                    } | Select-Object -First 1
                                }
                            }

                            if (-not $reportingProject) {
                                Write-Host "  Warning: Reporting data loaded but ProjectUId '$projectGuid' not found in ReportingProjectData." -ForegroundColor Yellow
                            }
                        }
                        catch {
                            Write-Host "  Warning: Could not parse reporting JSON '$reportingJsonFileName': $_" -ForegroundColor Yellow
                        }
                    }
                    else {
                        Write-Host "Reporting JSON not found for custom fields: $reportingJsonFileName" -ForegroundColor DarkYellow
                    }
                    # --------------------------------------------------------

                    # Check if Project exists in Dataverse (based on sensei_externalprojectid match)
                    $existingProject = $projectDesktopProjects | Where-Object { $_.sensei_externalprojectid -eq "ProjectDesktop_$projectGuid" }
                    #check if there is a sensei_project record with the sensei_externalprojectid but no external project reference
                    $orphanedProject = $projectsWithExternalIdButNoExternalProjectReference | Where-Object { $_.sensei_externalprojectid -eq "ProjectDesktop_$projectGuid" }
                    if ($orphanedProject) {
                        Write-Host "Found orphaned Project record for $projectName ($projectGuid) in Dataverse." -ForegroundColor Yellow
                    }
                    # If exists, skip and log
                    if ($existingProject) {
                        $nExistingProjectsSkipped++
                        Write-Host "Project with GUID $projectGuid already exists in Dataverse. Skipping import." -ForegroundColor Yellow
                        #will still check MPP custom properties - so still need the id for later
                        $newProjectId = $existingProject.sensei_projectid

                        if ($ExecutionMode) {
                            $updateBody = Get-ProjectDataverseUpdateBody -ProjectName $projectName -ProjectGuid $projectGuid -ReportingProject $reportingProject
                            if ($updateBody.Count -gt 0) {
                                Write-Host "Updating Project fields (existing record)..." -ForegroundColor Green
                                Update-Record -setName 'sensei_projects' -id $newProjectId -body $updateBody
                            }
                        }

                    }
                    else {
                        # Create Project record in Dataverse
                        if ($ExecutionMode) {
                            if ($null -eq $orphanedProject) {
                                Write-Host "Creating Project record in Dataverse for $projectName..." -ForegroundColor Green

                                $project = New-ProjectDataverseBody -ProjectName $projectName -ProjectGuid $projectGuid -DefaultProjectTypeId $DefaultProjectTypeId -ReportingProject $reportingProject

                                $newProjectId = New-Record -setName 'sensei_projects' -body $project
                                $nProjectsCreated++
                                Write-Host "Created Project record in Dataverse for $projectName with ID: $newProjectId" -ForegroundColor Green
                            }
                            else {
                                $newProjectId = $orphanedProject.sensei_projectid
                                Write-Host "Using existing orphaned Project record in Dataverse for $projectName with ID: $newProjectId" -ForegroundColor Green
                            }

                            $updateBody = Get-ProjectDataverseUpdateBody -ProjectName $projectName -ProjectGuid $projectGuid -ReportingProject $reportingProject
                            if ($updateBody.Count -gt 0) {
                                Write-Host "Updating Project fields (new/orphaned record)..." -ForegroundColor Green
                                Update-Record -setName 'sensei_projects' -id $newProjectId -body $updateBody
                            }

                            Write-Host "Creating External Project record in Dataverse for $projectName..." -ForegroundColor Green
                            $externalProject = @{
                                'sensei_name' = $projectName
                                'sensei_externalsystem@odata.bind' = "/sensei_externalsystems($ProjectDesktopExternalSystemId)"
                                'sensei_externalprojectidentifier' = "ProjectDesktop_$projectGuid"
                                'sensei_isprimary' = $true
                                'sensei_project@odata.bind' = "/sensei_projects($newProjectId)"
                            }
                            $newExternalProjectId = New-Record -setName 'sensei_externalprojects' -body $externalProject
                            $nExternalProjectsCreated++
                            Write-Host "Created External Project record in Dataverse for $projectName with ID: $newExternalProjectId" -ForegroundColor Green
                        }
                        else {
                            if ($null -eq $orphanedProject) {
                                Write-Host "[What-If] Would create Project record in Dataverse for $projectName." -ForegroundColor Magenta
                                $nProjectsCreated++

                            }
                            Write-Host "[What-If] Would create External Project record in Dataverse for $projectName." -ForegroundColor Magenta
                            #for the purposes of checking custom properties, we need a project id even in what-if mode
                            $newProjectId = [Guid]::NewGuid()
                            $nExternalProjectsCreated++
                        }
                    }

                    # Attempt to set custom properties using VBScript
                    Write-Host "Checking custom properties in $($mpp.Name) using VBScript..." -ForegroundColor Cyan
                    
                    # Kill any hung MS Project processes before starting (prevents issues from sleep/lock)
                    $msProjectProcesses = Get-Process -Name "WINPROJ" -ErrorAction SilentlyContinue
                    if ($msProjectProcesses) {
                        Write-Host "  Cleaning up existing MS Project processes..." -ForegroundColor Yellow
                        $msProjectProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 2
                    }
                    
                    $vbsPath = Join-Path $PSScriptRoot "SetMppProperty.vbs"
                    $externalProjectId = "ProjectDesktop_$projectGuid"
                    
                    #only proceed if we have the full set of data to populate custom properties
                    if ($externalProjectId -and $newProjectId -and $projectName -and $solutionVersion -and $orgName -and $envId) {
                        if (Test-Path $vbsPath) {
                            try {
                                # Build arguments as individual strings - avoid Invoke-Expression
                                $arg1 = $mpp.FullName
                                $arg2 = "ProjectId"
                                $arg3 = $externalProjectId
                                $arg4 = "ConnectedProjectId"
                                $arg5 = if ($newProjectId) { $newProjectId.ToString() } else { " " }
                                $arg6 = "ConnectedProjectName"
                                $arg7 = if ($projectName) { $projectName.ToString() } else { " " }
                                $arg8 = "ConnectedProjectDescription"
                                $arg9 = " "  # Use space instead of empty string - PowerShell won't pass empty strings
                                $arg10 = "ConnectedEnvironmentSolutionVersion"
                                $arg11 = if ($solutionVersion) { $solutionVersion.ToString() } else { " " }
                                $arg12 = "ConnectedEnvironmentName"
                                $arg13 = if ($orgName) { $orgName.ToString() } else { " " }
                                $arg14 = "ConnectedConnectionId"
                                $arg15 = $envId.ToString()
                                $arg16 = if ($ExecutionMode) { "True" } else { "False" }
                                
                                # Call VBScript with timeout handling (5 minutes max)
                                $timeoutSeconds = 300
                                $tempOutputFile = [System.IO.Path]::GetTempFileName()
                                $tempErrorFile = [System.IO.Path]::GetTempFileName()
                                
                                try {
                                    # Build argument string with proper quoting for paths with spaces
                                    $vbsArgs = "//NoLogo `"$vbsPath`" `"$arg1`" `"$arg2`" `"$arg3`" `"$arg4`" `"$arg5`" `"$arg6`" `"$arg7`" `"$arg8`" `"$arg9`" `"$arg10`" `"$arg11`" `"$arg12`" `"$arg13`" `"$arg14`" `"$arg15`" `"$arg16`""
                                    
                                    $processInfo = Start-Process -FilePath "cscript.exe" `
                                        -ArgumentList $vbsArgs `
                                        -NoNewWindow `
                                        -PassThru `
                                        -RedirectStandardOutput $tempOutputFile `
                                        -RedirectStandardError $tempErrorFile
                                    
                                    # Wait with timeout
                                    $completed = $processInfo.WaitForExit($timeoutSeconds * 1000)
                                    
                                    if (-not $completed) {
                                        Write-Host "  ✗ VBScript timeout after $timeoutSeconds seconds - killing process" -ForegroundColor Red
                                        $processInfo.Kill()
                                        # Also kill any MS Project processes
                                        Get-Process -Name "WINPROJ" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                                        throw "VBScript execution timed out"
                                    }
                                    
                                    # Read output from both files
                                    $vbsOutput = @()
                                    if (Test-Path $tempOutputFile) {
                                        $vbsOutput += Get-Content $tempOutputFile -ErrorAction SilentlyContinue
                                    }
                                    if (Test-Path $tempErrorFile) {
                                        $vbsOutput += Get-Content $tempErrorFile -ErrorAction SilentlyContinue
                                    }
                                    
                                    # Display VBScript output
                                    if ($vbsOutput) {
                                        $vbsOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
                                    }
                                    
                                    $exitCode = $processInfo.ExitCode
                                }
                                catch {
                                    $nErrored++
                                }
                                finally {
                                    # Cleanup temp files
                                    if (Test-Path $tempOutputFile) {
                                        Remove-Item $tempOutputFile -Force -ErrorAction SilentlyContinue
                                    }
                                    if (Test-Path $tempErrorFile) {
                                        Remove-Item $tempErrorFile -Force -ErrorAction SilentlyContinue
                                    }
                                }
                                
                                if ($exitCode -eq 0) {
                                    # Check if no changes were needed
                                    $noChangesMade = $vbsOutput -match 'No changes made, skipping save'
                                    
                                    if ($ExecutionMode) {
                                        if ($noChangesMade) {
                                            Write-Host "  No changes were needed in MPP file $($mpp.Name)." -ForegroundColor Green
                                            $nMPPsNotRequiringUpdate++
                                        } else {
                                            Write-Host "  ✓ Custom properties set successfully" -ForegroundColor Green
                                            $nMPPsUpdated++
                                        }
                                    }
                                    else {
                                        if ($noChangesMade) {
                                            Write-Host "[What-If] No changes required in MPP file $($mpp.Name)." -ForegroundColor Magenta
                                            $nMPPsNotRequiringUpdate++
                                        } else {
                                            Write-Host "[What-If] Would set custom properties in MPP file $($mpp.Name)." -ForegroundColor Magenta
                                            $nMPPsUpdated++
                                        }
                                    }
                                }
                                else {
                                    $nErrored++
                                    Write-Host "  ✗ VBScript failed (exit code: $LASTEXITCODE)" -ForegroundColor Red
                                    Write-Host "  Manual step required: Set custom properties in MS Project" -ForegroundColor Yellow
                                }
                            }
                            catch {
                                $nErrored++
                                Write-Host "  ✗ Error calling VBScript: $_" -ForegroundColor Red
                                Write-Host "  Manual step required: Set custom properties in MS Project" -ForegroundColor Yellow
                            }
                        }
                        else {
                            $nErrored++
                            Write-Host "  ✗ VBScript file not found: $vbsPath" -ForegroundColor Red
                            Write-Host "  Manual step required: Set custom properties in MS Project" -ForegroundColor Yellow
                        }
                    }
                    else {
                        $nErrored++
                        Write-Host "  ✗ Insufficient data to set custom properties in MPP file." -ForegroundColor Red
                        Write-Host "    Ensure External Project ID, Project ID, Project Name, Solution Version, Organization Name, and Environment ID are all available." -ForegroundColor Yellow
                        Write-Host "  Manual step required: Set custom properties in MS Project" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "No corresponding JSON file was found for: $jsonFileName. Skipping." -ForegroundColor Yellow
                    continue
                }
            }
            catch {
                $nErrored++
                Write-Host "  ✗ Error processing $($mpp.Name): $_" -ForegroundColor Red
            }
        }
        
        # No COM cleanup needed - using direct file manipulation

        #For Each MPP
            # Else
                # Create Project record in Dataverse
                # Create External Project record in Dataverse
                # Update MPP custom properties

        Write-Host "`n--------------------------------------------" -ForegroundColor Cyan
        Write-Host "Import Projects Summary" -ForegroundColor Cyan
        Write-Host "--------------------------------------------" -ForegroundColor Cyan
        Write-Host "Execution Mode:                $executionModeText" -ForegroundColor Cyan
        Write-Host "MPPs Processed:                $nMPPsProcessed" -ForegroundColor Cyan
        Write-Host "Existing Projects Skipped:     $nExistingProjectsSkipped" -ForegroundColor Cyan
        Write-Host "Projects Created:              $nProjectsCreated" -ForegroundColor Cyan
        Write-Host "External Projects Created:     $nExternalProjectsCreated" -ForegroundColor Cyan
        Write-Host "MPPs Updated:                  $nMPPsUpdated" -ForegroundColor Cyan
        Write-Host "MPPs Not Requiring Update:     $nMPPsNotRequiringUpdate" -ForegroundColor Cyan
        Write-Host "Errors Encountered:            $nErrored" -ForegroundColor Cyan
    }

    Write-Host "Import Projects completed" -ForegroundColor Green
}

# function Get-ProjectDesktopProjects {
#     Write-Host  '--Retrieving Projects from Dataverse--'

#     $projects = Get-AllRecords `
#         -setName 'sensei_projects' `
#         -query "?`$select=sensei_name,sensei_externalprojectid&`$filter=sensei_externalprojectid ne null&`$expand=sensei_externalproject_project_sensei_pro(`$select=sensei_name;`$filter=_sensei_externalsystem_value eq $ProjectDesktopExternalSystemId)"

#     # Filter out projects where sensei_externalproject_project_sensei_pro is empty
#     $projects = $projects | Where-Object { 
#         $null -ne $_.sensei_externalproject_project_sensei_pro -and 
#         $_.sensei_externalproject_project_sensei_pro.Count -gt 0 
#     }

#     return $projects
# }

function Get-ProjectsWithExternalId {
    Write-Host  '--Retrieving Projects with External ID but no External Project Reference--'

    $projects = Get-AllRecords `
        -setName 'sensei_projects' `
        -query "?`$select=sensei_name,sensei_externalprojectid&`$filter=sensei_externalprojectid ne null&`$expand=sensei_externalproject_project_sensei_pro(`$select=sensei_name,_sensei_externalsystem_value)"

    # # Filter to only projects where the expanded relationship is empty
    # $projects = $projects | Where-Object { 
    #     $null -eq $_.sensei_externalproject_project_sensei_pro -or 
    #     $_.sensei_externalproject_project_sensei_pro.Count -eq 0 
    # }

    return $projects
}

function Get-SolutionVersion {
    Write-Host  '--Retrieving Altus Solution Version--'

    $solutionVersion = Get-AllRecords `
        -setName 'solutions' `
        -query "?`$select=version&`$filter=uniquename eq 'SenseiProjectIndependent'"

    return $solutionVersion.version
}

function Get-OrgName {
    Write-Host  '--Retrieving Organization Info--'

    $orgInfo = Get-AllRecords `
        -setName 'organizations' `
        -query '?$select=organizationid,name'

    return $orgInfo.name
}

function Get-EnvironmentId {
    Write-Host  '--Retrieving Environment ID--'

    # Check if manually configured in Defaults.ps1
    if ($global:EnvironmentId) {
        Write-Host "  Using configured Environment ID" -ForegroundColor Gray
        return $global:EnvironmentId
    }

    try {
        Write-Host "  Querying Power Platform Admin API for Environment ID" -ForegroundColor Gray
        
        # Get the organization ID from WhoAmI
        $whoAmIUrl = $global:baseURI + "WhoAmI"
        $request = @{
            Uri = $whoAmIUrl
            Method = 'Get'
            Headers = $global:baseHeaders
        }
        $whoAmIResponse = Invoke-ResilientRestMethod -request $request
        $organizationId = $whoAmIResponse.OrganizationId
        
        Write-Host "  Organization ID: $organizationId" -ForegroundColor Gray
        
        # Get access token for Power Platform API
        $ppToken = (Get-AzAccessToken -ResourceUrl "https://api.bap.microsoft.com/" -AsSecureString).Token
        $token = ConvertFrom-SecureString -SecureString $ppToken -AsPlainText
        
        $ppHeaders = @{
            'Authorization' = "Bearer $token"
            'Accept' = 'application/json'
        }
        
        # Query all environments to find the one matching our organization ID
        $environmentsUrl = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2023-06-01"
        
        Write-Host "  Querying environments from Power Platform Admin API" -ForegroundColor Gray
        
        $ppRequest = @{
            Uri = $environmentsUrl
            Method = 'Get'
            Headers = $ppHeaders
        }
        
        $envsResponse = Invoke-ResilientRestMethod -request $ppRequest
        
        # Find environment matching our organization ID
        $matchingEnv = $envsResponse.value | Where-Object { 
            $_.properties.linkedEnvironmentMetadata.instanceApiUrl -like "*$organizationId*" -or
            $_.properties.linkedEnvironmentMetadata.resourceId -eq $organizationId
        }
        
        if ($matchingEnv) {
            $envId = $matchingEnv.name
            Write-Host "  Environment ID found: $envId" -ForegroundColor Green
            return $envId
        }
        
        Write-Host "  Environment ID not found - could not match organization to environment" -ForegroundColor Yellow
        return $null
    }
    catch {
        Write-Host "  Warning: Could not retrieve Environment ID: $_" -ForegroundColor Yellow
        return $null
    }
}
