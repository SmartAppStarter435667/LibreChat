# LibreChat on OCI — デプロイガイド

このディレクトリ一式（`terraform/`, `.github/workflows/`, `scripts/`）は、
[danny-avila/LibreChat](https://github.com/danny-avila/LibreChat) のクローン/フォークに
追加して使うことを想定しています。LibreChat 本体の `README.md` は上書きしていません。

## アーキテクチャ

```
GitHub Actions
  ├─ terraform-oci-deploy.yml … Terraform で OCI インフラを作成/更新 → 続けてアプリをデプロイ
  └─ librechat-redeploy.yml   … インフラはそのまま、アプリだけ再デプロイ(更新)

OCI
  ├─ VCN / Public Subnet / Internet Gateway / Security List
  └─ Compute Instance (VM.Standard.A1.Flex, Arm, Always Free枠)
       └─ Docker + docker compose で deploy-compose.yml を実行
            api / client(nginx) / mongodb / meilisearch / vectordb(pgvector) / rag_api
```

- インスタンスは Always Free 対象の **Ampere A1.Flex**（デフォルト 2 OCPU / 12GB、
  無料枠は合計 4 OCPU / 24GB まで）、Ubuntu 24.04 Minimal (aarch64) です。
- LibreChat のデプロイ構成は独自にでっち上げず、**本家の `deploy-compose.yml` /
  `librechat.example.yaml` / `client/nginx.conf` をそのまま使用**します。
  そのため今後 LibreChat 本体を `git pull` すれば、これらの改善もそのまま追従します。
- Terraform は **インフラ専用**（ネットワークとインスタンスのみ）です。LibreChat の
  `.env` はここでは持たず、GitHub Actions のワークフロー内で Secrets から都度生成し、
  SSH 経由でサーバーに配置します（Git にも Terraform state にも平文の秘密情報を
  残しません）。

## 事前準備

1. OCI アカウントと `oci` CLI（`oci setup config` 済み。APIキーを OCI コンソールの
   ユーザー設定からアップロード済みであること）
2. `gh` CLI（`gh auth login` 済み）
3. このリポジトリの GitHub 上のフォーク/クローン（`git clone
   https://github.com/danny-avila/LibreChat` の後、このガイド内のファイル一式を追加）

## セットアップ手順

### 1. GitHub Secrets を自動設定する

```bash
./scripts/oci-setup-secrets.sh
```

`~/.oci/config` からテナンシOCID等を読み取り、SSH鍵の生成、LibreChat用シークレット
（JWT_SECRET など）の生成、Terraform state 用の Object Storage バケットと
Customer Secret Key の作成までを行い、すべて GitHub Secrets に登録します。

**ここだけは自動化できません:** GitHub Secrets への書き込み自体、それを行う権限を
持つ資格情報（今回はあなたの `gh` ログイン）が最初に必要です。GitHub 自身が
「自分の Secrets を書く権限」をゼロから生成することはできないため、この
スクリプトを一度だけ手動実行する部分が、原理的に残る唯一の手作業です。
それ以降は全て自動化されています。

任意で追加できるもの（.envの `user_provided` のままなら各ユーザーが自分のAPIキーを
LibreChatのUIから入力する形になります。運営側で共通のキーを使わせたい場合のみ）:

```bash
gh secret set ANTHROPIC_API_KEY --repo <owner>/<repo>
gh secret set OPENAI_API_KEY    --repo <owner>/<repo>
gh secret set GOOGLE_KEY        --repo <owner>/<repo>
```

### 2. コミットしてプッシュする

```bash
git add terraform .github scripts OCI_DEPLOYMENT_GUIDE.md .gitignore
git commit -m "Add OCI Terraform + GitHub Actions deployment for LibreChat"
git push
```

> **重要:** `.github` フォルダは GitHub の Web UI から直接ドラッグ&ドロップで
> アップロードすると、隠しフォルダ扱いで認識されない/正しく展開されないことが
> あります。`git push` で反映することを強く推奨します。

### 3. デプロイを実行する

`main` へのプッシュで `terraform/**` に変更があれば自動実行されますが、初回は
Actions タブから **"Deploy LibreChat to OCI (Terraform)"** を手動実行（`workflow_dispatch`、
action=apply）するのが確実です。

1. `terraform` ジョブが VCN・サブネット・インスタンスを作成
2. `deploy-app` ジョブが SSH 経由で `deploy-compose.yml` / `.env` / `librechat.yaml` /
   `client/nginx.conf` を配置し、`docker compose up -d`
3. 完了後、`http://<インスタンスのIP>` でアクセス可能

初回はイメージのpull(6コンテナ分)に数分かかります。ワークフローの最後で
自動的に疎通確認するので、緑色になれば起動完了です。

## 必要な GitHub Secrets 一覧

`scripts/oci-setup-secrets.sh` を実行すると以下18個が自動設定されます。
`gh secret list --repo <owner>/<repo>` でこれが揃っているか確認できます
(値は表示されず名前だけ出ます)。1つでも足りなければワークフローは失敗します。

| Secret名 | 内容 |
|---|---|
| `OCI_TENANCY_OCID` | OCIテナンシOCID |
| `OCI_USER_OCID` | OCIユーザーOCID |
| `OCI_FINGERPRINT` | APIキーのフィンガープリント |
| `OCI_PRIVATE_KEY` | APIキー(PEM)本文 |
| `OCI_REGION` | 例: ap-tokyo-1 |
| `OCI_COMPARTMENT_OCID` | デプロイ先コンパートメントOCID |
| `SSH_PRIVATE_KEY` / `SSH_PUBLIC_KEY` | インスタンス用SSH鍵 |
| `SSH_ALLOWED_CIDR` | SSH許可元CIDR |
| `LIBRECHAT_JWT_SECRET` / `LIBRECHAT_JWT_REFRESH_SECRET` | LibreChat認証用 |
| `LIBRECHAT_CREDS_KEY` / `LIBRECHAT_CREDS_IV` | LibreChat暗号化用 |
| `LIBRECHAT_MEILI_MASTER_KEY` | Meilisearch用 |
| `TF_STATE_BUCKET` | Terraform state用バケット名 |
| `TF_STATE_NAMESPACE` | Object Storageネームスペース |
| `TF_STATE_ACCESS_KEY` / `TF_STATE_SECRET_KEY` | state用 Customer Secret Key |
| `DOMAIN_NAME`(任意) | 独自ドメイン |

## 日常の運用

- **LibreChat だけ更新したい**（最新の `:latest` イメージ、`librechat.yaml` の変更など)
  → Actions タブから **"Redeploy LibreChat (app only)"** を手動実行
