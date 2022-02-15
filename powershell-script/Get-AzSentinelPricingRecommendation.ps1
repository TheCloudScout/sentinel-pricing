<#
    Get-AzSentinelPricingRecommendation.ps1
    
    V0.1 by Koos Goossens @ Wortell. Last update: Febuary 2nd 2022

    This script will check all Log Analytics workspaces in your environment to see if you're using the most optimal pricing tier.
    For Microsoft Sentinel there's an extra layer on top of a workspace with its own pricing tier as well. And the thresholds for both
    of these isn't as straightforward as one might think.
    I see a lot of workspaces costing more money than they should have. So hopefully this script and its outcome will save you some money.

        - It will first loop through all your subscriptions
        - Then it will loop through all Log Analytics workspaces and perform a KQL query against it to determine the average daily data ingest based on the last month
        - It will compare this result with a fixed table of thresholds (set at the beginning of the script) to determine what the optimal pricing tier should be
        - Lastly, it will check if the Sentinel solution is enabled on the workspace and will repeat the comparison but with a different table with different values this time
        - All outcomes across all workspaces will be gathered in over overview and will automatically be exported as a CSV in the end

    Please note that the threshold for these pricing tiers are determined based on the actual 'list' prices as of February 2nd 2022 based on the West Europe region.
    If you're using a different region, and/or are receiving discounts through Microsoft, please update the tables accordingly.
    To help you with this you can use my Excel calculator sheet provided in this repository as well. Fill in your current prices for each tier, and the Excel sheet will calculate all thresholds.

#>
Clear-Host
# Reset hash tables and object(s)
$logAnalyticsPriceTable = @{}
$sentinelPriceTable = @{}
$listworkspace = @{}
$sentinelWorkspaces = @()
# Based on prices for West Europe region https://azure.microsoft.com/en-us/pricing/details/monitor/
$logAnalyticsPriceTable = @{
    'Pay per GB'    = [int]    0;
    '100 GB / day'  = [int]   85; 
    '200 GB / day'  = [int]  174;
    '300 GB / day'  = [int]  274;
    '400 GB / day'  = [int]  371;
    '500 GB / day'  = [int]  469;
    '1000 GB / day' = [int]  860;
    '2000 GB / day' = [int] 1699;
    '5000 GB / day' = [int] 4041
}
# Bases on prices for West Europe region https://azure.microsoft.com/en-us/pricing/details/microsoft-sentinel/
$sentinelPriceTable = @{
    'Pay per GB'    = [int]    0;
    '100 GB / day'  = [int]   50; 
    '200 GB / day'  = [int]  140;
    '300 GB / day'  = [int]  240;
    '400 GB / day'  = [int]  336;
    '500 GB / day'  = [int]  433;
    '1000 GB / day' = [int]  689;
    '2000 GB / day' = [int] 1349;
    '5000 GB / day' = [int] 3007
}
# KQL query to retrieve an average daily date ingest based on the last 31 days excluding the current day
$DailyAvgIngestQuery = @'

    Usage
    | where TimeGenerated > ago(31d) and TimeGenerated < ago(1d)
    // Only look at chargeable Tables
    | where IsBillable == True
    | summarize TotalGBytes =round(sum(Quantity/(1024)),2) by bin(TimeGenerated, 1d)
    | summarize ['GBs/day'] =round(avg(TotalGBytes),2)

'@
$LogAnalyticsRetentionQuery = @'

    Usage
    // Data older than 30 days is billed for additional retention
    | where TimeGenerated < ago(30d)
    // Only look at chargeable Tables
    | where IsBillable == true
    | summarize PayedRetentionGB = round(sum(Quantity) / 1024 , 0)

'@
$SentinelRetentionQuery = @'

    Usage
    // Data older than 90 days is billed for additional retention
    | where TimeGenerated < ago(90d)
    // Only look at chargeable Tables
    | where IsBillable == true
    | summarize PayedRetentionGB = round(sum(Quantity) / 1024 , 0)

