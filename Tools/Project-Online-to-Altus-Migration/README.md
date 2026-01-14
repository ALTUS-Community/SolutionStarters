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

## Custom Field Mapping

The scripts provide a mechanism to map additional Project and Resource fields from Project Online into Dataverse columns.

### Prerequisites

1. The destination column must already exist in Dataverse on the appropriate table:
   - Projects: `sensei_project`
   - Resources: `sensei_bookableresource`
2. Use the **logical name** (lowercase) of the Dataverse column, not the display name.

### Where to Edit

- **Projects:** `ImportProjects.ps1` — edit the **USER CONFIGURATION (EDIT HERE)** section at the top of the file (above the `===== Don't edit below this line =====` marker).
- **Resources:** `ImportResources.ps1` — edit the **USER CONFIGURATION (EDIT HERE)** section at the top of the file (above the `===== Don't edit below this line =====` marker).

### Data Sources

| Entity    | File Pattern                         | Where Fields Live                                      |
|-----------|--------------------------------------|--------------------------------------------------------|
| Projects  | `*_reporting.json`                   | OOTB: direct properties on `ReportingProjectData.Project`; Custom: `CustomFields[]` array |
| Resources | `*_reporting_Resources.json`         | Direct properties on each resource object              |

### Mapping OOTB (Out-of-the-Box) Fields

OOTB fields are direct properties on the project/resource object. Uncomment and edit lines inside the mapping functions.

**Projects** — edit `Add-ProjectDataverseFieldMappings` in `ImportProjects.ps1`:
```powershell
$Project['cr_project_text_ootb'] = $ProjectName
$Project['cr_project_date_ootb'] = ($ReportingProject.ProjectStartDate -as [datetime])
$Project['cr_project_whole_ootb'] = ($ReportingProject.ProjectIdentifier -as [int])
$Project['cr_project_decimal_ootb'] = ($ReportingProject.ProjectCalendarDuration -as [decimal])
```

**Resources** — edit `Add-NamedResourceDataverseFieldMappings` or `Add-GenericResourceDataverseFieldMappings` in `ImportResources.ps1`:
```powershell
$ResourceBody['cr_resource_text_ootb'] = $ProjectResource.ResourceName
$ResourceBody['cr_resource_date_ootb'] = ($ProjectResource.ResourceCreatedDate -as [datetime])
$ResourceBody['cr_resource_whole_ootb'] = ($ProjectResource.ResourceType -as [int])
$ResourceBody['cr_resource_decimal_ootb'] = ($ProjectResource.ResourceStandardRate -as [decimal])
```

### Mapping Enterprise Custom Fields (Projects only)

Project Online Enterprise Custom Fields are exported under `ReportingProjectData.Project.CustomFields[]`. Each entry has:
- `CustomFieldName` — the display name of the field in Project Online.
- `CFValue.'#text'` — the actual value (as a string).

Use the helper function `Get-ReportingCustomFieldTextValue` inside `Add-ProjectDataverseFieldMappings`:

```powershell
# Text field
$textValue = Get-ReportingCustomFieldTextValue -ReportingProject $ReportingProject -CustomFieldName 'Your Text Field'
if ($textValue) { $Project['cr_project_text_custom'] = [string]$textValue }

# Date field
$dateValue = Get-ReportingCustomFieldTextValue -ReportingProject $ReportingProject -CustomFieldName 'Your Date Field'
if ($dateValue) { $Project['cr_project_date_custom'] = ($dateValue -as [datetime]) }
```

### Supported Data Types

| Dataverse Type   | PowerShell Cast     | Example                                              |
|------------------|---------------------|------------------------------------------------------|
| Text             | `[string]`          | `$project['cr_text'] = [string]$value`               |
| Whole Number     | `-as [int]`         | `$project['cr_int'] = ($value -as [int])`            |
| Decimal/Currency | `-as [decimal]`     | `$project['cr_dec'] = ($value -as [decimal])`        |
| Date             | `-as [datetime]`    | `$project['cr_date'] = ($value -as [datetime])`      |

