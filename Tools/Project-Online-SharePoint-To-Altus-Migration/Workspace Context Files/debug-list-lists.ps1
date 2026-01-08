<#
.SYNOPSIS
  Diagnostic script to list all SharePoint lists in the first project web

.DESCRIPTION
  Connects to PWA and shows all lists available in the first project site to help identify
  the correct list names for the export configuration.
#>

$SiteCollectionUrl = "https://senseijumpstart.sharepoint.com/sites/pwa"
$ClientId = "30b4ad0b-d939-4cd4-bb6d-fa2d39fb4694"

Write-Host "Connecting to SharePoint..." -ForegroundColor Cyan
Connect-PnPOnline -Url $SiteCollectionUrl -Interactive -ClientId $ClientId

Write-Host "`nGetting project webs..." -ForegroundColor Cyan
$webs = Get-PnPSubWeb -Recurse
Write-Host "Found $($webs.Count) project webs." -ForegroundColor Green

if ($webs.Count -gt 0) {
    $firstWeb = $webs[0]
    Write-Host "`nInspecting first project web: $($firstWeb.Title)" -ForegroundColor Yellow
    Write-Host "URL: $($firstWeb.Url)" -ForegroundColor Gray
    Write-Host ""
    
    Write-Host "Available lists:" -ForegroundColor Cyan
    Write-Host "=================" -ForegroundColor Cyan
    
    $lists = Get-PnPList -Web $firstWeb
    foreach ($list in $lists) {
        # Skip system/hidden lists
        if (-not $list.Hidden) {
            Write-Host ""
            Write-Host "Title: $($list.Title)" -ForegroundColor Green
            Write-Host "  Internal Name: $($list.RootFolder.Name)" -ForegroundColor Gray
            Write-Host "  Item Count: $($list.ItemCount)" -ForegroundColor Gray
            Write-Host "  Base Template: $($list.BaseTemplate)" -ForegroundColor Gray
        }
    }
    
    Write-Host "`n`nLooking for 'Risks' or 'Issues' lists..." -ForegroundColor Yellow
    $risksLists = $lists | Where-Object { $_.Title -like "*risk*" -or $_.Title -like "*issue*" }
    if ($risksLists.Count -gt 0) {
        Write-Host "Found potential matches:" -ForegroundColor Green
        foreach ($list in $risksLists) {
            Write-Host "  - $($list.Title) (Items: $($list.ItemCount))" -ForegroundColor Green
        }
    }
    else {
        Write-Host "No lists with 'risk' or 'issue' in the name found." -ForegroundColor Red
    }
}
else {
    Write-Host "No project webs found!" -ForegroundColor Red
}
