#!/bin/bash
set -euo pipefail
# Run inside one gateway VM. An optional root-only auth-key file supports automation.
kind=${1:?usage: enroll-tailscale.sh tor|i2p [root-only-auth-key-file]}
case "$kind" in tor|i2p) ;; *) echo 'Expected tor or i2p' >&2; exit 2;; esac
if [ "$#" -gt 2 ]; then echo 'Too many arguments' >&2; exit 2; fi
args=(--hostname="winnow-$kind-gateway" --accept-dns=false --accept-routes=false)
if [ "$#" -eq 2 ]; then
    keyfile=$2
    if [ ! -f "$keyfile" ] || [ -L "$keyfile" ] || [ "$(stat -c %u "$keyfile")" != 0 ]; then
        echo 'Auth key must be a regular root-owned file' >&2; exit 2
    fi
    case "$(stat -c %a "$keyfile")" in 400|600) ;; *) echo 'Auth-key file must have mode 0400 or 0600' >&2; exit 2;; esac
    args+=(--auth-key="file:$keyfile")
fi
exec tailscale up "${args[@]}"