> **Note:** Lookup and Choice fields require different handling (`@odata.bind` for lookups, integer option-set values for choices) and are not covered by the simple examples above.

## Task Custom Field Mapping

Task-level custom field values from Project Online are imported via the **Altus for Project add-in** during the MPP publish process, not by this PowerShell script. This allows you to map individual task custom fields to Altus task columns.

### How It Works

1. PowerShell script creates the project and project tasks in Altus
2. User opens the MPP file in Microsoft Project with the Altus for Project add-in installed
3. User publishes the MPP to Altus via the add-in
4. During publish, the add-in reads configured custom field mappings from **projectDesktopConfig** and populates task columns in Altus

### Prerequisites

1. Custom columns must already exist in Altus on the `sensei_task` table
2. Custom fields must be configured in the MPP file (project-local or enterprise-level)
3. You must have access to configure **projectDesktopConfig** in your Altus environment (requires Altus Admin or configuration privileges)

### Identifying Custom Field Names

Refer to the [Microsoft Project Desktop custom fields reference](https://support.microsoft.com/en-au/office/custom-fields-in-project-desktop-604eaea9-9154-491a-9c00-764e5d46603e) to identify which field slot your custom field uses.

**Currently supported: Project-local custom fields only**

| Field Type | Slot Name | Example |
|------------|-----------|---------|
| Text | `Text1` through `Text30` | `Text7` |
| Number | `Number1` through `Number20` | `Number3` |
| Date | `Date1` through `Date10` | `Date5` |
| Flag | `Flag1` through `Flag20` | `Flag2` |

> **Note:** Enterprise-level task custom fields (defined at the Project Online/PWA tenant level) are not currently supported by the Altus for Project add-in. 

### Configuring Task Custom Field Mappings

Navigate to **Altus** → **Settings** → **Microsoft Project Configuration** in your Altus environment.

Under **Custom Field Mappings**, click **New Field Mapping**:

| Field | Value | Notes |
|-------|-------|-------|
| **Entity** | `sensei_task` | Maps to task-level fields |
| **Microsoft Project Field** | `Text7` (or your field slot) | Use the underlying slot name, not the display name |
| **Altus Field** | Select from dropdown | Must be a field on the sensei_task table |

**Example mappings:**

| Project Online Field | Slot | Altus Column |
|---------------------|------|--------------|
| Strategic Risk Assessment (enterprise) | Text7 | sensei_risk_assessment |
| Project Priority (enterprise) | Number2 | sensei_priority_score |
| Deadline Milestone (enterprise) | Date3 | sensei_milestone_date |

### Supported Field Types

The add-in supports mapping the following Microsoft Project field types to Altus columns:

| MS Project Type | Altus Types Supported |
|-----------------|----------------------|
| Text (Text1–Text30) | String, Memo, OptionSet, MultiSelect OptionSet |
| Number (Number1–Number20) | Integer, Decimal, Double, Money, OptionSet |
| Date (Date1–Date10) | Date/Time |
| Duration | Integer, Decimal, Double |
| Cost | Money, Decimal, Integer |
| Flag (Flag1–Flag20) | Boolean, OptionSet (Yes/No only) |

For detailed type-mapping rules and validation, see [Microsoft Project Configuration in Altus Docs](https://docs.altus.pro/products/AltusForProject/Configuration.html#custom-field-mappings).

### Important Notes

- **OptionSet mappings** use field **labels**, not values. Ensure field labels in MS Project exactly match OptionSet labels in Altus
- **MultiSelect OptionSets** require comma-separated values in MS Project (comma is the delimiter)
- Once a custom field is mapped, users must maintain the field definition exactly as configured — any changes to the field type or labels can break the mapping
- **Enterprise task custom fields are not currently supported** — only project-local custom fields can be mapped at this time

### Validating Your Mappings

When users publish the MPP file, the add-in will validate that:
1. The field exists in MS Project
2. The mapped Altus field exists
3. The field types are compatible

If validation fails, the add-in will display errors and the publish will not proceed. Review the error details and adjust the mapping in projectDesktopConfig, then try publishing again.

