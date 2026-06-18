<#
.SYNOPSIS
    現在のAzureサブスクリプションのリソース一覧をCSVおよびJSON形式で出力する。

.DESCRIPTION
    Get-AzResource を用いてリソース情報を取得し、出力ディレクトリにCSV/JSON両形式で保存する。
#>
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\output')
)

$ErrorActionPreference = 'Stop'

# 出力ディレクトリ準備
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
$OutputDir = (Resolve-Path $OutputDir).Path

# コンテキスト確認
$ctx = Get-AzContext
if ($null -eq $ctx) {
    throw 'Azureにサインインしていません。先に Connect-AzAccount を実行してください。'
}

Write-Host "サブスクリプション: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -ForegroundColor Cyan

# リソース取得
Write-Host 'リソース一覧を取得中...' -ForegroundColor Yellow
$resources = Get-AzResource

# 整形
$normalized = $resources | ForEach-Object {
    [pscustomobject]@{
        Name              = $_.Name
        ResourceType      = $_.ResourceType
        ResourceGroupName = $_.ResourceGroupName
        Location          = $_.Location
        SubscriptionId    = $_.SubscriptionId
        Sku               = if ($_.Sku) { $_.Sku.Name } else { $null }
        Kind              = $_.Kind
        Tags              = if ($_.Tags) { ($_.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';' } else { '' }
        ResourceId        = $_.ResourceId
    }
}

# 出力
$csvPath  = Join-Path $OutputDir 'resources.csv'
$jsonPath = Join-Path $OutputDir 'resources.json'

$normalized | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$normalized | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

Write-Host ''
Write-Host "リソース件数: $($normalized.Count)" -ForegroundColor Green
Write-Host "CSV : $csvPath" -ForegroundColor Green
Write-Host "JSON: $jsonPath" -ForegroundColor Green

# 後続スクリプトのために返す
return [pscustomobject]@{
    Count          = $normalized.Count
    CsvPath        = $csvPath
    JsonPath       = $jsonPath
    Subscription   = $ctx.Subscription.Name
    SubscriptionId = $ctx.Subscription.Id
}
