# Script overview

This script is intended to be used as part of a migration of data from Project Online to Altus. This particular script handles the creation of Resources and Projects in an Altus environment based on exported Project Online data.  

In order to run this script, each of the .ps1 files that you download for this solution need to be unblocked. To unblock, right-click the .ps1 file in File Explorer, select Properties and then select to Unblock.

## Prerequisites

The script requires:

- [PowerShell 7.4 or higher](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- [Az PowerShell module version 11.1.0 or higher](https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell)

The script relies on Project Online data having been extracted from a Project Online environment using the [Microsoft export script](https://learn.microsoft.com/en-au/projectonline/export-user-data-from-project-online)

The data extracted from Project Online which the user intends to migrate into Altus must then be placed in the /Files folder relative to the location of this script.

The user running the script must have sufficient access to the Dataverse environment in order to read and write the required Resource and Project data. Ideally they should be an Altus Admin User.

For Importing Projects, part of the process requires updating the MPP files to include custom parameters. In order to Import Projects, you will need Microsoft Project installed locally.

## Running the Script

To run the script, open Powershell or SharePoint Online Management Shell and navigate to the location of the script. (Note: If the version of Powershell you are running is lower than 7 then PowerShell 7 will be called and executed from within that window).

Select to run the following command;  
  
.\AltusPOLMigration.ps1

The script can also optionally be run by passing in the following parameters:

- EnvironmentUrl - The URL to the environment which contains your Altus instance e.g. "https://myorg.crm6.dynamics.com/"
- ExecutionMode - Allows the user to select between WhatIf mode or Execution mode (see below for further details on Execution Mode). Valid values are "W" or "WhatIf" for What-If mode or "E" or "Execute" for Execute mode.
- Action - This represents the action that should be taken by the script. Options are "ImportNamedResources", "ImportNamedAndGenericResources" or "ImportProjects".

Example call with parameters:

.\AltusPOLMigration.ps1 -EnvironmentUrl "https://myorg.crm6.dynamics.com/" -ExecutionMode W -Action ImportNamedAndGenericResources

If any parameters are not passed in to the call to the script, then the user will be prompted to enter them interactively.

### Execution Mode

The script can be run in What-If or Execution mode. When running the script, the user will be prompted for their execution mode preference.

What-If mode will run the script but will not execute any commands that actually create data in your Dataverse environment. The proposed changes however will be logged.

Execute mode will action the changes and create records in your Dataverse environment.

Each time the script runs a log file will be created. 

The script can be run in Execute mode multiple times in an environment. If data from a previous run already exists, duplicate records will not be created.

## Resource Import  

There are two options for Resource Import in this script. 'Named Only' or 'Generic and Named'.

- Read all existing Named Bookable Resources in your Dataverse environment
- Read all existing System Users in your Dataverse environment
- Read all of the Project Online resources json files that were extracted from your Project Online environment, deduplicate them and consolidate them according to type
- For each unique Project Online Named resource, the script will;
  - Look for a matching Named Bookable Resource (based on the login name of the Project Online user).
    - If a match is found, no action will be taken and a log entry will be noted
  - Look for a matching System User (based on the login name of the Project Online user)
    - If no match is foundno action will be taken and a log entry will be noted
  - If there is no matching Named Bookable Resource and a matching System User is found
    - If in Execute mode, a Named Bookable Resource will be created
      - Values for Primary Role, Target Utilization and Enterprise Calendar will be set as per the values set in the Defaults.ps1 file
    - If in What-If mode, no Resource will be created in Dataverse, but a log entry will be noted
- When run in 'Generic and Named' mode, the script will also;
  - Look for a matching Generic Bookable Resource (based on the name of the Project Online generic resource)
    - If a match is found, no action will be taken and a log entry will be noted
  - If there is no matching Generic Bookable Resource;
    - If in Execute mode, a Generic Bookable Resource will be created
    - If in What-If mode, no Resource will be created in Dataverse, but a log entry will be noted

## Project Import

Project import will perform the following actions:

- Read all Project Desktop aligned Projects from the Altus environment
- Read the Solution version number for the Altus Atsumeru Solution in the Altus environment
- Read the Organization name from the environment
- Get the EnvironmentId for the environment (via Power Platform Admin API)
- Read all Published MPP files from the /Files folder relative to the script
- For each Published MPP file;
  - Read the ProjectName and ProjectGUID from the related .json file
  - Look for an existing Altus Project which is linked to the Project Desktop external system for the project
    - If a match is found, no action will be taken and a log entry will be noted
  - Look for an existing Altus Project which has a matching External Project ID property but no matching External System record
    - If a match is found, the ExternalProject record will be created in Altus (and aligned to the Project Desktop external system)
  - If there is no matching Project in Altus;
    - If in Execute mode;
      - A Project will be created in Altus
        - The Project Type will be set as per the value set in the Defaults.ps1 file
      - An associated ExternalProject record will be created in Altus (and aligned to the Project Desktop external system)
  - The Published MPP file in the Files directory will be updated to include the custom properties required to align it to the Altus Project when used with the Altus for Project add-in. If the custom properties already contain the correct values, no changes will be made.
  - If in What-If mode, no Project, External Project or Custom Property updates will be performed. Instead, a log entry will be noted.
