[Download Timesheet to Finance Sync Flow solution](TimesheettoFinanceSyncFlow_1_0_0_5.zip)

## Flow steps:

- Get a list of all projects (your team can add a filter as needed)
- For each project, get the financial adjustments by calling the shipped Custom API we use in the Finance import UI 
- Aggregate the updates
- Then, using the DataVerse batch API, process the changes in the appropriate order

This Flow is designed to be run daily, ideally overnight.

If you have a large dataset of timesheet data which has not previously been imported, then the first run of this Flow will take a much longer time to complete because of all of catch up Financial Items and Financial Transaction that need to be created.  

Please note that the Do While loop that processes each type of create/update/delete action has an inbuilt default timeout of 60 minutes. If the processing time for batches within that loop reach 60 minutes then the remaining items from that collection will not be processed in that Flow run (but should complete the next time the Flow is run). In our tests, the Flow completed creation of 21000 new Financial Transactions before reaching this timeout.

The critical aspect of the updates contained is projects cannot be updated concurrently by multiple triggers, this as we found with the multi-approval live import can cause data corruption. Otherwise, you can break up the projects how you want.

## Install Instructions

**Note** - Recommended to run this process in a private browser session, as the connection wizard can get confused about which environment to authenticate against.

- Please take the unmanaged solution .zip supplied, and import it into the environment it will run.
  - **Note** - this must be installed as unmanaged, as otherwise the parameters may not be modified.

- Create the two connections, and ensure green ticks appear on the Flow overview page.
- Enter the environment base URL in both text fields for the HTTP with Entra ID connection,  
  e.g., `'https://iq-atsumeru.crm6.dynamics.com/'`

![Example of Entra ID connection setup](images/1.png)

![Example of connected Flow ready to run](images/2.png)


### Open the Flow in edit mode

- Change the 'Environment URL' variable to be the base environment URL.
- Change the recurrence settings to match your preferences.
  - **Note** - Once a day is recommended, but feel free to experiment with shorter times. Make sure the recurrence time well exceeds the longest expected execution time to avoid overlapping results.
- The MaxBatchSize variable can be adjusted, but must not ever exceed 1000 (this is the maximum batch size allowed by Dataverse)
- Save the changes
