# SharePoint to Dynamics 365 Migration Tool

This tool enables efficient migration of SharePoint project data to Microsoft Dynamics 365 using the MS CMT (Configuration Migration Tool) format.

## Configuration

All settings are defined in **`-Run-Migration.ps1`** within the `CONFIGURATION` section (lines 15–60).

### Site Collections

Define SharePoint site collections to migrate:

```powershell
$SiteCollections = @(
  @{
    Url           = "https://senseicloud.sharepoint.com/sites/vNext/"
    FolderName    = "vNext"         # Output folder name
    ProjectFilter = @()              # @() = all projects, or @("*2024*", "Project A")
  },
  @{
    Url           = "https://senseicloud.sharepoint.com/sites/Migration1"
    FolderName    = "Migration1"
    ProjectFilter = @()
  }
)
```

**ProjectFilter** supports wildcard patterns:
- `@()` – Export all projects
- `@("*2024*")` – Export only projects matching "*2024*"
- `@("Project A", "Project B")` – Export specific projects

### Dynamics 365 Settings

```powershell
$D365Url = "https://senseijumpstart.crm.dynamics.com"  # Your D365 environment
$ImportParallelRequests = 4                             # Parallel threads (1–10)
$ImportForce = $false                                   # $true = update existing records
```

### Authentication (Client ID)

```powershell
$ClientId = "30b4ad0b-d939-4cd4-bb6d-fa2d39fb4694"  # Sensei app
```

**First-time setup:** Grant admin consent to the application:

```
https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=30b4ad0b-d939-4cd4-bb6d-fa2d39fb4694&response_type=code&redirect_uri=http://localhost&response_mode=query&scope=.default&prompt=admin_consent
```

Copy the link, open in a browser, and sign in with tenant admin credentials.

## Quick Start - Run the Migration Orchestrator

```powershell
.\-Run-Migration.ps1
```

This is your primary entry point. The script:

- Prompts you to choose: **Export only**, **Import only**, or **Full migration** (export + import)
- Displays configured site collections and D365 environment before starting
- Processes multiple SharePoint site collections sequentially
- Creates organized output folders for each site
- Provides detailed summary with success/failure tracking

## Prerequisites & Permissions

### SharePoint Export

When running an export operation, **your user account must be a Site Collection Administrator** on each SharePoint site collection being exported. This is required because the export script needs to:

- Access all project sites and document libraries
- Read list items, metadata, and version history
- Retrieve property bag values

If you see an access denied error during export, ensure your account has Site Collection Admin privileges.

### Dynamics 365 Import

Your user account must have permissions to import data into the target Dynamics 365 environment.

### Authentication

Both SharePoint and Dynamics 365 use interactive authentication. You will be prompted to sign in during script execution.

## Core Scripts

### `01-export-lists.ps1` – SharePoint Export

Extracts project data from SharePoint lists and converts to CMT XML format.

**Called by:** `-Run-Migration.ps1` (automatically)

**Standalone usage:**
```powershell
.\01-export-lists.ps1 `
  -SiteCollectionUrl "https://senseicloud.sharepoint.com/sites/vNext/" `
  -MappingJsonPath ".\export.config.json" `
  -CmtSchemaPath ".\data_schema.xml" `
  -OutputFolder ".\Output\vNext"
```

**Output:**
- `Output/<SiteName>/<ProjectName>/Data.xml` – CMT-compliant XML for each project

### `02-import-lists.ps1` – Dynamics 365 Import

Loads CMT XML files into D365 using the Sensei migration tool.

**Called by:** `-Run-Migration.ps1` (automatically)

**Standalone usage:**
```powershell
.\02-import-lists.ps1 `
  -D365Url "https://senseijumpstart.crm.dynamics.com" `
  -SchemaPath ".\data_schema.xml" `
  -DataFolder ".\Output\vNext"
