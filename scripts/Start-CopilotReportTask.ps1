<#
.SYNOPSIS
    Copilot Cloud Agent にレポート本文（output/body.json）の執筆を依頼し、PR を作成させる。

.DESCRIPTION
    Agent tasks API (public preview) を user-to-server トークン（PAT）で呼び出す。
      - POST /agents/repos/{owner}/{repo}/tasks       … タスク起動（create_pull_request=true）
      - GET  /agents/repos/{owner}/{repo}/tasks/{id}  … 状態ポーリング

    prompts/report-narrative-task.md をテンプレートとして読み込み、{{FACTS_JSON}} を
    output/facts.json の全文に置換して prompt として渡す。

    設計原則（フォールバック継続）:
      Agent の失敗・タイムアウトでもジョブは止めず、success=false を GITHUB_OUTPUT に書いて exit 0。
      後段の quality-gate ジョブがルールベース HTML にフォールバックする。
      認証・設定エラーは summary に明示する。

    ※ このスクリプトは PAT が必要なため、ローカルでの完全な動作確認は不可。
      Actions 上のライブ実行で検証すること（README の手順参照）。

.NOTES
    必要な PAT 権限（fine-grained）: "Agent tasks" repository permissions (read and write) + contents / pull requests。
    API バージョン: 2026-03-10
#>
[CmdletBinding()]
param(
    [string]$Owner = ($env:GITHUB_REPOSITORY -split '/')[0],
    [string]$Repo  = ($env:GITHUB_REPOSITORY -split '/')[1],

    # user-to-server トークン。GITHUB_TOKEN(server-to-server) は不可。
    [string]$Token = $env:COPILOT_AGENT_PAT,

    [string]$PromptPath = (Join-Path $PSScriptRoot '..\prompts\report-narrative-task.md'),
    [string]$FactsPath  = (Join-Path $PSScriptRoot '..\output\facts.json'),

    [string]$BaseRef = 'main',

    # 省略時は Agent 側の auto 選択。許可モデルはプラン/組織ポリシー依存。
    [string]$Model = $env:COPILOT_AGENT_MODEL,

    [int]$TimeoutMinutes = 30,
    [int]$PollSeconds     = 20,

    # 後段ジョブ向けメタデータ出力
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\output\agent-task.json'),

    [string]$ApiVersion = '2026-03-10'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- 出力ユーティリティ ---------------------------------------------------
function Write-StepSummary {
    param([string]$Text)
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Text -Encoding utf8
    }
}

function Set-Output {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) {
        # 複数行値にも耐える heredoc 形式
        $delim = "ghadelim_$([guid]::NewGuid().ToString('N'))"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name<<$delim`n$Value`n$delim" -Encoding utf8
    }
    Write-Host "output: $Name=$Value"
}

function Complete-AsFallback {
    param([string]$Reason)
    Write-Warning "Copilot Agent 未成功: $Reason → ルールベース HTML にフォールバックします。"
    Write-StepSummary "> [!WARNING]"
    Write-StepSummary "> **Copilot Agent failed / fallback used**  "
    Write-StepSummary "> reason: $Reason  "
    Write-StepSummary "> run_id: $($env:GITHUB_RUN_ID)"
    Set-Output -Name 'success'    -Value 'false'
    Set-Output -Name 'reason'     -Value $Reason
    Set-Output -Name 'task_state' -Value ($script:LastState ?? 'n/a')
    # メタデータも残す
    try {
        $meta = [ordered]@{
            success   = $false
            reason    = $Reason
            taskId    = $script:TaskId
            state     = $script:LastState
            runId     = $env:GITHUB_RUN_ID
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $meta | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutputPath -Encoding utf8
    } catch { Write-Warning "メタデータ書き込み失敗: $($_.Exception.Message)" }
    exit 0
}

# ---- API 呼び出しラッパー -------------------------------------------------
function Invoke-AgentApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body
    )
    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'Authorization'        = "Bearer $Token"
        'X-GitHub-Api-Version' = $ApiVersion
        'User-Agent'           = 'azure-inventory-insights-generator'
    }
    $uri = "https://api.github.com$Path"
    $params = @{
        Method             = $Method
        Uri                = $uri
        Headers            = $headers
        SkipHttpErrorCheck = $true
        ErrorAction        = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 20)
        $params.ContentType = 'application/json'
    }
    $resp = Invoke-WebRequest @params
    $obj = $null
    if ($resp.Content) {
        try { $obj = $resp.Content | ConvertFrom-Json } catch { $obj = $null }
    }
    return [pscustomobject]@{
        StatusCode = [int]$resp.StatusCode
        Data       = $obj
        Raw        = $resp.Content
    }
}

# ---- 前提チェック ---------------------------------------------------------
$script:TaskId    = $null
$script:LastState = $null

if (-not $Owner -or -not $Repo) { Complete-AsFallback "owner/repo を特定できません（GITHUB_REPOSITORY 未設定）。" }
if (-not $Token) { Complete-AsFallback "PAT (COPILOT_AGENT_PAT) が未設定です。secrets を確認してください。" }
if (-not (Test-Path $PromptPath)) { Complete-AsFallback "プロンプトが見つかりません: $PromptPath" }
if (-not (Test-Path $FactsPath))  { Complete-AsFallback "facts.json が見つかりません: $FactsPath" }

