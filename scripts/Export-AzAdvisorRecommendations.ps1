<#
.SYNOPSIS
    Azure Advisor の推奨事項（コスト/運用/パフォーマンス/可用性/セキュリティ）を CSV/JSON で出力する。

.DESCRIPTION
    Get-AzAdvisorRecommendation を使用して全カテゴリの推奨事項を取得する。
    Az.Advisor モジュールが未インストールの場合は警告して空出力する。
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
Write-Host 'Azure Advisor 推奨事項を取得中...' -ForegroundColor Yellow

$recommendations = @()
$hasModule = $null -ne (Get-Command Get-AzAdvisorRecommendation -ErrorAction SilentlyContinue)

if (-not $hasModule) {
    Write-Warning 'Az.Advisor モジュールが見つかりません。Install-Module Az.Advisor を実行してください。空の結果を出力します。'
} else {
    try {
        $recommendations = Get-AzAdvisorRecommendation
    } catch {
        Write-Warning "Advisor 推奨事項の取得に失敗: $($_.Exception.Message)"
    }
}

function Get-ResourceTypeFromId([string]$id) {
    if ([string]::IsNullOrWhiteSpace($id)) { return '' }
    if ($id -match '/providers/([^/]+/[^/]+)(/|$)') { return $Matches[1] }
    if ($id -match '^/subscriptions/[^/]+/resourceGroups/[^/]+$') { return 'ResourceGroup' }
    if ($id -match '^/subscriptions/[^/]+$') { return 'Subscription' }
    return ''
}
function Get-ResourceNameFromId([string]$id) {
    if ([string]::IsNullOrWhiteSpace($id)) { return '' }
    return ($id -split '/')[-1]
}
function Get-RgFromId([string]$id) {
    if ($id -match '/resourceGroups/([^/]+)') { return $Matches[1] }
    return ''
}

$normalized = foreach ($r in $recommendations) {
    # Az.Advisor 3.x は ShortDescriptionProblem / ShortDescriptionSolution / ImpactedField / ImpactedValue がフラットに展開される
    $problem  = $r.ShortDescriptionProblem
    $solution = $r.ShortDescriptionSolution
    # ResourceMetadataResourceId が実リソース ID、ImpactedField がリソースタイプ
    $rid = if ($r.ResourceMetadataResourceId) { $r.ResourceMetadataResourceId } else { $r.Id }
    $rtype = if ($r.ImpactedField) { $r.ImpactedField } else { (Get-ResourceTypeFromId $rid) }
    $rname = if ($r.ImpactedValue) { $r.ImpactedValue } else { (Get-ResourceNameFromId $rid) }
    [pscustomobject]@{
        Category         = $r.Category
        Impact           = $r.Impact
        Risk             = $r.Risk
        Problem          = $problem
        Solution         = $solution
        ImpactedField    = $r.ImpactedField
        ImpactedValue    = $r.ImpactedValue
        ResourceId       = $rid
        ResourceName     = $rname
        ResourceType     = $rtype
        ResourceGroupName= (Get-RgFromId $rid)
        LastUpdated      = $r.LastUpdated
        RecommendationId = $r.Name
        Id               = $r.Id
    }
}

if (-not $normalized) { $normalized = @() }

$csvPath  = Join-Path $OutputDir 'advisor-recommendations.csv'
$jsonPath = Join-Path $OutputDir 'advisor-recommendations.json'

$normalized | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$normalized | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

$cost = @($normalized | Where-Object Category -eq 'Cost').Count
$op   = @($normalized | Where-Object Category -eq 'OperationalExcellence').Count
$perf = @($normalized | Where-Object Category -eq 'Performance').Count
$ha   = @($normalized | Where-Object Category -eq 'HighAvailability').Count
$sec  = @($normalized | Where-Object Category -eq 'Security').Count

Write-Host ''
Write-Host "Advisor 推奨事項: 合計 $($normalized.Count) (Cost $cost / Operational $op / Performance $perf / HA $ha / Security $sec)" -ForegroundColor Green
Write-Host "CSV : $csvPath"  -ForegroundColor Green
Write-Host "JSON: $jsonPath" -ForegroundColor Green

return [pscustomobject]@{
    Total            = $normalized.Count
    CostCount        = $cost
    OperationalCount = $op
    PerformanceCount = $perf
    HACount          = $ha
    SecurityCount    = $sec
    CsvPath          = $csvPath
    JsonPath         = $jsonPath
    Subscription     = $ctx.Subscription.Name
    SubscriptionId   = $ctx.Subscription.Id
}
