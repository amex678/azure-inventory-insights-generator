# Azure Inventory & Insights Reports

現在ログイン中の Azure サブスクリプションを対象に、リソース / RBAC / NSG / Microsoft Defender for Cloud / Azure Advisor の情報を PowerShell で収集し、CSV / JSON のローデータと総合 HTML レポートを 1 本生成するリポジトリです。

GitHub Copilot の prompt から対話的に実行することも、PowerShell スクリプトを直接実行することもできます。

> 重要: 本リポジトリはデモ / 学習目的のサンプルコードです。Microsoft 公式製品ではなく、無保証 (AS-IS) で提供されます。本番環境で使用する場合は、お客様自身で十分なレビューとテストを実施してください。詳細は [LICENSE](LICENSE) を参照してください。

## できること

| ドメイン | 取得対象 | 出力 |
| --- | --- | --- |
| リソース | `Get-AzResource` 全リソース | CSV / JSON |
| RBAC | `Get-AzRoleAssignment` 全割り当て | CSV / JSON |
| NSG | `Get-AzNetworkSecurityGroup` のルールをフラット化 | CSV / JSON |
| Microsoft Defender for Cloud | `Microsoft.Security/assessments` REST API | CSV / JSON |
| Azure Advisor | `Get-AzAdvisorRecommendation` | CSV / JSON |
| 総合レポート | 上記 5 ドメイン横断分析 | HTML |

総合レポートには以下を含みます。

- エグゼクティブ サマリ
- ドメイン別サマリ表
- 潜在リスク Top 5
- 30 日アクション プラン
- NSG / Defender / Advisor の付録一覧

## 前提条件

- PowerShell 7.x 以上
- Az モジュール
- `Az.Accounts`, `Az.Resources`, `Az.Network` は必須
- `Az.Advisor` は推奨
- 対象 Azure サブスクリプションへの Reader 以上の権限
- Defender for Cloud の評価取得には Security Reader ロール

## セットアップ

```powershell
Install-Module -Name Az         -Scope CurrentUser -Repository PSGallery -Force
Install-Module -Name Az.Advisor -Scope CurrentUser -Repository PSGallery -Force

Connect-AzAccount
Set-AzContext -Subscription "<サブスクリプション名 または ID>"
```

## 使い方

すべてのスクリプトは引数なしで実行できます。出力先は既定で `output/` ディレクトリです。

```powershell
cd scripts

./Export-AzResources.ps1
./Export-AzRoleAssignments.ps1
./Export-AzNsgRules.ps1
./Export-AzDefenderRecommendations.ps1
./Export-AzAdvisorRecommendations.ps1
./New-AzComprehensiveAdminReport.ps1
```

主な成果物:

- `output/resources.{csv,json}`
- `output/rbac.{csv,json}`
- `output/nsg-rules.{csv,json}`
- `output/defender-recommendations.{csv,json}`
- `output/advisor-recommendations.{csv,json}`
- `output/comprehensive-report.html`

## ディレクトリ構成

```
.
├── README.md
├── LICENSE
├── .gitignore
├── .github/
│   └── workflows/
│       └── azure-report-public.yml   # 週次自動生成 + Copilot Agent 連携 + Pages 公開
├── prompts/
│   └── report-narrative-task.md      # Copilot Agent への本文執筆タスク（{{FACTS_JSON}} 置換）
├── docs/
│   └── report-body-schema.md         # output/body.json のスキーマ契約
├── scripts/
│   ├── Export-AzResources.ps1
│   ├── Export-AzRoleAssignments.ps1
│   ├── Export-AzNsgRules.ps1
│   ├── Export-AzDefenderRecommendations.ps1
│   ├── Export-AzAdvisorRecommendations.ps1
│   ├── Export-AzFacts.ps1            # facts.json（全数値の唯一の出典）を生成
│   ├── Start-CopilotReportTask.ps1   # Copilot Cloud Agent タスク起動（PAT 認証）
│   ├── New-AzComprehensiveAdminReport.ps1
│   └── ci/
│       ├── Test-BodyAllowlist.ps1    # 変更ファイル allowlist ゲート
│       ├── Test-BodyFactcheck.ps1    # 数値/fact_ids が facts.json 由来か検証
│       └── Test-BodySanitize.ps1     # HTML/script/URL 混入を拒否
└── output/
```

## Copilot prompt での実行

VS Code + GitHub Copilot Chat 環境では、以下の prompt を使って一連の収集とレポート生成を実行できます。

```text
/azure-comprehensive-report
```

## GitHub Actions による自動生成（Copilot Cloud Agent 連携）

`.github/workflows/azure-report-public.yml` は、週次スケジュール（および手動 `workflow_dispatch`）で
レポートを自動生成し、GitHub Pages に公開します。レポート**本文（散文）**は
**GitHub Copilot Cloud Agent** が執筆し、**数値・スコア・リスク判定は PowerShell が確定**する
ハイブリッド構成です。

### パイプラインの流れ

