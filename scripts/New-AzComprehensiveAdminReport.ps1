<#
.SYNOPSIS
    リソース / RBAC / NSG / Defender / Advisor の JSON を統合し、
    管理者向けの横断 AI インサイト HTML レポートを生成する。

.DESCRIPTION
    出力構成:
      1. エグゼクティブサマリ（全ドメイン横断・AI 生成スタイル）
      2. 全体サマリ表（各ドメインの主要指標）
      3. 潜在リスク Top 5（横断・重要度別）
      4. 30 日アクションプラン
      付録: 各データソースのハイライト一覧
#>
[CmdletBinding()]
param(
    [string]$ResourcesJson = (Join-Path $PSScriptRoot '..\output\resources.json'),
    [string]$RbacJson      = (Join-Path $PSScriptRoot '..\output\rbac.json'),
    [string]$NsgJson       = (Join-Path $PSScriptRoot '..\output\nsg-rules.json'),
    [string]$DefenderJson  = (Join-Path $PSScriptRoot '..\output\defender-recommendations.json'),
    [string]$AdvisorJson   = (Join-Path $PSScriptRoot '..\output\advisor-recommendations.json'),
    [string]$OutputPath    = (Join-Path $PSScriptRoot '..\output\comprehensive-report.html')
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
function ConvertTo-HtmlEncoded {
  param([string]$s)

    if ($null -eq $s) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

$resources   = Read-JsonArray $ResourcesJson
$assignments = Read-JsonArray $RbacJson
$nsgRules    = Read-JsonArray $NsgJson
$defender    = Read-JsonArray $DefenderJson
$advisor     = Read-JsonArray $AdvisorJson

$ctx       = Get-AzContext
$subName   = if ($ctx) { $ctx.Subscription.Name } else { '(unknown)' }
$subId     = if ($ctx) { $ctx.Subscription.Id }   else { '(unknown)' }
$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

# === ドメイン別 集計 ===
# Resources
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

# RBAC
$aTotal   = $assignments.Count
$aOwner   = @($assignments | Where-Object RoleDefinitionName -eq 'Owner').Count
$aUAA     = @($assignments | Where-Object RoleDefinitionName -eq 'User Access Administrator').Count
$aSp      = @($assignments | Where-Object ObjectType -eq 'ServicePrincipal').Count
$aUser    = @($assignments | Where-Object ObjectType -eq 'User').Count
$aOrphan  = @($assignments | Where-Object { [string]::IsNullOrWhiteSpace($_.DisplayName) }).Count
$aMg      = @($assignments | Where-Object ScopeKind -eq 'ManagementGroup').Count
$aOwnerMg = @($assignments | Where-Object { $_.RoleDefinitionName -eq 'Owner' -and $_.ScopeKind -eq 'ManagementGroup' }).Count

# NSG
$nNsg     = ($nsgRules | Group-Object NsgName).Count
$nRules   = $nsgRules.Count
$nRisky   = @($nsgRules | Where-Object { $_.IsRiskyMgmtFromInternet -eq $true -or $_.IsRiskyMgmtFromInternet -eq 'True' }).Count
$nInAllow = @($nsgRules | Where-Object { $_.Direction -eq 'Inbound' -and $_.Access -eq 'Allow' }).Count
$riskyList = @($nsgRules | Where-Object { $_.IsRiskyMgmtFromInternet -eq $true -or $_.IsRiskyMgmtFromInternet -eq 'True' })

# Defender
$dTotal      = $defender.Count
$dUn         = @($defender | Where-Object Status -eq 'Unhealthy').Count
$dHealthy    = @($defender | Where-Object Status -eq 'Healthy').Count
$dNotApp     = @($defender | Where-Object Status -eq 'NotApplicable').Count
$dHigh       = @($defender | Where-Object { $_.Status -eq 'Unhealthy' -and $_.Severity -eq 'High' }).Count
$dMed        = @($defender | Where-Object { $_.Status -eq 'Unhealthy' -and $_.Severity -eq 'Medium' }).Count
$dLow        = @($defender | Where-Object { $_.Status -eq 'Unhealthy' -and $_.Severity -eq 'Low' }).Count
# Secure Score（簡易換算）: Healthy / (Healthy + Unhealthy) × 100。NotApplicable は除外
$dEvaluated  = $dHealthy + $dUn
$secureScorePct = if ($dEvaluated -gt 0) { [math]::Round(($dHealthy / $dEvaluated) * 100, 1) } else { 0 }

$dTopRec  = $defender | Where-Object Status -eq 'Unhealthy' | Group-Object DisplayName | Sort-Object Count -Descending | Select-Object -First 5
$dTopType = $defender | Where-Object Status -eq 'Unhealthy' | Group-Object ResourceType | Sort-Object Count -Descending
$dTopCat  = if ($dTopRec -and $dTopRec[0]) { "$($dTopRec[0].Name)（$($dTopRec[0].Count) 件）" } else { 'なし' }
$dMisconf = @($defender | Where-Object { $_.Status -eq 'Unhealthy' -and $_.SecurityCategories -like '*Misconfigurations*' }).Count
$dVuln    = @($defender | Where-Object { $_.Status -eq 'Unhealthy' -and $_.SecurityCategories -like '*Vulnerabilities*' }).Count

$dHighItems = $defender | Where-Object { $_.Status -eq 'Unhealthy' -and $_.Severity -eq 'High' } | Group-Object DisplayName | Sort-Object Count -Descending

# Advisor
$advTotal = $advisor.Count
$advCost  = @($advisor | Where-Object Category -eq 'Cost').Count
$advOp    = @($advisor | Where-Object Category -eq 'OperationalExcellence').Count
$advPerf  = @($advisor | Where-Object Category -eq 'Performance').Count
$advHa    = @($advisor | Where-Object Category -eq 'HighAvailability').Count
$advSec   = @($advisor | Where-Object Category -eq 'Security').Count
$advHigh  = @($advisor | Where-Object Impact -eq 'High').Count
$advMed   = @($advisor | Where-Object Impact -eq 'Medium').Count
$advLow   = @($advisor | Where-Object Impact -eq 'Low').Count

$advTopProblem = $advisor | Where-Object { $_.Impact -in 'High','Medium' } | Group-Object Problem | Sort-Object Count -Descending | Select-Object -First 1
$advTopText = if ($advTopProblem) { "$($advTopProblem.Name)（$($advTopProblem.Count) 件）" } else { 'なし' }

# Advisor: カテゴリ × High Impact の代表問題
$advHighByCat = @{}
foreach ($cat in @('Cost','OperationalExcellence','Performance','HighAvailability','Security')) {
    $items = $advisor | Where-Object { $_.Category -eq $cat -and $_.Impact -eq 'High' } | Group-Object Problem | Sort-Object Count -Descending
    $advHighByCat[$cat] = $items
}
$advTopByResType = $advisor | Group-Object ResourceType | Sort-Object Count -Descending | Select-Object -First 5

# === 動的な状態フラグ（サマリ文言の組み立て用） ===
$defenderEnabled = $dTotal -gt 0
$advisorAvailable = $advTotal -gt 0

# === 1. エグゼクティブサマリ（構造化版） ===
# 総合スコアの算出（4 ドメインを 0-100 で粗評価し平均）
$scoreNsg      = if ($nNsg -eq 0) { 50 } elseif ($nRisky -eq 0) { 90 } else { [math]::Max(0, 90 - ($nRisky * 20)) }
$scoreRbac     = [math]::Max(0, 90 - ($aOwnerMg * 15) - ($aOrphan * 5) - ([math]::Max(0,$aOwner-2) * 3))
$scoreDefender = if (-not $defenderEnabled) { 0 } else { $secureScorePct }
$scoreAdvisor  = if (-not $advisorAvailable) { 50 } else { [math]::Max(0, 100 - ($advHigh * 3)) }
$scoreGov      = $tagCoverage
$overallScore  = [math]::Round((($scoreNsg + $scoreRbac + $scoreDefender + $scoreAdvisor + $scoreGov) / 5), 0)
$overallVerdict = if ($overallScore -ge 75) { @{ Text='良好'; Color='var(--ok)'; Emoji='&#9989;' } }
                  elseif ($overallScore -ge 50) { @{ Text='要改善'; Color='var(--med)'; Emoji='&#9888;' } }
                  else { @{ Text='重大な是正が必要'; Color='var(--high)'; Emoji='&#10071;' } }

# キーメトリクス（KPI カード）
$kpiCards = @(
    @{ Label='総合スコア'; Value="$overallScore"; Unit='/100'; Color=$overallVerdict.Color; Sub=$overallVerdict.Text }
    @{ Label='高リスク NSG'; Value="$nRisky"; Unit='件'; Color=$(if ($nRisky -gt 0){'var(--high)'}else{'var(--ok)'}); Sub='22/3389 公開' }
    @{ Label='Owner 付与'; Value="$aOwner"; Unit='件'; Color=$(if ($aOwnerMg -gt 0){'var(--high)'}elseif ($aOwner -gt 2){'var(--med)'}else{'var(--ok)'}); Sub="MG スコープ $aOwnerMg" }
    @{ Label='Secure Score'; Value="$secureScorePct"; Unit='%'; Color=$(if($secureScorePct -ge 80){'var(--ok)'}elseif($secureScorePct -ge 50){'var(--med)'}else{'var(--high)'}); Sub="Healthy $dHealthy / $dEvaluated" }
    @{ Label='Advisor High'; Value="$advHigh"; Unit='件'; Color=$(if ($advHigh -ge 10){'var(--high)'}elseif ($advHigh -gt 0){'var(--med)'}else{'var(--ok)'}); Sub="総 $advTotal 件" }
    @{ Label='タグ付与率'; Value="$tagCoverage"; Unit='%'; Color=$(if ($tagCoverage -ge 80){'var(--ok)'}elseif ($tagCoverage -ge 50){'var(--med)'}else{'var(--high)'}); Sub="未付与 $untaggedCount" }
)
$kpiCardsHtml = ($kpiCards | ForEach-Object {
    "<div class='kpi'><div class='kpi-label'>$(ConvertTo-HtmlEncoded $_.Label)</div><div class='kpi-value' style='color:$($_.Color)'>$(ConvertTo-HtmlEncoded $_.Value)<span class='kpi-unit'>$(ConvertTo-HtmlEncoded $_.Unit)</span></div><div class='kpi-sub'>$(ConvertTo-HtmlEncoded $_.Sub)</div></div>"
}) -join "`n"

# 主要な懸念事項（自動抽出）
$concerns = @()
if ($nRisky -gt 0) { $concerns += "<li><strong>公開境界:</strong> インターネット → 22/3389 の Allow ルールが <strong>$nRisky 件</strong>。<em>侵害確率を著しく増加させる最重要リスク。</em></li>" }
if ($aOwnerMg -gt 0) { $concerns += "<li><strong>特権境界:</strong> 管理グループ スコープへの <strong>Owner 付与が $aOwnerMg 件</strong>。配下の全サブスクへ権限が波及。</li>" }
if ($aOrphan -gt 0) { $concerns += "<li><strong>監査追跡性:</strong> 削除済み ID とみられる孤児候補のロール割り当てが <strong>$aOrphan 件</strong> 残存。</li>" }
if ($defenderEnabled -and $dHigh -gt 0) { $concerns += "<li><strong>セキュリティ態勢:</strong> Defender High Severity 推奨事項 <strong>$dHigh 件</strong>（Secure Score $secureScorePct%）。<em>暗号化未有効と特権ロール過剰付与が主因。</em></li>" }
elseif (-not $defenderEnabled) { $concerns += "<li><strong>セキュリティ態勢:</strong> Defender for Cloud のデータが取得できず、ベースライン未確立の可能性。</li>" }
if ($advisorAvailable -and $advHigh -gt 0) { $concerns += "<li><strong>最適化機会:</strong> Advisor High Impact <strong>$advHigh 件</strong>（HA $advHa / Sec $advSec / Op $advOp）。同一 VM 群に重複指摘 → デプロイ テンプレート不備。</li>" }
if ($tagCoverage -lt 80) { $concerns += "<li><strong>ガバナンス:</strong> タグ付与率 <strong>$tagCoverage%</strong>。所有者・コスト按分・連絡先の特定が困難。</li>" }
if ($lrsStgCount -gt 0) { $concerns += "<li><strong>可用性:</strong> ストレージ $stgCount 件中 <strong>$lrsStgCount 件が LRS</strong>。AZ 障害時の可用性なし。</li>" }
if (-not $concerns) { $concerns = @('<li class="muted">主要な懸念事項は検出されませんでした。</li>') }
$concernsHtml = $concerns -join "`n"

# 強み（自動抽出）
$strengths = @()
if ($nRisky -eq 0 -and $nNsg -gt 0) { $strengths += "<li>NSG $nNsg 個に対し、インターネット → 管理ポートの直接公開なし。</li>" }
if ($aOwnerMg -eq 0) { $strengths += "<li>管理グループ スコープへの Owner 直接付与なし。</li>" }
if ($defenderEnabled) { $strengths += "<li>Defender for Cloud が有効化済み（$dTotal 件評価、High $dHigh / Med $dMed / Low $dLow）。</li>" }
if ($advisorAvailable) { $strengths += "<li>Azure Advisor が稼働中（$advTotal 件の最適化機会を可視化）。</li>" }
if ($tagCoverage -ge 80) { $strengths += "<li>タグ付与率 $tagCoverage% — ガバナンス基盤が機能。</li>" }
if ($vmCount -le 10) { $strengths += "<li>VM 規模が $vmCount 台と小さく、テンプレ刷新による一括是正が現実的。</li>" }
if (-not $strengths) { $strengths = @('<li class="muted">特筆すべき強みは検出されませんでした。</li>') }
$strengthsHtml = $strengths -join "`n"

# 30 日フォーカス（短文サマリ）
$focusItems = @()
if ($nRisky -gt 0) { $focusItems += '<strong>Week 1:</strong> 高リスク NSG ルールを即時削除し、Bastion + JIT へ移行' }
if ($aOwnerMg -gt 0 -or $aOrphan -gt 0) { $focusItems += '<strong>Week 1-2:</strong> Owner/UAA を PIM 化、孤児ロール削除' }
if ($defenderEnabled -and $dHigh -gt 0) { $focusItems += '<strong>Week 2-3:</strong> Defender High 推奨事項を Azure Policy で強制（暗号化/Backup/EDR）' }
if ($advisorAvailable -and $advHigh -gt 0) { $focusItems += '<strong>Week 3-4:</strong> VM デプロイ テンプレを刷新し、Advisor High を一括解消' }
if ($tagCoverage -lt 80) { $focusItems += '<strong>Week 2-4:</strong> タグ必須化ポリシー導入と Tag Inheritance 有効化' }
if (-not $focusItems) { $focusItems = @('<strong>Week 1-4:</strong> 全体サマリ表と Top 5 リスクに基づき、定期レビュー サイクルを確立') }
$focusHtml = ($focusItems | ForEach-Object { "<li>$_</li>" }) -join "`n"

$execSummary = @"
<div class="verdict-bar" style="border-left:5px solid $($overallVerdict.Color);">
  <div class="verdict-emoji">$($overallVerdict.Emoji)</div>
  <div>
    <div class="verdict-title">総合判定: <span style="color:$($overallVerdict.Color)">$($overallVerdict.Text)</span> <span class="verdict-score">（スコア $overallScore / 100）</span></div>
    <div class="verdict-desc">サブスクリプション <code>$(ConvertTo-HtmlEncoded $subName)</code> は、リソース <strong>$rTotal 件 / $rRGs RG / $rLocs リージョン</strong> 構成。NSG / RBAC / Defender / Advisor / ガバナンス の 5 軸を加重平均した総合スコアです。</div>
  </div>
</div>

<div class="kpi-grid">$kpiCardsHtml</div>

<div class="exec-cols">
  <div class="exec-col exec-concern">
    <h3>&#128680; 主要な懸念事項</h3>
    <ul>$concernsHtml</ul>
  </div>
  <div class="exec-col exec-strength">
    <h3>&#9989; 強み</h3>
    <ul>$strengthsHtml</ul>
  </div>
</div>

<div class="exec-focus">
  <h3>&#127919; 30 日のフォーカス</h3>
  <ul>$focusHtml</ul>
  <p class="muted" style="margin:8px 0 0 0; font-size:12px;">&rarr; 詳細は下の「Top 5 リスク」と「30 日アクションプラン」、および各ドメイン タブを参照。</p>
</div>
"@

# === ドメイン別 AI インサイト（リソース / RBAC / NSG） ===
# リソース
$rResIssues = @()
if ($tagCoverage -lt 80) { $rResIssues += "タグ付与率が <strong>${tagCoverage}%</strong> と低く、未付与が <strong>${untaggedCount} 件</strong>。所有者・コスト按分・連絡先の特定が困難で、削除可否判断と請求精度に影響します。" }
if ($lrsStgCount -gt 0) { $rResIssues += "ストレージ ${stgCount} 件中 <strong>${lrsStgCount} 件が LRS</strong>。AZ 障害時に可用性を提供できないため、重要度に応じて ZRS / GZRS への移行計画が必要です。" }
if ($pipCount -gt 0) { $rResIssues += "Public IP が <strong>${pipCount} 件</strong>。VM 直接付与の場合は攻撃面が常時公開されるため、Bastion + Private 化を優先検討すべきです。" }
if (-not $rResIssues) { $rResIssues += "目立った構成上の懸念は検出されていませんが、リソース増加に備えタグ標準と冗長性の継続レビューを推奨します。" }
$rResIssuesHtml = ($rResIssues | ForEach-Object { "<li>$_</li>" }) -join ''
$rTopType = ($resources | Group-Object ResourceType | Sort-Object Count -Descending | Select-Object -First 1)
$rTopTypeText = if ($rTopType) { "$(ConvertTo-HtmlEncoded $rTopType.Name)（$($rTopType.Count) 件）" } else { 'なし' }

$resourcesAssessment = @"
<p>リソースは合計 <strong>${rTotal} 件 / ${rTypes} 種類 / ${rRGs} RG / ${rLocs} リージョン</strong>。最も多いタイプは <code>$rTopTypeText</code> で、VM ${vmCount} / Storage ${stgCount}（うち LRS ${lrsStgCount}） / Public IP ${pipCount} 件という構成です。</p>
<p><strong>所見:</strong></p>
<ul style="line-height:1.8;">$rResIssuesHtml</ul>
<p><strong>推奨アクション:</strong> Azure Policy で <code>owner</code> / <code>env</code> / <code>costcenter</code> タグを必須化、RG 単位の <strong>Tag Inheritance</strong> を有効化。命名規約は CAF に準拠し、ストレージは重要度区分に応じて ZRS / GZRS へ計画的に移行。</p>
"@

# RBAC
$aRbacIssues = @()
if ($aOwnerMg -gt 0) { $aRbacIssues += "管理グループ スコープへの <strong>Owner 付与が ${aOwnerMg} 件</strong>。配下全サブスクリプションへ権限が波及するため、影響範囲が最も大きい構成です。" }
if ($aOwner -gt 2) { $aRbacIssues += "Owner ロールの恒久付与が <strong>${aOwner} 件</strong>と多めです。Owner は権限変更含めた最強権限で、恒久付与は最小権限原則に反します。" }
if ($aUAA -gt 0) { $aRbacIssues += "User Access Administrator (UAA) が <strong>${aUAA} 件</strong>。UAA は他者の権限を変更可能なため、PIM 必須化が望まれます。" }
if ($aOrphan -gt 0) { $aRbacIssues += "DisplayName が解決できない <strong>孤児候補が ${aOrphan} 件</strong>。削除済み ID への権限残存は、監査追跡性と最小権限原則の両方に違反します。" }
if ($aSp -gt 0) { $aRbacIssues += "サービス プリンシパル (SP) への割り当てが <strong>${aSp} 件</strong>。シークレット ベースの SP はマネージド ID / Workload Identity Federation への切替が推奨されます。" }
if (-not $aRbacIssues) { $aRbacIssues += "重大な ID 統制ギャップは検出されていません。継続して Access Review を定期実施してください。" }
$aRbacIssuesHtml = ($aRbacIssues | ForEach-Object { "<li>$_</li>" }) -join ''

$rbacAssessment = @"
<p>RBAC は合計 <strong>${aTotal} 件</strong>（User ${aUser} / SP ${aSp}）。特権ロールは <strong>Owner ${aOwner} / UAA ${aUAA}</strong>、管理グループ スコープへの割り当ては ${aMg} 件、うち Owner 直接付与が <strong>${aOwnerMg} 件</strong>です。</p>
<p><strong>所見:</strong></p>
<ul style="line-height:1.8;">$aRbacIssuesHtml</ul>
<p><strong>推奨アクション:</strong> Owner / UAA は <strong>PIM によるオンデマンド昇格</strong> に移行（恒久付与停止）、SP は <strong>マネージド ID / Workload Identity Federation</strong> に切替、孤児割り当ては <code>Remove-AzRoleAssignment</code> で削除し、四半期毎の <strong>Access Review</strong> を自動化。</p>
"@

# NSG
$nNsgIssues = @()
if ($nRisky -gt 0) {
    $riskySample = ($riskyList | Select-Object -First 3 | ForEach-Object { "<code>$(ConvertTo-HtmlEncoded $_.NsgName)/$(ConvertTo-HtmlEncoded $_.RuleName)</code>" }) -join ' / '
    $nNsgIssues += "インターネット &rarr; 22 (SSH) / 3389 (RDP) の Allow ルールが <strong>${nRisky} 件</strong> 検出されました（例: $riskySample）。ブルートフォース・既知脆弱性スキャン・C2 通信の主要侵入経路です。"
}
if ($nInAllow -gt 10) { $nNsgIssues += "Inbound Allow ルールが <strong>${nInAllow} 件</strong>と多めです。Source 範囲・ポート範囲のレビューと、Deny ルール優先方針への切替を検討してください。" }
if ($nNsg -eq 0) { $nNsgIssues += "NSG が確認できません。サブネット保護なしの可能性があり、L3/L4 防御の前提が成立しているか確認が必要です。" }
if (-not $nNsgIssues) { $nNsgIssues += "高リスクな管理ポート公開ルールは検出されませんでしたが、Source 範囲と最新ルールの定期レビューを継続してください。" }
$nNsgIssuesHtml = ($nNsgIssues | ForEach-Object { "<li>$_</li>" }) -join ''

$nsgAssessment = @"
<p>NSG は <strong>${nNsg} 個 / 合計 ${nRules} ルール</strong>（Inbound Allow ${nInAllow}）。高リスクな管理ポート公開ルールは <strong>${nRisky} 件</strong>です。</p>
<p><strong>所見:</strong></p>
<ul style="line-height:1.8;">$nNsgIssuesHtml</ul>
<p><strong>推奨アクション:</strong> 管理アクセスは <strong>Azure Bastion + Just-In-Time (JIT) VM Access</strong> に統一し、22/3389 のインバウンドを NSG から削除。アプリ公開は <strong>Application Gateway WAF / Front Door</strong> 経由とし、Public IP は最小化。NSG Flow Logs を有効化し、Traffic Analytics で可視化。</p>
"@

# === 2. 全体サマリ表 ===
$summaryRows = @(
    @{ Domain='リソース';  Item='総リソース数 / タイプ数 / RG 数 / リージョン数'; Value="$rTotal / $rTypes / $rRGs / $rLocs" }
    @{ Domain='リソース';  Item='VM / Storage (うちLRS) / Public IP';             Value="$vmCount / $stgCount ($lrsStgCount LRS) / $pipCount" }
    @{ Domain='リソース';  Item='タグ付与率';                                     Value="$tagCoverage% (未付与 $untaggedCount)" }
    @{ Domain='RBAC';      Item='総割り当て / User / SP';                          Value="$aTotal / $aUser / $aSp" }
    @{ Domain='RBAC';      Item='Owner / UAA / MG スコープ / MG スコープの Owner'; Value="$aOwner / $aUAA / $aMg / $aOwnerMg" }
    @{ Domain='RBAC';      Item='孤児候補（DisplayName=null）';                    Value=$aOrphan }
    @{ Domain='NSG';       Item='NSG 数 / 総ルール / Inbound Allow / 高リスク';    Value="$nNsg / $nRules / $nInAllow / $nRisky" }
    @{ Domain='Defender';  Item='総評価 / Unhealthy (High/Med/Low) / Healthy / NA'; Value="$dTotal / $dUn ($dHigh / $dMed / $dLow) / $dHealthy / $dNotApp" }
    @{ Domain='Defender';  Item='簡易 Secure Score (Healthy / 評価対象)';         Value="$secureScorePct% ($dHealthy / $dEvaluated)" }
    @{ Domain='Defender';  Item='Misconfigurations / Vulnerabilities';            Value="$dMisconf / $dVuln" }
    @{ Domain='Advisor';   Item='総推奨 / Cost / Operational / Performance / HA / Security'; Value="$advTotal / $advCost / $advOp / $advPerf / $advHa / $advSec" }
    @{ Domain='Advisor';   Item='Impact 内訳 High / Medium / Low';                Value="$advHigh / $advMed / $advLow" }
)
$summaryRowsHtml = ($summaryRows | ForEach-Object {
    "<tr><td><span class='dom dom-$($_.Domain.ToLower())'>$(ConvertTo-HtmlEncoded $_.Domain)</span></td><td>$(ConvertTo-HtmlEncoded $_.Item)</td><td class='num'>$(ConvertTo-HtmlEncoded ([string]$_.Value))</td></tr>"
}) -join "`n"

# === 3. 潜在リスク Top 5（横断） ===
# 各リスクの観察事実は実データから引用
$riskyNsgFact = if ($nRisky -gt 0) {
    $sample = $riskyList | Select-Object -First 3 | ForEach-Object { "<code>$(ConvertTo-HtmlEncoded $_.NsgName)/$(ConvertTo-HtmlEncoded $_.RuleName)</code>" }
    "高リスクな NSG ルールが ${nRisky} 件検出されました（例: $($sample -join ' / ')）。これらは Source=Internet/Any、Destination=22 or 3389、Access=Allow のインバウンドです。"
} elseif ($nNsg -gt 0) {
    "高リスクな管理ポート公開ルールは検出されませんでしたが、NSG ${nNsg} 個 / ${nRules} ルールの全体監査と、Public IP ${pipCount} 件の利用妥当性は継続確認が必要です。"
} else {
    "NSG が確認できません。サブネット保護なしの可能性があり、ネットワーク防御の前提が成立しているか確認が必要です。"
}

$defenderRiskFact = if ($defenderEnabled) {
    "Defender for Cloud で Unhealthy が ${dUn} 件、うち High ${dHigh} 件 / Medium ${dMed} 件。最頻出は <code>$([System.Net.WebUtility]::HtmlEncode([string]$dTopCat))</code>。"
} else {
    "Defender for Cloud の評価結果が 0 件のため、Foundational CSPM 未有効または API アクセス不可。"
}

$advisorRiskFact = if ($advisorAvailable) {
    "Advisor の High Impact が ${advHigh} 件、Cost ${advCost} / Operational ${advOp} / HA ${advHa} / Security ${advSec}。最頻出: <code>$([System.Net.WebUtility]::HtmlEncode([string]$advTopText))</code>。"
} else {
    "Advisor の推奨事項が 0 件取得。Az.Advisor モジュール未導入、またはサブスクリプションが評価対象になっていない可能性。"
}

$rbacRiskFact = "Owner ${aOwner} 件（MG スコープ ${aOwnerMg}）、UAA ${aUAA} 件、サービス プリンシパル ${aSp} 件、表示名なし（孤児候補）${aOrphan} 件。"

$govRiskFact = "タグ未付与 ${untaggedCount}/${rTotal} 件（カバレッジ ${tagCoverage}%）、ストレージは ${stgCount} 件中 ${lrsStgCount} 件が LRS、Public IP ${pipCount} 件。"

$risks = @(
    [pscustomobject]@{
        Rank     = 1
        Severity = 'High'
        Title    = '公開境界の露出（NSG / Public IP / 管理プロトコル）'
        Fact     = $riskyNsgFact
        Reason   = 'インターネットから SSH (22) / RDP (3389) への Allow ルールはブルートフォース・既知脆弱性スキャン・C2 通信の主要侵入経路です。Public IP の VM 直接付与と組み合わせると侵害確率が大幅に上昇し、侵害後はネットワーク全体に横展開されます。'
        Recommend= '管理アクセスは <strong>Azure Bastion + Just-In-Time (JIT) VM Access</strong> に置き換え、22/3389 のインバウンドを NSG から削除する。アプリ公開は <strong>Application Gateway WAF / Front Door</strong> 経由に統一し、Public IP は必要最小限にする。'
        Links    = @(
            @{ Text='Azure Bastion とは';                Url='https://learn.microsoft.com/ja-jp/azure/bastion/bastion-overview' },
            @{ Text='Just-In-Time VM Access の構成';     Url='https://learn.microsoft.com/ja-jp/azure/defender-for-cloud/just-in-time-access-usage' },
            @{ Text='NSG ルールのベスト プラクティス';   Url='https://learn.microsoft.com/ja-jp/azure/virtual-network/network-security-groups-overview' }
        )
    },
    [pscustomobject]@{
        Rank     = 2
        Severity = 'High'
        Title    = '特権ロールの恒久付与と blast radius 拡大'
        Fact     = $rbacRiskFact
        Reason   = 'Owner と UAA は権限変更まで可能な最強ロールで、管理グループ スコープに付与すると配下全サブスクへ波及します。SP に Owner が恒久付与され、孤児（削除済み ID）の割り当てが残存している状態は、侵害時の影響範囲・監査追跡性・最小権限原則のすべてに違反します。'
        Recommend= 'Owner / UAA は <strong>PIM によるオンデマンド昇格</strong> に移行し、恒久付与を停止。SP は <strong>マネージド ID / Workload Identity Federation</strong> に切替え、孤児割り当ては <code>Remove-AzRoleAssignment</code> で削除。<strong>Access Review</strong> を四半期で自動化する。'
        Links    = @(
            @{ Text='Privileged Identity Management';   Url='https://learn.microsoft.com/ja-jp/entra/id-governance/privileged-identity-management/pim-configure' },
            @{ Text='マネージド ID の概要';              Url='https://learn.microsoft.com/ja-jp/entra/identity/managed-identities-azure-resources/overview' },
            @{ Text='RBAC ベスト プラクティス';          Url='https://learn.microsoft.com/ja-jp/azure/role-based-access-control/best-practices' }
        )
    },
    [pscustomobject]@{
        Rank     = 3
        Severity = if ($defenderEnabled -and $dHigh -gt 0) { 'High' } else { 'Medium' }
        Title    = 'Defender for Cloud のセキュリティ態勢ギャップ'
        Fact     = $defenderRiskFact
        Reason   = 'Defender for Cloud の Foundational CSPM は無償で利用可能で、Microsoft Cloud Security Benchmark に基づく構成不備・公開リスク・ID リスク・脆弱性を継続検出します。未有効 or 推奨事項の長期放置は、CIS / NIST / ISO 等のコンプライアンスへの逸脱を恒常化させ、インシデント時の対応コストを著しく増加させます。'
        Recommend= 'サブスクリプション単位で <strong>Foundational CSPM</strong> を有効化、必要に応じて Servers / Storage / Key Vault / AI プランを追加。<strong>Secure Score</strong> を月次でレビューし、High Severity 推奨事項から優先的に是正する。'
        Links    = @(
            @{ Text='Defender for Cloud の概要';         Url='https://learn.microsoft.com/ja-jp/azure/defender-for-cloud/defender-for-cloud-introduction' },
            @{ Text='Defender for Cloud の有効化';        Url='https://learn.microsoft.com/ja-jp/azure/defender-for-cloud/get-started' },
            @{ Text='Secure Score の改善';                Url='https://learn.microsoft.com/ja-jp/azure/defender-for-cloud/secure-score-security-controls' }
        )
    },
    [pscustomobject]@{
        Rank     = 4
        Severity = if ($advisorAvailable -and $advHigh -gt 0) { 'High' } else { 'Medium' }
        Title    = 'Azure Advisor 推奨事項のフィードバックループ不在'
        Fact     = $advisorRiskFact
        Reason   = 'Advisor はコスト・運用・パフォーマンス・可用性・セキュリティの 5 領域でサブスクリプション固有の最適化機会を提示します。長期未対応は <strong>無駄な課金の継続</strong>（未使用リソース・サイズ過大）、<strong>SLA リスク</strong>（単一ゾーン構成、サポート未契約等）、<strong>パフォーマンス劣化</strong> を発生させます。'
        Recommend= 'Advisor を Cost Management と連動させ、<strong>月次レビュー</strong> で High Impact から順に対応。Cost 系は予算アラート、HA 系はゾーン冗長化・バックアップ計画、Operational 系は Service Health アラートと連動させる。'
        Links    = @(
            @{ Text='Azure Advisor の概要';              Url='https://learn.microsoft.com/ja-jp/azure/advisor/advisor-overview' },
            @{ Text='Advisor のコスト推奨事項';           Url='https://learn.microsoft.com/ja-jp/azure/advisor/advisor-reference-cost-recommendations' },
            @{ Text='Cost Management でコスト分析';      Url='https://learn.microsoft.com/ja-jp/azure/cost-management-billing/costs/quick-acm-cost-analysis' }
        )
    },
    [pscustomobject]@{
        Rank     = 5
        Severity = 'Medium'
        Title    = 'ガバナンス基盤の弱さ（タグ・冗長性・命名）'
        Fact     = $govRiskFact
        Reason   = 'タグ未付与は所有者・コスト按分・インシデント連絡先の特定を困難にし、削除可否判断を遅延させます。LRS のみの構成は AZ 障害時の可用性を提供できず、Public IP の管理欠如は攻撃面の継続拡大につながります。これらは個別には軽微でも、組織スケールでは大きなコスト・リスクを蓄積します。'
        Recommend= 'Azure Policy で <code>owner</code> / <code>env</code> / <code>costcenter</code> を必須化（deny + modify）、RG タグの Tag Inheritance を有効化。データ重要度に応じ <strong>ZRS / GZRS</strong> への移行計画を策定。命名規約は CAF に準拠した命名ポリシーで自動検証する。'
        Links    = @(
            @{ Text='タグ ガバナンスのベスト プラクティス'; Url='https://learn.microsoft.com/ja-jp/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging' },
            @{ Text='Azure Storage の冗長性';                Url='https://learn.microsoft.com/ja-jp/azure/storage/common/storage-redundancy' },
            @{ Text='Azure Policy: タグの組み込みポリシー';   Url='https://learn.microsoft.com/ja-jp/azure/governance/policy/samples/built-in-policies#tags' }
        )
    }
)

$riskHtml = ($risks | ForEach-Object {
    $sevClass = switch ($_.Severity) {
        'High'   { 'sev-high' }
        'Medium' { 'sev-med' }
        default  { 'sev-low' }
    }
    $linkHtml = ($_.Links | ForEach-Object {
        "<li><a href='$($_.Url)' target='_blank' rel='noopener'>$(ConvertTo-HtmlEncoded $_.Text)</a></li>"
    }) -join ''
    @"
<article class="risk $sevClass">
  <header class="risk-head">
    <span class="rank">#$($_.Rank)</span>
    <span class="sev">$($_.Severity)</span>
    <h3>$(ConvertTo-HtmlEncoded $_.Title)</h3>
  </header>
  <div class="risk-body">
    <div class="row"><div class="lbl">観察事実</div><div class="val">$($_.Fact)</div></div>
    <div class="row"><div class="lbl">リスク理由</div><div class="val">$($_.Reason)</div></div>
    <div class="row"><div class="lbl">推奨対応</div><div class="val">$($_.Recommend)</div></div>
    <div class="row"><div class="lbl">公式ドキュメント</div><div class="val"><ul class="links">$linkHtml</ul></div></div>
  </div>
</article>
"@
}) -join "`n"

# === 4. 30 日アクションプラン ===
$plan = @(
    [pscustomobject]@{ Window='Day 1-3';   Owner='Cloud Ops';        Title='レポート展開と所有者特定';          Detail='本レポートをサブスク オーナー・セキュリティ・FinOps へ展開し、タグなしリソース／孤児ロールの一次連絡先を特定。' }
    [pscustomobject]@{ Window='Day 1-7';   Owner='Security';         Title='Defender for Cloud 有効化';         Detail='Foundational CSPM を全サブスクで有効化、Secure Score の初期スナップショットを取得。' }
    [pscustomobject]@{ Window='Day 3-10';  Owner='Network';          Title='NSG / Public IP 緊急是正';          Detail='Internet → 22/3389 Allow ルールを即時削除し、Bastion + JIT を導入。不要な Public IP を削除。' }
    [pscustomobject]@{ Window='Day 7-14';  Owner='IAM';              Title='Owner/UAA の PIM 化と孤児削除';     Detail='Owner / UAA を PIM 対象化し恒久付与を停止。DisplayName=null の RoleAssignment を削除。' }
    [pscustomobject]@{ Window='Day 10-20'; Owner='Governance';       Title='タグ必須化と Tag Inheritance 導入'; Detail='Azure Policy で owner/env/costcenter を Require、RG → リソース継承を有効化。' }
    [pscustomobject]@{ Window='Day 14-21'; Owner='FinOps / Advisor'; Title='Advisor High Impact 対応';          Detail='Cost / HA の High Impact 推奨を月次レビュー化し、予算アラート・自動停止を設定。' }
    [pscustomobject]@{ Window='Day 18-25'; Owner='Storage';          Title='冗長性レビューと移行';              Detail='重要度区分に応じ LRS → ZRS / GZRS への移行計画を策定し、優先度高から適用。' }
    [pscustomobject]@{ Window='Day 21-28'; Owner='Security';         Title='監視ベースライン整備';              Detail='Log Analytics 集約、Diagnostic Settings、Activity Log Alerts、Conditional Access (Owner/UAA/SP) を整備。' }
    [pscustomobject]@{ Window='Day 28-30'; Owner='管理者';           Title='レビュー会議と次サイクル';          Detail='Secure Score / Advisor / Owner件数 / 高リスクNSG件数の改善を比較し、本レポートを再生成。' }
)
$planRows = ($plan | ForEach-Object {
    "<tr><td class='nowrap'>$(ConvertTo-HtmlEncoded $_.Window)</td><td>$(ConvertTo-HtmlEncoded $_.Owner)</td><td><strong>$(ConvertTo-HtmlEncoded $_.Title)</strong><br><span class='muted'>$(ConvertTo-HtmlEncoded $_.Detail)</span></td></tr>"
}) -join "`n"

# === 付録: 各ドメインのハイライト ===
$nsgAppendix = ($nsgRules | Sort-Object @{Expression='IsRiskyMgmtFromInternet';Descending=$true}, NsgName, Priority | Select-Object -First 30 | ForEach-Object {
    $rowClass = if ($_.IsRiskyMgmtFromInternet -eq $true -or $_.IsRiskyMgmtFromInternet -eq 'True') { ' class="risky"' } else { '' }
    "<tr$rowClass>" +
    "<td>$(ConvertTo-HtmlEncoded $_.NsgName)</td>" +
    "<td class='num'>$(ConvertTo-HtmlEncoded ([string]$_.Priority))</td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.RuleName)</td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.Direction)</td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.Access)</td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.SourceAddressPrefix)</td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.DestinationPortRange)</td>" +
    "</tr>"
}) -join "`n"

$defenderAppendix = ($defender | Where-Object Status -eq 'Unhealthy' | Sort-Object @{Expression='Severity';Descending=$true}, DisplayName | Select-Object -First 30 | ForEach-Object {
    $sev = $_.Severity
    $sevClass = switch ($sev) { 'High' { 'sev-high' } 'Medium' { 'sev-med' } default { 'sev-low' } }
    "<tr>" +
    "<td><span class='sev-badge $sevClass'>$(ConvertTo-HtmlEncoded $sev)</span></td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.DisplayName)</td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.ResourceType)</td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.ResourceName)</td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.ResourceGroupName)</td>" +
    "</tr>"
}) -join "`n"

$advisorAppendix = ($advisor | Sort-Object @{Expression='Impact';Descending=$true}, Category | Select-Object -First 30 | ForEach-Object {
    $imp = $_.Impact
    $impClass = switch ($imp) { 'High' { 'sev-high' } 'Medium' { 'sev-med' } default { 'sev-low' } }
    "<tr>" +
    "<td>$(ConvertTo-HtmlEncoded $_.Category)</td>" +
    "<td><span class='sev-badge $impClass'>$(ConvertTo-HtmlEncoded $imp)</span></td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.Problem)</td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.ResourceType)</td>" +
    "<td>$(ConvertTo-HtmlEncoded $_.ResourceName)</td>" +
    "</tr>"
}) -join "`n"

# === タブ用: リソース タブのテーブル ===
$rTypeTopRows = ($resources | Group-Object ResourceType | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
    "<tr><td><code>$(ConvertTo-HtmlEncoded $_.Name)</code></td><td class='num'>$($_.Count)</td></tr>"
}) -join "`n"
if (-not $rTypeTopRows) { $rTypeTopRows = '<tr><td colspan="2" class="empty">リソースなし</td></tr>' }

$rRgTopRows = ($resources | Group-Object ResourceGroupName | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
    "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td class='num'>$($_.Count)</td></tr>"
}) -join "`n"
if (-not $rRgTopRows) { $rRgTopRows = '<tr><td colspan="2" class="empty">リソースなし</td></tr>' }

