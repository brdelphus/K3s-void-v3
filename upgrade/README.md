# Automated k3s upgrades for Void Linux clusters

This directory contains the pieces that make automated k3s upgrades work on the
**Void Linux** nodes of this cluster (no systemd — k3s runs under
openrc/`supervise-daemon`), using `system-upgrade-controller`.

The stock `rancher/k3s-upgrade` script is actually **not systemd-bound**: it SIGTERMs
the k3s process and lets the host supervisor respawn it, and it already handles
`supervise-daemon` parents. The Void-specific fixes in `upgrade.sh` (marked `[VOID]`)
are:

1. **Host mount guard** — hostPath mounts are unstable on these nodes: a pod mounting
   `/` at `/host` can silently get an overlay of the container rootfs instead of the
   host root, which would write the "new" binary into the container and never upgrade
   the node. The script aborts unless `/host/etc/os-release` is really Void.
2. **Dynamic binary fallback** — if the controller did not stage a binary at `/opt/k3s`,
   the latest release is resolved live from the GitHub API (nothing pinned).
3. **Post-kill respawn check** — after SIGTERM, it confirms the supervisor brought k3s
   back and falls back to `rc-service` if not.

## Files

| File | Purpose |
|---|---|
| `upgrade.sh` | Adapted upgrade script (entrypoint of the custom image) |
| `Dockerfile` | Builds `ghcr.io/brdelphus/k3s-upgrade-void` on top of the official image |
| `suc-manifest.yaml` | system-upgrade-controller v0.20.1 (official; namespace already privileged) |
| `plans-void.yaml` | Example server + agent Plans (`channel` resolves the version — no pinning) |

## Usage

### 1. Build and publish the custom image

**Via GitHub Actions (recommended)** — builds linux/amd64 + linux/arm64 and pushes to
GHCR:

```sh
gh workflow run build-upgrade-image.yml -f version=v1.36.4-k3s1
# or: Actions tab → build-upgrade-image → Run workflow → version input
```

**Manually** — tag must match the k3s release being targeted (`v<ver>-k3s1`). Requires a
GHCR token with `write:packages` (`gh auth refresh -s write:packages` if missing).

```sh
cd upgrade
docker buildx create --name void-builder --driver docker-container \
  --platform linux/amd64,linux/arm64 --use   # once
docker buildx build --builder void-builder --platform linux/amd64,linux/arm64 \
  -t ghcr.io/brdelphus/k3s-upgrade-void:v1.36.4-k3s1 \
  -t ghcr.io/brdelphus/k3s-upgrade-void:latest --push .
```

> The package is **private** — the cluster needs a pull secret (step 3).

### 2. Install the controller (once per cluster)

```sh
kubectl --kubeconfig ~/.kube/clusters/k3s-v3.conf apply -f suc-manifest.yaml
kubectl -n system-upgrade get pods     # 1/1 Running
```

### 3. Allow the cluster to pull the private image

```sh
kubectl -n system-upgrade create secret docker-registry ghcr-cred \
  --docker-server=ghcr.io --docker-username=brdelphus --docker-password=<GHCR_TOKEN>
kubectl -n system-upgrade patch sa system-upgrade \
  -p '{"imagePullSecrets":[{"name":"ghcr-cred"}]}'
```

### 4. Apply the plans

```sh
kubectl --kubeconfig ~/.kube/clusters/k3s-v3.conf apply -f plans-void.yaml
```

The controller resolves the latest stable version from the channel, upgrades the
control-plane nodes first (one at a time, no drain — etcd quorum 2/2, the API drops
~40s per CP restart), then the workers (cordon + drain, one at a time).

### 5. Watch

```sh
kubectl --kubeconfig ~/.kube/clusters/k3s-v3.conf get plans -n system-upgrade -o wide
kubectl --kubeconfig ~/.kube/clusters/k3s-v3.conf get nodes -o wide
```

Both plans flip to `COMPLETE=True` when all nodes are done. If the nodes are already
on the target version, the run is a clean no-op (binary checksums match → exit 0).

### 6. Post-upgrade cleanup

Upgrade pods end up `Completed` (or `Unknown` if the service restarted mid-run). Remove
them:

```sh
kubectl -n system-upgrade get pod -o name | grep apply-k3s \
  | xargs -r kubectl -n system-upgrade delete --force --grace-period=0
```

## Next upgrade (when a new stable release lands)

1. Build + push the image with the new tag (step 1, swap the version in the tag).
2. Done — the controller picks up the new channel version and runs the plans
   automatically. No plan edits needed.

## Gotchas

- `spec.channel` in a Plan must be a **URL** (`https://update.k3s.io/v1-release/channels/stable`),
  not a bare name — `stable` alone fails with "unsupported protocol scheme".
- The GHCR token needs `write:packages`; the plain docker-config token is read-only for
  packages.
- A private GHCR package requires `imagePullSecrets` on the `system-upgrade` service
  account, otherwise upgrade pods fail with `ImagePullBackOff`.
