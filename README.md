# AUD/JPY 為替レートグラフ表示アプリ

オーストラリアドル/日本円（AUD/JPY）の為替レートを毎日自動取得し、推移をグラフで表示する静的Webアプリケーション。

## アーキテクチャ

```
EventBridge Rule (毎日JST 9:00)
        │
        ▼
  Lambda (Ruby 3.3)
        │
        ├──→ Exchange Rate API (レート取得)
        │
        ├──→ DynamoDB (データ保存)
        │
        └──→ S3 (HTML生成・アップロード)
                │
                ▼
         S3静的ウェブサイトホスティング
         (Chart.jsによるグラフ表示)
```

## 前提条件

- AWS CLI がインストール・設定済み
- Node.js (v18以上) がインストール済み
- AWS CDK CLI がインストール済み (`npm install -g aws-cdk`)
- Docker がインストール済み（Lambda関数のバンドリングに使用）

## プロジェクト構成

```
.
├── README.md                       # このファイル
├── bin/
│   └── app.ts                      # CDKエントリーポイント
├── lib/
│   └── my-aud-jpy-graph-stack.ts   # スタック定義
├── src/
│   ├── Gemfile                     # Ruby依存関係
│   └── lambda_function.rb          # Lambda関数本体
├── cdk.json                        # CDK設定
├── package.json                    # Node.js依存関係
└── tsconfig.json                   # TypeScript設定
```

## セットアップ手順

### 1. 依存関係のインストール

```bash
npm install
```

### 2. CDK Bootstrap（初回のみ）

対象アカウント・リージョンで初めてCDKを使う場合に実行する:

```bash
cdk bootstrap
```

### 3. デプロイ

```bash
# 変更内容の確認
cdk diff

# デプロイ実行
cdk deploy
```

デプロイ完了後、出力されるWebsiteURLにアクセスしてグラフが表示されることを確認する。

為替レートの取得には [Frankfurter API](https://frankfurter.dev/) を使用している。APIキーは不要。

### 4. 動作確認

初回はデータがないため、Lambda関数を手動実行してデータを投入する:

```bash
# Lambda関数を手動実行
aws lambda invoke \
  --function-name MyAudJpyGraphStack-fetch-rate \
  --payload '{}' \
  response.json

# レスポンス確認
cat response.json
```

## 運用情報

### スケジュール

- 毎日UTC 0:00（JST 9:00）に自動実行
- EventBridge Ruleで管理

### データ構造（DynamoDB）

| 属性名 | 型 | 説明 |
|--------|-----|------|
| currency_pair (PK) | String | 通貨ペア（`AUD/JPY`） |
| date (SK) | String | 日付（`YYYY-MM-DD`形式） |
| rate | Number | 為替レート |
| updated_at | String | 更新日時（ISO 8601形式） |

### コスト目安

このアプリは低コスト設計:

- **Lambda**: 1日1回実行、無料枠内で収まる
- **DynamoDB**: オンデマンドモード、数百レコード程度なら無料枠内
- **S3**: 静的ホスティング、1ファイルのみなのでほぼ無料
- **Frankfurter API**: 無料、APIキー不要

### 削除方法

```bash
cdk destroy
```

S3バケットは `autoDeleteObjects: true` を設定しているため、スタック削除時に自動的に中身が空になり削除される。

## 開発コマンド

```bash
# TypeScriptのビルド
npm run build

# 合成されたCloudFormationテンプレートの確認
npm run synth

# デプロイ前の差分確認
npm run diff

# デプロイ
npm run deploy
```

## カスタマイズ

### 取得頻度の変更

`lib/my-aud-jpy-graph-stack.ts` の `Schedule.cron()` を変更する:

```typescript
// 例: 6時間ごと
schedule: events.Schedule.rate(cdk.Duration.hours(6))

// 例: 平日のみ JST 9:00
schedule: events.Schedule.cron({ minute: '0', hour: '0', weekDay: 'MON-FRI' })
```

### 別の通貨ペアへの変更

`src/lambda_function.rb` の `fetch_exchange_rate` メソッドで、APIのエンドポイントURLを変更する:

```ruby
# 例: USD/JPY
uri = URI("https://api.frankfurter.dev/v1/latest?base=USD&symbols=JPY")
```

`save_to_dynamodb` メソッドの `currency_pair` の値も合わせて変更すること。
