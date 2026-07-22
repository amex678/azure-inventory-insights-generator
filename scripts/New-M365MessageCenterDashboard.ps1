<#
.SYNOPSIS
    公開許可済み Message Center メタデータから単一 HTML ダッシュボードを生成する。
#>
[CmdletBinding()]
param(
    [string]$MessagesJson = (Join-Path $PSScriptRoot '..\output\m365\messages.json'),
    [string]$InsightsJson,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\output\m365\index.html')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $MessagesJson)) { throw "Messages JSON not found: $MessagesJson" }
$data = Get-Content -LiteralPath $MessagesJson -Raw -Encoding UTF8 | ConvertFrom-Json
$safeJson = $data | ConvertTo-Json -Depth 12 -Compress
$safeJson = $safeJson.Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e')
$safeInsightsJson = 'null'
if ($InsightsJson -and (Test-Path -LiteralPath $InsightsJson)) {
    $insights = Get-Content -LiteralPath $InsightsJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $safeInsightsJson = $insights | ConvertTo-Json -Depth 8 -Compress
    $safeInsightsJson = $safeInsightsJson.Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e')
}

$html = @'
<!doctype html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <script>
    (() => {
      const param = new URLSearchParams(window.location.search).get("scoutTheme");
      const theme =
        param || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
      document.documentElement.setAttribute("data-theme", theme);
    })();
  </script>
  <title>Microsoft 365 Change Radar</title>
  <style>
    :root {
      color-scheme: light;
      --cp-bg: #f7f4ef;
      --cp-bg-elevated: #fcfbf8;
      --cp-surface: #ffffff;
      --cp-surface-soft: #f5f5f5;
      --cp-border: #dedede;
      --cp-border-strong: #919191;
      --cp-text: #242424;
      --cp-text-muted: #5c5c5c;
      --cp-text-soft: #6f6f6f;
      --cp-accent: #b11f4b;
      --cp-accent-hover: #9a1a41;
      --cp-accent-soft: rgba(177, 31, 75, 0.08);
      --cp-accent-fg: #ffffff;
      --cp-success: #16a34a;
      --cp-danger: #dc2626;
      --cp-warning: #f59e0b;
      --cp-link: #0078d4;
      --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.12);
      --cp-overlay: rgba(255, 255, 255, 0.8);
      --cp-panel: rgba(255, 255, 255, 0.86);
      --cp-panel-strong: rgba(255, 255, 255, 0.96);
      --cp-sheen: rgba(255, 255, 255, 0.55);
      --cp-highlight: rgba(177, 31, 75, 0.12);
    }
    html[data-theme="dark"] {
      color-scheme: dark;
      --cp-bg: #3d3b3a;
      --cp-bg-elevated: #343231;
      --cp-surface: #292929;
      --cp-surface-soft: #2e2e2e;
      --cp-border: #474747;
      --cp-border-strong: #5f5f5f;
      --cp-text: #dedede;
      --cp-text-muted: #919191;
      --cp-text-soft: #b0b0b0;
      --cp-accent: #fd8ea1;
      --cp-accent-hover: #fb7b91;
      --cp-accent-soft: rgba(253, 142, 161, 0.14);
      --cp-accent-fg: #1a1a1a;
      --cp-success: #4ade80;
      --cp-danger: #f87171;
      --cp-warning: #fbbf24;
      --cp-link: #4da6ff;
      --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.32);
      --cp-overlay: rgba(41, 41, 41, 0.88);
      --cp-panel: rgba(41, 41, 41, 0.72);
      --cp-panel-strong: rgba(41, 41, 41, 0.96);
      --cp-sheen: rgba(255, 255, 255, 0.04);
      --cp-highlight: rgba(253, 142, 161, 0.12);
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body {
      margin: 0;
      background: var(--cp-bg);
      color: var(--cp-text);
      font-family: "Segoe UI", Aptos, Calibri, -apple-system, BlinkMacSystemFont, sans-serif;
      line-height: 1.5;
      min-height: 100vh;
    }
    .aurora {
      position: fixed; inset: 0; z-index: -1; pointer-events: none;
      background:
        radial-gradient(circle at 10% 5%, color-mix(in srgb, var(--cp-link) 24%, var(--cp-bg)) 0, var(--cp-bg) 32%),
        radial-gradient(circle at 92% 12%, color-mix(in srgb, var(--cp-accent) 20%, var(--cp-bg)) 0, var(--cp-bg) 30%),
        radial-gradient(circle at 78% 82%, color-mix(in srgb, var(--cp-warning) 18%, var(--cp-bg)) 0, var(--cp-bg) 34%),
        radial-gradient(circle at 12% 88%, color-mix(in srgb, var(--cp-success) 16%, var(--cp-bg)) 0, var(--cp-bg) 30%);
    }
    button, input { font: inherit; }
    .shell { width: min(1180px, calc(100% - 32px)); margin: 0 auto; padding: 28px 0 64px; }
    .nav {
      position: sticky; top: 12px; z-index: 10; display: flex; align-items: center;
      justify-content: space-between; gap: 16px; padding: 12px 16px;
      background: var(--cp-panel); border: 1px solid var(--cp-border); border-radius: 16px;
      backdrop-filter: blur(20px); box-shadow: 0 1px 2px var(--cp-border);
    }
    .brand { display: flex; align-items: center; gap: 10px; font-weight: 700; letter-spacing: -0.02em; }
    .brand-mark {
      width: 32px; height: 32px; display: grid; place-items: center; border-radius: 0.625rem;
      color: var(--cp-accent-fg);
      background: linear-gradient(135deg, var(--cp-link), var(--cp-accent), var(--cp-warning));
    }
    .nav-meta { color: var(--cp-text-muted); font-size: 0.84rem; text-align: right; }
    .source-status { font-weight: 700; color: var(--cp-text); }
    .hero { padding: 88px 8px 48px; max-width: 840px; }
    .eyebrow { color: var(--cp-text-muted); font-size: 0.82rem; font-weight: 800; letter-spacing: 0.14em; text-transform: uppercase; }
    h1 {
      margin: 12px 0 18px; font-size: clamp(3rem, 8vw, 6.6rem); line-height: 0.94; letter-spacing: -0.075em;
      color: var(--cp-text);
      background: linear-gradient(105deg, var(--cp-link), var(--cp-accent), var(--cp-warning), var(--cp-success));
      background-clip: text; -webkit-background-clip: text; -webkit-text-fill-color: transparent;
    }
    .lede { max-width: 720px; margin: 0; color: var(--cp-text-muted); font-size: clamp(1.05rem, 2vw, 1.35rem); }
    .insights {
      padding: clamp(24px, 5vw, 48px); margin-bottom: 18px; overflow: hidden;
      background: var(--cp-panel-strong); border: 1px solid var(--cp-border); border-radius: 16px;
      box-shadow: 0 1px 2px var(--cp-border); backdrop-filter: blur(24px);
    }
    .insight-headline { max-width: 900px; margin: 8px 0 14px; font-size: clamp(1.8rem, 4vw, 3.5rem); line-height: 1.08; letter-spacing: -0.055em; }
    .insight-summary { max-width: 900px; margin: 0; color: var(--cp-text-muted); font-size: 1.05rem; }
    .insight-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-top: 28px; }
    .insight-column { padding: 18px; background: var(--cp-surface-soft); border: 1px solid var(--cp-border); border-radius: 0.625rem; }
    .insight-column h3 { margin: 0 0 10px; font-size: 0.78rem; letter-spacing: 0.1em; text-transform: uppercase; }
    .insight-column ul { margin: 0; padding-left: 18px; color: var(--cp-text-muted); }
    .insight-column li + li { margin-top: 8px; }
    .insight-pending { color: var(--cp-text-muted); }
    .metrics { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 48px; }
    .metric, .panel, .message {
      background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 16px;
      box-shadow: 0 1px 2px var(--cp-border);
    }
    .metric { padding: 22px; min-height: 150px; display: flex; flex-direction: column; justify-content: space-between; }
    .metric-value { font-size: 2.7rem; font-weight: 750; letter-spacing: -0.055em; }
    .metric-label { color: var(--cp-text-muted); font-size: 0.88rem; }
    .metric-alert .metric-value { color: var(--cp-link); }
    .section-head { display: flex; align-items: end; justify-content: space-between; gap: 20px; margin: 40px 0 16px; }
    h2 { margin: 0; font-size: clamp(1.8rem, 4vw, 3rem); letter-spacing: -0.045em; }
    .section-note { color: var(--cp-text-muted); font-size: 0.9rem; }
    .services { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; }
    .service { padding: 16px; background: var(--cp-bg-elevated); border: 1px solid var(--cp-border); border-radius: 0.625rem; }
    .service strong { display: block; font-size: 1.35rem; }
    .service span { color: var(--cp-text-muted); font-size: 0.82rem; }
    .toolbar { display: grid; grid-template-columns: minmax(220px, 1fr) auto; gap: 12px; margin-bottom: 14px; }
    .search {
      width: 100%; padding: 13px 16px; color: var(--cp-text); background: var(--cp-surface);
      border: 1px solid var(--cp-border); border-radius: 0.625rem; outline: none;
    }
    .search:focus { border-color: var(--cp-accent); box-shadow: 0 0 0 3px var(--cp-accent-soft); }
    .filters { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
    .filter {
      padding: 10px 14px; color: var(--cp-text-muted); background: var(--cp-surface);
      border: 1px solid var(--cp-border); border-radius: 999px; cursor: pointer;
    }
    .filter:hover, .filter.active {
      color: var(--cp-accent-fg);
      background: linear-gradient(110deg, var(--cp-link), var(--cp-accent), var(--cp-warning));
      border-color: var(--cp-border-strong);
    }
    .message-list { display: grid; gap: 10px; }
    .message { padding: 20px; transition: transform 140ms ease, border-color 140ms ease; }
    .message:hover { transform: translateY(-1px); border-color: var(--cp-border-strong); }
    .message-top { display: flex; justify-content: space-between; gap: 20px; }
    .message h3 { margin: 6px 0 10px; font-size: 1.12rem; letter-spacing: -0.02em; }
    .message-id { color: var(--cp-text-soft); font-family: Consolas, "Courier New", Courier, monospace; font-size: 0.78rem; }
    .message-date { min-width: 105px; color: var(--cp-text-muted); font-size: 0.82rem; text-align: right; }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; }
    .chip { padding: 4px 9px; color: var(--cp-text-muted); background: var(--cp-surface-soft); border-radius: 999px; font-size: 0.75rem; }
    .chip.major { color: var(--cp-accent); background: var(--cp-accent-soft); font-weight: 700; }
    .chip.high { color: var(--cp-danger); font-weight: 700; }
    .chip.due { color: var(--cp-warning); font-weight: 700; }
    .empty { padding: 48px; color: var(--cp-text-muted); text-align: center; }
    footer { padding: 56px 8px 0; color: var(--cp-text-muted); font-size: 0.82rem; }
    @media (max-width: 820px) {
      .metrics, .services { grid-template-columns: repeat(2, 1fr); }
      .insight-grid { grid-template-columns: 1fr; }
      .toolbar { grid-template-columns: 1fr; }
      .filters { justify-content: flex-start; }
    }
    @media (max-width: 520px) {
      .shell { width: min(100% - 20px, 1180px); padding-top: 10px; }
      .nav-meta { display: none; }
      .hero { padding-top: 64px; }
      .metrics { grid-template-columns: 1fr 1fr; }
      .metric { min-height: 120px; padding: 16px; }
      .metric-value { font-size: 2.1rem; }
      .services { grid-template-columns: 1fr; }
      .message-top { display: block; }
      .message-date { margin-top: 8px; text-align: left; }
    }
  </style>
