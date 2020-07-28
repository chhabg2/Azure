<#

Script Name	: IdentifyOrphanResourceGroups.ps1
Description	: List resource groups that do not have a matching owner (by tag) on Azure AD
Author		: Martin Schvartzman, Microsoft
Last Update	: 2020/07/28
Keywords	: Azure, Automation, Runbook, Tags, Governance

#>

PARAM(
    [string] $SubscriptionNamePattern = 'maschvar.*',
    [string] $ConnectionName = 'AzureRunAsConnection',
    [string] $ExcludeResourceGroupNames = '^cloud-shell-storage-(\w+)|^DefaultResourceGroup-(\w+)|^AzureBackupRG_(\+w)_(\d+)|^NetworkWatcherRG|^VstsRG-(\w+)-\w{4}',
    [string] $SendToEmailAddress = $null
)

Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Starting' -f (Get-Date))

try {

    # Login to Azure
    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName
    $null = Add-AzAccount -ServicePrincipal -Tenant $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint

    # Login to AzureAD
    $null = Connect-AzureAD -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint

    $orphanResourceGroups = @()

    # Iterate all subscriptions and get all resource groups
    $allResourceGroups = Get-AzSubscription -PipelineVariable sub | Where-Object { $_.Name -match $SubscriptionNamePattern } | ForEach-Object {
        Write-Verbose ('Switching to subscription: {0}' -f $_.Name) -Verbose
        $context = Set-AzContext -SubscriptionObject $_ -Force
        if ($context.Subscription.Id -eq $_.SubscriptionId) {
            Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -notmatch $excludeResourceGroupNames } |
                Select-Object  @{N = 'Subscription'; E = { $sub.Name } }, ResourceGroupName, @{N = 'IsOrphan'; E = { $true } }, @{N = 'TaggedOwner'; E = { $_.Tags.Owner } }
        } else {
            Write-Output ('There was an error changing the context to {0}' -f $sub.Name)
        }
    }

    # Verify the owners exist in azure Active Directory (by DisplayName or UPN)
    $owners = $allResourceGroups | Where-Object { $_.TaggedOwner } | Group-Object TaggedOwner -NoElement | Select-Object Name, @{N = 'Exists'; E = { $false } }
    foreach ($owner in $owners) {
        try {
            if ($owner.Name -match '@') {
                $exists = @(Get-AzureADUser -Filter "userPrincipalName eq '$($owner.Name)'" -ErrorAction Stop |
                        Where-Object { @($_.DisplayName, $_.UserPrincipalName) -contains $owner.Name }).Count -eq 1
            } else {
                $exists = @(Get-AzureADUser -SearchString $owner.Name -ErrorAction Stop |
                        Where-Object { @($_.DisplayName, $_.UserPrincipalName) -contains $owner.Name }).Count -eq 1
            }
        } catch {
            Write-Output ($_.Exception.Message)
            $exists = 'Unable to determine'
        }
        $allResourceGroups | Where-Object { $_.TaggedOwner -eq $owner.Name } | ForEach-Object {
            $_.IsOrphan = $exists.ToString()
        }
    }
    $orphanResourceGroups = @($allResourceGroups | Where-Object { (-not ($_.IsOrphan -eq $false)) })

    # Send report by email
    if ($orphanResourceGroups.Count -gt 0 -and $SendToEmailAddress) {
        $body = ($orphanResourceGroups | ConvertTo-Html -Fragment) -join ''
        .\Send-GridMailMessage.ps1 -Subject 'Orphan resource groups identified' -content $body -bodyAsHtml `
            -FromEmailAddress AzureAutomation@azure.com -destEmailAddress $SendToEmailAddress
    }

} catch {
    Write-Output ($_.Exception.Message)
} finally {
    Write-Output ($orphanResourceGroups)
    Write-Output ('{0:yyyy-MM-dd HH:mm:ss.f} - Completed' -f (Get-Date))
}
