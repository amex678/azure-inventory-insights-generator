<#
.SYNOPSIS
    リソース / RBAC / NSG / Defender / Advisor の JSON を統合し、
    レポートの「確定した事実（facts）」を構造化 JSON として出力する。

.DESCRIPTION
    このスクリプトはレポートの数値・スコア・リスク判定を **決定論的に確定** させる責務を持つ。
    ここで出力される facts.json が「唯一の真実（single source of truth）」であり、
    後段の LLM（Copilot Cloud Agent）は facts.json の数値を一切変更せず、
    その事実に基づく文章のみを生成する。CI ゲートは生成物の数値が facts.json 由来かを検証する。

    出力構造:
      meta      : サブスクリプション情報・生成時刻・run_id
      facts     : fact_id(=domain.metric) -> 数値/文字列 のフラットマップ（CI 検証の正）
      scores    : ドメイン別スコアと総合スコア・判定
      kpi       : KPI カード（ラベル/値/単位/severity/補足）
      highlights: concerns / strengths / focus の判定結果（各項目に fact_ids と severity）
      top_risks : 横断リスク候補（severity 付き・fact_ids 付き）
      samples   : リソース名等の untrusted データ（LLM には data として提示、要 HTML escape）
#>
[CmdletBinding()]
param(
    [string]$ResourcesJson = (Join-Path $PSScriptRoot '..\output\resources.json'),
    [string]$RbacJson      = (Join-Path $PSScriptRoot '..\output\rbac.json'),
    [string]$NsgJson       = (Join-Path $PSScriptRoot '..\output\nsg-rules.json'),
    [string]$DefenderJson  = (Join-Path $PSScriptRoot '..\output\defender-recommendations.json'),
    [string]$AdvisorJson   = (Join-Path $PSScriptRoot '..\output\advisor-recommendations.json'),
    [string]$OutputPath    = (Join-Path $PSScriptRoot '..\output\facts.json'),
    [string]$RunId         = $env:GITHUB_RUN_ID
)

$ErrorActionPreference = 'Stop'

function Read-JsonArray([string]$path) {
    if (-not (Test-Path $path)) { return @() }
    $raw = Get-Content -Path $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $data = $raw | ConvertFrom-Json
    if ($null -eq $data) { return @() }
    return @($data)
}

$resources   = Read-JsonArray $ResourcesJson
$assignments = Read-JsonArray $RbacJson
$nsgRules    = Read-JsonArray $NsgJson
$defender    = Read-JsonArray $DefenderJson
$advisor     = Read-JsonArray $AdvisorJson

$ctx = $null
if (Get-Command Get-AzContext -ErrorAction SilentlyContinue) {
    try { $ctx = Get-AzContext } catch { $ctx = $null }
}
$subName   = if ($ctx) { $ctx.Subscription.Name } else { '(unknown)' }
$subId     = if ($ctx) { $ctx.Subscription.Id }   else { '(unknown)' }
$generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$reportDate = (Get-Date).ToString('yyyy-MM-dd')

# ==========================================================================
# ドメイン別 集計（New-AzComprehensiveAdminReport.ps1 の集計式を忠実に移植）
# ==========================================================================

# --- Resources ---
$rTotal = $resources.Count
$rTypes = ($resources | Group-Object ResourceType).Count
$rRGs   = ($resources | Group-Object ResourceGroupName).Count
$rLocs  = ($resources | Group-Object Location).Count
$vmCount   = @($resources | Where-Object ResourceType -eq 'Microsoft.Compute/virtualMachines').Count
$pipCount  = @($resources | Where-Object ResourceType -eq 'Microsoft.Network/publicIPAddresses').Count
$stgCount  = @($resources | Where-Object ResourceType -eq 'Microsoft.Storage/storageAccounts').Count
$lrsStgCount = @($resources | Where-Object { $_.ResourceType -eq 'Microsoft.Storage/storageAccounts' -and $_.Sku -like '*_LRS' }).Count
$untaggedCount = @($resources | Where-Object { [string]::IsNullOrWhiteSpace($_.Tags) }).Count
$tagCoverage   = if ($rTotal -gt 0) { [math]::Round((($rTotal - $untaggedCount) / $rTotal) * 100, 1) } else { 0 }
$rTopType = ($resources | Group-Object ResourceType | Sort-Object Count -Descending | Select-Object -First 1)

