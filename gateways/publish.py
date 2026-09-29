#!/usr/bin/env python3
"""Publish just the two SOCKS listeners through the host's existing Tailscale identity."""
import json, socket, subprocess

ports = [(9050,19050),(4447,14447)]
status = json.loads(subprocess.check_output(['tailscale','serve','status','--json']))
for public, local in ports:
    expected = {'TCPForward':f'127.0.0.1:{local}'}
    current = status.get('TCP',{}).get(str(public))
    if current is not None and current != expected:
        raise SystemExit(f'Tailscale port {public} already belongs to another service; left unchanged')
    with socket.create_connection(('127.0.0.1',local),timeout=5) as connection:
        connection.sendall(b'\x05\x01\x00')
        response = connection.makefile('rb').read(2)
        if response != b'\x05\x00': raise SystemExit(f'{local} is not a ready SOCKS5 listener')
for public, local in ports:
    subprocess.run(['tailscale','serve','--bg',f'--tcp={public}',f'tcp://127.0.0.1:{local}'],check=True)
