# SharePoint to Dynamics 365 Migration Tool

This tool exports and imports SharePoint list data and documents to Microsoft Dynamics 365 using the MS CMT (Configuration Migration Tool) format. It works in conjunction with the Project Online and Project migration tools.

## Prerequisites

**Required:** Projects must already be present in your Altus (Dynamics 365) environment from a previous migration step. SharePoint list items will be linked to these projects during import.

**Note:** The POLExport data from previous migration steps (step 1) is used to identify and map projects in SharePoint.

## Migration Workflow & Prerequisites

**This tool performs three steps:**

1. **Export Lists** – Export list data from SharePoint
   - Extract list items, metadata, and project references from configured SharePoint site collections
   - Convert to CMT XML format
   - Can use POLExport path from previous step 1 (optional)

2. **Import Lists** – Import list data to Dynamics 365
   - Requires projects to already exist in Altus (from step 1 migration)
   - Links list items to their corresponding projects in D365
   - Creates/updates records based on configuration

3. **Export Documents** – Download documents from SharePoint libraries
   - **NOT a full SharePoint migration** - this is document extraction only
   - Downloads documents from document libraries and preserves folder structure
   - Intended for use with SharePoint sync tools (OneDrive sync, etc.)
   - Output files can be dragged into a SharePoint synced folder for upload
   - Optional: Extended metadata and version history
   - Simple mode (default): Fast download of files and folders

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

## Setup Requirements

Before running any migration scripts, you must configure two essential files:

### 1. Configure the Schema File (`data_schema.xml`)

The schema file defines the target Dynamics 365 entities and fields. **Maintain this file using the MS Configuration Migration Tool (CMT):**

1. Open the **Configuration Migration Tool** on your local machine
2. Load the existing `data_schema.xml` file
3. Modify entities and fields as needed to match your D365 customizations
4. Save the updated schema back to `data_schema.xml`
5. Verify that all entities and fields used in your field mappings are present

**Alternatively**, you can export a fresh schema directly from your D365 environment and replace the existing file.

**Why?** Using the CMT ensures your schema is valid and matches your D365 customizations, preventing validation errors during import.

### 2. Configure the Field Mapping File (`export.config.json`)

The mapping file controls how SharePoint fields are transformed to D365 attributes:

1. Open `export.config.json`
2. For each SharePoint list being migrated, add an entry to the `lists` array
3. Map each SharePoint field to its corresponding D365 attribute
4. Define value transformations (choiceMap, thresholds, multipliers, etc.)
5. Verify field names match the schema exactly (case-sensitive)

See the **Configuration Files** section below for detailed examples and syntax.

## Quick Start - Two Options

### Option 1: Use the Migration Orchestrator (Recommended)

```powershell
.\-Run-Migration.ps1
```

This is the primary entry point. The script:

- Prompts you to choose: **Export Lists**, **Import Lists**, or **Export Documents**
- Displays configured site collections and D365 environment before starting
- Processes multiple SharePoint site collections sequentially
- Creates organized output folders for each site
- Provides detailed summary with success/failure tracking

**Operation Modes:**

1. **Export Lists** - Extract SharePoint list data to CMT XML files
2. **Import Lists** - Load XML files into Dynamics 365
3. **Export Documents** - Download documents from SharePoint libraries

⚠️ **Important:** The document export feature downloads files only. It is **not a complete SharePoint migration**. For full SharePoint site migration including lists, pages, workflows, and site structure, use dedicated migration tools such as **ShareGate**.

### Option 2: Run Scripts Individually

Export, import, and document export are available as standalone scripts for advanced scenarios:

```powershell
# Step 1: Export SharePoint lists
.\1-export-lists.ps1 -SiteCollectionUrl "..." -OutputFolder ".\Output" -POLExportPath "..."

# Step 2: Import to Dynamics 365 (requires projects in Altus)
.\2-import-lists.ps1 -D365Url "..." -DataFolder ".\Output" -POLExportPath "..."

# Step 3: Export documents from SharePoint libraries
.\3-export-documents.ps1 -SiteCollectionUrl "..." -OutputFolder ".\Output\Documents" -POLExportPath "..."
```

Both the orchestrator and individual scripts require the same configuration settings defined below.

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

### `1-export-lists.ps1` – SharePoint Export

Extracts list data from SharePoint and converts to CMT XML format.

**Called by:** `-Run-Migration.ps1` (automatically)

**Standalone usage:**
```powershell
.\1-export-lists.ps1 `
  -SiteCollectionUrl "https://senseicloud.sharepoint.com/sites/vNext/" `
  -MappingJsonPath ".\export.config.json" `
  -CmtSchemaPath ".\data_schema.xml" `
  -OutputFolder ".\Output\vNext" `
  -PolExportPath "C:\path\to\polexport\from\step\1"
