# Original from ExportDraftAndPublishedAsXml.ps1 from https://learn.microsoft.com/en-au/projectonline/export-user-data-from-project-online#scripts
function RunScriptBlockWithRetry ($ScriptBlock)
{
	$retryCount = 0
	$tryAgain = $true
	while ($tryAgain -and $retryCount -le 30)
	{
		try
		{
			Invoke-Command -ScriptBlock $ScriptBlock
			$tryAgain = $false
		}
		catch
		{
			if ($_.ToString().Contains("RPC_E_CALL_REJECTED"))
			{
				# retry on RPC_E_CALL_REJECTED error - with a second sleep
				Start-Sleep -Seconds 1
				$retryCount++
			}
			else
			{
				throw
			}
		}
	}
}

# Original from ExportDraftAndPublishedAsXml.ps1 from https://learn.microsoft.com/en-au/projectonline/export-user-data-from-project-online#scripts
# Modified from Connect-WinProjToProjectServer as we no longer need to connect to Project Server.
function Open-WinProj
{
	Write-Output "1. verify existence of interop dll"
	$gac = [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.Office.Interop.MSProject').GlobalAssemblyCache
	if (-not $gac)
	{
		throw "interop dll not in gac"
	}

	$projectProcess =  [System.Diagnostics.Process]::GetProcessesByName("winproj");
	if (-not $projectProcess) {
		throw "Start Project before running this script."
	}

	Write-Output "2. initialize the interop dll"
	$WinProjApp = New-Object -ComObject msproject.application
	RunScriptBlockWithRetry -ScriptBlock {
		$WinProjApp.DisplayAlerts = $false
	}

	$global:WinProjApp = $WinProjApp
}

# Original from ExportDraftAndPublishedAsXml.ps1 from https://learn.microsoft.com/en-au/projectonline/export-user-data-from-project-online#scripts
function Close-WinProj()
{
	if ($null -ne $global:WinProjApp)
	{
		RunScriptBlockWithRetry -ScriptBlock {
			$global:WinProjApp.Quit([Microsoft.Office.Interop.MSProject.PjSaveType]::pjDoNotSave)
		}

		$global:WinProjApp = $null
	}
}

function Get-AltusAutomationObject()
{
    if ($null -eq $global:WinProjApp)
    {
        throw "WinProj is not opened. Call Open-WinProj first."
    }

    Write-Host "Getting Altus Automation Object..."

    $addin = RunScriptBlockWithRetry -ScriptBlock {
		# First search for ClickOnce AddIn 
		foreach ($a in $global:WinProjApp.COMAddIns) {
			if ($a.ProgId -eq "Altus" -or $a.ProgId -eq "Altus.Project" -or $a.ProgId -eq "Altus.ProjectAddIn") {
				return $a;
            }
        }

		# Second search for MSI installed AddIn 
        foreach ($a in $global:WinProjApp.COMAddIns) {
			if ($a.ProgId -eq "Sensei.AltusAddin") {
				return $a;
            }
        }

        return $null;
    }

    if ($null -eq $addin)
    {
        throw "Failed to find Altus for Project Automation."
    }

	if (-not $addin.Connect)
    {
        throw "Altus for Project Application COM Add-in is disabled."
    }

	$automation = $addin.Object;

    if ($null -eq $automation)
    {
        throw "Failed to find Altus for Project Automation object."
    }

	return $automation;
}

function Invoke-AltusPublishProject($projectPath, $automation, $isDebug)
{
    if ($null -eq $global:WinProjApp)
    {
        throw "WinProj is not opened. Call Open-WinProj first."
    }

    if ($null -eq $automation)
    {
        throw "Failed to find Altus for Project Automation object."
    }

    Write-Host "Opening project..."
    $WinProjApp.FileOpenEx($projectPath, $false)
    Write-Host "AfP Automation object ready calling PublishProject..."
    $result = $automation.PublishProject()
    Write-Host "Closing and Saving project..."
    $WinProjApp.FileCloseEx('pjSave')

    return $result
}
