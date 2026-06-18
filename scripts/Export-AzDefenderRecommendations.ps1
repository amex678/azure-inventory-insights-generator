<#
.SYNOPSIS
    Microsoft Defender for Cloud のセキュリティ推奨事項を CSV/JSON で出力する。

.DESCRIPTION
    Az.Security の Get-AzSecurityAssessment / Get-AzSecurityTask があるが、ここでは
    REST API (Microsoft.Security/assessments) を直接呼び出してより安定した結果を取得する。
    Defender for Cloud が未有効、または推奨事項が存在しない場合は空配列を出力する。
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

$subId   = $ctx.Subscription.Id
$subName = $ctx.Subscription.Name
Write-Host "サブスクリプション: $subName ($subId)" -ForegroundColor Cyan
Write-Host 'Defender for Cloud 推奨事項を取得中...' -ForegroundColor Yellow

# Microsoft.Security/assessments を REST API で列挙
# $expand=metadata を付けないと severity / categories / description が空になる
$path = "/subscriptions/$subId/providers/Microsoft.Security/assessments?api-version=2021-06-01&`$expand=metadata"

$assessments = @()
try {
    $next = $path
    while ($next) {
        $resp = Invoke-AzRestMethod -Method GET -Path $next
        if ($resp.StatusCode -ne 200) {
            Write-Warning "Microsoft.Security/assessments の取得に失敗 (Status=$($resp.StatusCode))。Defender for Cloud が無効の可能性があります。"
            break
        }
        $body = $resp.Content | ConvertFrom-Json
        if ($body.value) { $assessments += $body.value }
        if ($body.nextLink) {
            $uri = [Uri]$body.nextLink
            $next = $uri.PathAndQuery
        } else {
            $next = $null
        }
    }
} catch {
    Write-Warning "Defender for Cloud 推奨事項の取得中にエラー: $($_.Exception.Message)"
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

$normalized = foreach ($a in $assessments) {
    $props = $a.properties
    $meta  = $props.metadata
    # resourceDetails の Id (PascalCase) / id (camelCase) どちらも来る場合がある
    $rid   = if ($props.resourceDetails) {
        if ($props.resourceDetails.Id) { $props.resourceDetails.Id } else { $props.resourceDetails.id }
    } else { '' }
    $sev    = if ($meta) { $meta.severity }                 else { '' }
    $sc     = if ($meta -and $meta.securityCategories)  { ($meta.securityCategories -join ',') } else { '' }
    $rcat   = if ($meta) { $meta.recommendationCategory }   else { '' }
    $sissue = if ($meta) { $meta.securityIssue }            else { '' }
    $desc   = if ($meta) { $meta.description }              else { '' }
    $remed  = if ($meta) { $meta.remediationDescription }   else { '' }

    [pscustomobject]@{
        AssessmentName         = $a.name
        DisplayName            = $props.displayName
        Severity               = $sev
        Status                 = $props.status.code
        StatusCause            = $props.status.cause
        StatusDescription      = $props.status.description
        SecurityIssue          = $sissue
        SecurityCategories     = $sc
        RecommendationCategory = $rcat
        Description            = $desc
        Remediation            = $remed
        ResourceId             = $rid
        ResourceName           = (Get-ResourceNameFromId $rid)
        ResourceType           = (Get-ResourceTypeFromId $rid)
        ResourceGroupName      = (Get-RgFromId $rid)
        AssessmentId           = $a.id
    }
}

if (-not $normalized) { $normalized = @() }

$csvPath  = Join-Path $OutputDir 'defender-recommendations.csv'
$jsonPath = Join-Path $OutputDir 'defender-recommendations.json'

$normalized | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$normalized | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

$unhealthy = @($normalized | Where-Object Status -eq 'Unhealthy').Count
$healthy   = @($normalized | Where-Object Status -eq 'Healthy').Count

Write-Host ''
Write-Host "Defender 推奨事項: 合計 $($normalized.Count) ／ Unhealthy $unhealthy ／ Healthy $healthy" -ForegroundColor Green
Write-Host "CSV : $csvPath"  -ForegroundColor Green
Write-Host "JSON: $jsonPath" -ForegroundColor Green

return [pscustomobject]@{
    Total          = $normalized.Count
    Unhealthy      = $unhealthy
    Healthy        = $healthy
    CsvPath        = $csvPath
    JsonPath       = $jsonPath
    Subscription   = $subName
    SubscriptionId = $subId
}
