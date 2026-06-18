---
description: "現在ログイン中の Azure サブスクリプションのリソース / RBAC / NSG / Defender for Cloud / Azure Advisor を横断収集し、CSV/JSON と総合 HTML レポートを生成する"
mode: "agent"
---

# Azure 総合レポート生成ワークフロー

現在ログイン中の Azure サブスクリプションを対象に、複数ドメインを横断した総合的な棚卸し・リスク分析レポートを作成してください。

引数（任意）: 対象サブスクリプション ID または名前。省略時は現在のコンテキスト。

## 取り扱うドメイン

| ドメイン | 取得 cmdlet / API | 出力 JSON/CSV |
| --- | --- | --- |
| リソース | `Get-AzResource` | `resources.{csv,json}` |
| RBAC | `Get-AzRoleAssignment` | `rbac.{csv,json}` |
| NSG | `Get-AzNetworkSecurityGroup`（SecurityRules をフラット化） | `nsg-rules.{csv,json}` |
| Defender for Cloud | `Invoke-AzRestMethod` で `Microsoft.Security/assessments` | `defender-recommendations.{csv,json}` |
| Azure Advisor | `Get-AzAdvisorRecommendation` (`Az.Advisor`) | `advisor-recommendations.{csv,json}` |

## 成果物 1: 各ドメインの CSV / JSON

既存の `Export-AzResources.ps1` / `Export-AzRoleAssignments.ps1` を再利用し、追加で以下 3 本を作成・実行する。

- `scripts/Export-AzNsgRules.ps1`
  - `Get-AzNetworkSecurityGroup` の `SecurityRules` を 1 ルール 1 行にフラット化
  - 列: `NsgName`, `ResourceGroupName`, `Location`, `AssociationCount`, `RuleName`, `Priority`, `Direction`, `Access`, `Protocol`, `SourceAddressPrefix`, `SourcePortRange`, `DestinationAddressPrefix`, `DestinationPortRange`, `Description`, `IsRiskyMgmtFromInternet`, `NsgId`
  - `IsRiskyMgmtFromInternet` は **Allow / Inbound / Source=Internet or `*` or `0.0.0.0/0` / Destination port 22 or 3389** を満たす場合に `true`

- `scripts/Export-AzDefenderRecommendations.ps1`
  - `Invoke-AzRestMethod -Method GET -Path "/subscriptions/{id}/providers/Microsoft.Security/assessments?api-version=2021-06-01"` で評価結果を列挙
  - `nextLink` ページングを処理。Defender for Cloud 未有効や 403 時は警告のみで空配列を出力する
  - 列: `AssessmentName`, `DisplayName`, `Severity`, `Status`, `StatusCause`, `StatusDescription`, `Categories`, `Description`, `Remediation`, `ResourceId`, `ResourceName`, `ResourceType`, `ResourceGroupName`, `AssessmentId`

- `scripts/Export-AzAdvisorRecommendations.ps1`
  - `Az.Advisor` 未導入時は警告して空配列を出力
  - 列: `Category`, `Impact`, `Risk`, `Problem`, `Solution`, `ImpactedField`, `ImpactedValue`, `ResourceId`, `ResourceName`, `ResourceType`, `ResourceGroupName`, `LastUpdated`, `RecommendationId`, `Id`

## 成果物 2: 総合 HTML レポート

**スクリプト**: `scripts/New-AzComprehensiveAdminReport.ps1`
**入力**: 上記 5 つの JSON
**出力**: `output/comprehensive-report.html`

本シナリオでは 5 ドメインを横断した分析を行うこと。

### 1. エグゼクティブサマリの主要数値
- リソース総数 / RG 数 / リージョン数、VM / Storage(LRS) / Public IP 件数、タグ付与率
- RBAC 総割り当て / Owner / UAA / SP / 孤児候補件数 / MG スコープの Owner
- NSG 数 / 総ルール / 高リスクルール件数
- Defender Unhealthy 件数（High/Med/Low 内訳）と最頻出推奨事項
- Advisor 件数（5カテゴリ内訳）、High Impact 件数、最頻出問題
- データ取得不可（Defender 未有効 / Az.Advisor 未導入）時は明示的に「未取得＝統制ギャップ」として記述する
- 4 つの主要改善領域として **公開境界 / 特権境界 / 監視フィードバック / ガバナンス基盤** を提示

### 2. 全体サマリ表
ドメインバッジ（リソース / RBAC / NSG / Defender / Advisor）付きで、各ドメインの主要指標を 8〜12 行で表示。

### 3. 潜在リスク Top 5（横断）
データ駆動で観察事実を組み立てる。Severity は実データに応じて昇降させる（例: Defender に High があれば Defender リスクを High に格上げ）。

1. **公開境界の露出** — NSG 高リスク件数、Public IP 件数を引用。推奨: Bastion + JIT、Application Gateway WAF。
2. **特権ロールの恒久付与と blast radius** — Owner/UAA/SP/孤児件数を引用。推奨: PIM、マネージド ID、Access Review。
3. **Defender for Cloud のセキュリティ態勢ギャップ** — 未有効なら「ベースライン不在」、有効なら High/Med 件数。推奨: Foundational CSPM、Secure Score 月次レビュー。
4. **Advisor フィードバックループ不在** — High Impact 件数。推奨: 月次レビュー、Cost Management 連動。
5. **ガバナンス基盤の弱さ** — タグ未付与・LRS のみ・Public IP。推奨: Azure Policy、Tag Inheritance、ZRS/GZRS。

各リスクカードには Microsoft Learn (`learn.microsoft.com/ja-jp/`) のリンクを 2〜3 件、`target="_blank" rel="noopener"` 付きで含める。

### 4. 30 日アクションプラン
役割例: Cloud Ops / Security / Network / IAM / Governance / FinOps / Storage / 管理者。
代表項目: レポート展開、Defender 有効化、NSG 緊急是正、Owner/UAA の PIM 化＋孤児削除、タグ必須化、Advisor 月次レビュー、Storage 冗長性移行、監視ベースライン整備、レビュー会議。

### 付録
- A: NSG ルール ハイライト（高リスク優先 上位 30）
- B: Defender 推奨事項（Unhealthy, Severity 順 上位 30）
- C: Advisor 推奨事項（Impact 順 上位 30）

## 実行フロー

1. `Get-AzContext` で接続状態を確認（未ログインなら `Connect-AzAccount`）
2. 必要に応じて `Az.Advisor` をインストール
3. 以下を順に実行
   1. `Export-AzResources.ps1`
   2. `Export-AzRoleAssignments.ps1`
   3. `Export-AzNsgRules.ps1`
   4. `Export-AzDefenderRecommendations.ps1`
   5. `Export-AzAdvisorRecommendations.ps1`
  6. `New-AzComprehensiveAdminReport.ps1`
4. 生成ファイルへのワークスペース相対リンクをまとめて報告
