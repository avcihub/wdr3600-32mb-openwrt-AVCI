#!/usr/bin/env python3
"""TL-WDR3600 v1 / 32 MB flash için CH341A ile yazılacak tam (32 MiB) imaj üretir.

Düzen:
  0x0000000  Breed (breed-ar9344-ar8327n.bin, sonu 0xFF ile doldurulur)
  0x0000080  Breed env başlığı ("ENVC", env ofseti 0x1e000, boyut 0x1000)
  0x001e000  Breed env: autoboot.command=flash dump 0x20000 16; autoboot
  0x001fc00  MAC adresi (--mac)
  0x0020000  OpenWrt firmware (--firmware, sysupgrade veya factory), geri kalanı 0xFF
  0x1ff0000  ART / Wi-Fi kalibrasyonu (--art, 64 KiB, cihazın kendi yedeği)

Firmware'den sonrası 0xFF olduğu için /overlay ilk açılışta temiz biçimlendirilir.

Kullanım:
  make_fullflash.py --breed breed-ar9344-ar8327n.bin --mac aa:bb:cc:dd:ee:ff \\
      --art art.bin --firmware openwrt-...-sysupgrade.bin -o fullflash.bin
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

FLASH_SIZE = 0x2000000
BREED_SIZE = 0x20000
FW_OFS = 0x20000
FW_MAX = 0x1FD0000
ART_OFS = 0x1FF0000
ART_SIZE = 0x10000
MAC_OFS = 0x1FC00
ENV_HDR_OFS = 0x80
ENV_OFS = 0x1E000
ENV_SIZE = 0x1000

# Breed 1.1 r1337 (2021-12-15, git-f9b74d0), hackpascal: breed.hackpascal.net
BREED_SHA256 = "4f30f85e6622245c86d446b071224cd3ab714b1b9fee3275063fbdd82345aba7"
# Breed env etkinken 0x80'de duran başlık (24.10.2026 dökümünden; cihaza özel veri yok)
ENV_HEADER = b"ENVC" + ENV_OFS.to_bytes(4, "big") + ENV_SIZE.to_bytes(4, "big")
ENV_FILE = os.path.join(HERE, "breed_env_autoboot.bin")


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def parse_mac(s):
    if not re.fullmatch(r"[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}", s):
        sys.exit(f"HATA: MAC biçimi yanlış: {s}")
    mac = bytes.fromhex(re.sub(r"[:-]", "", s))
    if mac[0] & 1 or mac == bytes(6) or mac == b"\xff" * 6:
        sys.exit("HATA: MAC geçersiz (multicast, sıfır veya FF)")
    return mac


def build(breed, mac, art, fw, env):
    if len(breed) > ENV_OFS:
        sys.exit("HATA: Breed dosyası env bölgesine taşıyor")
    if any(breed[ENV_HDR_OFS:ENV_HDR_OFS + len(ENV_HEADER)]):
        sys.exit("HATA: Breed'de 0x80'de beklenmeyen veri var (farklı Breed sürümü?)")
    if len(env) != ENV_SIZE or not env.startswith(b"ENV\0"):
        sys.exit("HATA: breed_env_autoboot.bin geçersiz")
    if len(art) != ART_SIZE:
        sys.exit(f"HATA: ART {len(art)} bayt, 65536 olmalı")
    if art == b"\xff" * ART_SIZE:
        sys.exit("HATA: ART tamamen boş (0xFF): bu cihazın gerçek ART yedeğini verin")
    if len(fw) > FW_MAX:
        sys.exit(f"HATA: firmware {len(fw):#x} bayt, en fazla {FW_MAX:#x}")

    img = bytearray(b"\xff" * FLASH_SIZE)
    img[:len(breed)] = breed
    img[ENV_HDR_OFS:ENV_HDR_OFS + len(ENV_HEADER)] = ENV_HEADER
    img[ENV_OFS:ENV_OFS + ENV_SIZE] = env
    img[MAC_OFS:MAC_OFS + 6] = mac
    img[FW_OFS:FW_OFS + len(fw)] = fw
    img[ART_OFS:ART_OFS + ART_SIZE] = art
    return bytes(img)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--breed", required=True)
    ap.add_argument("--mac", required=True)
    ap.add_argument("--art", required=True)
    ap.add_argument("--firmware", required=True)
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--allow-other-breed", action="store_true",
                    help="sha256'sı farklı Breed dosyasına izin ver (önerilmez)")
    ap.add_argument("--no-verify", action="store_true",
                    help="verify_image.py'yi atla (yalnızca ham flash dökümü için)")
    a = ap.parse_args()

    breed = open(a.breed, "rb").read()
    if sha256(breed) != BREED_SHA256 and not a.allow_other_breed:
        sys.exit(f"HATA: Breed sha256 {sha256(breed)}\n  beklenen {BREED_SHA256} (breed-ar9344-ar8327n.bin, r1337)")

    if not a.no_verify:
        r = subprocess.run([sys.executable, os.path.join(HERE, "verify_image.py"), a.firmware])
        if r.returncode != 0:
            sys.exit("HATA: verify_image.py firmware'i reddetti")

    img = build(breed, parse_mac(a.mac), open(a.art, "rb").read(),
                open(a.firmware, "rb").read(), open(ENV_FILE, "rb").read())
    with open(a.output, "wb") as f:
        f.write(img)
    print(f"\n{a.output}: {len(img)} bayt, sha256 {sha256(img)}")


if __name__ == "__main__":
    main()