'@
$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
$subscriptionsCount = ($subscriptions | Measure-Object).Count
$count = 1
foreach ($subscription in $subscriptions) {
    Write-Host ""
    Write-Host "[$($count)/$($subscriptionsCount)] Switching to subscription $($subscription.Name)..." -ForegroundColor Yellow
    Select-AzSubscription -subscriptionId $subscription.Id > $null
    # Get all log analytics workspaces but excluded those from Defender for Cloud
    $workspaces = Get-AzOperationalInsightsWorkspace | Where-Object { $_.Name -notlike "DefaultWorkspace-*" }
    foreach ($workspace in $workspaces) {
        Write-Host ""
        Write-Host "Investigating workspace $($workspace.Name)" -ForegroundColor Green
        # Query for average daily date ingest
        Write-Host "Querying for average daily data ingest..." -ForegroundColor Gray
        $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $DailyAvgIngestQuery -Wait 120 | Select-Object Results
        $avgDailyIngest = ($queryResults.Results | Select-Object -ExpandProperty "GBs/day")
        # In case KQL gave no results, the daily data ingest equals zero
        if($avgDailyIngest -eq "NaN") { 
            $avgDailyIngest = 0
        }
        # Compare the daily data ingest with the values of the pricing hash table defined above
        $loganalyticsAllRecommendations = $logAnalyticsPriceTable.GetEnumerator() | Where-Object { $_.Value -le $avgDailyIngest }
        # Next, we want to show only the pricing tier with the highest amount of data/day aplicable
        $loganalyticsBestRecommendation = $loganalyticsAllRecommendations | Where-Object { $_.Value -eq (($loganalyticsAllRecommendations | measure-object -Property Value -maximum).maximum) } | Select-Object -ExpandProperty Name
        # Check is Sentinel solution is enabled on the log analytics workspace
        Write-Host "Check if workspace is Sentinel enabled..." -ForegroundColor Gray
        $checkSentinelEnabled = Get-AzMonitorLogAnalyticsSolution | Where-Object { $_.Name -eq "SecurityInsights($($workspace.Name))"  }
        Write-Host "Gathering pricing tier recommendations..." -ForegroundColor Gray
        If (($checkSentinelEnabled | Measure-Object).Count -eq 0) {
            $sentinelEnabled = "false" 
            # Then also no Sentinel pricing tier is aplicable
            $sentinelBestRecommendation = "N/A"
        } else {
            $sentinelEnabled = "true"
            # Compare the daily data ingest with the values of the pricing hash table defined above
            $sentinelAllRecommendations = $sentinelPriceTable.GetEnumerator() | Where-Object { $_.Value -le $avgDailyIngest }
            # Next, we want to show only the pricing tier with the highest amount of data/day aplicable
            $sentinelBestRecommendation = $sentinelAllRecommendations | Where-Object { $_.Value -eq (($sentinelAllRecommendations | measure-object -Property Value -maximum).maximum) } | Select-Object -ExpandProperty Name
        }
        # Check data beyond free retention
        If ($sentinelEnabled -eq "false") {
            Write-Host "Querying how much data is saved beyond free retention period (30d) and billed for..." -ForegroundColor Gray
            $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $LogAnalyticsRetentionQuery -Wait 120 | Select-Object Results
            $billedRetentionGB = ($queryResults.Results | Select-Object -ExpandProperty "PayedRetentionGB")
        }
        If ($sentinelEnabled -eq "true") {
            Write-Host "Querying how much data is saved beyond free retention period (90d) and billed for..." -ForegroundColor Gray
            $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $SentinelRetentionQuery -Wait 120 | Select-Object Results
            $billedRetentionGB = ($queryResults.Results | Select-Object -ExpandProperty "PayedRetentionGB")
        }
        # Construct new hash table with information about this workspace
        $listworkspace = New-Object PSObject -property @{
            workspaceName           = $workspace.Name;
            SubscriptionName        = $subscription.Name;
            sentinelEnabled         = $sentinelEnabled;
            retentionInDays         = $workspace.retentionInDays;
            averageDailyIngest      = $avgDailyIngest;
            bestLogAnalyticsTier    = $loganalyticsBestRecommendation;
            bestSentinelTier        = $sentinelBestRecommendation;
            billedRetentionGB       = $billedRetentionGB
        }
        # Add hash table to already existing object with all the other workspaces
        $sentinelWorkspaces += $listworkspace
    }
    $count++
}
# Output all findings and export to CSV
Write-Host ""
Write-Host "The following (Sentinel) workspace(s) were found" -ForegroundColor Green
Write-Host ""
$sentinelWorkspaces | Select-Object -Last 20 | Format-Table workspaceName, SubscriptionName, sentinelEnabled, retentionInDays, averageDailyIngest, bestLogAnalyticsTier, bestSentinelTier, billedRetentionGB
If(($sentinelWorkspaces | Measure-Object).Count -gt 20) { Write-Host "More than 20 workspaces found, output is truncated!" -ForegroundColor Red }
$sentinelWorkspaces | Select-Object workspaceName, SubscriptionName, sentinelEnabled, retentionInDays, averageDailyIngest, bestLogAnalyticsTier, bestSentinelTier,billedRetentionGB | Export-Csv sentinel-workspaces-pricing-tier-recommendations.csv
Write-Host ""
Write-Host "Output is exported to $(Get-Location | Select-Object -ExpandProperty Path)\sentinel-workspaces-pricing-tier-recommendations.csv" -ForegroundColor Green
Write-Host ""