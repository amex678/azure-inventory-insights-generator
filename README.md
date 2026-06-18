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
│   └── prompts/
│       └── azure-comprehensive-report.prompt.md
├── scripts/
│   ├── Export-AzResources.ps1
│   ├── Export-AzRoleAssignments.ps1
│   ├── Export-AzNsgRules.ps1
│   ├── Export-AzDefenderRecommendations.ps1
│   ├── Export-AzAdvisorRecommendations.ps1
│   └── New-AzComprehensiveAdminReport.ps1
└── output/
```

## Copilot prompt での実行

VS Code + GitHub Copilot Chat 環境では、以下の prompt を使って一連の収集とレポート生成を実行できます。

```text
/azure-comprehensive-report
```

## セキュリティと取り扱い上の注意

- 生成物にはサブスクリプション ID、リソース ID、プリンシパル名、IP アドレス、NSG ルール、セキュリティ評価結果が含まれます。社外共有前に必ず確認してください。
- `output/` は `.gitignore` 対象です。Git でコミットしないでください。
- 収集対象を制限したい場合は、`Export-Az*.ps1` を編集してリソースグループ / リソースタイプ / スコープでフィルタしてください。
- HTML はローカル閲覧を想定しています。
- 本ツールは読み取りのみを行い、Azure リソースの作成・変更・削除は行いません。

## ライセンス

[MIT License](LICENSE)