</head>
<body>
  <div class="aurora" aria-hidden="true"></div>
  <main class="shell">
    <nav class="nav" aria-label="Dashboard navigation">
      <div class="brand"><span class="brand-mark">M</span><span>Microsoft 365 Change Radar</span></div>
      <div class="nav-meta"><div id="generated"></div><div class="source-status" id="source-status"></div></div>
    </nav>

    <header class="hero">
      <div class="eyebrow">Weekly intelligence</div>
      <h1>変化を、<br>先回りする。</h1>
      <p class="lede">Microsoft 365 Message Center の本文をAgentic Workflowが読み解き、公開可能な要約とメタデータだけを届ける週次レーダー。</p>
    </header>

    <section class="insights" aria-label="Agentic weekly insights">
      <div class="eyebrow">Copilot weekly brief</div>
      <div id="insight-content"></div>
    </section>

    <section class="metrics" aria-label="Summary metrics">
      <article class="metric"><div class="metric-label">Tracked messages</div><div class="metric-value" id="metric-total">0</div></article>
      <article class="metric metric-alert"><div class="metric-label">Major changes</div><div class="metric-value" id="metric-major">0</div></article>
      <article class="metric"><div class="metric-label">Due within 30 days</div><div class="metric-value" id="metric-due">0</div></article>
      <article class="metric"><div class="metric-label">Updated this week</div><div class="metric-value" id="metric-updated">0</div></article>
    </section>

    <section>
      <div class="section-head"><div><div class="eyebrow">Signal map</div><h2>影響サービス</h2></div><div class="section-note">上位8サービス</div></div>
      <div class="services" id="services"></div>
    </section>

    <section>
      <div class="section-head"><div><div class="eyebrow">Message stream</div><h2>変更一覧</h2></div><div class="section-note" id="result-count"></div></div>
      <div class="toolbar">
        <input class="search" id="search" type="search" placeholder="タイトル、MC ID、サービスを検索" aria-label="Search messages">
        <div class="filters" aria-label="Message filters">
          <button class="filter active" data-filter="all">すべて</button>
          <button class="filter" data-filter="major">Major</button>
          <button class="filter" data-filter="due">期限あり</button>
          <button class="filter" data-filter="high">High</button>
        </div>
      </div>
      <div class="message-list" id="messages"></div>
    </section>

    <footer>
      Message Center の本文・詳細・テナント識別子は公開していません。表示内容は自動収集されたメタデータであり、正式な判断は Microsoft 365 管理センターで確認してください。
    </footer>
  </main>

  <script>
    const DATA = __DATA__;
    const INSIGHTS = __INSIGHTS__;
    const state = { filter: "all", query: "" };
    const fmt = value => value ? new Intl.DateTimeFormat("ja-JP", { year: "numeric", month: "short", day: "numeric" }).format(new Date(value)) : "—";
    const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);

    document.getElementById("generated").textContent = `Updated ${fmt(DATA.meta.generatedAt)}`;
    document.getElementById("source-status").textContent =
      DATA.meta.source === "fixture" ? "Synthetic preview data" : "Live tenant via AZURE_TENANT_ID";
    document.getElementById("metric-total").textContent = DATA.summary.total;
    document.getElementById("metric-major").textContent = DATA.summary.majorChanges;
    document.getElementById("metric-due").textContent = DATA.summary.actionDueWithin30Days;
    document.getElementById("metric-updated").textContent = DATA.summary.updatedLast7Days;

    const listItems = value => String(value || "")
      .split(/\r?\n/)
      .map(line => line.replace(/^\s*[-*・]\s*/, "").trim())
      .filter(Boolean)
      .map(line => `<li>${escapeHtml(line)}</li>`)
      .join("");
    document.getElementById("insight-content").innerHTML = INSIGHTS
      ? `<h2 class="insight-headline">${escapeHtml(INSIGHTS.headline)}</h2>
         <p class="insight-summary">${escapeHtml(INSIGHTS.executiveSummary)}</p>
         <div class="insight-grid">
           <article class="insight-column"><h3>今週確認</h3><ul>${listItems(INSIGHTS.thisWeek)}</ul></article>
           <article class="insight-column"><h3>今月準備</h3><ul>${listItems(INSIGHTS.thisMonth)}</ul></article>
           <article class="insight-column"><h3>継続監視</h3><ul>${listItems(INSIGHTS.watch)}</ul></article>
         </div>`
      : `<h2 class="insight-headline">週次要約を準備中です。</h2>
         <p class="insight-pending">初回のGitHub Agentic Workflow完了後、ここに重要変更・期限・推奨アクションが表示されます。</p>`;

    document.getElementById("services").innerHTML = DATA.topServices.length
      ? DATA.topServices.map(service => `<article class="service"><strong>${service.count}</strong><span>${escapeHtml(service.name)}</span></article>`).join("")
      : `<div class="empty">サービス情報はありません。</div>`;

    function matches(message) {
      const haystack = [message.id, message.title, message.category, message.severity, ...(message.services || [])].join(" ").toLowerCase();
      if (state.query && !haystack.includes(state.query)) return false;
      if (state.filter === "major" && !message.isMajorChange) return false;
      if (state.filter === "due" && !message.actionRequiredByDateTime) return false;
      if (state.filter === "high" && !["high", "critical"].includes(String(message.severity).toLowerCase())) return false;
      return true;
    }

    function render() {
      const visible = DATA.messages.filter(matches);
      document.getElementById("result-count").textContent = `${visible.length} / ${DATA.messages.length} messages`;
      document.getElementById("messages").innerHTML = visible.length ? visible.map(message => {
        const high = ["high", "critical"].includes(String(message.severity).toLowerCase());
        const chips = [
          message.isMajorChange ? `<span class="chip major">Major change</span>` : "",
          high ? `<span class="chip high">${escapeHtml(message.severity)}</span>` : "",
          message.actionRequiredByDateTime ? `<span class="chip due">Action ${fmt(message.actionRequiredByDateTime)}</span>` : "",
          `<span class="chip">${escapeHtml(message.category || "Uncategorized")}</span>`,
          ...(message.services || []).map(service => `<span class="chip">${escapeHtml(service)}</span>`)
        ].filter(Boolean).join("");
        return `<article class="message">
          <div class="message-top">
            <div><div class="message-id">${escapeHtml(message.id)}</div><h3>${escapeHtml(message.title)}</h3><div class="chips">${chips}</div></div>
            <div class="message-date"><div>更新 ${fmt(message.lastModifiedDateTime)}</div><div>開始 ${fmt(message.startDateTime)}</div></div>
          </div>
        </article>`;
      }).join("") : `<div class="panel empty">条件に一致するメッセージはありません。</div>`;
    }

    document.getElementById("search").addEventListener("input", event => {
      state.query = event.target.value.trim().toLowerCase();
      render();
    });
    document.querySelectorAll(".filter").forEach(button => button.addEventListener("click", () => {
      document.querySelectorAll(".filter").forEach(item => item.classList.remove("active"));
      button.classList.add("active");
      state.filter = button.dataset.filter;
      render();
    }));
    render();
  </script>
</body>
</html>
'@

$html = $html.Replace('__DATA__', $safeJson)
$html = $html.Replace('__INSIGHTS__', $safeInsightsJson)
$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$html | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Dashboard written to $OutputPath"
