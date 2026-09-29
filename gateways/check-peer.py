#!/usr/bin/env python3
"""SOCKS5-by-name + Bitcoin mainnet version handshake. No wallet data."""
import argparse, hashlib, json, os, socket, struct, time

def read(sock, size):
    result = b''
    while len(result) < size:
        data = sock.recv(size-len(result))
        if not data:
            raise RuntimeError('connection closed')
        result += data
    return result

def check(proxy, proxy_port, host, port):
    with socket.create_connection((proxy,proxy_port), timeout=65) as sock:
        sock.sendall(b'\x05\x01\x00')
        if read(sock,2) != b'\x05\x00': raise RuntimeError('SOCKS method refused')
        name = host.encode('ascii')
        sock.sendall(b'\x05\x01\x00\x03'+bytes([len(name)])+name+struct.pack('>H',port))
        reply = read(sock,4)
        if reply[:2] != b'\x05\x00': raise RuntimeError(f'SOCKS refusal: {reply.hex()}')
        size = {1:4,4:16}.get(reply[3])
        if size is None:
            if reply[3] != 3: raise RuntimeError('SOCKS address type')
            size = read(sock,1)[0]
        read(sock,size+2)
        address = b'\0'*26
        agent = b'/WinnowGatewayCheck:1/'
        payload = struct.pack('<iQq',70016,0,int(time.time()))+address+address+os.urandom(8)+bytes([len(agent)])+agent+struct.pack('<i?',0,False)
        checksum = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
        sock.sendall(bytes.fromhex('f9beb4d9')+b'version\0\0\0\0\0'+struct.pack('<I',len(payload))+checksum+payload)
        header = read(sock,24)
        if header[:4] != bytes.fromhex('f9beb4d9') or header[4:16].rstrip(b'\0') != b'version':
            raise RuntimeError('Expected Bitcoin mainnet version message')
        size = struct.unpack('<I',header[16:20])[0]
        if size > 4096: raise RuntimeError('Oversized version')
        body = read(sock,size)
        if hashlib.sha256(hashlib.sha256(body).digest()).digest()[:4] != header[20:24]:
            raise RuntimeError('Bitcoin checksum mismatch')
        version, services = struct.unpack('<iQ',body[:12])
        if not services & 64: raise RuntimeError('Peer does not advertise compact filters')
        print(json.dumps({'peer':host,'port':port,'gateway':f'{proxy}:{proxy_port}',
                          'version':version,'services':services,'compact_filters':bool(services & 64)}),flush=True)

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('gateway'); parser.add_argument('gateway_port',type=int)
    parser.add_argument('peer'); parser.add_argument('peer_port',type=int)
    args=parser.parse_args()
    check(args.gateway,args.gateway_port,args.peer,args.peer_port)
