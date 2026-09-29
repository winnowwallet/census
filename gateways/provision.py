#!/usr/bin/env python3
"""Run as root on the KVM host. Owns only winnow-{tor,i2p}-gateway resources."""
import fcntl, hashlib, json, os, pathlib, subprocess, sys, urllib.request

ROOT = pathlib.Path('/var/lib/winnow-peer-gateways')
HERE = pathlib.Path(__file__).resolve().parent

def run(*args):
    subprocess.run(args, check=True)

def provision(key):
    lock = json.loads((HERE / 'image.json').read_text())
    image = ROOT / 'ubuntu-base.img'
    if not image.exists():
        temp = image.with_suffix('.download')
        urllib.request.urlretrieve(lock['url'], temp)
        if hashlib.file_digest(temp.open('rb'), 'sha256').hexdigest() != lock['sha256']:
            raise RuntimeError('Cloud image checksum mismatch')
        temp.rename(image)
    if hashlib.file_digest(image.open('rb'), 'sha256').hexdigest() != lock['sha256']:
        raise RuntimeError('Cached image checksum mismatch')
    for kind, port, local, ssh in [('tor',9050,19050,22051), ('i2p',4447,14447,22052)]:
        name = f'winnow-{kind}-gateway'
        folder = ROOT / kind
        folder.mkdir(exist_ok=True)
        package = 'tor' if kind == 'tor' else 'i2pd'
        conf = ('SocksPort 0.0.0.0:9050\nClientOnly 1\nSafeSocks 1\n' if kind == 'tor' else
                'ipv4 = true\nipv6 = false\nbandwidth = L\ntunconf = /etc/i2pd/gateway-tunnels.conf\ntunnelsdir = /etc/i2pd/gateway-tunnels.d\n[http]\nenabled = false\n[httpproxy]\nenabled = false\n[socksproxy]\nenabled = true\naddress = 0.0.0.0\nport = 4447\noutproxy.enabled = false\n[sam]\nenabled = false\n[upnp]\nenabled = false\n')
        config_path = '/etc/tor/torrc' if kind == 'tor' else '/etc/i2pd/i2pd.conf'
        apt = f'''Types: deb
URIs: https://snapshot.ubuntu.com/ubuntu/{lock['apt_snapshot']}/
Suites: noble noble-updates noble-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
'''
        cloud = {
            'hostname':name, 'ssh_pwauth':False,
            'users':[{'name':'gateway','groups':['sudo'],'sudo':'ALL=(ALL) NOPASSWD:ALL',
                      'shell':'/bin/bash','lock_passwd':True,'ssh_authorized_keys':[key]}],
            'write_files':[{'path':config_path,'content':conf},
                           {'path':'/etc/apt/sources.list.d/ubuntu.sources','content':apt}],
            'apt':{'preserve_sources_list':True},
            'package_update':True, 'packages':['tor','ca-certificates','curl'] if kind == 'tor' else ['ca-certificates','curl'],
            'runcmd':[['systemctl','enable','--now',package], ['systemctl','restart',package],
                       ['sh','-c','dpkg-query -W > /var/lib/gateway-packages.txt']],
        }
        if kind == 'i2p':
            cloud['write_files'].append({'path':'/etc/i2pd/gateway-tunnels.conf','content':'# No application tunnels. SOCKS only.\n'})
            cloud['write_files'].append({'path':'/usr/local/sbin/install-gateway-i2pd',
                'permissions':'0755', 'content':(HERE/'install-i2pd.sh').read_text()})
            cloud['runcmd'] = [['/usr/local/sbin/install-gateway-i2pd']]
        for filename, destination in [('install-tailscale.sh', 'install-gateway-tailscale'),
                                      ('enroll-tailscale.sh', 'enroll-gateway-tailscale')]:
            cloud['write_files'].append({'path':'/usr/local/sbin/'+destination,
                'permissions':'0755', 'content':(HERE/filename).read_text()})
        cloud['runcmd'].append(['/usr/local/sbin/install-gateway-tailscale'])
        # JSON is a YAML subset accepted by cloud-init.
        rendered = '#cloud-config\n'+json.dumps(cloud,indent=2)
        digest = hashlib.sha256(rendered.encode()).hexdigest()
        stamp = folder/'configuration.sha256'
        if stamp.exists() and stamp.read_text() != digest:
            raise RuntimeError(f'{name} configuration changed; review and apply guest changes explicitly or rebuild into a new directory')
        (folder/'user-data').write_text(rendered)
        stamp.write_text(digest)
        (folder/'meta-data').write_text(json.dumps({'instance-id':name+'-v1','local-hostname':name}))
        disk = folder/'disk.qcow2'
        if not disk.exists():
            run('qemu-img','create','-f','qcow2','-F','qcow2','-b',str(image),str(disk),'12G')
        seed = folder/'seed.iso'
        if not seed.exists():
            run('genisoimage','-quiet','-output',str(seed),'-volid','cidata','-joliet','-rock',str(folder/'user-data'),str(folder/'meta-data'))
        unit = f'''[Unit]
Description=Winnow {kind} gateway VM
After=network-online.target
Wants=network-online.target
[Service]
User=libvirt-qemu
Group=kvm
ExecStart=/usr/bin/qemu-system-x86_64 -name {name} -enable-kvm -machine q35 -cpu host -smp 2 -m 1536 -display none -serial file:{folder}/console.log -drive file={disk},format=qcow2,if=virtio -drive file={seed},format=raw,media=cdrom,readonly=on -netdev user,id=net0,hostfwd=tcp:127.0.0.1:{local}-:{port},hostfwd=tcp:127.0.0.1:{ssh}-:22 -device virtio-net-pci,netdev=net0
Restart=on-failure
RestartSec=5
TimeoutStopSec=90
[Install]
WantedBy=multi-user.target
'''
        unit_path = pathlib.Path('/etc/systemd/system')/(name+'.service')
        if unit_path.exists() and unit_path.read_text() != unit:
            raise RuntimeError(f'Review changed service before replacing {unit_path}')
        unit_path.write_text(unit)
        run('chown','-R','libvirt-qemu:kvm',str(folder))
        run('systemctl','daemon-reload')
        run('systemctl','enable','--now',name)
        print(f'{name}: host loopback {local}; SSH {ssh}; publish tailnet TCP {port} after readiness check')

if __name__ == '__main__':
    if os.geteuid() != 0 or len(sys.argv) != 2:
        sys.exit('Usage: sudo python3 provision.py /path/to/authorized_key.pub')
    key = pathlib.Path(sys.argv[1]).read_text().strip()
    if not key.startswith(('ssh-ed25519 ', 'ssh-rsa ', 'ecdsa-sha2-')) or '\n' in key:
        sys.exit('Expected one SSH public key')
    ROOT.mkdir(mode=0o755,exist_ok=True)
    with (ROOT/'provision.lock').open('w') as mutex:
        fcntl.flock(mutex,fcntl.LOCK_EX|fcntl.LOCK_NB)
        provision(key)
