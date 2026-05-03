# apps_clickhouse-operator

Offline `.run` installer for the Altinity ClickHouse Operator Helm chart.

This repository follows the same air-gapped packaging pattern used by `app_prometheus`:

- vendor the upstream Helm chart inside `charts/`
- package all required images as tar archives into a self-extracting `.run`
- rewrite image references to a target registry during install
- build release artifacts through GitHub Actions instead of relying on local foreign image access

## Upstream baseline

- Upstream chart source: `Altinity/clickhouse-operator`
- Vendored chart path: `deploy/helm/clickhouse-operator`
- Chart version: `0.26.3`
- App version: `0.26.3`

The installer intentionally pins the CRD hook image instead of inheriting the chart's `latest` default:

- `docker.io/bitnamilegacy/kubectl:1.33.4-debian-12-r0`

Bundled images:

- `docker.io/altinity/clickhouse-operator:0.26.3`
- `docker.io/altinity/metrics-exporter:0.26.3`
- `docker.io/bitnamilegacy/kubectl:1.33.4-debian-12-r0`

## Repository layout

```text
apps_clickhouse-operator/
  build.sh
  install.sh
  images/image.json
  charts/clickhouse-operator/
  .github/workflows/build-offline-installer.yml
```

## Build strategy

The recommended path is GitHub Actions.

Reason:

- local environments may not be able to pull upstream images from foreign registries
- the workflow already does the required `amd64` / `arm64` matrix build
- tag builds automatically publish release assets

Push flow:

```bash
git push origin main
git tag v0.1.0
git push origin v0.1.0
```

Workflow outputs:

- `dist/clickhouse-operator-installer-amd64.run`
- `dist/clickhouse-operator-installer-arm64.run`
- matching `.sha256` files

If your local environment can reach the upstream registries, local build still works:

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

Basic install:

```bash
./clickhouse-operator-installer-amd64.run install -y
```

Enable ServiceMonitor and Grafana dashboard provisioning for a cluster that already has a Prometheus/Grafana stack:

```bash
./clickhouse-operator-installer-amd64.run install \
  --enable-service-monitor \
  --enable-dashboards \
  -y
```

Reuse images that are already present in the target registry:

```bash
./clickhouse-operator-installer-amd64.run install \
  --registry harbor.example.com/kube4 \
  --skip-image-prepare \
  -y
```

Add extra Helm overrides:

```bash
./clickhouse-operator-installer-amd64.run install \
  --helm-set operator.resources.requests.cpu=100m \
  --helm-set operator.resources.requests.memory=256Mi \
  --helm-arg --debug \
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

Uninstall and delete CRDs:

```bash
./clickhouse-operator-installer-amd64.run uninstall --delete-crds -y
```

## Defaults

- release name: `clickhouse-operator`
- namespace: `clickhouse`
- registry prefix: `sealos.hub:5000/kube4`
- image pull policy: `IfNotPresent`
- operator secret username: `clickhouse_operator`
- operator secret password: `clickhouse_operator_password`

Optional behavior flags:

- `--disable-crd-hook`
- `--disable-metrics-exporter`
- `--enable-service-monitor`
- `--enable-dashboards`
- `--namespace-scoped-rbac`

## Notes

- This change set does not perform local install verification.
- The intended verification path is the GitHub Actions build and downstream cluster-side install by environments that can reach the target registry.
- The vendored Helm chart is kept as close to upstream as possible. Image pinning and registry remapping are handled by the installer values, not by patching chart logic.
