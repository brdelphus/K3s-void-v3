# k3s-upgrade-void — k3s upgrade image adapted for Void Linux
# Base: the official k3s-upgrade image (contains /opt/k3s + /bin/upgrade.sh).
# The adapted /bin/upgrade.sh adds: host mount verification, dynamic binary
# fallback and post-kill respawn check (see upgrade.sh [VOID] markers).
#
# Build + push (version tag must match the k3s release, e.g. v1.36.4-k3s1).
# Pushed to GHCR (auth already present in ~/.docker/config.json):
#   sudo HOME=$HOME docker buildx build --platform linux/amd64,linux/arm64 \
#     -t ghcr.io/brdelphus/k3s-upgrade-void:v1.36.4-k3s1 \
#     -t ghcr.io/brdelphus/k3s-upgrade-void:latest --push .
FROM rancher/k3s-upgrade:v1.36.4-k3s1
COPY upgrade.sh /bin/upgrade.sh
RUN chmod +x /bin/upgrade.sh
