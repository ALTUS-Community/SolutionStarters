# Work In Progress (WIP) - Document Migration Scripts

This folder contains scripts for SharePoint document export and import functionality that are not yet ready for production use.

## Contents

- `03-export-documents.ps1` - Export documents, metadata, and version history from SharePoint
- `04-import-documents.ps1` - Import documents to target SharePoint site collection
- `-Run-Migration.ps1` - Orchestration script with document export/import options enabled (for testing)

## Status

These scripts are under development. Document export/import options have been disabled in the main migration tool and are available here for future work.

## Related Files

The main migration tool (in the parent directory) currently supports:
1. Export Lists - Extract data from SharePoint to XML files
2. Import Lists - Load existing XML files into Dynamics 365

Document functionality will be re-enabled once development is complete.