# --- RBAC ---
$aTotal   = $assignments.Count
$aOwner   = @($assignments | Where-Object RoleDefinitionName -eq 'Owner').Count
$aUAA     = @($assignments | Where-Object RoleDefinitionName -eq 'User Access Administrator').Count
$aSp      = @($assignments | Where-Object ObjectType -eq 'ServicePrincipal').Count
$aUser    = @($assignments | Where-Object ObjectType -eq 'User').Count
$aOrphan  = @($assignments | Where-Object { [string]::IsNullOrWhiteSpace($_.DisplayName) }).Count
$aMg      = @($assignments | Where-Object ScopeKind -eq 'ManagementGroup').Count
$aOwnerMg = @($assignments | Where-Object { $_.RoleDefinitionName -eq 'Owner' -and $_.ScopeKind -eq 'ManagementGroup' }).Count

# --- NSG ---
$nNsg     = ($nsgRules | Group-Object NsgName).Count
$nRules   = $nsgRules.Count
$nRisky   = @($nsgRules | Where-Object { $_.IsRiskyMgmtFromInternet -eq $true -or $_.IsRiskyMgmtFromInternet -eq 'True' }).Count
$nInAllow = @($nsgRules | Where-Object { $_.Direction -eq 'Inbound' -and $_.Access -eq 'Allow' }).Count
$riskyList = @($nsgRules | Where-Object { $_.IsRiskyMgmtFromInternet -eq $true -or $_.IsRiskyMgmtFromInternet -eq 'True' })

# --- Defender ---
$dTotal      = $defender.Count
$dUn         = @($defender | Where-Object Status -eq 'Unhealthy').Count
$dHealthy    = @($defender | Where-Object Status -eq 'Healthy').Count
$dNotApp     = @($defender | Where-Object Status -eq 'NotApplicable').Count
$dHigh       = @($defender | Where-Object { $_.Status -eq 'Unhealthy' -and $_.Severity -eq 'High' }).Count
$dMed        = @($defender | Where-Object { $_.Status -eq 'Unhealthy' -and $_.Severity -eq 'Medium' }).Count
$dLow        = @($defender | Where-Object { $_.Status -eq 'Unhealthy' -and $_.Severity -eq 'Low' }).Count
$dEvaluated  = $dHealthy + $dUn
$secureScorePct = if ($dEvaluated -gt 0) { [math]::Round(($dHealthy / $dEvaluated) * 100, 1) } else { 0 }

# --- Advisor ---
$advTotal = $advisor.Count
$advCost  = @($advisor | Where-Object Category -eq 'Cost').Count
$advOp    = @($advisor | Where-Object Category -eq 'OperationalExcellence').Count
$advPerf  = @($advisor | Where-Object Category -eq 'Performance').Count
$advHa    = @($advisor | Where-Object Category -eq 'HighAvailability').Count
$advSec   = @($advisor | Where-Object Category -eq 'Security').Count
$advHigh  = @($advisor | Where-Object Impact -eq 'High').Count
$advMed   = @($advisor | Where-Object Impact -eq 'Medium').Count
$advLow   = @($advisor | Where-Object Impact -eq 'Low').Count

# --- 状態フラグ ---
$defenderEnabled  = $dTotal -gt 0
$advisorAvailable = $advTotal -gt 0

# ==========================================================================
# スコア算出（既存式を移植）
# ==========================================================================
$scoreNsg      = if ($nNsg -eq 0) { 50 } elseif ($nRisky -eq 0) { 90 } else { [math]::Max(0, 90 - ($nRisky * 20)) }
$scoreRbac     = [math]::Max(0, 90 - ($aOwnerMg * 15) - ($aOrphan * 5) - ([math]::Max(0, $aOwner - 2) * 3))
$scoreDefender = if (-not $defenderEnabled) { 0 } else { $secureScorePct }
$scoreAdvisor  = if (-not $advisorAvailable) { 50 } else { [math]::Max(0, 100 - ($advHigh * 3)) }
$scoreGov      = $tagCoverage
$overallScore  = [math]::Round((($scoreNsg + $scoreRbac + $scoreDefender + $scoreAdvisor + $scoreGov) / 5), 0)
$verdict = if ($overallScore -ge 75) { 'good' } elseif ($overallScore -ge 50) { 'needs_improvement' } else { 'critical' }
$verdictLabel = switch ($verdict) { 'good' { '良好' } 'needs_improvement' { '要改善' } default { '重大な是正が必要' } }

