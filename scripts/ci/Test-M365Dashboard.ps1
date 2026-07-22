[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "m365-dashboard-$([guid]::NewGuid().ToString('N'))"
$agentContext = Join-Path $temp 'agent-context.json'
$publishedInsights = Join-Path $temp 'insights.json'

try {
    & (Join-Path $root 'scripts\Export-M365MessageCenter.ps1') `
        -InputJsonPath (Join-Path $root 'tests\fixtures\m365-messages.json') `
        -OutputDirectory $temp `
        -LookbackDays 365 `
        -RunId 'fixture-run' `
        -ReferenceTime '2026-07-23T00:00:00Z' `
        -AgentContextPath $agentContext
    & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
        -AgentOutputPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output.json') `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -OutputPath $publishedInsights
    & (Join-Path $root 'scripts\New-M365MessageCenterDashboard.ps1') `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -InsightsJson $publishedInsights `
        -OutputPath (Join-Path $temp 'index.html')

    $messagesRaw = Get-Content -LiteralPath (Join-Path $temp 'messages.json') -Raw -Encoding UTF8
    $messages = $messagesRaw | ConvertFrom-Json
    $html = Get-Content -LiteralPath (Join-Path $temp 'index.html') -Raw -Encoding UTF8

    if ($messages.messages.Count -ne 3) { throw "Expected 3 messages, got $($messages.messages.Count)." }
    if ($messagesRaw -match 'THIS_BODY|THIS_DETAIL|"body"|"details"') { throw 'Private body/details leaked into public JSON.' }
    if ($html -match 'THIS_BODY|THIS_DETAIL') { throw 'Private fixture content leaked into dashboard HTML.' }
    if ((Get-Content -LiteralPath $agentContext -Raw -Encoding UTF8) -notmatch 'THIS_BODY_MUST_NEVER_BE_PUBLISHED') {
        throw 'Transient agent context did not include the message body for summarization.'
    }
    if ($html -notmatch '共同作業と管理者設定の変更') { throw 'Agentic summary is missing from dashboard HTML.' }
    if ($html -notmatch 'Microsoft 365 Change Radar') { throw 'Dashboard title is missing.' }
    if ($html -notmatch 'scoutTheme' -or $html -notmatch '--cp-accent') { throw 'Mandatory artifact theme is missing.' }
    if ($html -match '<script[^>]+src=' -or $html -match '<link[^>]+href=') { throw 'Dashboard contains external resources.' }

    Write-Host 'M365 dashboard fixture validation passed.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
