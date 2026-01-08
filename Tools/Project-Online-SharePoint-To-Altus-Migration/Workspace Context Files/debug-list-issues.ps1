# Debug script to inspect lists in "Pauls Test 20210311 1" project

$SiteCollectionUrl = "https://senseijumpstart.sharepoint.com/sites/pwa"
$ClientId = "30b4ad0b-d939-4cd4-bb6d-fa2d39fb4694"
$ProjectName = "Pauls Test 20210311 1"

Write-Host "Connecting to SharePoint..." -ForegroundColor Cyan
Connect-PnPOnline -Url $SiteCollectionUrl -Interactive -ClientId $ClientId

Write-Host "Finding project web: $ProjectName" -ForegroundColor Cyan
$webs = Get-PnPSubWeb -Recurse
$targetWeb = $webs | Where-Object { $_.Title -eq $ProjectName }

if ($null -eq $targetWeb) {
    Write-Host "Project '$ProjectName' not found!" -ForegroundColor Red
    Write-Host "Available projects:" -ForegroundColor Yellow
    $webs | ForEach-Object { Write-Host "  - $($_.Title)" }
    exit 1
}

Write-Host "Found project web: $($targetWeb.Url)" -ForegroundColor Green

Write-Host "`nListing all lists in this project:" -ForegroundColor Cyan
try {
    # Connect to the specific web
    Connect-PnPOnline -Url $targetWeb.Url -Interactive -ClientId $ClientId
    
    $lists = Get-PnPList -ErrorAction Stop
    Write-Host "Total lists: $($lists.Count)`n" -ForegroundColor Green
    
    foreach ($list in $lists) {
        if (-not $list.Hidden) {
            $itemCount = Get-PnPListItem -List $list | Measure-Object | Select-Object -ExpandProperty Count
            Write-Host "Title: $($list.Title)" -ForegroundColor Yellow
            Write-Host "  Internal Name: $($list.RootFolder.Name)"
            Write-Host "  Item Count: $itemCount"
            Write-Host "  Base Template: $($list.BaseTemplate)"
            Write-Host ""
        }
    }
    
    Write-Host "Searching for 'Issue' or 'Risk' lists:" -ForegroundColor Cyan
    $matches = $lists | Where-Object { $_.Title -match "(issue|risk)" -and -not $_.Hidden }
    if ($matches) {
        Write-Host "Found: $($matches.Count) matching list(s)" -ForegroundColor Green
        foreach ($list in $matches) {
            Write-Host "  - $($list.Title)"
        }
    }
    else {
        Write-Host "No lists found matching 'issue' or 'risk'" -ForegroundColor Red
    }
}
catch {
    Write-Error "Error listing lists: $($_.Exception.Message)"
}
