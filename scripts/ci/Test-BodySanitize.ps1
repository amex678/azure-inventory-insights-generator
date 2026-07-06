<#
.SYNOPSIS
    CI ゲート③: HTML/インジェクション サニタイズ検証。
    body.json の散文はプレーンテキスト + 限定 Markdown のみ許可。
    HTML タグ・イベントハンドラ・javascript:・data:・外部 URL・Markdown リンクを検出したら fail。
.NOTES
    レンダラ側の HTML escape と二重防御。LLM が制約を無視して HTML を書いた場合を検出する。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BodyJson
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BodyJson)) { Write-Host "::error::body.json が見つかりません: $BodyJson"; exit 1 }
$body = Get-Content $BodyJson -Raw -Encoding UTF8 | ConvertFrom-Json

# 全 string 値を再帰収集
$strings = [System.Collections.Generic.List[string]]::new()
function Collect($o) {
    if ($null -eq $o) { return }
    if ($o -is [string]) { $strings.Add($o); return }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) {
        foreach ($i in $o) { Collect $i }; return
    }
    if ($o.PSObject -and $o.PSObject.Properties) {
        foreach ($p in $o.PSObject.Properties) { Collect $p.Value }
    }
}
Collect $body.slots

$patterns = [ordered]@{
    'HTML タグ'          = '</?[a-zA-Z][a-zA-Z0-9]*(\s|>|/)'
    'イベントハンドラ'    = '(?i)\bon[a-z]+\s*='
    'javascript: スキーム' = '(?i)javascript:'
    'data: スキーム'      = '(?i)data:'
    'vbscript: スキーム'  = '(?i)vbscript:'
    '外部 URL'           = '(?i)https?://'
    'Markdown リンク'     = '\]\(\s*\S+\s*\)'
    'HTML エンティティ注入' = '&#x?[0-9a-fA-F]+;'
}

$errors = @()
foreach ($str in $strings) {
    foreach ($name in $patterns.Keys) {
        if ([regex]::IsMatch($str, $patterns[$name])) {
            $snippet = $str.Substring(0, [Math]::Min(60, $str.Length))
            $errors += "$name を検出: `"$snippet...`""
        }
    }
}

Write-Host "== sanitize gate =="
Write-Host "検査文字列数: $($strings.Count)"

if ($errors.Count -gt 0) {
    $errors | Select-Object -Unique | ForEach-Object { Write-Host "::error::$_" }
    Write-Host "FAIL: 不正コンテンツ $($errors.Count) 件（散文はプレーンテキスト + 限定 Markdown のみ許可）"
    exit 1
}
Write-Host "PASS: HTML/スクリプト/外部リンクなし"
exit 0
