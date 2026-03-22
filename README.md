# Hello K8s Logging on OrbStack

OrbStack の Kubernetes 機能を使い、**1つの Docker イメージから2種類の Web サービスを起動する**ミニマル構成です。
`ENTRYPOINT` + `CMD` パターンにより、同一イメージでも起動引数で振る舞いを切り替えられることを体験します。

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
│   ├── deployment-blue.yaml   # Blue Deployment（args: ["blue"]）
│   ├── deployment-green.yaml  # Green Deployment（args: ["green"]）
│   ├── service-blue.yaml      # Blue Service（NodePort 30080）
│   └── service-green.yaml     # Green Service（NodePort 30081）
└── README.md
```

## 手順

### 1. Docker イメージをビルド

イメージは1つだけビルドします。Blue / Green 両方の HTML が含まれます。

```bash
docker build -t hello-k8s-logging-web:latest ./app
```

### 2. Kubernetes にデプロイ

```bash
kubectl apply -f k8s/
```

Pod が Running になるまで待ちます。

```bash
kubectl get pods -w
```

Blue 2つ、Green 2つの計4 Pod が起動します。

### 3. 動作確認

**方法 A: NodePort でアクセス**

```bash
# Blue（ポート 30080）
curl http://localhost:30080

# Green（ポート 30081）
curl http://localhost:30081
```

**方法 B: OrbStack のドメインでアクセス（推奨）**

OrbStack では Service 名でアクセスできます。
この方法は Service の ClusterIP に直接ルーティングされるため、Service の `port: 8080` を指定してアクセスします。
方法 A の `:30080` / `:30081` は NodePort（ノード上の公開ポート）なので、ここでは使いません。

```bash
# Blue
curl http://hello-k8s-logging-blue.default.svc.cluster.local:8080

# Green
curl http://hello-k8s-logging-green.default.svc.cluster.local:8080
```

またはブラウザで上記 URL を開きます。

## 学習ポイント: ENTRYPOINT と CMD

### Kubernetes レベル

```yaml
spec:
  containers:
    - name: web-server
      image: hello-k8s-logging-web:latest
      args: ["green"]    # ← Dockerfile の CMD を上書き
```

K8s の `args` は Docker の `CMD` に対応します。
`command` は `ENTRYPOINT` に対応しますが、今回は ENTRYPOINT はそのまま使うため指定しません。

| Docker       | Kubernetes | 本プロジェクトでの値          |
|--------------|------------|-------------------------------|
| `ENTRYPOINT` | `command`  | `/docker-entrypoint.sh`       |
| `CMD`        | `args`     | `["blue"]` or `["green"]`     |

## セルフヒーリングを体験する

各 Deployment は `replicas: 2` で Pod を維持します。

まず、variant ラベルで Pod を確認します。

```bash
kubectl get pods -l variant=blue
kubectl get pods -l variant=green
```

Blue の Pod を1つ削除してみます。

```bash
kubectl delete pod -l variant=blue --field-selector=status.phase=Running --grace-period=0 | head -1
```

別ターミナルで監視すると、新しい Pod が即座に作成される様子を観察できます。

```bash
kubectl get pods -l variant=blue -w
```

全ての Pod を削除しても、Deployment が `replicas: 2` の状態に自動復旧します。

```bash
kubectl delete pods -l app=hello-k8s-logging
kubectl get pods -w
```

## クリーンアップ

```bash
kubectl delete -f k8s/
```

Docker イメージも不要であれば削除します。

```bash
docker rmi hello-k8s-logging-web:latest
```

## トラブルシューティング

### Pod が起動しない

```bash
kubectl describe pod -l app=hello-k8s-logging
kubectl logs -l app=hello-k8s-logging
```

### イメージが見つからない（ErrImagePull）

`imagePullPolicy: Never` が設定されているか確認してください。
ローカルでイメージがビルド済みか `docker images | grep hello-k8s-logging-web` で確認できます。

### NodePort に接続できない

```bash
kubectl get svc
```

Blue は `8080:30080/TCP`、Green は `8080:30081/TCP` と表示されていることを確認してください。

### entrypoint のエラー

Pod のログに `Error: unknown variant` と出ている場合、`args` の値が `blue` または `green` であることを確認してください。

```bash
kubectl logs -l app=hello-k8s-logging
```