```

**Parameters:**

- **-PolExportPath** (optional)
  - Path to the POLExport data from the previous Project Online extraction step (step 1)
  - Used to identify and map project references in SharePoint lists
  - If not provided, defaults to standard SharePoint list export without POL context

**Output:**
- `Output/<SiteName>/<ProjectName>/Data.xml` – CMT-compliant XML for each project

### `2-import-lists.ps1` – Dynamics 365 Import

Loads CMT XML files into D365 and links list items to projects already present in Altus.

**Prerequisite:** Projects must already exist in your Altus environment (from step 1 project migration)

**Called by:** `-Run-Migration.ps1` (automatically)

**Standalone usage:**
```powershell
.\2-import-lists.ps1 `
  -D365Url "https://senseijumpstart.crm.dynamics.com" `
  -SchemaPath ".\data_schema.xml" `
  -DataFolder ".\Output\vNext" `
  -POLExportPath "C:\path\to\polexport\from\step\1"
```

### `3-export-documents.ps1` – Document Export

Downloads documents from SharePoint document libraries for use with SharePoint sync tools or manual upload.

**⚠️ Important Note:**
- This script extracts **files only** from document libraries
- It is **NOT a complete SharePoint migration tool**
- No migration to another SharePoint environment is performed
- Exported files can be used with:
  - SharePoint sync (OneDrive sync) to move to a new location
  - Manual drag-and-drop into a synced folder
  - Backing up important documents
- **For complete SharePoint site migration** (lists, pages, workflows, permissions, etc.), use dedicated migration tools:
  - **ShareGate** (recommended for enterprise)
  - Microsoft's built-in SharePoint Migration Tool
  - Other third-party migration solutions

**Called by:** `-Run-Migration.ps1` (automatically when selecting "Export Documents")

**Standalone usage:**
```powershell
# Simple mode (default) - Just files and folders
.\3-export-documents.ps1 `
  -SiteCollectionUrl "https://senseicloud.sharepoint.com/sites/vNext/" `
  -OutputFolder ".\Output\Documents\vNext" `
  -POLExportPath "C:\path\to\polexport\from\step\1"

# Detailed mode - With metadata and version history
.\3-export-documents.ps1 `
  -SiteCollectionUrl "https://senseicloud.sharepoint.com/sites/vNext/" `
  -OutputFolder ".\Output\Documents\vNext" `
  -POLExportPath "C:\path\to\polexport\from\step\1" `
  -DetailedMetadata `
  -ExcludeVersionHistory:$false
```

**Parameters:**

- **-SiteCollectionUrl** (required)
  - SharePoint site collection URL

- **-OutputFolder** (optional)
  - Where to save downloaded documents
  - Default: `.\Output\Documents\Default`

- **-POLExportPath** (optional)
  - Path to POL export data from step 1
  - Used to identify and map project references

- **-ProjectFilter** (optional)
  - Array of wildcard patterns to filter projects
  - Example: `@("*2024*", "Project A")`

- **-DetailedMetadata** (switch, optional)
  - When enabled: Exports extended metadata (ETag, ContentType, UniqueId, all FieldValues)
  - When enabled: Creates folder per file with metadata.json
  - Default: $false (simple mode)

- **-ExcludeVersionHistory** (switch, optional)
  - When $true: Only exports current version
  - When $false: Exports all versions (requires -DetailedMetadata)
  - Default: $true

- **-ExcludeLibraries** (optional)
  - Comma-separated list of library names to skip
  - Default: `"Style Library,Preservation Hold Library,Form Templates,Recycle Bin,Site Assets"`

- **-ExcludeFilePatterns** (optional)
  - File patterns to exclude (wildcards supported)
  - Default: `@("*.aspx")`

- **-IncludeRootWeb** (switch, optional)
  - Include root web in project discovery
  - Default: $false

**Output Modes:**

**Simple Mode (default):**
```
Output/Documents/vNext/
├── Project A/
│   ├── Documents/
│   │   ├── file1.docx
│   │   ├── file2.pdf
│   │   ├── Subfolder/
│   │   │   └── file3.xlsx
│   │   ├── manifest.csv
│   │   └── manifest.json
│   └── Shared Documents/
│       └── ...
└── Project B/
    └── ...