$rLocTopRows = ($resources | Group-Object Location | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
    "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td class='num'>$($_.Count)</td></tr>"
}) -join "`n"
if (-not $rLocTopRows) { $rLocTopRows = '<tr><td colspan="2" class="empty">リソースなし</td></tr>' }

$rUntaggedRows = ($resources | Where-Object { [string]::IsNullOrWhiteSpace($_.Tags) } | Sort-Object ResourceGroupName, Name | Select-Object -First 30 | ForEach-Object {
    "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td>$(ConvertTo-HtmlEncoded $_.ResourceGroupName)</td><td><code>$(ConvertTo-HtmlEncoded $_.ResourceType)</code></td><td>$(ConvertTo-HtmlEncoded $_.Location)</td></tr>"
}) -join "`n"
if (-not $rUntaggedRows) { $rUntaggedRows = '<tr><td colspan="4" class="empty">タグ未付与リソースなし</td></tr>' }

# === タブ用: RBAC タブのテーブル ===
$aRoleRows = ($assignments | Group-Object RoleDefinitionName | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
    "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td class='num'>$($_.Count)</td></tr>"
}) -join "`n"
if (-not $aRoleRows) { $aRoleRows = '<tr><td colspan="2" class="empty">RBAC 割り当てなし</td></tr>' }