```

---

## Configuration Files

### `export.config.json` – Field Mapping

Maps SharePoint fields to Dynamics 365 attributes. Controls data transformation and validation.

**Structure:**
```json
{
  "version": "1.0",
  "lists": [
    {
      "spListTitle": "Risks",
      "entityLogicalName": "sensei_risk",
      "projectLookupAttribute": "sensei_project",
      "backlinkAttribute": "sensei_sourceitemurl",
      "columnMap": [
        {
          "spFieldInternalName": "Status",
          "entityAttribute": "statuscode",
          "type": "Status",
          "choiceMap": {
            "(1) Active": 1,
            "(2) Postponed": 2
          }
        },
        {
          "spFieldInternalName": "Probability",
          "entityAttribute": "sensei_probability",
          "type": "OptionSet",
          "thresholds": {
            "0": 955000000,
            "0.2": 955000001,
            "0.4": 955000002,
            "0.6": 955000003,
            "0.8": 955000004
          }
        }
      ]
    }
  ]
}
```

**Key concepts:**

- **choiceMap**: Maps SharePoint choice values to D365 option set integers.
  ```json
  "choiceMap": { "(1) Active": 1, "(2) Postponed": 2 }
  ```

- **thresholds**: For numeric OptionSets (Probability, Impact), maps ranges to option values.
  ```json
  "thresholds": { "0": 955000000, "0.2": 955000001 }
  ```
  If a field value is 0.5, it matches threshold 0.2 (highest threshold ≤ value) → 955000001.

- **Field Types Supported:**
  - `Text`, `Number`, `Money`, `DateTime` – Direct conversion
  - `OptionSet`, `Status`, `State` – Use choiceMap or thresholds
  - `Lookup` – Converts to D365 lookup with entity reference

### `data_schema.xml` – CMT Schema

Defines the target Dynamics 365 entities and their valid fields. Used to validate export data against your D365 customizations.

**To customize:**
1. Export from your D365 environment using the **Configuration Migration Tool** (CMT)
2. Update field names and entity names to match your customizations
3. Place the updated file in this directory

**Structure:**
```xml
<?xml version="1.0"?>
<entities>
  <entity name="sensei_risk">
    <fields>
      <field name="sensei_riskid" />
      <field name="sensei_name" />
      <field name="statuscode" />
      <field name="sensei_probability" />
    </fields>
  </entity>
</entities>
```

---

## Advanced Usage

### Custom Export Filters

Edit **`-Run-Migration.ps1`** to filter projects per site:

```powershell
$SiteCollections = @(
  @{
    Url           = "https://senseicloud.sharepoint.com/sites/vNext/"
    FolderName    = "vNext"
    ProjectFilter = @("*2024*", "Infrastructure*")  # Only 2024 projects and Infrastructure
  }
)
```

### Using Individual Scripts

For advanced scenarios, call `01-export.ps1` and `02-import.ps1` directly:

```powershell
# Custom export with specific parameters
.\01-export.ps1 `
  -SiteCollectionUrl "https://tenant.sharepoint.com/sites/custom-pwa" `
  -OutputFolder ".\Output\CustomExport" `
  -ProjectFilter @("ProjectA", "ProjectB")

# Custom import with different D365 environment
.\02-import.ps1 `
  -D365Url "https://custom-org.crm.dynamics.com" `
  -DataFolder ".\Output\CustomExport" `
  -Force $true
```

### Updating Field Mappings

To add or modify field mappings:

1. Open `export.config.json`
2. Add a new entry to the `columnMap` array:
   ```json
   {
     "spFieldInternalName": "MyCustomField",
     "entityAttribute": "new_customfield",
     "type": "Text"
   }
   ```
3. Verify the field exists in your `data_schema.xml`
4. Re-run the export

---

## Output Structure

```
Output/
├── vNext/
│   ├── Project A/
│   │   └── Data.xml
│   ├── Project B/
│   │   └── Data.xml
│   └── Export_<timestamp>.log
├── Migration1/
│   ├── Project C/
│   │   └── Data.xml
│   └── Export_<timestamp>.log
└── migration-summary.json
```

**migration-summary.json** contains:
- Site collection name and URL
- Operation performed (Export/Import/Full)
- Success/Failure status
- Duration and output folder paths

---

## Troubleshooting

### "ChoiceMap for field 'X' missing value 'Y'"

**Cause:** Field value in SharePoint doesn't match any key in choiceMap.
**Solution:** Add the missing value to `export.config.json`:
```json
"choiceMap": {
  "Existing Value": 1,
  "Missing Value": 2
}
```

### "Field 'X' not found in schema"

**Cause:** Field in `export.config.json` doesn't exist in `data_schema.xml`.
**Solution:**
1. Verify field name matches D365 logical name (case-sensitive)
2. Re-export schema from D365 if customizations were added

### Import fails with "Record exists"

**Cause:** Records already exist in D365.
**Solution:** Set `$ImportForce = $true` in `-Run-Migration.ps1` to update existing records.

---

## Need Help?

- **Export issues?** Check `Output/Export_<timestamp>.log` for detailed error messages
- **Field mapping?** Review `export.config.json` structure and compare with SharePoint field names
- **D365 connectivity?** Verify `$D365Url` and admin consent granted

---

## License

For internal use only.