function Get-Severity([bool]$isHigh, [bool]$isMed) {
    if ($isHigh) { return 'high' } elseif ($isMed) { return 'medium' } else { return 'ok' }
}

# ==========================================================================
# facts: フラットな fact_id -> 値 マップ（CI 検証の正・数値は転記のみ許可）
# ==========================================================================
$facts = [ordered]@{
    'resources.total'          = $rTotal
    'resources.types'          = $rTypes
    'resources.resourceGroups' = $rRGs
    'resources.locations'      = $rLocs
    'resources.vmCount'        = $vmCount
    'resources.publicIpCount'  = $pipCount
    'resources.storageCount'   = $stgCount
    'resources.lrsStorageCount'= $lrsStgCount
    'resources.untaggedCount'  = $untaggedCount
    'resources.tagCoveragePct' = $tagCoverage
    'rbac.total'               = $aTotal
    'rbac.ownerCount'          = $aOwner
    'rbac.uaaCount'            = $aUAA
    'rbac.servicePrincipalCount' = $aSp
    'rbac.userCount'           = $aUser
    'rbac.orphanCount'         = $aOrphan
    'rbac.mgScopeCount'        = $aMg
    'rbac.ownerMgCount'        = $aOwnerMg
    'nsg.nsgCount'             = $nNsg
    'nsg.ruleCount'            = $nRules
    'nsg.riskyCount'           = $nRisky
    'nsg.inboundAllowCount'    = $nInAllow
    'defender.total'           = $dTotal
    'defender.unhealthyCount'  = $dUn
    'defender.healthyCount'    = $dHealthy
    'defender.notApplicableCount' = $dNotApp
    'defender.highCount'       = $dHigh
    'defender.mediumCount'     = $dMed
    'defender.lowCount'        = $dLow
    'defender.evaluatedCount'  = $dEvaluated
    'defender.secureScorePct'  = $secureScorePct
    'advisor.total'            = $advTotal
    'advisor.costCount'        = $advCost
    'advisor.operationalCount' = $advOp
    'advisor.performanceCount' = $advPerf
    'advisor.highAvailabilityCount' = $advHa
    'advisor.securityCount'    = $advSec
    'advisor.highCount'        = $advHigh
    'advisor.mediumCount'      = $advMed
    'advisor.lowCount'         = $advLow
}

# ==========================================================================
# scores
# ==========================================================================
$scores = [ordered]@{
    nsg          = $scoreNsg
    rbac         = $scoreRbac
    defender     = $scoreDefender
    advisor      = $scoreAdvisor
    governance   = $scoreGov
    overall      = $overallScore
    verdict      = $verdict
    verdictLabel = $verdictLabel
}

# ==========================================================================
# kpi カード（値は facts 由来。severity はここで確定）
# ==========================================================================
$kpi = @(
    [ordered]@{ id='overall';     label='総合スコア';   value=$overallScore;   unit='/100'; severity=(Get-Severity ($overallScore -lt 50) ($overallScore -lt 75)); sub=$verdictLabel; fact_id='scores.overall' }
    [ordered]@{ id='riskyNsg';    label='高リスク NSG'; value=$nRisky;         unit='件';   severity=(Get-Severity ($nRisky -gt 0) $false); sub='22/3389 公開'; fact_id='nsg.riskyCount' }
    [ordered]@{ id='owner';       label='Owner 付与';   value=$aOwner;         unit='件';   severity=(Get-Severity ($aOwnerMg -gt 0) ($aOwner -gt 2)); sub="MG スコープ $aOwnerMg"; fact_id='rbac.ownerCount' }
    [ordered]@{ id='secureScore'; label='Secure Score'; value=$secureScorePct; unit='%';    severity=(Get-Severity ($secureScorePct -lt 50) ($secureScorePct -lt 80)); sub="Healthy $dHealthy / $dEvaluated"; fact_id='defender.secureScorePct' }
    [ordered]@{ id='advisorHigh'; label='Advisor High'; value=$advHigh;        unit='件';   severity=(Get-Severity ($advHigh -ge 10) ($advHigh -gt 0)); sub="総 $advTotal 件"; fact_id='advisor.highCount' }
    [ordered]@{ id='tagCoverage'; label='タグ付与率';   value=$tagCoverage;    unit='%';    severity=(Get-Severity ($tagCoverage -lt 50) ($tagCoverage -lt 80)); sub="未付与 $untaggedCount"; fact_id='resources.tagCoveragePct' }
)

