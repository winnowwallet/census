#!/bin/bash
set -euo pipefail
# Latest stable at deployment, pinned for reproducible VM rebuilds.
package=/var/cache/tailscale_1.102.4_amd64.deb
curl --fail --location --retry 3 https://pkgs.tailscale.com/stable/ubuntu/pool/tailscale_1.102.4_amd64.deb --output "$package"
printf '%s  %s\n' 758cd0b2536d35dc1f02b785784dd18d08945ff644fcd92b1b0d597b6fa56f8b "$package" | sha256sum --check -
DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install "$package"
systemctl enable --now tailscaled
dpkg-query -W > /var/lib/gateway-packages.txt
# Enrollment is separate; no auth key or cloned Tailscale state is in the image.
