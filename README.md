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
│   └── app/                   # アプリケーション + ログ収集 マニフェスト
│       ├── kustomization.yaml # Kustomize: Namespace 注入 + 適用順序
│       ├── namespace.yaml     # hello-k8s-logging Namespace
│       ├── configmap.yaml     # Fluent Bit 設定
│       ├── deployment-blue.yaml
│       ├── deployment-green.yaml
│       ├── service-blue.yaml
│       └── service-green.yaml
└── README.md
```

## 手順

### 1. Docker イメージをビルド

```bash
docker build -t hello-k8s-logging-web:latest ./app
```

### 2. アプリケーションをデプロイ

```bash
kubectl apply -k k8s/app/
```

Pod が Running になるまで待ちます。各 Pod には web-server と log-collector の 2 コンテナが含まれます。

```bash
kubectl get pods -n hello-k8s-logging -w
```

### 3. 動作確認

```bash
# Blue（ポート 30080）
curl http://localhost:30080

# Green（ポート 30081）
curl http://localhost:30081
```

OrbStack では Service 名でもアクセスできます。

```bash
curl http://blue.hello-k8s-logging.svc.cluster.local:8080
curl http://green.hello-k8s-logging.svc.cluster.local:8080
```

### 4. ログ収集の確認

トラフィックを発生させてから Fluent Bit サイドカーのログをtailすると、nginxのアクセスログをJSON形式で確認できます。

```bash
curl http://localhost:30080
curl http://localhost:30081

# Blue Pod のログ収集サイドカーを確認
kubectl logs -n hello-k8s-logging -l variant=blue -c log-collector --tail=3

# Green Pod のログ収集サイドカーを確認
kubectl logs -n hello-k8s-logging -l variant=green -c log-collector --tail=3
```

## 学習ポイント

### Kustomize と `kubectl apply -k`

本プロジェクトでは `kustomization.yaml` を配置し、`kubectl apply -k` で一括デプロイしています。

```bash
# -f: ディレクトリ内のマニフェストを個別に適用（順序保証なし）
kubectl apply -f k8s/app/

# -k: Kustomize でビルドしてから適用（Namespace 注入 + 順序保証）
kubectl apply -k k8s/app/
```

`kustomization.yaml` の `namespace` フィールドで Namespace を一括注入するため、個々のマニフェストに `namespace:` を書く必要がありません。

```yaml
# k8s/app/kustomization.yaml
namespace: hello-k8s-logging    # ← 全リソースに注入される
resources:
  - namespace.yaml              # Namespace は最初にリストする
  - configmap.yaml
  - deployment-blue.yaml
  - ...
```

### Liveness / Readiness Probe

Pod のヘルスチェックには 2 種類の Probe を使います。

| Probe | 役割 | 失敗時の動作 |
|-------|------|-------------|
| Liveness | コンテナが生きているか | Pod を再起動 |
| Readiness | トラフィックを受ける準備ができているか | Service のエンドポイントから除外 |

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 80
  initialDelaySeconds: 3
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /healthz
    port: 80
  initialDelaySeconds: 1
  periodSeconds: 5
```

#### Self-healing を体験する

Liveness Probe が失敗すると K8s が自動で Pod を再起動します。

```bash
# Pod 名を取得
POD=$(kubectl get pods -n hello-k8s-logging -l variant=blue -o jsonpath='{.items[0].metadata.name}')

# nginx を停止して Liveness Probe を失敗させる
kubectl exec -n hello-k8s-logging $POD -c web-server -- nginx -s stop

# Pod の再起動を観察（RESTARTS カウントが増える）
kubectl get pods -n hello-k8s-logging -w
```

### サイドカーパターンとログ収集

サイドカーパターンでは、アプリケーションコンテナと同じ Pod 内にログ収集コンテナを配置します。

```
┌─ Pod ──────────────────────────────────┐
│                                         │
│  [web-server]                           │
│    nginx → /var/log/nginx/access.log    │
│              ↓ (emptyDir 共有ボリューム) │
│  [log-collector]                        │
│    Fluent Bit ← tail access.log        │
│              ↓                          │
│           stdout (kubectl logs で確認)  │
└─────────────────────────────────────────┘
```

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

### ENTRYPOINT と CMD

```yaml
spec:
  containers:
    - name: web-server
      image: hello-k8s-logging-web:latest
      env:
        - name: VARIANT
          value: "green"    # ← 環境変数でバリアントを切り替え
```

| Docker       | Kubernetes | 本プロジェクトでの値                     |
|--------------|------------|------------------------------------------|
| `ENTRYPOINT` | `command`  | `/docker-entrypoint.sh`                  |
| `CMD`        | `args`     | `["nginx", "-g", "daemon off;"]`         |
| (なし)       | `env`      | `VARIANT=blue` or `VARIANT=green`        |

## クリーンアップ

```bash
# アプリケーションの削除
kubectl delete -k k8s/app/

# Docker イメージの削除
docker rmi hello-k8s-logging-web:latest
```

## トラブルシューティング

### App の Pod が起動しない

```bash
kubectl describe pod -n hello-k8s-logging -l app=hello-k8s-logging
kubectl logs -n hello-k8s-logging -l app=hello-k8s-logging -c web-server
```

### イメージが見つからない（ErrImagePull）

`imagePullPolicy: Never` が設定されているか確認してください。
ローカルでイメージがビルド済みか `docker images | grep hello-k8s-logging-web` で確認できます。

### Fluent Bit がログを収集しない

```bash
# Fluent Bit サイドカーの状態確認
kubectl logs -n hello-k8s-logging -l variant=blue -c log-collector

# ConfigMap の内容確認
kubectl describe configmap fb-config -n hello-k8s-logging
```
