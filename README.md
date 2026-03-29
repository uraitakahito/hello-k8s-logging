# Hello K8s Logging

[hello-k8s](https://github.com/uraitakahito/hello-k8s) をベースに、**サイドカー + Fluent Bit によるログ収集基盤** を追加した教材です。
Kubernetes 機能を使い、Blue / Green 2種類の Nginx Web サービスのアクセスログを Fluent Bit サイドカーが自動収集します。

## 前提条件

- [OrbStack](https://orbstack.dev/) がインストール済み
- OrbStack の Kubernetes が有効（Settings → Kubernetes → Enable Kubernetes）

## プロジェクト構成

```
.
├── app/
│   ├── Dockerfile             # Nginx イメージ
│   ├── default.conf
│   ├── docker-entrypoint.sh
│   ├── index-blue.html
│   └── index-green.html
├── k8s/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── configmap.yaml           # Fluent Bit 設定
│   ├── deployment-blue.yaml
│   ├── deployment-green.yaml
│   ├── service-blue.yaml
│   └── service-green.yaml
└── README.md
```

## 手順

### 1. Docker イメージをビルド

```bash
docker build -t hello-k8s-logging-web ./app
```

### 2. アプリケーションをデプロイ

-k で Kustomize で変換を行い、Kindベースのソート順で適用:

```bash
kubectl apply -k k8s/
```

Pod が Running になるまで待ちます。各 Pod には web-server と log-collector の 2 コンテナが含まれます。

```bash
kubectl get pods -n hello-k8s-logging -w
```

### 3. 動作確認

```bash
# Blue（ポート 30080）, Green（ポート 30081）
curl http://localhost:30080
curl http://localhost:30081
```

OrbStack では Service 名でもアクセスできます。

```
<Service名>.<Namespace名>.svc.cluster.local
```

この方法は Service の ClusterIP に直接ルーティングされるため、Service の port: 8080 を指定してアクセスします。

```bash
curl http://blue.hello-k8s-logging.svc.cluster.local:8080
curl http://green.hello-k8s-logging.svc.cluster.local:8080
```

### 4. ログ収集の確認

各 Pod には 2 つのコンテナがあり、それぞれ独立した stdout を持ちます。`kubectl logs` は指定したコンテナの stdout を表示するコマンドです。

```
deploy-blue (replicas: 2)
├── Pod-1
│   ├── web-server     → stdout
│   └── log-collector  → stdout  ← kubectl logs -l variant=blue -c log-collector で表示
└── Pod-2
    ├── web-server     → stdout
    └── log-collector  → stdout  ← kubectl logs -l variant=blue -c log-collector で表示

deploy-green (replicas: 2)
├── Pod-1
│   ├── web-server     → stdout
│   └── log-collector  → stdout
└── Pod-2
    ├── web-server     → stdout
    └── log-collector  → stdout
```

curlやブラウザでトラフィックを発生させてから Fluent Bit サイドカーのログをtailすると、nginxのアクセスログをJSON形式で確認できます。

```bash
# Blue,Green Pod 内の log-collector コンテナの stdout を表示
kubectl logs -n hello-k8s-logging -l variant=blue -c log-collector --tail=3
kubectl logs -n hello-k8s-logging -l variant=green -c log-collector --tail=3
```

## 学習ポイント

### サイドカーパターンとログ収集

サイドカーパターンでは、アプリケーションコンテナと同じ Pod 内にログ収集コンテナを配置します。

#### なぜ Fluent Bit の設定に ConfigMap を使うのか

Fluent Bit の設定ファイル (`fluent-bit.conf`) は静的ですが、イメージに埋め込まず ConfigMap で渡しています。
これにより公式の `fluent/fluent-bit` イメージをそのまま使え、カスタム Dockerfile が不要です。

設定ファイルをコンテナに渡す手段は他にもありますが、ConfigMap が最適です。

| 手段 | 問題点 |
|------|--------|
| イメージに埋め込み | 設定変更のたびにイメージの再ビルドが必要。公式イメージが使えない |
| `hostPath` | ノードのファイルシステムを共有するため、ノード側から設定ファイルを改ざんされるリスクがある。PSS Restricted 不適合 |
| `PersistentVolume` | 小さな設定ファイルに対してストレージのプロビジョニングが過剰 |

ConfigMap は Kubernetes API オブジェクトなので、変更には RBAC 認証が必要でノード側からの改ざん経路がありません。
また Pod がどのノードにスケジュールされても同じ内容が渡されるため、ノード依存がなくなります。

#### なぜ DaemonSet ではなくサイドカーパターンを採用したか

Kubernetes のログ収集で最も一般的なのは DaemonSet パターン（各ノードに 1 つのログ収集 Pod を配置）です。
しかし DaemonSet パターンには、Pod Security Standards (PSS) の観点で根本的な制約があります。

DaemonSet パターンでは、ノード上の `/var/log/containers/*.log` を読み取るために `hostPath` ボリュームが必須です。
この `hostPath` は PSS の Baseline/Restricted プロファイルで**禁止**されており、namespace の PSA 除外設定なしには使用できません。

DaemonSet パターンのまま対象 Namespace を絞る方法として、Fluent Bit の Path フィルタ（`Path /var/log/containers/*_hello-k8s-logging_*.log`）や grep フィルタ（`Regex kubernetes['namespace_name'] ^hello-k8s-logging$`）がありますが、これらは **Fluent Bit が「何を処理するか」を設定しているだけ**です。
`hostPath` でマウントされた `/var/log` 配下の全ファイルには依然としてアクセス可能であり、コンテナが侵害された場合に他 Namespace のログやシステムログが読み取られるリスクは残ります。
つまり Path フィルタはアプリケーション層の制限であって、OS/カーネル層のセキュリティ境界ではありません。

サイドカーパターンでは `emptyDir` 共有ボリュームを使い、同一 Pod 内のアプリケーションログのみを読み取ります。
`hostPath` が不要なため PSS Restricted に適合し、ClusterRole による K8s API への読み取り権限も不要です。
Pod ごとにログ収集コンテナが必要になるリソース効率のトレードオフはありますが、セキュリティ境界の明確さを優先してサイドカーパターンを採用しています。

#### DaemonSet パターンとの比較

| | DaemonSet | DaemonSet + Path フィルタ | サイドカー |
|---|---|---|---|
| 配置 | ノードごとに 1 Pod | ノードごとに 1 Pod | アプリ Pod ごとに 1 コンテナ |
| ログアクセス | hostPath で全コンテナログを読む | hostPath で全コンテナログを読む | emptyDir で同一 Pod のログのみ |
| 正常時の収集範囲 | 全 Namespace | 指定 Namespace のみ | 同一 Pod のみ |
| 侵害時のアクセス範囲 | `/var/log` 配下すべて | **`/var/log` 配下すべて** | **同一 Pod のログのみ** |
| hostPath | 必要 | 必要 | **不要** |
| RBAC | ClusterRole が必要 | ClusterRole が必要 | **不要** |
| Pod Security Standards | Baseline/Restricted 不適合 | **Baseline/Restricted 不適合** | **Restricted 適合** |
| リソース効率 | 高い（ノード単位） | 高い（ノード単位） | 低い（Pod 単位） |

### Fluent Bit のパイプライン

```
[INPUT] tail → [OUTPUT] stdout
```

| ステージ | 役割 |
|---------|------|
| INPUT (tail) | 共有ボリューム内の `/var/log/nginx/access.log` を tail で読み取り |
| OUTPUT (stdout) | 収集したログを標準出力に表示（`kubectl logs -c log-collector` で確認可能） |

サイドカーパターンでは同一 Pod 内のログのみを扱うため、DaemonSet パターンで必要だった kubernetes メタデータフィルタや RBAC が不要になります。

## クリーンアップ

```bash
# アプリケーションの削除
kubectl delete -k k8s/

# Docker イメージの削除
docker rmi hello-k8s-logging-web
```