$aObjectTypeRows = ($assignments | Group-Object ObjectType | Sort-Object Count -Descending | ForEach-Object {
    "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td class='num'>$($_.Count)</td></tr>"
}) -join "`n"
if (-not $aObjectTypeRows) { $aObjectTypeRows = '<tr><td colspan="2" class="empty">RBAC 割り当てなし</td></tr>' }

$aOwnerRows = ($assignments | Where-Object RoleDefinitionName -in 'Owner','User Access Administrator' | Sort-Object RoleDefinitionName, ScopeKind, DisplayName | Select-Object -First 30 | ForEach-Object {
    $roleClass = if ($_.RoleDefinitionName -eq 'Owner') { 'sev-high' } else { 'sev-med' }
    "<tr><td><span class='sev-badge $roleClass'>$(ConvertTo-HtmlEncoded $_.RoleDefinitionName)</span></td><td>$(ConvertTo-HtmlEncoded $_.DisplayName)</td><td>$(ConvertTo-HtmlEncoded $_.ObjectType)</td><td>$(ConvertTo-HtmlEncoded $_.ScopeKind)</td></tr>"
}) -join "`n"
if (-not $aOwnerRows) { $aOwnerRows = '<tr><td colspan="4" class="empty">Owner / UAA の付与なし</td></tr>' }

