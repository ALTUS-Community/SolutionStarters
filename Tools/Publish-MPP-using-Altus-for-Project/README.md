# Altus Schedule Publish Script

## Purpose

Automates bulk publishing of Microsoft Project (.mpp) schedules to an Altus (Dataverse) environment as part of a Project Online to Altus migration (or for any already linked MPPs).

## Prerequisites

This script requires:

- Microsoft Project
- [Altus For Project](https://docs.altus.pro/products/AltusForProject/Index.html)

The script is intended to be used with its sister script `AltusPOLMigration.ps1`, however, it can be used on any linked MPPs.

The user running the script must have sufficient access to the Dataverse environment in order to read and write the required Resource and Project data. Ideally, they should be an Altus Admin User.

The user running the script must establish a connection to the target Altus environment at least once. This will ensure the authentication process operates correctly. If this has not been done, consult [here](#establish-a-connection-to-target-environment).

## Running the Script

Start Microsoft Project and ensure [Altus For Project](https://docs.altus.pro/products/AltusForProject/Index.html) Add-in is installed, active and connected to Altus.

To run the script, open PowerShell 5 (or SharePoint Online Management Shell) and navigate to the location of the script.

Select to run the following command:

```PS1
.\Publish-MPPsToAltus.ps1
```

The script can also optionally be run by passing in the following parameters:

- All - A switch parameter when set will tell the script to process all MPPs found within the directory. This takes precedence over NamePattern.
- NamePattern - A string parameter which a user can pass to filter the MPPs to be processed. E.g., Project_*.mpp
  - By default, this is set to Project_*_published.mpp.

If a user requires more info about the script, the following command can be run:

```PS1
Get-Help .\Publish-MPPsToAltus.ps1
```

On actioning the script, the following will occur:

1. Find Microsoft Project Interop.
2. Initialize the Microsoft Project Interop.
3. Find the Altus For Project Add-In.
4. For each project discovered in the directory:
   1. Open project.
   2. Connect to Altus.
   3. Publish schedule to Altus.
   4. Close and save project.

The terminal will inform the following to the user:

- Successful Publish.
- Failed Publish:
  - The associated error message.
- Count of Successful Publishes.
- Count of Failed Publishes.

### Script Outputs

The script will output to a folder following the naming convention of `Logs\Publish-MPPsToAltus_yyyyMMddHHmmss\`.

It will contain the following files:

- `successes.txt`
  - A log of all successful publishes indicated by a file path.
- `failures.txt`
  - A log of all failed publishes with the following:
    - Path.
    - Error.
    - Timestamp.
- `failures.csv`
  - A log of all failed publishes with the following:
    - Path.
    - Error.
    - Timestamp.

Per project:

- `[ProjectName]-publish-log.txt`
  - A log of the publish operations performed.
- `[ProjectName]-resource-config.json`
  - A JSON of the resource configuration created using fuzzy matching used to publish resource assignments.
  - This file documents how resources were matched/published (useful for auditing).
- `[ProjectName]-errors.json`
  - If there were warnings during publish a file with the warning details will be created.
- `[ProjectName]-errors.txt`
  - If there was an error during publish a file with the error details will be created.

## Establish a Connection to Target Environment

To establish a connection to an environment, perform the following steps in Microsoft Project:

1. Open an MPP.
2. Locate the Altus tab in the ribbon.
3. Click Connect to Altus.
4. Sign in.
5. Select the environment.
6. Click Next.

Once this has been done once, there is no need to do this again (unless you are setting this up on a new machine).

## Common Issues & Resolutions

| Symptom | Cause | Resolution |
|---------|-------|------------|
| “Not linked to Altus” error | Project missing ConnectedProjectId document property | Manually connect via ribbon first. |
| Script exits immediately | Running in PowerShell 7+ | Use Windows PowerShell 5. |
| Altus automation not found | Add-in not loaded / disabled | Re-enable in COM Add-ins manager. |
| Many failures with resource assignment | Missing fuzzy mapping alignment | Review generated resource-config JSON and adjust resources manually then re-publish. |
| COM exceptions / Project remains in memory | Stale instances or abrupt termination | Ensure clean shutdown; close other Project windows before rerun. |

## Safety / Idempotency

- Re-publishing updates existing remote records; it does not create duplicate project shells if linking already established.
- Script saves each project after publish—ensure you do not have unsaved experimental changes you wish to keep separate.

## Performance Tips

- Run locally (avoid network latency for opening .mpp).
- Close other Office applications.
- Disable real-time antivirus scanning on the batchlogs folder if performance is critical (subject to IT policy).

## Limitations

- No parallel publishing (sequential by design).
- No retry logic for transient network failures unless implemented inside the add-in.
- Assumes stable add-in automation surface—update script if interface changes.

## Changelog

| Version | Date | Notes |
|---------|------|-------|
| 1.0.0   | 2025-11-12 | Initial documented revision. |