# ==========================================================================
# highlights: concerns / strengths / focus（判定フラグ + fact_ids）
# LLM はこれらを根拠に文章化する。各 issue は id で参照可能。
# ==========================================================================
$concerns = @()
if ($nRisky -gt 0)      { $concerns += [ordered]@{ id='concern.riskyNsg';   severity='high';   fact_ids=@('nsg.riskyCount'); topic='公開境界' } }
if ($aOwnerMg -gt 0)    { $concerns += [ordered]@{ id='concern.ownerMg';    severity='high';   fact_ids=@('rbac.ownerMgCount'); topic='特権境界' } }
if ($aOrphan -gt 0)     { $concerns += [ordered]@{ id='concern.orphan';     severity='medium'; fact_ids=@('rbac.orphanCount'); topic='監査追跡性' } }
if ($defenderEnabled -and $dHigh -gt 0) { $concerns += [ordered]@{ id='concern.defenderHigh'; severity='high'; fact_ids=@('defender.highCount','defender.secureScorePct'); topic='セキュリティ態勢' } }
elseif (-not $defenderEnabled)          { $concerns += [ordered]@{ id='concern.defenderMissing'; severity='medium'; fact_ids=@('defender.total'); topic='セキュリティ態勢' } }
if ($advisorAvailable -and $advHigh -gt 0) { $concerns += [ordered]@{ id='concern.advisorHigh'; severity='medium'; fact_ids=@('advisor.highCount','advisor.highAvailabilityCount','advisor.securityCount','advisor.operationalCount'); topic='最適化機会' } }
if ($tagCoverage -lt 80) { $concerns += [ordered]@{ id='concern.tagCoverage'; severity='medium'; fact_ids=@('resources.tagCoveragePct'); topic='ガバナンス' } }
if ($lrsStgCount -gt 0)  { $concerns += [ordered]@{ id='concern.lrsStorage'; severity='medium'; fact_ids=@('resources.storageCount','resources.lrsStorageCount'); topic='可用性' } }

$strengths = @()
if ($nRisky -eq 0 -and $nNsg -gt 0) { $strengths += [ordered]@{ id='strength.noRiskyNsg'; fact_ids=@('nsg.nsgCount','nsg.riskyCount') } }
if ($aOwnerMg -eq 0)                { $strengths += [ordered]@{ id='strength.noOwnerMg'; fact_ids=@('rbac.ownerMgCount') } }
if ($defenderEnabled)               { $strengths += [ordered]@{ id='strength.defenderEnabled'; fact_ids=@('defender.total','defender.highCount','defender.mediumCount','defender.lowCount') } }
if ($advisorAvailable)              { $strengths += [ordered]@{ id='strength.advisorActive'; fact_ids=@('advisor.total') } }
if ($tagCoverage -ge 80)            { $strengths += [ordered]@{ id='strength.tagCoverage'; fact_ids=@('resources.tagCoveragePct') } }
if ($vmCount -le 10)                { $strengths += [ordered]@{ id='strength.smallVmFleet'; fact_ids=@('resources.vmCount') } }

