<#
.SYNOPSIS
    現在のAzureサブスクリプションの NSG (Network Security Group) ルール一覧を CSV/JSON で出力する。

.DESCRIPTION
    Get-AzNetworkSecurityGroup で全 NSG を取得し、各 NSG の SecurityRules（カスタムルール）を
    1 ルール 1 行にフラット化して出力する。DefaultSecurityRules は除外する。
#>
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\output')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
$OutputDir = (Resolve-Path $OutputDir).Path

$ctx = Get-AzContext
if ($null -eq $ctx) {
    throw 'Azureにサインインしていません。先に Connect-AzAccount を実行してください。'
}

Write-Host "サブスクリプション: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -ForegroundColor Cyan
Write-Host 'NSG 一覧を取得中...' -ForegroundColor Yellow

$nsgs = Get-AzNetworkSecurityGroup

function Join-AddressPrefixes($single, $list) {
    if ($list -and $list.Count -gt 0) { return ($list -join ',') }
    if ($single) { return $single }
    return ''
}
function Join-Ports($single, $list) {
    if ($list -and $list.Count -gt 0) { return ($list -join ',') }
    if ($single) { return $single }
    return ''
}

$normalized = foreach ($nsg in $nsgs) {
    $assocCount = ( @($nsg.NetworkInterfaces).Count + @($nsg.Subnets).Count )
    foreach ($rule in $nsg.SecurityRules) {
        $src     = Join-AddressPrefixes $rule.SourceAddressPrefix      $rule.SourceAddressPrefixes
        $dst     = Join-AddressPrefixes $rule.DestinationAddressPrefix $rule.DestinationAddressPrefixes
        $sport   = Join-Ports           $rule.SourcePortRange          $rule.SourcePortRanges
        $dport   = Join-Ports           $rule.DestinationPortRange     $rule.DestinationPortRanges

        $isInternetSource = (
            $src -match '(^|,)(\*|0\.0\.0\.0/0|Internet|Any)(,|$)'
        )
        $isMgmtPort = (
            $dport -match '(^|,)(22|3389)(,|$)'
        )
        $risky = ($rule.Access -eq 'Allow' -and $rule.Direction -eq 'Inbound' -and $isInternetSource -and $isMgmtPort)

        [pscustomobject]@{
            NsgName                  = $nsg.Name
            ResourceGroupName        = $nsg.ResourceGroupName
            Location                 = $nsg.Location
            AssociationCount         = $assocCount
            RuleName                 = $rule.Name
            Priority                 = $rule.Priority
            Direction                = $rule.Direction
            Access                   = $rule.Access
            Protocol                 = $rule.Protocol
            SourceAddressPrefix      = $src
            SourcePortRange          = $sport
            DestinationAddressPrefix = $dst
            DestinationPortRange     = $dport
            Description              = $rule.Description
            IsRiskyMgmtFromInternet  = $risky
            NsgId                    = $nsg.Id
        }
    }
}

if (-not $normalized) { $normalized = @() }

$csvPath  = Join-Path $OutputDir 'nsg-rules.csv'
$jsonPath = Join-Path $OutputDir 'nsg-rules.json'

$normalized | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$normalized | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

Write-Host ''
Write-Host "NSG 数: $($nsgs.Count) ／ ルール数: $($normalized.Count)" -ForegroundColor Green
Write-Host "CSV : $csvPath"  -ForegroundColor Green
Write-Host "JSON: $jsonPath" -ForegroundColor Green

return [pscustomobject]@{
    NsgCount       = $nsgs.Count
    RuleCount      = $normalized.Count
    CsvPath        = $csvPath
    JsonPath       = $jsonPath
    Subscription   = $ctx.Subscription.Name
    SubscriptionId = $ctx.Subscription.Id
}
