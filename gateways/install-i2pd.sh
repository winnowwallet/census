#!/bin/bash
set -euo pipefail
# Upstream 2.61.0, verified against the release asset's SHA-256 digest.
url=https://github.com/PurpleI2P/i2pd/releases/download/2.61.0/i2pd_2.61.0-1noble1_amd64.deb
sha=5d4138be6cb448c1d59bba8c1e67e99f6cdbfea3e6f8697d3cce0252cfe24cf8
package=/var/cache/i2pd_2.61.0-1noble1_amd64.deb
curl --fail --location --retry 3 "$url" --output "$package"
printf '%s  %s\n' "$sha" "$package" | sha256sum --check -
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install "$package"
mkdir -p /etc/i2pd/gateway-tunnels.d /etc/systemd/system/i2pd.service.d
cat > /etc/systemd/system/i2pd.service.d/gateway.conf <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/bin/i2pd --conf=/etc/i2pd/i2pd.conf --tunconf=/etc/i2pd/gateway-tunnels.conf --tunnelsdir=/etc/i2pd/gateway-tunnels.d --pidfile=/run/i2pd/i2pd.pid --logfile=/var/log/i2pd/i2pd.log --daemon --service
Restart=on-failure
RestartSec=10
UNIT
systemctl daemon-reload
systemctl enable i2pd
systemctl restart i2pd
dpkg-query -W > /var/lib/gateway-packages.txt
