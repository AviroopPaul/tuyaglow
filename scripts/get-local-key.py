#!/usr/bin/env python3
"""Get the device ID and local key of your Tuya / Smart Life bulbs.

Uses the Smart Life app's QR sign-in, the same flow Home Assistant's Tuya integration uses.
No Tuya developer account is needed. Your password is never asked for; you approve the
sign-in in the app.

    python3 -m venv .venv && .venv/bin/pip install tuya-device-sharing-sdk "qrcode[pil]"
    .venv/bin/python scripts/get-local-key.py

You need your Smart Life "User Code": Smart Life app > Me > settings (gear) >
Account and Security > User Code.
"""
import json
import socket
import struct
import sys
import time

try:
    import qrcode
    from tuya_sharing import LoginControl, Manager
except ImportError:
    sys.exit('Missing packages. Run: pip install tuya-device-sharing-sdk "qrcode[pil]"')

CLIENT_ID, SCHEMA = "HA_3y9q4ak7g4ephrvke", "haauthorize"


def lan_scan(seconds=8):
    """Listen for Tuya LAN broadcasts and return {device_id: (ip, version)}.
    Only plain and 6699 frames are decoded here; that covers most bulbs."""
    found = {}
    try:
        from hashlib import md5
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    except ImportError:
        return found
    udpkey = md5(b"yGAdlopoPVldABfn").digest()
    socks = []
    for port in (6666, 6667):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        try:
            s.bind(("", port))
        except OSError:
            continue
        s.settimeout(0.2)
        socks.append(s)
    end = time.time() + seconds
    while time.time() < end and socks:
        for s in socks:
            try:
                data, _ = s.recvfrom(4096)
            except socket.timeout:
                continue
            info = None
            try:
                if data[:4] == b"\x00\x00\x66\x99":
                    length = struct.unpack(">I", data[14:18])[0]
                    iv, ct, tag = data[18:30], data[30:18 + length - 16], data[18 + length - 16:18 + length]
                    dec = Cipher(algorithms.AES(udpkey), modes.GCM(iv, tag)).decryptor()
                    dec.authenticate_additional_data(data[4:18])
                    plain = dec.update(ct) + dec.finalize()
                    info = json.loads(plain[plain.index(b"{"):].rstrip(b"\x00"))
                elif data[:4] == b"\x00\x00\x55\xaa":
                    body = data[20:-8]
                    if body[:1] == b"{":
                        info = json.loads(body)
                    else:
                        dec = Cipher(algorithms.AES(udpkey), modes.ECB()).decryptor()
                        plain = dec.update(body) + dec.finalize()
                        info = json.loads(plain[:-plain[-1]])
            except Exception:
                continue
            if info and "gwId" in info:
                found[info["gwId"]] = (info.get("ip", "?"), info.get("version", "?"))
    return found


def main():
    user_code = input("Smart Life User Code: ").strip()
    lc = LoginControl()
    r = lc.qr_code(CLIENT_ID, SCHEMA, user_code)
    if not r.get("success"):
        sys.exit("Could not start sign-in: %s %s" % (r.get("code"), r.get("msg")))
    token = r["result"]["qrcode"]
    qr = qrcode.QRCode(border=1)
    qr.add_data("tuyaSmart--qrLogin?token=" + token)
    print("\nOpen Smart Life, tap the scan icon (top right of Home), scan this, then tap Confirm:\n")
    qr.print_ascii(invert=True)
    qrcode.make("tuyaSmart--qrLogin?token=" + token).save("smartlife-login-qr.png")
    print("(Also saved as smartlife-login-qr.png if the terminal QR is hard to scan.)")

    for _ in range(100):
        time.sleep(3)
        ok, info = lc.login_result(token, CLIENT_ID, user_code)
        if ok:
            break
    else:
        sys.exit("Timed out waiting for the scan. Run the script again.")

    tok = {k: info[k] for k in ("t", "uid", "expire_time", "access_token", "refresh_token")}
    m = Manager(CLIENT_ID, user_code, info["terminal_id"], info["endpoint"], tok)
    m.update_device_cache()
    print("\nSigned in. Listening on your Wi-Fi for 8 seconds to find IPs...")
    lan = lan_scan()

    print("\nYour devices (keep the local key private):\n")
    for d in m.device_map.values():
        ip, ver = lan.get(d.id, ("not seen on this Wi-Fi", "?"))
        print("  %s  (%s)" % (d.name, d.product_name))
        print("    Device ID : %s" % d.id)
        print("    Local key : %s" % d.local_key)
        print("    IP        : %s" % ip)
        print("    Version   : %s" % ver)
        print("    Category  : %s  (dj = light)\n" % d.category)
    print("Paste the Device ID and Local key into TuyaGlow > Bulb settings, then press Find on Wi-Fi.")


if __name__ == "__main__":
    main()
