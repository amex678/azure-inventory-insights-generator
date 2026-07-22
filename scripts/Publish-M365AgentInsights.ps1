<#
.SYNOPSIS
    gh-aw の検証済み safe output を公開用 insights.json に変換する。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AgentOutputPath,
    [Parameter(Mandatory)][string]$MessagesJson,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $AgentOutputPath)) { throw "Agent output not found: $AgentOutputPath" }
if (-not (Test-Path -LiteralPath $MessagesJson)) { throw "Messages JSON not found: $MessagesJson" }

$agentOutput = Get-Content -LiteralPath $AgentOutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($agentOutput.items | Where-Object type -eq 'publish_m365_dashboard')
if ($items.Count -ne 1) { throw "Expected exactly one publish_m365_dashboard item, got $($items.Count)." }
$item = $items[0]

function Get-SafeText {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(1, 10000)][int]$MaxLength
    )
    if (-not ($item.PSObject.Properties.Name -contains $Name)) { throw "Missing insight field: $Name" }
    $value = [string]$item.$Name
    $value = ($value -replace '[\u0000-\u0008\u000B\u000C\u000E-\u001F]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Insight field is empty: $Name" }
    if ($value.Length -gt $MaxLength) { throw "Insight field exceeds $MaxLength characters: $Name" }
    if ($value -match '<\s*(script|iframe|object|embed|style|svg)\b' -or $value -match '(?i)javascript:|data:text/html') {
        throw "Unsafe content detected in insight field: $Name"
    }
    return $value
}

$messages = Get-Content -LiteralPath $MessagesJson -Raw -Encoding UTF8 | ConvertFrom-Json
$allowedIds = @($messages.messages | ForEach-Object { [string]$_.id })
$referencedIds = @(
    ([string]$item.referenced_ids -split '[,\s]+') |
        Where-Object { $_ } |
        ForEach-Object { $_.Trim().ToUpperInvariant() } |
        Sort-Object -Unique
)
$invalidIds = @($referencedIds | Where-Object { $_ -notin $allowedIds })
if ($invalidIds.Count) { throw "Agent referenced unknown MC IDs: $($invalidIds -join ', ')" }

$insights = [ordered]@{
    generatedAt       = [DateTimeOffset]::UtcNow.ToString('o')
    source            = 'GitHub Agentic Workflows / Copilot'
    headline          = Get-SafeText -Name 'headline' -MaxLength 160
    executiveSummary  = Get-SafeText -Name 'executive_summary' -MaxLength 2000
    thisWeek          = Get-SafeText -Name 'this_week' -MaxLength 3000
    thisMonth         = Get-SafeText -Name 'this_month' -MaxLength 3000
    watch             = Get-SafeText -Name 'watch' -MaxLength 3000
    customerQuestions = Get-SafeText -Name 'customer_questions' -MaxLength 3000
    referencedIds     = $referencedIds
}

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$insights | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Published validated Agentic insights to $OutputPath"