```

Use with SharePoint Sync or manual upload:
1. Open OneDrive sync on your computer (Settings → OneDrive → Start sync)
2. Sync a folder in the new SharePoint location
3. Drag exported files from `Output/Documents/<Project>/Documents/` into the synced folder
4. OneDrive automatically uploads them to SharePoint

**Detailed Mode (`-DetailedMetadata`):**
```
Output/Documents/vNext/
├── Project A/
│   ├── Documents/
│   │   ├── file1.docx/
│   │   │   ├── file1.docx
│   │   │   ├── file1_v1.0.docx (if version history enabled)
│   │   │   └── metadata.json
│   │   ├── manifest.csv
│   │   └── manifest.json
│   └── ...
```

**Manifest Files:**
- Each library gets `manifest.csv` and `manifest.json` summarizing all exported documents
- Global manifests created at root: `documents-manifest.csv` and `documents-manifest.json`

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
  - `Text`
  - `Number`, `Money` — supports optional `multiplier`/`divider` per column (e.g., Probability 0.75 with `multiplier:100` exports as 75)
  - `DateTime`
  - `OptionSet`, `Status`, `State` — use `choiceMap` or `thresholds`
  - `OptionSetCollection` — multi-select choice mapping; use `choiceMap` and optional `includeSentinel:true` to emit values as `[ -1,<ids>,-1 ]`
  - `Boolean` — exports literal `"true"`/`"false"`; optionally map with `trueValue`/`falseValue` when needed
  - `Lookup` — converts to D365 lookup with entity reference

**Common mapping examples:**

- Scale a percentage to whole number output:
  ```json
  {
    "spFieldInternalName": "Probability",
    "entityAttribute": "custom_percenttestwn",
    "type": "Number",
    "multiplier": 100
  }
  ```

- Divide a numeric value:
  ```json
  {
    "spFieldInternalName": "Cost",
    "entityAttribute": "custom_cost",
    "type": "Number",
    "divider": 1000
  }
  ```

- Boolean field mapping:
  ```json
  {
    "spFieldInternalName": "Bool_x0020_Test",
    "entityAttribute": "custom_booltest",
    "type": "Boolean"
  }
  ```

- Multi-select choice field with sentinel wrapping:
  ```json
  {
    "spFieldInternalName": "Multi_x0020_Choice_x0020_Test",
    "entityAttribute": "custom_multichoicetest",
    "type": "OptionSetCollection",
    "includeSentinel": true,
    "choiceMap": {
      "Negligible": 955000000,
      "Minor": 955000001,
      "Moderate": 955000002,
      "Major": 955000003,
      "Severe": 955000004
    }
  }
  ```
  Output format in Data.xml: `[ -1,955000000,955000002,955000003,-1 ]`

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

### Understanding the SharePoint Migration Dependencies

This tool is **step 3** in the overall migration process:

- **Step 1** (Previous): Project Online extraction (`0.Project-Online-Extraction/`)
  - Exports POL data; output is available as `PolExportPath`

- **Step 2** (Previous): Project migration (`1.Project-and-Resource-Migration/`)
  - Imports projects into Altus
  - **Must complete BEFORE running this SharePoint migration**

- **Step 3** (This tool): SharePoint list and document export
  - Export Lists: Use the POLExport path from step 1 (optional, for context)
  - Import Lists: **Requires projects to exist in Altus** from step 2
  - Export Documents: **File extraction only** - downloads files for use with sync tools
  - List items are linked to Altus projects during import
  - Documents are output for manual drag-into-sync or use with SharePoint sync tools

- **Step 4** (Later): Schedule migration (`2.Schedule-Migration/`)
  - Runs after projects and lists are in place

**Note on SharePoint Document Migration:**

This tool provides **document extraction only**. For complete SharePoint site migration (including lists, pages, workflows, permissions, site structure), use dedicated enterprise migration tools:

- **ShareGate** - Industry-leading SharePoint migration platform
- **Microsoft SharePoint Migration Tool** - Built-in Microsoft solution
- **Sharegate, AvePoint, or other third-party solutions** - Various specialized scenarios

These tools handle:
- ✅ Complete site structure and metadata
- ✅ Permissions and sharing settings
- ✅ Workflows and business logic
- ✅ Content types and custom fields
- ✅ Versioning and retention policies

### Document Export Modes

The document export script supports two modes:

**Simple Mode (Default):**
- Downloads files directly to library folders
- No metadata.json files created
- No version history
- Fast and efficient for basic document backup
- Perfect for creating a clean copy of documents to sync to SharePoint or other locations
- Typical use: Export documents, then drag into OneDrive sync folder or SharePoint

**Detailed Mode (`-DetailedMetadata`):**
- Creates a folder for each file
- Generates metadata.json with extended properties
- Optional version history with `-ExcludeVersionHistory:$false`
- Includes ETag, ContentType, UniqueId, and all SharePoint FieldValues
- Suitable for document backup with complete metadata preservation

**Using Exported Documents:**

1. **With OneDrive/SharePoint Sync:**
   ```
   1. Set up OneDrive sync for your new SharePoint location
   2. Drag files from Output/Documents/<Project>/ into the synced folder
   3. OneDrive automatically uploads to SharePoint
   ```

2. **For Complete SharePoint Migration:**
   ```
   Use specialized tools like ShareGate for full site migration:
   - ShareGate: Enterprise-grade SharePoint migration
   - Microsoft SharePoint Migration Tool: Native Microsoft solution
   - Other third-party tools: Various vendors support specific scenarios
   ```

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
.\1-export-lists.ps1 `
  -SiteCollectionUrl "https://tenant.sharepoint.com/sites/custom-pwa" `
  -OutputFolder ".\Output\CustomExport" `
  -ProjectFilter @("ProjectA", "ProjectB") `
  -POLExportPath "C:\exports\POL"

# Custom import with different D365 environment
.\2-import-lists.ps1 `
  -D365Url "https://custom-org.crm.dynamics.com" `
  -DataFolder ".\Output\CustomExport" `
  -Force $true `
  -POLExportPath "C:\exports\POL"

# Custom document export with detailed metadata
.\3-export-documents.ps1 `
  -SiteCollectionUrl "https://tenant.sharepoint.com/sites/custom-pwa" `
  -OutputFolder ".\Output\Documents\Custom" `
  -DetailedMetadata `
  -ExcludeVersionHistory:$false `
  -ProjectFilter @("*Important*") `
  -POLExportPath "C:\exports\POL"
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

**List Export:**
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

**Document Export (Simple Mode):**
```
Output/Documents/
├── vNext/
│   ├── Project A/
│   │   ├── Documents/
│   │   │   ├── file1.docx
│   │   │   ├── file2.pdf
│   │   │   ├── manifest.csv
│   │   │   └── manifest.json
│   │   └── Shared Documents/
│   │       └── ...
│   └── Project B/
│       └── ...
├── documents-manifest.csv
└── documents-manifest.json
```

**Document Export (Detailed Mode with -DetailedMetadata):**
```
Output/Documents/
├── vNext/
│   ├── Project A/
│   │   └── Documents/
│   │       ├── file1.docx/
│   │       │   ├── file1.docx
│   │       │   ├── file1_v1.0.docx  (if version history enabled)
│   │       │   └── metadata.json
│   │       ├── manifest.csv
│   │       └── manifest.json
├── documents-manifest.csv
└── documents-manifest.json
```

**migration-summary.json** contains:
- Site collection name and URL
- Operation performed (Export Lists/Import Lists/Export Documents)
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

### Document export taking too long

**Cause:** Detailed metadata and version history add significant processing time.
**Solution:** Use simple mode (default) for basic document backup. Only use `-DetailedMetadata` when you need extended properties, and `-ExcludeVersionHistory:$false` only when version history is required.

### "Access denied" during document export

**Cause:** User account lacks Site Collection Administrator permissions.
**Solution:** Ensure your account has Site Collection Admin role on the SharePoint site collection.

### Documents downloading but no metadata.json created

**Cause:** Running in simple mode (default behavior).
**Solution:** This is expected. Simple mode only downloads files. Use `-DetailedMetadata` if you need metadata.json files.

### How do I upload the exported documents to SharePoint?

**Option 1: OneDrive Sync (Recommended)**
1. Set up OneDrive sync on your local machine for the target SharePoint folder
2. Drag files from `Output/Documents/<Project>/` into the synced folder
3. OneDrive automatically uploads them to SharePoint
4. This preserves created/modified dates and file metadata

**Option 2: Manual SharePoint Upload**
1. Open SharePoint in your browser
2. Navigate to the target document library
3. Click "Upload" and select files from `Output/Documents/<Project>/`
4. Files upload directly to SharePoint

**Option 3: For Enterprise SharePoint Migration**
Consider using **ShareGate** or other enterprise migration tools for:
- Complex site structure preservation
- Permission and sharing settings
- Content type and metadata preservation
- Workflow migration
- Retention policies and compliance settings

---

## Need Help?

- **Export issues?** Check `Output/Export_<timestamp>.log` or `Logs/DataMigration-<timestamp>.txt` for detailed error messages
- **Field mapping?** Review `export.config.json` structure and compare with SharePoint field names
- **D365 connectivity?** Verify `$D365Url` and admin consent granted
- **Document export?** Check manifest files for summary of what was exported
- **Performance?** Use simple mode for documents, enable detailed metadata only when needed

---

## License

For internal use only.
