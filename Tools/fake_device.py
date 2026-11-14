#!/usr/bin/env python3
"""Fake Tuya bulb for testing TuyaGlow's protocol code without hardware.

Speaks Tuya local protocol 3.3, 3.4 or 3.5 on TCP 6668 (localhost) using tinytuya's own
framing and crypto helpers, so it checks our Swift port against the reference.
It also sends one LAN discovery broadcast to 127.0.0.1 on UDP 6666/6667.

    pip install tinytuya
    python3 Tools/fake_device.py 3.4          # serve one client, then exit
    python3 Tools/fake_device.py udp          # send discovery packets only
"""
import hmac
import json
import os
import socket
import struct
import sys
import time
from hashlib import md5, sha256

from tinytuya.core import header as H
from tinytuya.core.crypto_helper import AESCipher
from tinytuya.core.message_helper import TuyaMessage, pack_message, unpack_message, parse_header

DEV_ID = "bf0123456789abcdefgh"
KEY = b"0123456789abcdef"
dps = {"20": True, "21": "white", "22": 1000, "23": 0, "24": "000003e803e8"}


def ecb(key, data, enc=True, pad=True):
    c = AESCipher(key)
    return c.encrypt(data, use_base64=False, pad=pad) if enc else c.decrypt(data, use_base64=False, decode_text=False)


def serve(version):
    vh = ("%.1f" % version).encode() + b"\x00" * 12
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 6668))
    srv.listen(1)
    srv.settimeout(30)
    print("fake %s listening" % version, flush=True)
    conn, _ = srv.accept()
    conn.settimeout(10)
    key = KEY
    local_nonce = remote_nonce = None
    buf = b""
    seq = 100

    def reply(cmd, payload):
        nonlocal seq
        seq += 1
        if version >= 3.5:
            msg = TuyaMessage(seq, cmd, 0, payload, 0, True, H.PREFIX_6699_VALUE, True)
            conn.sendall(pack_message(msg, hmac_key=key))
        elif version >= 3.4:
            enc = ecb(key, payload)
            msg = TuyaMessage(seq, cmd, 0, struct.pack(">I", 0) + enc, 0, True, H.PREFIX_55AA_VALUE, False)
            conn.sendall(pack_message(msg, hmac_key=key))
        else:
            enc = ecb(key, payload)
            body = struct.pack(">I", 0) + (vh + enc if cmd == 8 else enc)
            msg = TuyaMessage(seq, cmd, 0, body, 0, True, H.PREFIX_55AA_VALUE, False)
            conn.sendall(pack_message(msg))

    try:
        while True:
            data = conn.recv(4096)
            if not data:
                break
            buf += data
            while len(buf) >= 16:
                hdr = parse_header(buf)
                if len(buf) < hdr.total_length:
                    break
                raw, buf = buf[:hdr.total_length], buf[hdr.total_length:]
                hk = key if version >= 3.4 else None
                m = unpack_message(raw, hmac_key=hk, no_retcode=True)
                if not m.crc_good:
                    print("BAD CRC/HMAC/TAG cmd", m.cmd, flush=True)
                    continue
                p = m.payload
                if version == 3.4:
                    p = ecb(key, p, enc=False)
                if p.startswith(vh[:3]):
                    p = p[15:]
                if version < 3.4 and m.cmd not in (3, 4, 5) and p and p[:1] != b"{":
                    p = ecb(key, p, enc=False)
                if m.cmd == 3:   # session start
                    local_nonce = p[:16]
                    remote_nonce = os.urandom(16)
                    reply(4, remote_nonce + hmac.new(KEY, local_nonce, sha256).digest())
                    print("negotiate: got client nonce", flush=True)
                elif m.cmd == 5:  # session finish
                    ok = p[:32] == hmac.new(KEY, remote_nonce, sha256).digest()
                    x = bytes(a ^ b for a, b in zip(local_nonce, remote_nonce))
                    if version >= 3.5:
                        key = AESCipher(KEY).encrypt(x, use_base64=False, pad=False, iv=local_nonce[:12])[12:28]
                    else:
                        key = ecb(KEY, x, pad=False)
                    print("negotiate: finish hmac ok=%s" % ok, flush=True)
                elif m.cmd in (10, 16):
                    reply(m.cmd, json.dumps({"devId": DEV_ID, "dps": dps}).encode())
                    print("query -> sent status", flush=True)
                elif m.cmd in (7, 13):
                    obj = json.loads(p)
                    new = obj.get("dps") or obj.get("data", {}).get("dps", {})
                    dps.update(new)
                    print("control:", json.dumps(new), flush=True)
                    reply(8, json.dumps({"devId": DEV_ID, "dps": new, "t": int(time.time())}).encode())
                elif m.cmd == 9:
                    print("heartbeat", flush=True)
    except socket.timeout:
        pass
    print("final dps:", json.dumps(dps), flush=True)


def udp():
    udpkey = md5(b"yGAdlopoPVldABfn").digest()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for ver, port in (("3.3", 6666), ("3.4", 6667), ("3.5", 6667)):
        info = json.dumps({"ip": "10.0.0.%s" % ver[-1], "gwId": "fake%s" % ver.replace(".", ""), "active": 2, "version": ver}).encode()
        if ver == "3.5":
            msg = pack_message(TuyaMessage(0, 0x13, None, info, 0, True, H.PREFIX_6699_VALUE, True), hmac_key=udpkey)
        elif ver == "3.3":   # 6666: plain JSON
            msg = pack_message(TuyaMessage(0, 0x13, 0, struct.pack(">I", 0) + info, 0, True, H.PREFIX_55AA_VALUE, False))
        else:                # 6667: ECB with the UDP key
            msg = pack_message(TuyaMessage(0, 0x13, 0, struct.pack(">I", 0) + ecb(udpkey, info), 0, True, H.PREFIX_55AA_VALUE, False))
        for _ in range(3):
            s.sendto(msg, ("127.0.0.1", port))
            time.sleep(0.2)
    print("udp sent", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "udp":
        udp()
    else:
        serve(float(sys.argv[1]))