- **インフラも変えたい**（スペック変更など）→ `terraform/*.tf` を編集して push
- **壊す/作り直す** → "Deploy LibreChat to OCI (Terraform)" を `workflow_dispatch` で
  action=destroy を指定して実行(コンテナ内のデータも失われるので注意)

## セキュリティに関する注意

- **SSH_ALLOWED_CIDR**: セットアップ時に指定しなければ `0.0.0.0/0`（全世界）です。
  自分のIP（`curl ifconfig.me`で確認）に絞ることを推奨します。
  `gh secret set SSH_ALLOWED_CIDR --repo <owner>/<repo>` で後から変更できます。
- **ユーザー登録が初期状態で開放**（`ALLOW_REGISTRATION=true`）です。個人利用なら
  自分のアカウント作成後に `ALLOW_REGISTRATION=false` にして再デプロイすることを
  検討してください。
- **HTTPS**: `deploy-compose.yml` の nginx はポート443を開けていますが証明書は
  同梱されていません。手っ取り早い方法は、独自ドメインを **Cloudflare**
  （プロキシ有効=オレンジ雲）経由でこのインスタンスのIPに向けること、または
  Caddy/Certbot を自前で構成することです。ドメインを `DOMAIN_NAME` シークレットに
  設定すると `DOMAIN_CLIENT`/`DOMAIN_SERVER` が自動でそのドメインを使うようになります。

## コストに関する注意

- デフォルト設定（A1.Flex 2OCPU/12GB、ブートボリューム100GB）は Always Free 枠
  （4OCPU/24GB、ブロックストレージ200GBまで）に収まります。
- OCI の Always Free A1.Flex は人気リージョンで "Out of host capacity" エラーに
  なることがあります。その場合は少し時間を置いて `workflow_dispatch` を再実行するか、
  リージョン/可用性ドメインを変えて試してください。

## トラブルシューティング

### terraform init が「region」や「bucket」が空というエラーで失敗する

```
Error: Invalid Value / Missing region value
```

`TF_VAR_*` や `-backend-config` の値が軒並み空の場合、原因は100%
「このリポジトリに GitHub Secrets が設定されていない」ことです。よくある原因:

1. `scripts/oci-setup-secrets.sh` をまだ実行していない
2. 実行はしたが、**別のリポジトリを指すディレクトリ**から実行してしまった
   (スクリプトは `gh repo view` でカレントディレクトリのリポジトリを自動検出するため)
3. Secretsを手動でGitHub画面から登録した際、"Repository secrets" ではなく
   "Environments" 配下に作ってしまった(ワークフロー側で `environment:` を
   指定していないため見えません)

対処:

```bash
# 対象リポジトリにSecretsが揃っているか確認(上の一覧と照合)
gh secret list --repo <owner>/<repo>

# 不足していれば、このリポジトリのクローン内で実行し直す
git clone https://github.com/<owner>/<repo>.git
cd <repo>
oci setup config          # 未設定なら先にこちらを済ませる
gh auth login              # 未ログインなら
./scripts/oci-setup-secrets.sh
```

実行後にエラーなく完了し、`gh secret list` で18個揃っていることを確認してから、
Actions タブでワークフローを再実行してください。

なお `Warning: Deprecated Parameter ... "endpoint" ... use "endpoints.s3"` は
警告のみでビルドを止める原因ではないため、上記を解消すれば無視して問題ありません。

### サーバーにログインして状態を見る

```bash
ssh -i .secrets/librechat_oci_ed25519 ubuntu@<IP>

# コンテナのログ
cd /opt/librechat && docker compose -f deploy-compose.yml logs -f

# cloud-init自体のログ(Docker導入やiptables設定でつまずいた場合)
sudo cat /var/log/cloud-init-output.log
```

80/443番ポートに繋がらない場合、OCIの既定イメージはSSH以外を拒否する
iptablesルールを最初から持っていることが原因であることが多いです。
`terraform/cloud-init.yaml` はこれを起動時に解除しますが、手動で確認する場合は
`sudo iptables -L INPUT -n --line-numbers` で 80/443 の ACCEPT ルールが
REJECT より上にあるか確認してください。
