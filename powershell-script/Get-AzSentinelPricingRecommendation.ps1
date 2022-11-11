<#

    Get-AzSentinelPricingRecommendation.ps1
    
    V0.9 by Koos Goossens @ Wortell. Last update: November 11th 2022

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

[CmdletBinding()]
param (
    [Parameter (Mandatory = $true)]
    [String] $subscriptionId
)

Clear-Host

Write-Host ""
Write-Host "                                                               _____" -ForegroundColor DarkCyan
Write-Host "                                                            .-'     `-." -ForegroundColor DarkCyan
Write-Host "                                                          .'  .-"""-.-"'" -ForegroundColor DarkCyan
Write-Host " ██████╗ ██████╗ ████████╗██╗███╗   ███╗██╗███████╗      /  .'     ██████╗ " -ForegroundColor DarkCyan
Write-Host "██╔═══██╗██╔══██╗╚══██╔══╝██║████╗ ████║██║╚══███╔╝  .--' '-------.██╔══██╗" -ForegroundColor DarkCyan
Write-Host "██║   ██║██████╔╝   ██║   ██║██╔████╔██║██║  ███╔╝   """"""":  :"""""""""""  ██████╔╝" -ForegroundColor DarkCyan
Write-Host "██║   ██║██╔═══╝    ██║   ██║██║╚██╔╝██║██║ ███╔╝  .----'  '----.  ██╔══██╗" -ForegroundColor DarkCyan
Write-Host "╚██████╔╝██║        ██║   ██║██║ ╚═╝ ██║██║███████╗ """""""\  \"""""""""    ██║  ██║" -ForegroundColor DarkCyan
Write-Host " ╚═════╝ ╚═╝        ╚═╝   ╚═╝╚═╝     ╚═╝╚═╝╚══════╝      \  '.     ╚═╝  ╚═╝" -ForegroundColor DarkCyan
Write-Host "                                                          '.  '-----." -ForegroundColor DarkCyan
Write-Host "                                                            '-.____.'" -ForegroundColor DarkCyan
Write-Host ""

# Make sure any modules we depend on are installed

    $modulesToInstall = @(
        'Az.Accounts',
        'Az.OperationalInsights',
        'Az.MonitoringSolutions'
    )
    Write-Host "Installing/Importing PowerShell modules..." -ForegroundColor DarkGray
    $modulesToInstall | ForEach-Object {
        if (-not (Get-Module -ListAvailable -All $_)) {
            Write-Host "Module [$_] not found, installing..." -ForegroundColor DarkGray
            Install-Module $_ -Force
        }
    }

    $modulesToInstall | ForEach-Object {
        Write-Host "Importing Module [$_]" -ForegroundColor DarkGray
        Import-Module $_ -Force
    }

# (Re-)setting Variables

    $logAnalyticsPriceTable = @{}
    $sentinelPriceTable = @{}
    $listworkspace = @{}
    $sentinelWorkspaces = @()
    $changeRequired = $false

# Based on prices for West Europe region https://azure.microsoft.com/en-us/pricing/details/monitor/

    $logAnalyticsPriceTable = @{
        'PerGB2018' = [int]    0;
        '100'       = [int]   85; 
        '200'       = [int]  193;
        '300'       = [int]  293;
        '400'       = [int]  391;
        '500'       = [int]  491;
        '1000'      = [int]  983;
        '2000'      = [int] 1953;
        '5000'      = [int] 4849
    }

# Bases on prices for West Europe region https://azure.microsoft.com/en-us/pricing/details/microsoft-sentinel/

    $sentinelPriceTable = @{
        'perGB'     = [int]    0;
        '100'       = [int]   50; 
        '200'       = [int]  179;
        '300'       = [int]  290;
        '400'       = [int]  384;
        '500'       = [int]  480;
        '1000'      = [int]  974;
        '2000'      = [int] 1897;
        '5000'      = [int] 4730
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

$subscription = get-azsubscription -SubscriptionId $subscriptionId

Write-Host ""
Write-Host "Selecting Azure subscripton $($subscriptionId)" -ForegroundColor DarkCyan
Write-Host ""
Select-AzSubscription -subscriptionId $subscriptionId | Out-Null

# Get all log analytics workspaces but excluded those from Defender for Cloud
$workspaces = Get-AzOperationalInsightsWorkspace | Where-Object { $_.Name -notlike "DefaultWorkspace-*" }

foreach ($workspace in $workspaces) {
    
    Write-Host "┏━━━" -ForegroundColor Yellow
    Write-Host "┃ Investigating workspace $($workspace.Name)" -ForegroundColor Yellow
    Write-Host "┗━━━" -ForegroundColor Yellow
    $changeRequired = $false

    # Retrieve current Log Analytics Sku
    if ($workspace.Sku -eq "PerGB2018") {
        $currentSku = "PerGB2018"
    } else {
        $currentSku = $workspace.CapacityReservationLevel
    }

    # Query for average daily date ingest
    Write-Host "  ┖─ Querying for average daily data ingest..." -ForegroundColor Gray
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $DailyAvgIngestQuery -Wait 120 | Select-Object Results
    $avgDailyIngest = ($queryResults.Results | Select-Object -ExpandProperty "GBs/day")
    if ($avgDailyIngest -eq "NaN") {    # In case KQL gave no results, the daily data ingest = zero
        $avgDailyIngest = 0
    }
    
    # Compare the daily data ingest with the values of the pricing hash table defined above
    $loganalyticsAllRecommendations = $logAnalyticsPriceTable.GetEnumerator() | Where-Object { $_.Value -le $avgDailyIngest }
    
    # Next, we want to show only the pricing tier with the highest amount of data/day aplicable
    $getSku = $loganalyticsAllRecommendations | Where-Object { $_.Value -eq (($loganalyticsAllRecommendations | measure-object -Property Value -maximum).maximum) } | Select-Object -ExpandProperty Name
    if ($getSku -eq 'PerGB2018') {      # Check if Sku = string
        $optimalSku = $getSku
    } else {
        $optimalSku = [int]$getSku      # Otherwise it's an integer
    }
    
    # Check is Sentinel solution is enabled on the log analytics workspace
    Write-Host "  ┖─ Check if workspace is Sentinel enabled..." -ForegroundColor Gray
    $checkSentinelEnabled = Get-AzMonitorLogAnalyticsSolution | Where-Object { $_.Name -eq "SecurityInsights($($workspace.Name))" }
    Write-Host "  ┖─ Gathering Log Analytics pricing tier recommendations..." -ForegroundColor Gray
    If (($checkSentinelEnabled | Measure-Object).Count -eq 0) {
        $sentinelEnabled = $false
        # Then also no Sentinel pricing tier is aplicable
        $optimalSentinelSku = "N/A"
        $currentSentinelSku = "N/A"
    } else {
        $sentinelEnabled = $true
        # Retrieve current Sentinel SKU
        $context = Get-AzContext
        $profileClient = [Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient]::new([Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile)
        $token = $profileClient.AcquireAccessToken($context.Subscription.TenantId)
        $headers = @{
            "Authorization" = "Bearer $($token.AccessToken)"
            "Content-Type"  = "application/json"
        }
        Write-Host "  ┖─ Retrieve Sentinal SKU..." -ForegroundColor Gray
        $params = @{
            "Method"  = "Get"
            "Uri"     = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$($workspace.ResourceGroupName)/providers/Microsoft.OperationsManagement/solutions/SecurityInsights($($workspace.Name))?api-version=2015-11-01-preview"
            "Headers" = $headers
        }
        $sentinelProperties = Invoke-RestMethod @params -UseBasicParsing
        if ($sentinelProperties.properties.sku.name -eq "perGB") {
            $currentSentinelSku = "perGB"
        } else {
            $currentSentinelSku = [int]$sentinelProperties.properties.sku.capacityReservationLevel
        }
        Write-Host "  ┖─ Gathering Sentinel pricing tier recommendations..." -ForegroundColor Gray
        # Compare the daily data ingest with the values of the pricing hash table defined above
        $sentinelAllRecommendations = $sentinelPriceTable.GetEnumerator() | Where-Object { $_.Value -le $avgDailyIngest }
        # Next, we want to show only the pricing tier with the highest amount of data/day aplicable
        $getSentinelSku = $sentinelAllRecommendations | Where-Object { $_.Value -eq (($sentinelAllRecommendations | measure-object -Property Value -maximum).maximum) } | Select-Object -ExpandProperty Name
        if ($getSentinelSku -eq 'perGB') {
            # Check if Sku = string
            $optimalSentinelSku = $getSentinelSku
        } else {
            $optimalSentinelSku = [int]$getSentinelSku      # Otherwise it's an integer
        }
    }

    # Check data beyond free retention
    Write-Host "  ┖─ Checking data retention ..." -ForegroundColor Gray
    If ($sentinelEnabled -eq $false) {
        Write-Host "     Data older than free retention (30d) ?..." -ForegroundColor DarkGray
        $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $LogAnalyticsRetentionQuery -Wait 120 | Select-Object Results
        $billedRetentionGB = ($queryResults.Results | Select-Object -ExpandProperty "PayedRetentionGB")
    }
    If ($sentinelEnabled -eq $true) {
        Write-Host "     Data older than free retention (90d) ?..." -ForegroundColor DarkGray
        $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $SentinelRetentionQuery -Wait 120 | Select-Object Results
        $billedRetentionGB = ($queryResults.Results | Select-Object -ExpandProperty "PayedRetentionGB")
    }
    # Construct new hash table with information about this workspace
    $listworkspace = New-Object PSObject -property @{
        workspaceName        = $workspace.Name;
        SubscriptionName     = $subscription.Name;
        sentinelEnabled      = $sentinelEnabled;
        retentionInDays      = $workspace.retentionInDays;
        averageDailyIngest   = $avgDailyIngest;
        currentSku           = $currentSku;
        optimalSku           = $optimalSku;
        currentSentinelSku   = $currentSentinelSku;
        optimalSentinelSku   = $optimalSentinelSku;
        billedRetentionGB    = $billedRetentionGB
    }
    # Add hash table to already existing object with all the other workspaces
    $sentinelWorkspaces += $listworkspace

    # Compare Current Sku's with optimal Sku's
    Write-Host "  ┖─ Checking if Sku's needs changing..." -ForegroundColor Gray
    if ($currentSku.Equals($optimalSku)) {
        Write-Host "     ✓ Log Analytics Sku is currently running optimal Sku" -ForegroundColor Green
    } else {
        Write-Host "     ! Log Analytics Sku needs to be changed from $($currentSku) to $($optimalSku)" -ForegroundColor DarkYellow
        $changeRequired = $true
    }
    if ($currentSentinelSku.Equals($optimalSentinelSku)) {
        Write-Host "     ✓ Microsoft Sentinel Sku is currently running optimal Sku" -ForegroundColor Green
    } else {
        Write-Host "     ! Microsoft Sentinel Sku needs to be changed from $($currentSentinelSku) to $($optimalSentinelSku)" -ForegroundColor DarkYellow
        $changeRequired = $true
    }

    # Make adjustments to ARM template parameters file
    if ($changeRequired) {
        # Read ARM template parameters file
        $parametersFile = (Get-ChildItem "parameters" | where-object name -match $listworkspace.workspaceName).Name
        $parametersFileContents = get-content "parameters/$($parametersFile)" | ConvertFrom-Json

        # Change Log Analytics parameters values to match optimal Sku
        If($optimalSku -eq "PerGB2018") {
            $parametersFileContents.parameters.pricingTierLogAnalytics.value                = "PerGB2018"
            $parametersFileContents.parameters.capacityReservationLevelLogAnalytics.value   = 100
        } else {
            $parametersFileContents.parameters.pricingTierLogAnalytics.value                = "CapacityReservation"
            $parametersFileContents.parameters.capacityReservationLevelLogAnalytics.value   = $optimalSku
        }

        # Change Sentinel parameters values to match optimal Sku
        If($optimalSentinelSku -eq "perGB") {
            $parametersFileContents.parameters.pricingTierSentinel.value                    = $false
            $parametersFileContents.parameters.capacityReservationLevelSentinel.value       = 100
        } else {
            $parametersFileContents.parameters.pricingTierSentinel.value                    = $true
            $parametersFileContents.parameters.capacityReservationLevelSentinel.value       = $optimalSentinelSku
        }
        
        # Write changes to ARM template parameters file
        Write-Host "  ┖─ Writing ARM template parameters file to disk..." -ForegroundColor Gray
        $parametersFileContents | Convertto-Json | out-file "parameters/$($parametersFile)"
        try {
            $parametersFileContents | Convertto-Json | out-file "parameters/$($parametersFile)"
            Write-Host "     ✓ Changes to ARM template parameters file 'parameters/$($parametersFile)' written" -ForegroundColor Magenta
        }
        catch {
            Write-Host "     ✘ There was a problem writing file" -ForegroundColor Red
        }
        
        # Write Github variables for next step(s)
        "fileChanges=true" >> $env:GITHUB_OUTPUT
        "filePath=parameters/$parameterFile" >> $env:GITHUB_OUTPUT
    }

}

# Output all findings

Write-Host ""
Write-Host ""
Write-Host "┏━━━" -ForegroundColor Green
Write-Host "┃ The following (Sentinel) workspace(s) were found:" -ForegroundColor Green
Write-Host "┗━━━" -ForegroundColor Green
$sentinelWorkspaces | Select-Object -Last 20 | Format-Table workspaceName, SubscriptionName, sentinelEnabled, retentionInDays, averageDailyIngest, currentSku, optimalSku, currentSentinelSku, optimalSentinelSku, billedRetentionGB
# Notify is list is shortened
If (($sentinelWorkspaces | Measure-Object).Count -gt 20) {
    Write-Host "More than 20 workspaces found, output is truncated!" -ForegroundColor Red
}