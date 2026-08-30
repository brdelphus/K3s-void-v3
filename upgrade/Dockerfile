# k3s-upgrade-void — k3s upgrade image adapted for Void Linux
# Base: the official k3s-upgrade image (contains /opt/k3s + /bin/upgrade.sh).
# The adapted /bin/upgrade.sh adds: host mount verification, dynamic binary
# fallback and post-kill respawn check (see upgrade.sh [VOID] markers).
#
# Build locally (version tag must match the k3s release, e.g. v1.36.4-k3s1):
#   sudo HOME=$HOME docker buildx build --platform linux/amd64,linux/arm64 \
#     -t ghcr.io/brdelphus/k3s-upgrade-void:v1.36.4-k3s1 \
#     -t ghcr.io/brdelphus/k3s-upgrade-void:latest --push .
# Or use the GitHub Actions workflow (.github/workflows/build-upgrade-image.yml).
ARG K3S_VERSION=v1.36.4-k3s1
FROM rancher/k3s-upgrade:${K3S_VERSION}
COPY upgrade.sh /bin/upgrade.sh
RUN chmod +x /bin/upgrade.sh
