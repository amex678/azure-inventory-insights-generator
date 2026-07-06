<#
.SYNOPSIS
    CI ゲート①: 変更ファイル allowlist。
    Copilot Agent の PR で変更が許されるのは output/body.json のみ。
    それ以外（.github/**, scripts/**, prompts/**, templates/** 等）の変更は即 fail。
.NOTES
    プロンプトは境界にならないため、リポジトリ改変を CI で機械的に拒否する最重要ゲート。
#>
[CmdletBinding()]
param(
    # 改行区切りの変更ファイル一覧（git diff --name-only の出力等）。未指定なら stdin から読む。
    [string]$ChangedFiles = '',
    [string[]]$Allowed = @('output/body.json')
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ChangedFiles)) {
    $ChangedFiles = [Console]::In.ReadToEnd()
}
$files = @($ChangedFiles -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

if ($files.Count -eq 0) {
    Write-Host "::warning::変更ファイルが 0 件です。検証対象なし。"
    exit 0
}

$normalizedAllowed = $Allowed | ForEach-Object { $_.Replace('\','/').ToLowerInvariant() }
$violations = @()
foreach ($f in $files) {
    $n = $f.Replace('\','/').ToLowerInvariant()
    if ($normalizedAllowed -notcontains $n) { $violations += $f }
}

Write-Host "== allowlist gate =="
Write-Host "許可: $($Allowed -join ', ')"
Write-Host "変更: $($files -join ', ')"

if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "::error::許可外のファイルが変更されています: $v" }
    Write-Host "FAIL: allowlist 違反 $($violations.Count) 件"
    exit 1
}
Write-Host "PASS: 変更は許可対象のみ"
exit 0
