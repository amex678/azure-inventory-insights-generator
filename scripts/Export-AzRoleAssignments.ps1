<#
.SYNOPSIS
    現在のAzureサブスクリプションの RBAC ロール割り当て一覧を取得し、CSVおよびJSONで出力する。
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
Write-Host 'RBAC ロール割り当てを取得中...' -ForegroundColor Yellow

# サブスクリプション スコープ配下のロール割り当てを全件取得
$assignments = Get-AzRoleAssignment

# スコープ種別を判定する関数
function Get-ScopeKind([string]$scope) {
    if ([string]::IsNullOrWhiteSpace($scope)) { return 'Unknown' }
    if ($scope -match '^/$' -or $scope -match '^/providers/Microsoft\.Management/managementGroups/') { return 'ManagementGroup' }
    if ($scope -match '^/subscriptions/[^/]+$') { return 'Subscription' }
    if ($scope -match '^/subscriptions/[^/]+/resourceGroups/[^/]+$') { return 'ResourceGroup' }
    if ($scope -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/') { return 'Resource' }
    return 'Other'
}

$normalized = $assignments | ForEach-Object {
    [pscustomobject]@{
        DisplayName        = $_.DisplayName
        SignInName         = $_.SignInName
        ObjectId           = $_.ObjectId
        ObjectType         = $_.ObjectType
        RoleDefinitionName = $_.RoleDefinitionName
        RoleDefinitionId   = $_.RoleDefinitionId
        Scope              = $_.Scope
        ScopeKind          = Get-ScopeKind $_.Scope
        ConditionVersion   = $_.ConditionVersion
        Condition          = $_.Condition
        Description        = $_.Description
        RoleAssignmentId   = $_.RoleAssignmentId
    }
}

$csvPath  = Join-Path $OutputDir 'rbac.csv'
$jsonPath = Join-Path $OutputDir 'rbac.json'

$normalized | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$normalized | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

Write-Host ''
Write-Host "ロール割り当て件数: $($normalized.Count)" -ForegroundColor Green
Write-Host "CSV : $csvPath"  -ForegroundColor Green
Write-Host "JSON: $jsonPath" -ForegroundColor Green

return [pscustomobject]@{
    Count          = $normalized.Count
    CsvPath        = $csvPath
    JsonPath       = $jsonPath
    Subscription   = $ctx.Subscription.Name
    SubscriptionId = $ctx.Subscription.Id
}