```
1. Azure データ収集        Export-Az*.ps1
2. 事実確定（真実の源泉）    Export-AzFacts.ps1        -> output/facts.json（全数値の唯一の出典）
3. フォールバック HTML 生成 New-AzComprehensiveAdminReport.ps1（body なし = ルールベース散文）
4. Copilot Agent 起動       Start-CopilotReportTask.ps1（PAT 認証・facts をプロンプト全文埋め込み）
                            -> Agent が output/body.json（散文のみ・fact_ids 付き）の PR を作成
5. 品質ゲート               scripts/ci/Test-Body*.ps1（allowlist / factcheck / sanitize）
                            + run_id 整合・PR 差分検証
   - 全ゲート合格           -> body.json を差し込んで最終 HTML を再レンダリング（mode=ai）
   - 失敗/Agent 未成功      -> ルールベース HTML のまま公開（mode=fallback）
6. reports/ にコミット + Pages 公開、本文提供元 PR は close（マージはしない）
```

- **LLM は HTML を書きません**。Agent は本文 JSON だけを生成し、HTML 化は必ず Actions 側の
  deterministic renderer が行います（XSS・レイアウト崩れ・数値創作を根本から封じる設計）。
- **フォールバック優先**：Agent 失敗・ゲート不合格・タイムアウトのいずれでも、手順 3 の
  ルールベース HTML で必ず公開が継続します。採用モード（ai / fallback）と理由は
  Actions のジョブサマリとレポート上部バナーに明示されます。
- 本文提供用の PR は**マージせず close**します（main を実行時プロダクトで汚さず、
  fast-forward 競合も回避）。監査証跡は close 済み PR とジョブサマリに残ります。

### 必要な GitHub シークレット / 変数

| 種別 | 名前 | 用途 |
| --- | --- | --- |
| Secret | `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` | Azure OIDC ログイン（既存） |
| Secret | `COPILOT_AGENT_PAT` | **Copilot Cloud Agent 起動用の user-to-server トークン（必須）** |
| Variable（任意） | `COPILOT_AGENT_MODEL` | 使用モデルの明示指定（未設定なら auto 選択） |

> `GITHUB_TOKEN`（server-to-server）では Agent tasks API を呼べません。**必ず PAT が必要**です。

### `COPILOT_AGENT_PAT`（fine-grained PAT）の作り方

1. GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**
2. **Resource owner**: このリポジトリを所有するアカウント / Organization
3. **Repository access**: *Only select repositories* → 本リポジトリのみ
4. **Repository permissions**（最小権限）:
   - **Agent tasks**: **Read and write**（タスク起動に必須）
   - **Contents**: **Read and write**（Agent がブランチにコミット）
   - **Pull requests**: **Read and write**（Agent が PR を作成）
   - **Metadata**: Read（自動付与）
5. **Expiration** はできるだけ短く（例: 90 日）。
6. 生成したトークンを **Settings → Secrets and variables → Actions → New repository secret** に
   `COPILOT_AGENT_PAT` として登録。
7. 前提: リポジトリで **Copilot cloud agent が有効**（`copilot-swe-agent` が割り当て可能）であり、
   トークン所有者が **Copilot Business / Enterprise** を利用できること。

### PAT の運用（重要）

- **最小権限**：上記スコープ以外は付与しない。Organization 全体や classic PAT の広域スコープは避ける。
- **ローテーション**：Expiration が切れる前に再発行し、Secret を更新する。失効時は自動で
  フォールバック公開に切り替わります（ジョブサマリに理由が出ます）。
- **漏洩対策**：PAT はリポジトリ改変権限を持つため、値をログ・コミット・Issue に出さない。
  漏洩が疑われる場合は即 **Revoke** して再発行する。
- **コスト**：実行のたびに Copilot premium request を消費します。本番は週次スケジュール前提です。

### 手動での動作確認（初回は必須）

Agent 連携部分（PAT 認証・PR 作成・自動 close）はローカルでは完全検証できません。初回は
**Actions タブ → 当該ワークフロー → Run workflow** で手動実行し、ジョブサマリで
`mode=ai / fallback` と理由、Pages の公開結果を確認してください。

## セキュリティと取り扱い上の注意

- 生成物にはサブスクリプション ID、リソース ID、プリンシパル名、IP アドレス、NSG ルール、セキュリティ評価結果が含まれます。社外共有前に必ず確認してください。
- **GitHub Pages 公開に関する重要注意**：`azure-report-public.yml` は生成レポートを **GitHub Pages（既定で公開）** に発行し、`reports/` にもコミットします。上記の機微情報が**インターネットに公開される**ことを意味します。**自分の検証用サブスクリプションを対象とする前提**でのみ利用し、顧客・本番サブスクリプションでは使用しないでください。公開したくない場合は Pages を Private にするか、当該ワークフローを無効化してください。
- ローカル実行時の `output/` は `.gitignore` 対象です（手動実行の生成物は Git にコミットされません）。
- 収集対象を制限したい場合は、`Export-Az*.ps1` を編集してリソースグループ / リソースタイプ / スコープでフィルタしてください。
- HTML はローカル閲覧を想定しています。
- 本ツールは読み取りのみを行い、Azure リソースの作成・変更・削除は行いません。

## ライセンス

[MIT License](LICENSE)
