[Back to main README](../README.md)

# Tor and I2P peer gateways

Two gateways expose one SOCKS5 listener each on the tailnet, one for Tor and
one for I2P. Winnow's Automatic peer routing finds them by name and sends Tor
and I2P Bitcoin peer connections through them; the census job itself runs its
own Tor and i2pd on the Actions runner and does not use them. How the wallet
uses them is in
[winnow's peer-gateway guide](https://github.com/winnowwallet/winnow/blob/main/docs/peer-gateways.md).

Since 2026-10-13 the project's gateways run on an Umbrel home server as the
community app
[`ph4-winnow-gateways`](https://github.com/posix4e/ph4-umbrel/tree/main/ph4-winnow-gateways):
two Tailscale containers in userspace mode forward the SOCKS ports, Tor goes
through Umbrel's own Tor proxy, and the app's i2pd also serves the census
mirror. From 2026-09-15 to 2026-10-13 they ran as the two KVM VMs this
directory reproduces, and the recipe below still builds them on any KVM host.

This recipe first appeared in the closed winnowwallet/winnow#146. On
2026-09-29 `provision.py` rendered cloud-init byte-identical to the deployed
guests (user-data SHA-256 `3e60a391…22b9b1` for Tor and `5c94c15a…2ef7c7` for
I2P, matching each guest's `configuration.sha256`), and the host's cached
`ubuntu-base.img` matched `image.json`.

## Naming contract

Winnow's discovery asks Tailscale's resolver for two fixed names and accepts
only a tailnet IPv4 address that answers a SOCKS5 greeting:

| Network | MagicDNS name | SOCKS port | Tag | VM guest SSH via host |
| --- | --- | --- | --- | --- |
| Tor | `winnow-tor-gateway` | 9050 | `tag:winnow-tor` | 22051 |
| I2P | `winnow-i2p-gateway` | 4447 | `tag:winnow-i2p` | 22052 |

Tags are for tailnet administration; the wallet never reads them. A
replacement must enroll with the same hostnames, and the tailnet ACLs must
allow clients TCP 9050/4447 to them. The current deployment's addresses are
`100.110.238.104` (Tor) and `100.101.121.117` (I2P); both are tagged devices,
so their keys do not expire.

An auth key can apply a tag only if the tag has an owner in the tailnet
policy. With `"tag:winnow-tor": []` in `tagOwners`, every key, tagged or not,
was refused with `requested tags [tag:winnow-tor] are invalid or not
permitted`, and only an interactive admin login got through. With
`["autogroup:admin"]` as the owner of both tags, one reusable, untagged key
enrolled both gateways, each with its own tag.

Each VM has two vCPUs, 1.5 GiB RAM, a 12 GiB copy-on-write disk and its own
daemon state. QEMU runs as `libvirt-qemu` under the systemd services
`winnow-tor-gateway` and `winnow-i2p-gateway`, on separate QEMU user-mode
networks that leave the host's libvirt networks and other VMs alone. These
are ordinary KVM guests; the recipe does not enable confidential-guest
attestation. Neither gateway advertises or accepts routes; they are SOCKS5
proxies, not exit nodes, and applications must use them explicitly with
remote DNS.

## The I2P census mirror

`CensusCatalog.i2pMirror` in the wallet
(`yts2d2oyrsz2eytnofuutgnsixymdkj2nmcmmpfv3aofzsnjt4eq.b32.i2p`) is served by
the I2P gateway. On the Umbrel, the app's `mirror.py` does what
`winnow-census-sync` and `winnow-census-http` did on the VM, and its i2pd
server tunnel reads the key from `data/i2pd/winnow-census-mirror.dat` in the
app's data directory. On the VM the mirror was added on 2026-09-28, after
provisioning, so it is not part of cloud-init; the files in
[`i2p-mirror/`](i2p-mirror) are copied byte-for-byte from that guest:

| File | Guest path | Role |
| --- | --- | --- |
| `winnow-census-mirror.conf` | `/etc/i2pd/gateway-tunnels.d/` | i2pd HTTP server tunnel: I2P port 80 → `127.0.0.1:8480`, keys `winnow-census-mirror.dat` |
| `winnow-census-http.service` | `/etc/systemd/system/` | `python3 -m http.server` on loopback 8480 serving `/var/lib/winnow-census-mirror`, sandboxed with `DynamicUser` |
| `winnow-census-sync` | `/usr/local/bin/` | Fetches `peers.json` and `peers.json.sig` from census.winnowwallet.com with size and time limits, checks the JSON parses, then moves both into place |
| `winnow-census-sync.service`, `.timer` | `/etc/systemd/system/` | Runs the sync a minute after boot and every 30 minutes |

The mirror is untrusted: the wallet verifies the census signature, and the
sync script copies files without checking it. It replaces `peers.json` just
before `peers.json.sig`, so a fetch in that instant can pair a new list with
the old signature; the wallet then rejects it and retries later.

**Back up the destination keys.** The `.b32.i2p` address is compiled into the
wallet and is derived from `winnow-census-mirror.dat` (on a VM
`/var/lib/i2pd/winnow-census-mirror.dat`, `i2pd:i2pd`, mode 0640). Rebuilding
the I2P gateway without that file gives the mirror a new address and breaks
I2P-only census downloads until a wallet release carries it. Keep a copy in
your secret store, never in this repository.

To move the mirror, stop the old router before the new one loads the key, so
the destination is never published from two places. On 2026-10-13 the moved
destination answered through the I2P network about seven minutes after the
Umbrel app restarted with the key.

To add the mirror to a freshly provisioned I2P VM, restore the keys first so
i2pd reuses the address, then install and start the pieces:

```sh
# on the I2P guest, with this directory copied to ~/i2p-mirror
sudo install -o i2pd -g i2pd -m 0640 winnow-census-mirror.dat /var/lib/i2pd/
sudo install -m 0644 ~/i2p-mirror/winnow-census-mirror.conf /etc/i2pd/gateway-tunnels.d/
sudo install -m 0755 ~/i2p-mirror/winnow-census-sync /usr/local/bin/
sudo install -m 0644 ~/i2p-mirror/winnow-census-*.service ~/i2p-mirror/winnow-census-sync.timer /etc/systemd/system/
sudo mkdir -p /var/lib/winnow-census-mirror/census
sudo systemctl daemon-reload
sudo systemctl enable --now winnow-census-http winnow-census-sync.timer
sudo systemctl start winnow-census-sync
sudo systemctl restart i2pd
```

Both guests also run [`winnow-tailscale-ssh.service`](winnow-tailscale-ssh.service),
which waits for tailscaled and runs `tailscale set --ssh`; whether Tailscale
SSH is allowed is then up to the tailnet policy.

## Reproduce

Host prerequisites: Linux x86-64, KVM, QEMU with user networking,
`qemu-img`, `genisoimage`, Python 3.11+, systemd, a `libvirt-qemu` user with
KVM access, and an already enrolled Tailscale host. On a new Ubuntu host the
VM tools come from `qemu-system-x86`, `qemu-utils`, `genisoimage` and
`libvirt-daemon-system`.

Copy this directory and your **public** SSH key to the host, then from the
copied directory:

```sh
sudo python3 provision.py /path/to/admin.pub
```

The recipe pins the Ubuntu cloud image by dated URL and SHA-256, apt to
Ubuntu's 2026-09-15 snapshot, upstream i2pd 2.61.0 by release-asset hash, and
Tailscale 1.102.4 by package hash. Tor resolves to
`0.4.9.11-0ubuntu0.24.04.1` from that snapshot. Both guests record
`dpkg-query -W` in `/var/lib/gateway-packages.txt`. Reproducibility means the
same software and configuration with fresh machine and overlay identities; do
not distribute existing Tor or I2P private state as a template. Keep the
verified base image when archiving a deployment: the overlays depend on it and
upstream retention is outside this recipe's control.

Wait for cloud-init and the daemons (first boot takes a few minutes):

```sh
ssh -J tdx2 -p 22051 gateway@127.0.0.1 'cloud-init status; systemctl is-active tor@default'
ssh -J tdx2 -p 22052 gateway@127.0.0.1 'cloud-init status; systemctl is-active i2pd'
```

Enroll each guest with the installed helper:

```sh
ssh -J tdx2 -p 22051 gateway@127.0.0.1 'sudo /usr/local/sbin/enroll-gateway-tailscale tor'
ssh -J tdx2 -p 22052 gateway@127.0.0.1 'sudo /usr/local/sbin/enroll-gateway-tailscale i2p'
```

Open each printed login URL and connect that VM to the tailnet. For
unattended enrollment, place a scoped auth key in a root-owned 0600 file
inside the guest, pass it as the helper's second argument, and remove it
afterwards. Never commit an auth key or put it in cloud-init, and never clone
`/var/lib/tailscale/`.

Provisioning is serialized and idempotent: it does not restart a running VM
or recreate an existing disk, and it rejects a changed cloud-init
configuration rather than letting a booted guest silently ignore it. To
upgrade, update the pinned inputs and apply the matching guest changes
explicitly, or build replacement VMs with distinct paths, names and ports.

## Verify and operate

`check-peer.py` checks SOCKS5, a checksummed mainnet `version` reply and the
compact-filter service bit, with a current peer from
`https://census.winnowwallet.com/census/peers.json`. It sends no wallet data.

```sh
python3 check-peer.py 100.110.238.104 9050 PEER.onion 8333
python3 check-peer.py 100.101.121.117 4447 PEER.b32.i2p 8333
```

From a Mac on the tailnet, winnow's `scripts/check-live-gateways` exercises
discovery, the I2P mirror and handshakes through both gateways; the
2026-09-29 run against the VMs and the 2026-10-13 run against the Umbrel are
recorded in winnow's `docs/security/evidence/`.

```sh
# Umbrel
docker ps --filter name=ph4-winnow-gateways
docker exec ph4-winnow-gateways_tor_1 tailscale status
docker logs --tail 30 ph4-winnow-gateways_i2pd_1
# VM host
sudo systemctl status winnow-tor-gateway winnow-i2p-gateway
sudo tail /var/lib/winnow-peer-gateways/tor/console.log
sudo tail /var/lib/winnow-peer-gateways/i2p/console.log
# Guests
ssh -J tdx2 -p 22051 gateway@127.0.0.1 'sudo journalctl -u tor@default -n 30'
ssh -J tdx2 -p 22052 gateway@127.0.0.1 'sudo tail /var/log/i2pd/i2pd.log'
```

`publish.py`, from the earlier manual configuration, also forwards the VM
host's own tailnet address, ports 9050 and 4447, to the VMs' loopback
listeners (19050 and 14447) through Tailscale Serve. Winnow's discovery does
not use it. To withdraw only that forwarding, or the gateways:

```sh
sudo tailscale serve --tcp=9050 off
sudo tailscale serve --tcp=4447 off
sudo systemctl disable --now winnow-tor-gateway winnow-i2p-gateway
```

Do not use `tailscale serve reset`, which removes other services too.

## Sources

- [Ubuntu cloud images](https://cloud-images.ubuntu.com/noble/)
- [Ubuntu snapshot service](https://snapshot.ubuntu.com/)
- [i2pd 2.61.0 release](https://github.com/PurpleI2P/i2pd/releases/tag/2.61.0)
- [i2pd configuration](https://docs.i2pd.website/en/latest/user-guide/configuration/)
- [Tailscale Linux installation](https://tailscale.com/docs/install/linux)
- [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)
