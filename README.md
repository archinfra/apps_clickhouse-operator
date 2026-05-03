# apps_clickhouse-operator

Offline `.run` installer for a production-oriented ClickHouse delivery on Kubernetes.

This repository no longer stops at `CRD + operator`. The default install path is:

- Altinity ClickHouse Operator
- operator metrics exporter
- a real `ClickHouseInstallation` with persistent volumes
- a real `ClickHouseKeeperInstallation` for replicated mode
- optional Prometheus Operator monitoring resources
- optional Grafana dashboards from the vendored upstream chart

The package still supports `operator-only`, but that is now an explicit profile instead of the only outcome.

## Upstream baseline

- upstream operator repo: `Altinity/clickhouse-operator`
- vendored chart path: `deploy/helm/clickhouse-operator`
- chart version: `0.26.3`
- app version: `0.26.3`

Vendored examples are under [examples](C:/Users/yuanyp8/Desktop/archinfra/apps_clickhouse-operator/examples):

- [production-clickhouseinstallation.yaml](C:/Users/yuanyp8/Desktop/archinfra/apps_clickhouse-operator/examples/production-clickhouseinstallation.yaml)
- [production-clickhousekeeperinstallation.yaml](C:/Users/yuanyp8/Desktop/archinfra/apps_clickhouse-operator/examples/production-clickhousekeeperinstallation.yaml)
- [single-clickhouseinstallation.yaml](C:/Users/yuanyp8/Desktop/archinfra/apps_clickhouse-operator/examples/single-clickhouseinstallation.yaml)

## What the installer builds

The default `production` profile installs:

- 1 operator deployment
- 1 `ClickHouseInstallation`
- 1 `ClickHouseKeeperInstallation`
- ClickHouse topology: `1 shard x 2 replicas`
- Keeper topology: `3 replicas`
- ClickHouse PVCs: `200Gi` data + `20Gi` log per replica
- Keeper PVCs: `20Gi` per replica
- internal service exposure with `ClusterIP`

The `single` profile installs:

- operator
- 1 persistent `ClickHouseInstallation`
- topology `1 shard x 1 replica`
- no Keeper

The `operator-only` profile installs:

- only operator-side resources

## Bundled images

- `docker.io/altinity/clickhouse-operator:0.26.3`
- `docker.io/altinity/metrics-exporter:0.26.3`
- `docker.io/bitnamilegacy/kubectl:1.33.4-debian-12-r0`
- `docker.io/clickhouse/clickhouse-server:24.8`
- `docker.io/clickhouse/clickhouse-keeper:25.3`

The CRD hook image is pinned deliberately. The upstream chart leaves it at `latest`, which is not acceptable for air-gapped reproducible delivery.

## Build strategy

Recommended path: GitHub Actions.

Reason:

- local environments may not be able to pull upstream images from foreign registries
- the workflow already does the `amd64` / `arm64` matrix build
- tag builds publish `.run` and `.sha256` release assets

Build workflow:

```bash
git push origin main
git tag v0.2.0
git push origin v0.2.0
```

Workflow outputs:

- `dist/clickhouse-operator-installer-amd64.run`
- `dist/clickhouse-operator-installer-arm64.run`
- matching `.sha256` files

If your environment can reach upstream registries, local build still works:

```bash
./build.sh --arch amd64
./build.sh --arch arm64
./build.sh --arch all
```

Build requirements:

- `docker`
- `python` or `python3`
- `sha256sum`

## Install usage

Show help:

```bash
./clickhouse-operator-installer-amd64.run --help
```

Default production install:

```bash
./clickhouse-operator-installer-amd64.run install -y
```

Single replica install:

```bash
./clickhouse-operator-installer-amd64.run install \
  --profile single \
  --storage-class nfs \
  --data-size 100Gi \
  -y
```

Operator only:

```bash
./clickhouse-operator-installer-amd64.run install \
  --profile operator-only \
  -y
```

Production install with monitoring:

```bash
./clickhouse-operator-installer-amd64.run install \
  --enable-service-monitor \
  --enable-dashboards \
  -y
```

Reuse images that already exist in the target registry:

```bash
./clickhouse-operator-installer-amd64.run install \
  --registry harbor.example.com/kube4 \
  --skip-image-prepare \
  -y
```

Tune cluster sizing:

```bash
./clickhouse-operator-installer-amd64.run install \
  --profile production \
  --shards 2 \
  --replicas 2 \
  --keeper-replicas 3 \
  --data-size 500Gi \
  --log-size 50Gi \
  --storage-class fast-ssd \
  --admin-password 'StrongPasswordHere' \
  -y
```

Check status:

```bash
./clickhouse-operator-installer-amd64.run status
```

Uninstall:

```bash
./clickhouse-operator-installer-amd64.run uninstall -y
```

Uninstall and remove CRDs:

```bash
./clickhouse-operator-installer-amd64.run uninstall --delete-crds -y
```

## Important flags

- `--profile production|single|operator-only`
- `--storage-class <name>`
- `--data-size <size>`
- `--log-size <size>`
- `--shards <n>`
- `--replicas <n>`
- `--keeper-replicas <n>`
- `--service-type ClusterIP|NodePort|LoadBalancer`
- `--admin-user <name>`
- `--admin-password <pass>`
- `--enable-service-monitor`
- `--enable-dashboards`

## Notes

- This repository is intended to deliver a usable ClickHouse runtime, not only the operator control plane.
- The default production profile uses `ClickHouseKeeperInstallation` for the replicated starter topology.
- I did not run local install verification in this environment. Validation stayed at script syntax, JSON parsing, and repo consistency, while image build and packaging are intended to run in GitHub Actions.
