<#
.SYNOPSIS
    CI ゲート②: 事実整合性チェック。body.json の散文が facts.json 由来かを検証する。
.DESCRIPTION
    検証内容:
      1. body.slots が存在すること
      2. すべての fact_ids が facts.json に実在するキーであること（無効参照は fail）
      3. Assessment / Risk スロットは非空の fact_ids を持つこと（根拠なしの主張を禁止）
      4. 散文中の数値・割合が facts の数値のいずれかに一致すること
         （ポート/計画日数/年などのドメイン定数はホワイトリストで許容）
    いずれか fail の場合 exit 1。呼び出し側はフォールバックへ切替える。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BodyJson,
    [Parameter(Mandatory)][string]$FactsJson
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BodyJson))  { Write-Host "::error::body.json が見つかりません: $BodyJson";  exit 1 }
if (-not (Test-Path $FactsJson)) { Write-Host "::error::facts.json が見つかりません: $FactsJson"; exit 1 }

$body  = Get-Content $BodyJson  -Raw -Encoding UTF8 | ConvertFrom-Json
$facts = Get-Content $FactsJson -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $body.slots) { Write-Host "::error::body.json に slots がありません"; exit 1 }

$errors = @()

# --- 有効な fact_id 集合を構築 ---
$validFactIds = [System.Collections.Generic.HashSet[string]]::new()
if ($facts.facts) {
    foreach ($p in $facts.facts.PSObject.Properties) { [void]$validFactIds.Add($p.Name) }
}
if ($facts.scores) {
    foreach ($p in $facts.scores.PSObject.Properties) { [void]$validFactIds.Add("scores.$($p.Name)") }
}

# --- 有効な数値集合（facts の全数値）---
$validNumbers = [System.Collections.Generic.HashSet[double]]::new()
function Add-Number([object]$v) {
    $d = 0.0
    if ([double]::TryParse([string]$v, [ref]$d)) { [void]$validNumbers.Add([math]::Round($d, 3)) }
}
if ($facts.facts)  { foreach ($p in $facts.facts.PSObject.Properties)  { Add-Number $p.Value } }
if ($facts.scores) { foreach ($p in $facts.scores.PSObject.Properties) { Add-Number $p.Value } }

# ドメイン定数（facts に無くても許容）: ポート・計画日数・週・年・軸数など
$whitelist = @(0,1,2,3,4,5,6,7,8,9,10,14,15,18,20,21,24,25,28,30,50,80,100,443,3389,22)
foreach ($n in $whitelist) { }  # 参照用
$yearMin = 2020; $yearMax = 2035

# --- 散文からテキストと fact_ids を収集 ---
$proseBlocks = @()   # @{ text=; factIds=; label=; requireFactIds= }

function Add-Block($text, $factIds, $label, $require) {
    $script:proseBlocks += [pscustomobject]@{ Text=[string]$text; FactIds=@($factIds); Label=$label; Require=$require }
}

$s = $body.slots
if ($s.verdictDesc) { Add-Block $s.verdictDesc @() 'verdictDesc' $false }
if ($s.concerns)  { foreach ($c in @($s.concerns))  { if ($c) { Add-Block $c @() 'concerns'  $false } } }
if ($s.strengths) { foreach ($c in @($s.strengths)) { if ($c) { Add-Block $c @() 'strengths' $false } } }
if ($s.focus)     { foreach ($c in @($s.focus))     { if ($c) { Add-Block $c @() 'focus'     $false } } }

foreach ($key in 'resourcesAssessment','rbacAssessment','nsgAssessment','defenderAssessment','advisorAssessment') {
    $a = $s.$key
    if ($a) {
        $txt = @($a.summary) + @($a.findings) + @($a.recommendation) -join ' '
        Add-Block $txt $a.fact_ids $key $true
    }
}
if ($s.risks) {
    foreach ($r in @($s.risks)) {
        if (-not $r) { continue }
        $txt = @($r.fact) + @($r.reason) + @($r.recommend) -join ' '
        Add-Block $txt $r.fact_ids "risk#$($r.rank)" $true
    }
}
if ($s.actionPlan) {
    foreach ($p in @($s.actionPlan)) {
        if (-not $p) { continue }
        Add-Block (@($p.title) + @($p.detail) -join ' ') $p.fact_ids "plan:$($p.window)" $false
    }
}

# --- 検証 ---
foreach ($b in $proseBlocks) {
    # fact_ids 実在チェック
    foreach ($fid in $b.FactIds) {
        if (-not [string]::IsNullOrWhiteSpace($fid) -and -not $validFactIds.Contains([string]$fid)) {
            $errors += "[$($b.Label)] 無効な fact_id: '$fid'"
        }
    }
    # 根拠必須スロットの fact_ids 非空チェック
    $nonEmpty = @($b.FactIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($b.Require -and $nonEmpty.Count -eq 0) {
        $errors += "[$($b.Label)] 数値を含む主張に fact_ids がありません（根拠必須）"
    }
    # 数値整合チェック
    $matches = [regex]::Matches([string]$b.Text, '(?<![\w.])\d+(?:\.\d+)?')
    foreach ($m in $matches) {
        $numStr = $m.Value
        $d = 0.0
        [void][double]::TryParse($numStr, [ref]$d)
        $rounded = [math]::Round($d, 3)
        $ok = $validNumbers.Contains($rounded) `
              -or ($whitelist -contains [int]$d) `
              -or ($d -ge $yearMin -and $d -le $yearMax)
        if (-not $ok) {
            $errors += "[$($b.Label)] facts に無い数値: '$numStr'（創作の疑い）"
        }
    }
}

Write-Host "== factcheck gate =="
Write-Host "有効 fact_id 数: $($validFactIds.Count) / 有効数値数: $($validNumbers.Count) / 検査ブロック: $($proseBlocks.Count)"

if ($errors.Count -gt 0) {
    $errors | Select-Object -Unique | ForEach-Object { Write-Host "::error::$_" }
    Write-Host "FAIL: 事実整合性エラー $($errors.Count) 件"
    exit 1
}
Write-Host "PASS: すべての数値・fact_id が facts.json 由来"
exit 0
