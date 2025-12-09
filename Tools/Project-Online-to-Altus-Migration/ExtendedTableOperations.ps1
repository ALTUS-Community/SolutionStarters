. $PSScriptRoot\TableOperations.ps1

<#
.SYNOPSIS
Gets all records from a Dataverse table with automatic paging support.

.DESCRIPTION
The Get-AllRecords function retrieves all records from a Dataverse table, automatically handling paging when there are more than 5,000 records.
It continues to fetch pages until all records are retrieved by following the @odata.nextLink property in the response.

.PARAMETER setName
The name of the entity set to retrieve records from. This parameter is mandatory.

.PARAMETER query
The query parameters to filter, sort, or select the records. This parameter is mandatory.

.PARAMETER strongConsistency
When true, requests Strong Consistency for the query. This parameter is optional. Default is false.

.EXAMPLE
$allAccounts = Get-AllRecords -setName 'accounts' -query '?$select=name,accountnumber'
This example retrieves all accounts with their name and accountnumber, automatically handling paging if there are more than 5,000 records.

.EXAMPLE
$filteredContacts = Get-AllRecords `
    -setName 'contacts' `
    -query '?$select=fullname,emailaddress1&$filter=statecode eq 0'
This example retrieves all active contacts with automatic paging support.
#>

function Get-AllRecords {
    param (
        [Parameter(Mandatory)] 
        [String] 
        $setName,
        [Parameter(Mandatory)] 
        [String] 
        $query,
        [bool] 
        $strongConsistency = $false
    )
    
    $allRecords = @()
    $response = Get-Records -setName $setName -query $query -strongConsistency $strongConsistency
    
    if ($response.value) {
        $allRecords += $response.value
    }
    
    # Handle paging if there are more records
    $pageCount = 1
    while ($response.'@odata.nextLink') {
        $pageCount++
        Write-Host "Fetching page $pageCount..." -ForegroundColor Gray
        
        $nextUrl = $response.'@odata.nextLink'
        # Extract just the query portion after the base URI
        $nextQuery = $nextUrl.Substring($nextUrl.IndexOf($setName) + $setName.Length)
        $response = Get-Records -setName $setName -query $nextQuery -strongConsistency $strongConsistency
        
        if ($response.value) {
            $allRecords += $response.value
        }
    }
    
    if ($pageCount -gt 1) {
        Write-Host "Retrieved $($allRecords.Count) records across $pageCount pages." -ForegroundColor Gray
    }
    
    return $allRecords
}