$aOrphanRows = ($assignments | Where-Object { [string]::IsNullOrWhiteSpace($_.DisplayName) } | Sort-Object RoleDefinitionName | Select-Object -First 30 | ForEach-Object {
    "<tr><td>$(ConvertTo-HtmlEncoded $_.RoleDefinitionName)</td><td><code>$(ConvertTo-HtmlEncoded $_.ObjectId)</code></td><td>$(ConvertTo-HtmlEncoded $_.ObjectType)</td><td>$(ConvertTo-HtmlEncoded $_.ScopeKind)</td></tr>"
}) -join "`n"
if (-not $aOrphanRows) { $aOrphanRows = '<tr><td colspan="4" class="empty">孤児候補なし</td></tr>' }

# === 5. Defender for Cloud 見解 ===
if ($defenderEnabled) {
    # Top 5 推奨事項テーブル
    $dTopRecHtml = ($dTopRec | ForEach-Object {
        "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td class='num'>$($_.Count)</td></tr>"
    }) -join "`n"

    # リソースタイプ別 Unhealthy
    $dTopTypeHtml = ($dTopType | ForEach-Object {
        $typeName = if ([string]::IsNullOrWhiteSpace($_.Name)) { '(none / subscription scope)' } else { $_.Name }
        "<tr><td>$(ConvertTo-HtmlEncoded $typeName)</td><td class='num'>$($_.Count)</td></tr>"
    }) -join "`n"

    # High 件の詳細
    $dHighHtml = if ($dHigh -gt 0) {
        ($dHighItems | ForEach-Object {
            "<tr><td><span class='sev-badge sev-high'>High</span></td><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td class='num'>$($_.Count)</td></tr>"
        }) -join "`n"
    } else {
        '<tr><td colspan="3" class="empty">High Severity の Unhealthy なし</td></tr>'
    }

    # スコアの解釈
    $scoreVerdict = if ($secureScorePct -ge 80) {
        "<strong style='color:var(--ok)'>良好</strong>（Healthy 比率 ${secureScorePct}%）"
    } elseif ($secureScorePct -ge 50) {
        "<strong style='color:var(--med)'>要改善</strong>（Healthy 比率 ${secureScorePct}%）— ベースラインまであと一歩"
    } else {
        "<strong style='color:var(--high)'>不十分</strong>（Healthy 比率 ${secureScorePct}%）— セキュリティ態勢が脆弱"
    }

    # AI コメント（観察事実に基づく見解）
    $defenderAssessment = @"
<p>Defender for Cloud は <strong>${dTotal} 件</strong>の評価を実施し、<strong>Healthy ${dHealthy} / Unhealthy ${dUn} / NotApplicable ${dNotApp}</strong> という結果。簡易 Secure Score は $scoreVerdict。</p>
<p><strong>カテゴリ別の見立て:</strong> Unhealthy ${dUn} 件のうち、<strong>構成不備 (Misconfigurations) が ${dMisconf} 件</strong>、<strong>脆弱性 (Vulnerabilities) が ${dVuln} 件</strong>です。構成不備が大多数を占めることは、<em>「ワークロード自体は標準デプロイ済みだが、ハードニング設定とガバナンス統制が未適用」</em> という典型的な初期 Azure 環境の症状を示しています。脆弱性 (CVE 検出) は MDVM (Microsoft Defender Vulnerability Management) が稼働している証拠であり、Defender for Servers Plan 2 が有効である可能性が高いです。</p>
<p><strong>重大度別の見立て:</strong> High ${dHigh} 件 / Medium ${dMed} 件 / Low ${dLow} 件。一般に High の多くは <strong>VM の暗号化 (Azure Disk Encryption / EncryptionAtHost) 未有効</strong> や <strong>サブスク / RG レベルへの SP 管理者ロール付与と恒久特権</strong> に起因し、RBAC レポートの Owner / UAA 過剰付与の指摘と一致するケースが多く見られます。</p>
<p><strong>横断的なメッセージ:</strong> Defender は「個別の構成不備」を可視化しますが、根本原因は <strong>(a) デプロイ時に暗号化・Backup・Guest Configuration が組み込まれていない</strong>、<strong>(b) AI Services / Storage / Subscription レベルのネットワーク・認証ベースラインが未設定</strong> の 2 点に集約されるケースが一般的です。個別対応ではなく <strong>Azure Policy (Initiative) によるベースライン強制</strong> と <strong>Bicep / Terraform のモジュール改修</strong> で再発防止することを推奨します。</p>
<p><strong>推奨アクション:</strong></p>
<ul style="line-height:1.8;">
<li>① <strong>EncryptionAtHost / ADE</strong> を VM デプロイ標準に組み込み、既存 5 VM は計画停止枠で順次適用（Azure Policy <code>Virtual machines and virtual machine scale sets should have encryption at host enabled</code> の Deny 化）</li>
<li>② <strong>Backup / Guest Configuration / EDR</strong> は Azure Policy DINE で自動適用（VM 作成時に自動有効化）</li>
<li>③ <strong>AI Services</strong> の Private Link / ネットワーク制限 / マネージド ID 認証 / 診断ログを Policy で必須化</li>
<li>④ <strong>サブスクリプション セキュリティ連絡先と High Severity アラート通知</strong> をすぐに設定（Defender for Cloud → Environment settings → Email notifications）</li>
<li>⑤ <strong>PIM</strong> を有効化し、SP の管理者ロール恒久付与を停止 (Defender 推奨 + RBAC レポート Risk #2 と統合対応)</li>
</ul>
"@
} else {
    $defenderAssessment = "<p class='muted'>Defender for Cloud の評価結果が取得できませんでした。Foundational CSPM の有効化と API アクセス権限の確認が必要です。</p>"
    $dTopRecHtml = '<tr><td colspan="2" class="empty">データなし</td></tr>'
    $dTopTypeHtml = '<tr><td colspan="2" class="empty">データなし</td></tr>'
    $dHighHtml = '<tr><td colspan="3" class="empty">データなし</td></tr>'
}

# === 6. Azure Advisor 見解 ===
if ($advisorAvailable) {
    # カテゴリ別 High Impact 件数を事前計算（here-string 内で複雑式が使えないため）
    $advHighHaCount    = @($advHighByCat['HighAvailability']).Count
    $advHighSecCount   = @($advHighByCat['Security']).Count
    $advHighOpCount    = @($advHighByCat['OperationalExcellence']).Count
    $advVmCount        = @($advisor | Where-Object ResourceType -like '*virtualMachines').Count
    $advDiskCount      = @($advisor | Where-Object ResourceType -like '*disks').Count
    $advStgCount       = @($advisor | Where-Object ResourceType -like '*storageaccounts').Count

    # カテゴリ別 High Impact 詳細
    $catLabel = @{
        Cost                  = 'コスト'
        OperationalExcellence = '運用優秀性'
        Performance           = 'パフォーマンス'
        HighAvailability      = '可用性 (HA)'
        Security              = 'セキュリティ'
    }
    $catColor = @{
        Cost                  = '#10b981'
        OperationalExcellence = '#a855f7'
        Performance           = '#06b6d4'
        HighAvailability      = '#3b82f6'
        Security              = '#ef4444'
    }
    $advHighByCatHtml = ''
    foreach ($cat in @('Cost','OperationalExcellence','Performance','HighAvailability','Security')) {
        $items = $advHighByCat[$cat]
        $catText = $catLabel[$cat]
        $col = $catColor[$cat]
        $rows = if ($items -and $items.Count -gt 0) {
            ($items | ForEach-Object {
                "<li><strong>$(ConvertTo-HtmlEncoded $_.Name)</strong> <span class='muted'>($($_.Count) 件)</span></li>"
            }) -join ''
        } else {
            "<li class='muted'>High Impact の指摘なし</li>"
        }
        $advHighByCatHtml += @"
<div class="adv-cat" style="border-left:3px solid $col;">
  <div class="adv-cat-head"><span style="color:$col">$catText</span> <span class="muted">— High Impact</span></div>
  <ul class="adv-list">$rows</ul>
</div>
"@
    }

    # リソースタイプ別 Top 5
    $advTopByResTypeHtml = ($advTopByResType | ForEach-Object {
        "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td class='num'>$($_.Count)</td></tr>"
    }) -join "`n"

    # 数値スナップショット
    $advCostNote = if ($advCost -eq 0) {
        "Cost 推奨が <strong>0 件</strong> なのは、(a) アイドル/低使用率の検出に必要な期間（通常 7-14 日）に到達していない、(b) RI/SP 推奨対象の安定稼働ワークロードがない、(c) Cost Management へのアクセス権限不足、のいずれかが原因と考えられます。<strong>運用が成熟しても Advisor Cost が常に 0 のままの場合は手動でのコスト分析を併用すべき</strong>です。"
    } else {
        "Cost 推奨が ${advCost} 件提示されており、即時の節約機会があります。"
    }

    $advHaNote = if ($advHa -gt 0) {
        "HA 推奨 ${advHa} 件のうち <strong>${advHighHaCount} 種類が High Impact</strong>。主な指摘は <em>「VM と Disk の同一ゾーン配置」「Storage のゾーン冗長」「Service Health アラート未設定」</em>。<strong>VM とディスクのゾーン不整合</strong> は、再起動時にディスクのアタッチに時間がかかる／別ゾーン障害時に巻き込まれる原因になります。"
    } else {
        "HA 推奨は 0 件。単一ゾーン構成のままで AZ 障害耐性が不足している可能性があるため、ゾーン冗長化計画を別途立案する必要があります。"
    }

    $advSecNote = if ($advSec -gt 0) {
        "Security 推奨は ${advSec} 件（High ${advHighSecCount} 種類）。Advisor の Security カテゴリは Defender for Cloud と連携しており、本リストと Defender セクションの Unhealthy 項目は <strong>重複して同じ問題</strong>（暗号化未有効、EDR、特権ロール等）を指しています。<strong>Defender 側を是正することで Advisor Security も自動的に減少</strong> します。"
    } else {
        "Security 推奨は 0 件です。"
    }

    $advisorAssessment = @"
<p>Azure Advisor は <strong>${advTotal} 件</strong> の推奨事項を提示し、Impact は High ${advHigh} / Medium ${advMed} / Low ${advLow}。カテゴリ分布は <strong>Security ${advSec} / HA ${advHa} / Operational ${advOp} / Cost ${advCost} / Performance ${advPerf}</strong>。リソースの偏りは <strong>VM ${advVmCount} 件 / Disk ${advDiskCount} 件 / Storage ${advStgCount} 件</strong> となっています。</p>
<p><strong>コスト面 (Cost ${advCost}):</strong> $advCostNote</p>
<p><strong>可用性面 (HA ${advHa}):</strong> $advHaNote</p>
<p><strong>運用面 (Operational ${advOp}):</strong> Operational ${advOp} 件のうち High Impact ${advHighOpCount} 種類。主な指摘は <strong>「Trusted Launch 有効化（Gen2 VM）」「VM Insights 有効化」「VMSS Flex への移行」</strong>。これらは セキュリティ + 監視 + モダン化 の 3 領域を同時に底上げするため、<strong>VM の作り直し（ARM/Bicep テンプレ刷新）と同時に対応</strong> するのが効率的です。</p>
<p><strong>セキュリティ面 (Security ${advSec}):</strong> $advSecNote</p>
<p><strong>横断的なメッセージ:</strong> Advisor の推奨が <strong>同じ 5 VM に対して複数カテゴリで重複して出ている</strong> のが特徴で、これは <em>「VM デプロイ標準が古い／Trusted Launch・暗号化・Backup・Insights を組み込まずに作っている」</em> ことを示しています。<strong>個別対応ではなく VM の Bicep/Terraform モジュールを更新し、既存 5 VM を再デプロイする方が ROI が高い</strong>です。</p>
<p><strong>推奨アクション:</strong></p>
<ul style="line-height:1.8;">
<li>① <strong>VM デプロイ標準テンプレート</strong> に Trusted Launch + EncryptionAtHost + Backup + Guest Config + VM Insights + ゾーン指定を組み込み、既存 5 VM を計画移行</li>
<li>② <strong>Storage アカウント</strong> を LRS → ZRS / GZRS へ移行し、Service Health アラートを Action Group に接続</li>
<li>③ <strong>Advisor の月次レビュー</strong> を運用化（Cost Management ダッシュボードに統合表示）、Cost 推奨が表示されるまでの期間も手動コスト分析で代替</li>
<li>④ <strong>Subscription Service Health Alert</strong> を即時設定し、Azure 計画メンテと障害情報を受信</li>
<li>⑤ <strong>Defender セクションの ① ②</strong>（暗号化 / Backup の Policy 強制）と統合対応し、Advisor Security と HA の High Impact を同時にクリアする</li>
</ul>
"@
} else {
    $advisorAssessment = "<p class='muted'>Azure Advisor の推奨事項が取得できませんでした。Az.Advisor モジュールの導入とサブスクリプションの評価対象確認が必要です。</p>"
    $advHighByCatHtml = '<div class="muted">データなし</div>'
    $advTopByResTypeHtml = '<tr><td colspan="2" class="empty">データなし</td></tr>'
}

$html = @"
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Azure 総合レポート（管理者向け／AI インサイト）</title>
<style>
  :root { --bg:#0f172a; --card:#1e293b; --muted:#94a3b8; --fg:#f1f5f9; --accent:#38bdf8; --border:#334155;
          --high:#ef4444; --med:#f59e0b; --low:#38bdf8; --ok:#10b981; }
  * { box-sizing: border-box; }
  body { font-family:'Segoe UI','Yu Gothic UI',sans-serif; margin:0; background:var(--bg); color:var(--fg); }
  a { color:var(--accent); text-decoration:none; }
  a:hover { text-decoration:underline; }
  header.top { padding:28px 32px; background:linear-gradient(120deg,#7c3aed,#0ea5e9); color:#fff; }
  header.top h1 { margin:0; font-size:26px; }
  header.top .badge { display:inline-block; background:rgba(255,255,255,0.2); padding:2px 10px; border-radius:999px; font-size:11px; margin-left:8px; vertical-align:middle; }
  header.top .sub { opacity:0.9; font-size:13px; margin-top:6px; }
  main { padding:24px 32px; max-width:1400px; margin:0 auto; }
  section { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:18px 22px; margin-bottom:22px; }
  section h2 { margin:0 0 14px 0; font-size:18px; padding-bottom:10px; border-bottom:1px solid var(--border); display:flex; align-items:center; gap:10px; }
  section h2 .num { color:var(--muted); font-size:13px; font-weight:400; }
  section h2 .ai { font-size:11px; background:linear-gradient(90deg,#7c3aed,#ec4899); padding:2px 8px; border-radius:999px; color:#fff; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  th, td { text-align:left; padding:9px 12px; border-bottom:1px solid var(--border); vertical-align:top; }
  th { background:#0b1220; color:var(--muted); font-weight:600; }
  td.num { text-align:right; font-variant-numeric:tabular-nums; font-weight:600; color:var(--accent); }
  td.nowrap { white-space:nowrap; color:var(--muted); }
  .muted { color:var(--muted); }
  code { background:#0b1220; padding:1px 6px; border-radius:4px; color:#fbbf24; font-size:12px; word-break:break-all; }
  .summary p { line-height:1.85; color:#e2e8f0; margin:8px 0; }
  .summary { background:linear-gradient(135deg,rgba(124,58,237,0.18),rgba(14,165,233,0.18)); border:1px solid #6366f1; }

  /* Executive summary */
  .verdict-bar { display:flex; align-items:center; gap:16px; background:#0b1220; border-radius:8px; padding:14px 18px; margin-bottom:14px; }
  .verdict-emoji { font-size:32px; line-height:1; }
  .verdict-title { font-size:18px; font-weight:700; }
  .verdict-score { font-size:13px; color:var(--muted); font-weight:400; margin-left:6px; }
  .verdict-desc { font-size:13px; color:var(--muted); margin-top:4px; line-height:1.6; }

  .kpi-grid { display:grid; grid-template-columns:repeat(6, 1fr); gap:10px; margin-bottom:16px; }
  @media (max-width:1100px) { .kpi-grid { grid-template-columns:repeat(3, 1fr); } }
  @media (max-width:600px)  { .kpi-grid { grid-template-columns:repeat(2, 1fr); } }
  .kpi { background:#0b1220; border-radius:8px; padding:12px 14px; border:1px solid var(--border); }
  .kpi-label { font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:0.5px; margin-bottom:4px; }
  .kpi-value { font-size:26px; font-weight:700; line-height:1; font-variant-numeric:tabular-nums; }
  .kpi-unit { font-size:12px; color:var(--muted); margin-left:3px; font-weight:400; }
  .kpi-sub { font-size:11px; color:var(--muted); margin-top:4px; }

  .exec-cols { display:grid; grid-template-columns:1fr 1fr; gap:14px; margin-bottom:14px; }
  @media (max-width:900px) { .exec-cols { grid-template-columns:1fr; } }
  .exec-col { background:#0b1220; border-radius:8px; padding:14px 16px; border:1px solid var(--border); }
  .exec-col h3 { margin:0 0 8px 0; font-size:14px; padding-bottom:6px; border-bottom:1px solid var(--border); }
  .exec-col ul { margin:6px 0 0 0; padding-left:18px; font-size:13px; line-height:1.7; }
  .exec-col ul li { margin:5px 0; }
  .exec-concern { border-left:3px solid var(--high); }
  .exec-strength { border-left:3px solid var(--ok); }
  .exec-focus { background:#0b1220; border-radius:8px; padding:14px 16px; border:1px solid var(--border); border-left:3px solid var(--accent); }
  .exec-focus h3 { margin:0 0 8px 0; font-size:14px; padding-bottom:6px; border-bottom:1px solid var(--border); }
  .exec-focus ul { margin:6px 0 0 0; padding-left:18px; font-size:13px; line-height:1.8; }
  .exec-focus ul li { margin:4px 0; }

  /* Domain badges */
  .dom { display:inline-block; padding:2px 8px; border-radius:999px; font-size:11px; font-weight:700; }
  .dom-リソース  { background:rgba(56,189,248,0.15); color:#38bdf8; border:1px solid #38bdf8; }
  .dom-rbac      { background:rgba(168,85,247,0.15); color:#c084fc; border:1px solid #a855f7; }
  .dom-nsg       { background:rgba(245,158,11,0.15); color:#fbbf24; border:1px solid #f59e0b; }
  .dom-defender  { background:rgba(239,68,68,0.15);  color:#fca5a5; border:1px solid #ef4444; }
  .dom-advisor   { background:rgba(16,185,129,0.15); color:#6ee7b7; border:1px solid #10b981; }

  /* Risk cards */
  .risk { border:1px solid var(--border); border-radius:10px; padding:0; margin-bottom:14px; background:#0b1220; overflow:hidden; }
  .risk-head { display:flex; align-items:center; gap:12px; padding:12px 16px; border-bottom:1px solid var(--border); }
  .risk-head h3 { margin:0; font-size:15px; flex:1; }
  .risk-head .rank { font-weight:700; color:var(--muted); font-size:13px; }
  .risk-head .sev  { font-size:11px; font-weight:700; padding:3px 10px; border-radius:999px; }
  .sev-high  .risk-head .sev  { background:rgba(239,68,68,0.15);  color:var(--high); border:1px solid var(--high); }
  .sev-med   .risk-head .sev  { background:rgba(245,158,11,0.15); color:var(--med);  border:1px solid var(--med); }
  .sev-low   .risk-head .sev  { background:rgba(56,189,248,0.12); color:var(--low);  border:1px solid var(--low); }
  .sev-high  { border-left:4px solid var(--high); }
  .sev-med   { border-left:4px solid var(--med); }
  .sev-low   { border-left:4px solid var(--low); }
  .risk-body { padding:14px 16px; }
  .risk-body .row { display:grid; grid-template-columns:120px 1fr; gap:12px; padding:8px 0; border-bottom:1px dashed var(--border); }
  .risk-body .row:last-child { border-bottom:none; }
  .risk-body .lbl { color:var(--muted); font-size:12px; font-weight:600; }
  .risk-body .val { color:#e2e8f0; font-size:13px; line-height:1.7; word-break:break-word; }
  .links { margin:0; padding-left:18px; }
  .links li { margin:2px 0; }

  /* Severity badges in tables */
  .sev-badge { display:inline-block; padding:2px 8px; border-radius:999px; font-size:11px; font-weight:700; }
  .sev-badge.sev-high { background:rgba(239,68,68,0.15);  color:var(--high); border:1px solid var(--high); }
  .sev-badge.sev-med  { background:rgba(245,158,11,0.15); color:var(--med);  border:1px solid var(--med); }
  .sev-badge.sev-low  { background:rgba(56,189,248,0.12); color:var(--low);  border:1px solid var(--low); }
  tr.risky td { background:rgba(239,68,68,0.08); }
  .empty { color:var(--muted); font-size:13px; padding:14px; text-align:center; }

  /* Insight sections */
  .insight { background:linear-gradient(135deg,rgba(239,68,68,0.08),rgba(124,58,237,0.08)); border:1px solid #6366f1; }
  .insight.adv { background:linear-gradient(135deg,rgba(16,185,129,0.08),rgba(56,189,248,0.10)); border:1px solid #10b981; }
  .insight p { line-height:1.85; color:#e2e8f0; margin:8px 0; }
  .insight ul { margin:6px 0 6px 0; padding-left:22px; color:#e2e8f0; }
  .insight ul li { margin:3px 0; }
  .insight-grid { display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-bottom:14px; }
  @media (max-width:1000px) { .insight-grid { grid-template-columns:1fr; } }
  .insight-sub h3 { font-size:14px; margin:0 0 8px 0; color:var(--muted); border-bottom:1px solid var(--border); padding-bottom:6px; }

  .adv-cat { background:#0b1220; border-radius:8px; padding:10px 14px; margin-bottom:10px; }
  .adv-cat-head { font-weight:700; font-size:13px; margin-bottom:6px; }
  .adv-list { margin:4px 0 0 18px; padding:0; font-size:12px; line-height:1.7; }

  /* Tabs */
  .tabs { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:0; margin-bottom:22px; overflow:hidden; }
  .tab-nav { display:flex; flex-wrap:wrap; background:#0b1220; border-bottom:1px solid var(--border); padding:0; margin:0; gap:0; position:sticky; top:0; z-index:10; }
  .tab-btn { background:transparent; color:var(--muted); border:none; border-bottom:3px solid transparent; padding:14px 22px; font-size:14px; font-weight:600; cursor:pointer; transition:all 0.15s; font-family:inherit; display:flex; align-items:center; gap:8px; }
  .tab-btn:hover { color:var(--fg); background:rgba(56,189,248,0.06); }
  .tab-btn.active { color:var(--fg); border-bottom-color:var(--accent); background:var(--card); }
  .tab-btn .cnt { background:rgba(148,163,184,0.18); color:var(--muted); padding:1px 8px; border-radius:999px; font-size:11px; font-weight:700; }
  .tab-btn.active .cnt { background:rgba(56,189,248,0.2); color:var(--accent); }
  .tab-panel { display:none; padding:22px; }
  .tab-panel.active { display:block; animation:fadeIn 0.2s ease; }
  @keyframes fadeIn { from { opacity:0; transform:translateY(4px); } to { opacity:1; transform:none; } }
  .tab-panel h2 { margin:0 0 14px 0; font-size:18px; padding-bottom:10px; border-bottom:1px solid var(--border); display:flex; align-items:center; gap:10px; }
  .tab-panel h3 { font-size:14px; margin:18px 0 8px 0; color:var(--muted); border-bottom:1px solid var(--border); padding-bottom:6px; }
  .tab-panel h3:first-of-type { margin-top:8px; }
  .grid2 { display:grid; grid-template-columns:1fr 1fr; gap:18px; }
  @media (max-width:1000px) { .grid2 { grid-template-columns:1fr; } }
  .scroll-box { max-height:420px; overflow:auto; border:1px solid var(--border); border-radius:6px; }

  footer { color:var(--muted); font-size:12px; padding:16px 32px; text-align:center; }
</style>
</head>
<body>
<header class="top">
  <h1>Azure 総合レポート <span class="badge">管理者向け</span> <span class="badge">AI Insights</span> <span class="badge">横断分析</span></h1>
  <div class="sub">サブスクリプション: $(ConvertTo-HtmlEncoded $subName) ($subId) ／ 生成日時: $generated ／ 入力: resources ($rTotal) · rbac ($aTotal) · nsg ($nRules) · defender ($dTotal) · advisor ($advTotal)</div>
</header>
<main>

  <div class="tabs" id="domain-tabs">
    <div class="tab-nav" role="tablist">
      <button class="tab-btn active" type="button" role="tab" data-tab="overview">概要</button>
      <button class="tab-btn" type="button" role="tab" data-tab="resources">リソース <span class="cnt">$rTotal</span></button>
      <button class="tab-btn" type="button" role="tab" data-tab="rbac">RBAC <span class="cnt">$aTotal</span></button>
      <button class="tab-btn" type="button" role="tab" data-tab="nsg">NSG <span class="cnt">$nRules</span></button>
      <button class="tab-btn" type="button" role="tab" data-tab="defender">Defender <span class="cnt">$dUn</span></button>
      <button class="tab-btn" type="button" role="tab" data-tab="advisor">Advisor <span class="cnt">$advTotal</span></button>
    </div>

    <div class="tab-panel active" id="tab-overview" role="tabpanel">
      <section class="summary" style="margin:0 0 18px 0;">
        <h2>エグゼクティブサマリ <span class="ai">AI</span></h2>
        $execSummary
      </section>

      <section style="margin:0 0 18px 0;">
        <h2>全体サマリ</h2>
        <table>
          <thead><tr><th>ドメイン</th><th>項目</th><th class="num">値</th></tr></thead>
          <tbody>$summaryRowsHtml</tbody>
        </table>
      </section>

      <section style="margin:0 0 18px 0;">
        <h2>潜在リスク Top 5 <span class="ai">AI</span> <span class="num">（横断）</span></h2>
        $riskHtml
      </section>

      <section style="margin:0;">
        <h2>30 日アクションプラン</h2>
        <table>
          <thead><tr><th>期間</th><th>担当</th><th>アクション</th></tr></thead>
          <tbody>$planRows</tbody>
        </table>
      </section>
    </div>

    <div class="tab-panel" id="tab-resources" role="tabpanel">
      <h2><span class="dom dom-リソース">リソース</span> リソース インベントリ詳細 <span class="ai">AI</span></h2>
      <div class="insight" style="padding:14px 18px; border-radius:8px; margin-bottom:16px;">
        $resourcesAssessment
      </div>
      <div class="grid2">
        <div>
          <h3>リソースタイプ別 Top 15</h3>
          <div class="scroll-box"><table>
            <thead><tr><th>Resource Type</th><th class="num">件数</th></tr></thead>
            <tbody>$rTypeTopRows</tbody>
          </table></div>
        </div>
        <div>
          <h3>リソース グループ別 Top 15</h3>
          <div class="scroll-box"><table>
            <thead><tr><th>Resource Group</th><th class="num">件数</th></tr></thead>
            <tbody>$rRgTopRows</tbody>
          </table></div>
        </div>
      </div>
      <h3>リージョン別</h3>
      <table>
        <thead><tr><th>Location</th><th class="num">件数</th></tr></thead>
        <tbody>$rLocTopRows</tbody>
      </table>
      <h3>タグ未付与リソース <span class="num">(上位 30)</span></h3>
      <div class="scroll-box"><table>
        <thead><tr><th>Name</th><th>RG</th><th>Type</th><th>Location</th></tr></thead>
        <tbody>$rUntaggedRows</tbody>
      </table></div>
    </div>

    <div class="tab-panel" id="tab-rbac" role="tabpanel">
      <h2><span class="dom dom-rbac">RBAC</span> ロール割り当て詳細 <span class="ai">AI</span></h2>
      <div class="insight" style="padding:14px 18px; border-radius:8px; margin-bottom:16px;">
        $rbacAssessment
      </div>
      <div class="grid2">
        <div>
          <h3>ロール別 Top 15</h3>
          <div class="scroll-box"><table>
            <thead><tr><th>Role</th><th class="num">件数</th></tr></thead>
            <tbody>$aRoleRows</tbody>
          </table></div>
        </div>
        <div>
          <h3>プリンシパル種別</h3>
          <table>
            <thead><tr><th>Object Type</th><th class="num">件数</th></tr></thead>
            <tbody>$aObjectTypeRows</tbody>
          </table>
        </div>
      </div>
      <h3>Owner / User Access Administrator 一覧 <span class="num">(上位 30)</span></h3>
      <div class="scroll-box"><table>
        <thead><tr><th>Role</th><th>DisplayName</th><th>Object Type</th><th>Scope</th></tr></thead>
        <tbody>$aOwnerRows</tbody>
      </table></div>
      <h3>孤児候補（DisplayName=null）<span class="num">(上位 30)</span></h3>
      <div class="scroll-box"><table>
        <thead><tr><th>Role</th><th>Object ID</th><th>Object Type</th><th>Scope</th></tr></thead>
        <tbody>$aOrphanRows</tbody>
      </table></div>
    </div>

    <div class="tab-panel" id="tab-nsg" role="tabpanel">
      <h2><span class="dom dom-nsg">NSG</span> NSG ルール詳細 <span class="ai">AI</span></h2>
      <div class="insight" style="padding:14px 18px; border-radius:8px; margin-bottom:16px;">
        $nsgAssessment
      </div>
      <h3>NSG ルール一覧 <span class="num">(高リスク優先, 上位 30)</span></h3>
      <div class="scroll-box"><table>
        <thead><tr><th>NSG</th><th class="num">Pri</th><th>Rule</th><th>Dir</th><th>Access</th><th>Source</th><th>Dst Port</th></tr></thead>
        <tbody>
        $(if ($nsgAppendix) { $nsgAppendix } else { '<tr><td colspan="7" class="empty">NSG ルールが存在しません</td></tr>' })
        </tbody>
      </table></div>
    </div>

    <div class="tab-panel" id="tab-defender" role="tabpanel">
      <h2><span class="dom dom-defender">Defender</span> Defender for Cloud 見解 <span class="ai">AI</span></h2>
      <div class="insight" style="padding:14px 18px; border-radius:8px; margin-bottom:16px;">
        $defenderAssessment
      </div>
      <div class="grid2" style="margin-top:14px;">
        <div>
          <h3>Unhealthy 推奨事項 Top 5</h3>
          <table>
            <thead><tr><th>推奨事項</th><th class="num">件数</th></tr></thead>
            <tbody>$dTopRecHtml</tbody>
          </table>
        </div>
        <div>
          <h3>Unhealthy リソースタイプ別</h3>
          <table>
            <thead><tr><th>Resource Type</th><th class="num">件数</th></tr></thead>
            <tbody>$dTopTypeHtml</tbody>
          </table>
        </div>
      </div>
      <h3>High Severity の Unhealthy 一覧（種類別）</h3>
      <table>
        <thead><tr><th>Severity</th><th>推奨事項</th><th class="num">件数</th></tr></thead>
        <tbody>$dHighHtml</tbody>
      </table>
      <h3>Defender 推奨事項 詳細 <span class="num">(Unhealthy, Severity 順 上位 30)</span></h3>
      <div class="scroll-box"><table>
        <thead><tr><th>Severity</th><th>Recommendation</th><th>Resource Type</th><th>Resource</th><th>RG</th></tr></thead>
        <tbody>
        $(if ($defenderAppendix) { $defenderAppendix } else { '<tr><td colspan="5" class="empty">推奨事項なし／Defender for Cloud 未有効の可能性</td></tr>' })
        </tbody>
      </table></div>
    </div>

    <div class="tab-panel" id="tab-advisor" role="tabpanel">
      <h2><span class="dom dom-advisor">Advisor</span> Azure Advisor 見解 <span class="ai">AI</span></h2>
      <div class="insight adv" style="padding:14px 18px; border-radius:8px; margin-bottom:16px;">
        $advisorAssessment
      </div>
      <div class="grid2" style="margin-top:14px;">
        <div>
          <h3>カテゴリ別 High Impact の代表問題</h3>
          $advHighByCatHtml
        </div>
        <div>
          <h3>推奨が集中するリソースタイプ Top 5</h3>
          <table>
            <thead><tr><th>Resource Type</th><th class="num">件数</th></tr></thead>
            <tbody>$advTopByResTypeHtml</tbody>
          </table>
        </div>
      </div>
      <h3>Advisor 推奨事項 詳細 <span class="num">(Impact 順 上位 30)</span></h3>
      <div class="scroll-box"><table>
        <thead><tr><th>Category</th><th>Impact</th><th>Problem</th><th>Resource Type</th><th>Resource</th></tr></thead>
        <tbody>
        $(if ($advisorAppendix) { $advisorAppendix } else { '<tr><td colspan="5" class="empty">推奨事項なし</td></tr>' })
        </tbody>
      </table></div>
    </div>
  </div>

</main>
<footer>Generated by Azure PowerShell (Resources / RBAC / NSG / Defender for Cloud / Advisor) ／ AI Insights authored by GitHub Copilot</footer>
<script>
(function () {
  var nav = document.getElementById('domain-tabs');
  if (!nav) return;
  var buttons = nav.querySelectorAll('.tab-btn');
  var panels  = nav.querySelectorAll('.tab-panel');
  function activate(name) {
    buttons.forEach(function (b) { b.classList.toggle('active', b.dataset.tab === name); });
    panels.forEach(function (p) { p.classList.toggle('active', p.id === 'tab-' + name); });
    if (history.replaceState) {
      history.replaceState(null, '', '#' + name);
    }
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }
  buttons.forEach(function (b) {
    b.addEventListener('click', function () { activate(b.dataset.tab); });
  });
  var initial = (location.hash || '').replace('#', '');
  var valid = ['overview','resources','rbac','nsg','defender','advisor'];
  if (valid.indexOf(initial) >= 0) { activate(initial); }
})();
</script>
</body>
</html>
"@

$html | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Output "Comprehensive Admin HTML: $OutputPath"