# ---- プロンプト組み立て ---------------------------------------------------
$factsRaw   = Get-Content -Path $FactsPath -Raw
$promptTmpl = Get-Content -Path $PromptPath -Raw
$prompt     = $promptTmpl.Replace('{{FACTS_JSON}}', $factsRaw)

Write-Host "Copilot Agent タスクを起動します: $Owner/$Repo (base_ref=$BaseRef, model=$([string]::IsNullOrWhiteSpace($Model) ? 'auto' : $Model))"

# ---- タスク起動 -----------------------------------------------------------
$body = [ordered]@{
    prompt              = $prompt
    base_ref            = $BaseRef
    create_pull_request = $true
}
if (-not [string]::IsNullOrWhiteSpace($Model)) { $body.model = $Model }

try {
    $start = Invoke-AgentApi -Method POST -Path "/agents/repos/$Owner/$Repo/tasks" -Body $body
} catch {
    Complete-AsFallback "タスク起動リクエストが例外で失敗: $($_.Exception.Message)"
}

if ($start.StatusCode -ne 201) {
    Complete-AsFallback "タスク起動失敗 (HTTP $($start.StatusCode)): $($start.Raw)"
}

$script:TaskId    = $start.Data.id
$script:LastState = $start.Data.state
if (-not $script:TaskId) { Complete-AsFallback "起動レスポンスに task id がありません: $($start.Raw)" }

Write-Host "タスク起動成功: id=$($script:TaskId) state=$($script:LastState) html_url=$($start.Data.html_url)"

# ---- ポーリング -----------------------------------------------------------
$deadline       = (Get-Date).AddMinutes($TimeoutMinutes)
$terminalFail   = @('failed','timed_out','cancelled')
$pullArtifact   = $null
$headRef        = $null

while ($true) {
    if ((Get-Date) -gt $deadline) {
        Complete-AsFallback "タイムアウト (${TimeoutMinutes}分)。最終状態: $($script:LastState)"
    }

    Start-Sleep -Seconds $PollSeconds

    try {
        $poll = Invoke-AgentApi -Method GET -Path "/agents/repos/$Owner/$Repo/tasks/$($script:TaskId)"
    } catch {
        Write-Warning "ポーリング中に例外（継続）: $($_.Exception.Message)"
        continue
    }
    if ($poll.StatusCode -ne 200) {
        Write-Warning "ポーリング HTTP $($poll.StatusCode)（継続）: $($poll.Raw)"
        continue
    }

    $task             = $poll.Data
    $script:LastState = $task.state
    Write-Host "[$([DateTime]::UtcNow.ToString('HH:mm:ss'))] state=$($script:LastState)"

    # artifacts から PR / head_ref を抽出
    if ($task.PSObject.Properties.Name -contains 'artifacts' -and $task.artifacts) {
        foreach ($a in $task.artifacts) {
            if ($a.type -eq 'pull' -and $a.data) { $pullArtifact = $a.data }
            if ($a.type -eq 'branch' -and $a.data -and $a.data.PSObject.Properties.Name -contains 'head_ref') {
                $headRef = $a.data.head_ref
            }
        }
    }

    if ($terminalFail -contains $script:LastState) {
        $errMsg = $null
        if ($task.PSObject.Properties.Name -contains 'sessions' -and $task.sessions) {
            $errMsg = ($task.sessions | Where-Object { $_.error } | Select-Object -First 1).error.message
        }
        Complete-AsFallback "Agent タスクが $($script:LastState) で終了。$errMsg"
    }

    # 完了 or PR 生成済みなら成功扱い
    $done = ($script:LastState -eq 'completed') -or ($pullArtifact -and ($script:LastState -in @('completed','idle','waiting_for_user')))
    if ($done) { break }
}

# ---- 成功メタデータ出力 ---------------------------------------------------
$prGlobalId = if ($pullArtifact -and ($pullArtifact.PSObject.Properties.Name -contains 'global_id')) { $pullArtifact.global_id } else { $null }
$prDbId     = if ($pullArtifact -and ($pullArtifact.PSObject.Properties.Name -contains 'id'))        { $pullArtifact.id }        else { $null }

Write-Host "Agent タスク完了: state=$($script:LastState) head_ref=$headRef pr_id=$prDbId"
Write-StepSummary "> [!NOTE]"
Write-StepSummary "> **Copilot Agent task completed**  "
Write-StepSummary "> task_id: $($script:TaskId)  "
Write-StepSummary "> state: $($script:LastState)  "
Write-StepSummary "> head_ref: $headRef  "
Write-StepSummary "> run_id: $($env:GITHUB_RUN_ID)"

Set-Output -Name 'success'     -Value 'true'
Set-Output -Name 'task_id'     -Value ([string]$script:TaskId)
Set-Output -Name 'task_state'  -Value ([string]$script:LastState)
Set-Output -Name 'head_ref'    -Value ([string]$headRef)
Set-Output -Name 'pr_global_id' -Value ([string]$prGlobalId)

$meta = [ordered]@{
    success    = $true
    taskId     = $script:TaskId
    state      = $script:LastState
    headRef    = $headRef
    prDbId     = $prDbId
    prGlobalId = $prGlobalId
    htmlUrl    = $start.Data.html_url
    runId      = $env:GITHUB_RUN_ID
    timestamp  = (Get-Date).ToUniversalTime().ToString('o')
}
$dir = Split-Path -Parent $OutputPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$meta | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutputPath -Encoding utf8
Write-Host "メタデータを出力: $OutputPath"
