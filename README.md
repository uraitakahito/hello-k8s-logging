# Hello K8s Logging on OrbStack

[hello-k8s](https://github.com/uraitakahito/hello-k8s) をベースに、**DaemonSet + Fluent Bit によるログ収集基盤**を追加した教材です。
OrbStack の Kubernetes 機能を使い、Blue / Green 2種類の Nginx Web サービスのアクセスログを Fluent Bit が自動収集します。

## 前提条件

- [OrbStack](https://orbstack.dev/) がインストール済み
- OrbStack の Kubernetes が有効（Settings → Kubernetes → Enable Kubernetes）

有効化すると `kubectl` が自動的に使えるようになります。

```bash
kubectl get nodes
```

ノードが表示されれば準備完了です。

## プロジェクト構成

```
.
├── app/
│   ├── Dockerfile             # Nginx イメージ（ENTRYPOINT + CMD パターン）
│   ├── docker-entrypoint.sh   # CMD 引数で配信する HTML を切り替え
│   ├── index-blue.html        # Blue 版ページ
│   └── index-green.html       # Green 版ページ
├── k8s/
│   ├── app/                   # アプリケーション マニフェスト
│   │   ├── deployment-blue.yaml
│   │   ├── deployment-green.yaml
│   │   ├── service-blue.yaml
│   │   └── service-green.yaml
│   └── logging/               # ログ基盤 マニフェスト
│       ├── namespace.yaml
│       ├── service-account.yaml
│       ├── cluster-role.yaml
│       ├── cluster-role-binding.yaml
│       ├── configmap.yaml
│       └── daemonset.yaml
└── README.md
```

## 手順

### 1. Docker イメージをビルド

```bash
docker build -t hello-k8s-logging-web:latest ./app
```

### 2. アプリケーションをデプロイ

```bash
kubectl apply -f k8s/app/
```

Pod が Running になるまで待ちます。

```bash
kubectl get pods -w
```

Blue 2つ、Green 2つの計4 Pod が起動します。

### 3. 動作確認

```bash
# Blue（ポート 30080）
curl http://localhost:30080

# Green（ポート 30081）
curl http://localhost:30081
```

OrbStack では Service 名でもアクセスできます。

```bash
curl http://hello-k8s-logging-blue.default.svc.cluster.local:8080
curl http://hello-k8s-logging-green.default.svc.cluster.local:8080
```

### 4. ログ基盤をデプロイ

RBAC → ConfigMap → DaemonSet の順にデプロイします。

```bash
# Namespace と RBAC
kubectl apply -f k8s/logging/namespace.yaml
kubectl apply -f k8s/logging/service-account.yaml
kubectl apply -f k8s/logging/cluster-role.yaml
kubectl apply -f k8s/logging/cluster-role-binding.yaml

# Fluent Bit 設定と DaemonSet
kubectl apply -f k8s/logging/configmap.yaml
kubectl apply -f k8s/logging/daemonset.yaml
```

Fluent Bit Pod が起動したことを確認します。

```bash
kubectl get daemonset log-collector -n logging
kubectl get pods -n logging
```

### 5. ログ収集の確認

トラフィックを発生させてから Fluent Bit のログを確認します。

```bash
curl http://localhost:30080
curl http://localhost:30081

kubectl logs -n logging -l app=log-collector --tail=10
```

nginx のアクセスログが JSON 形式で表示され、Kubernetes メタデータ（Pod 名、Namespace、ラベル等）が付与されていることを確認できます。

## 学習ポイント

### DaemonSet とログ収集

DaemonSet はクラスタの**各ノードに1つずつ Pod を配置**するリソースです。
Deployment が「N 個のレプリカをどこかに配置」するのに対し、DaemonSet は「全ノードに1つずつ」を保証します。

```bash
# DaemonSet の状態を確認（DESIRED = ノード数 = READY）
kubectl get daemonset log-collector -n logging
```

ログ収集エージェントは各ノードのログファイルを読む必要があるため、DaemonSet が最適です。

### Fluent Bit のパイプライン

```
[INPUT] tail → [FILTER] kubernetes → [OUTPUT] stdout
```

| ステージ | 役割 |
|---------|------|
| INPUT (tail) | ノード上の `/var/log/containers/*.log` を tail で読み取り |
| FILTER (kubernetes) | K8s API に問い合わせ、Pod 名・Namespace・ラベル等のメタデータを付与 |
| OUTPUT (stdout) | 収集したログを標準出力に表示（`kubectl logs` で確認可能） |

### RBAC（Role-Based Access Control）

Fluent Bit が Kubernetes API からメタデータを取得するには、適切な権限が必要です。

| リソース | 役割 |
|---------|------|
| ServiceAccount | Fluent Bit Pod の認証 ID |
| ClusterRole | pods と namespaces への get/list/watch 権限 |
| ClusterRoleBinding | ServiceAccount と ClusterRole の紐付け |

ClusterRole（Namespace を横断する権限）を使うのは、Fluent Bit が全 Namespace のログを収集するためです。

### ENTRYPOINT と CMD

```yaml
spec:
  containers:
    - name: web-server
      image: hello-k8s-logging-web:latest
      args: ["green"]    # ← Dockerfile の CMD を上書き
```

| Docker       | Kubernetes | 本プロジェクトでの値          |
|--------------|------------|-------------------------------|
| `ENTRYPOINT` | `command`  | `/docker-entrypoint.sh`       |
| `CMD`        | `args`     | `["blue"]` or `["green"]`     |

## クリーンアップ

```bash
# ログ基盤の削除
kubectl delete -f k8s/logging/daemonset.yaml
kubectl delete -f k8s/logging/configmap.yaml
kubectl delete -f k8s/logging/cluster-role-binding.yaml
kubectl delete -f k8s/logging/cluster-role.yaml
kubectl delete -f k8s/logging/service-account.yaml
kubectl delete -f k8s/logging/namespace.yaml

# アプリケーションの削除
kubectl delete -f k8s/app/

# Docker イメージの削除
docker rmi hello-k8s-logging-web:latest
```

## トラブルシューティング

### App の Pod が起動しない

```bash
kubectl describe pod -l app=hello-k8s-logging
kubectl logs -l app=hello-k8s-logging
```

### イメージが見つからない（ErrImagePull）

`imagePullPolicy: Never` が設定されているか確認してください。
ローカルでイメージがビルド済みか `docker images | grep hello-k8s-logging-web` で確認できます。

### Fluent Bit がログを収集しない

```bash
# Fluent Bit Pod の状態確認
kubectl get pods -n logging
kubectl logs -n logging -l app=log-collector

# ConfigMap の内容確認
kubectl describe configmap fb-config -n logging

# RBAC の確認
kubectl describe clusterrole fb-cluster-role
kubectl describe clusterrolebinding fb-crb
```