$focus = @()
if ($nRisky -gt 0)                       { $focus += [ordered]@{ id='focus.nsg';      window='Week 1';   fact_ids=@('nsg.riskyCount') } }
if ($aOwnerMg -gt 0 -or $aOrphan -gt 0)  { $focus += [ordered]@{ id='focus.rbac';     window='Week 1-2'; fact_ids=@('rbac.ownerMgCount','rbac.orphanCount') } }
if ($defenderEnabled -and $dHigh -gt 0)  { $focus += [ordered]@{ id='focus.defender'; window='Week 2-3'; fact_ids=@('defender.highCount') } }
if ($advisorAvailable -and $advHigh -gt 0) { $focus += [ordered]@{ id='focus.advisor'; window='Week 3-4'; fact_ids=@('advisor.highCount') } }
if ($tagCoverage -lt 80)                 { $focus += [ordered]@{ id='focus.governance'; window='Week 2-4'; fact_ids=@('resources.tagCoveragePct') } }

$highlights = [ordered]@{
    concerns  = @($concerns)
    strengths = @($strengths)
    focus     = @($focus)
}

# ==========================================================================
# top_risks: 横断リスク候補（severity でソート）
# ==========================================================================
$topRisks = @()
if ($nRisky -gt 0)   { $topRisks += [ordered]@{ id='risk.riskyNsg';     severity='high';   score=100; fact_ids=@('nsg.riskyCount') } }
if ($aOwnerMg -gt 0) { $topRisks += [ordered]@{ id='risk.ownerMg';      severity='high';   score=90;  fact_ids=@('rbac.ownerMgCount') } }
if ($defenderEnabled -and $dHigh -gt 0) { $topRisks += [ordered]@{ id='risk.defenderHigh'; severity='high'; score=80; fact_ids=@('defender.highCount') } }
if ($aOrphan -gt 0)  { $topRisks += [ordered]@{ id='risk.orphan';       severity='medium'; score=60;  fact_ids=@('rbac.orphanCount') } }
if ($advisorAvailable -and $advHigh -gt 0) { $topRisks += [ordered]@{ id='risk.advisorHigh'; severity='medium'; score=50; fact_ids=@('advisor.highCount') } }
if ($lrsStgCount -gt 0) { $topRisks += [ordered]@{ id='risk.lrsStorage'; severity='medium'; score=40; fact_ids=@('resources.lrsStorageCount') } }
if ($tagCoverage -lt 80) { $topRisks += [ordered]@{ id='risk.tagCoverage'; severity='low'; score=30; fact_ids=@('resources.tagCoveragePct') } }
$topRisks = @($topRisks | Sort-Object -Property @{Expression='score';Descending=$true} | Select-Object -First 5)

# ==========================================================================
# samples: untrusted データ（リソース名等）。LLM には data として提示し、
# renderer / CI で必ず HTML escape する。数値検証の対象外。
# ==========================================================================
$rTopTypeName = if ($rTopType) { $rTopType.Name } else { $null }
$rTopTypeCount = if ($rTopType) { $rTopType.Count } else { 0 }
$riskyNsgSamples = @($riskyList | Select-Object -First 3 | ForEach-Object {
    [ordered]@{ nsg = [string]$_.NsgName; rule = [string]$_.RuleName }
})
$samples = [ordered]@{
    topResourceType = [ordered]@{ name = $rTopTypeName; count = $rTopTypeCount }
    riskyNsgRules   = @($riskyNsgSamples)
}

# ==========================================================================
# 出力
# ==========================================================================
$factsDoc = [ordered]@{
    meta = [ordered]@{
        subscriptionName = $subName
        subscriptionId   = $subId
        generatedAt      = $generated
        reportDate       = $reportDate
        runId            = if ($RunId) { [string]$RunId } else { $null }
        schemaVersion    = 1
    }
    facts      = $facts
    scores     = $scores
    kpi        = @($kpi)
    highlights = $highlights
    topRisks   = @($topRisks)
    samples    = $samples
}

$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$factsDoc | ConvertTo-Json -Depth 12 | Out-File -FilePath $OutputPath -Encoding UTF8

Write-Host "facts.json を出力しました: $OutputPath" -ForegroundColor Green
Write-Host "  総合スコア: $overallScore / 100 ($verdictLabel)" -ForegroundColor Cyan
Write-Host "  fact 件数: $($facts.Count) / concerns: $($concerns.Count) / topRisks: $($topRisks.Count)" -ForegroundColor Cyan

return $factsDoc
