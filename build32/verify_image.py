#!/usr/bin/env python3
"""32 MB WDR3600 imajını flaşlamadan önce doğrular.

Kontroller:
  * TP-Link v1 başlığı (hwid 0x36000001, fw_length 0x1fd0000)
  * Çekirdek LZMA'sı açılır; vmlinux kısmı ImageBuilder'ın vmlinux'u ile
    bayt bayt aynı mı (çekirdek koduna yanlışlıkla yama yapılmadığının kanıtı)
  * Ekli DTB'de firmware=0x20000+0x1fd0000, art=0x1ff0000+0x10000
  * Tahmini /overlay (rootfs_data) boyutu

Kullanım: verify_image.py <imaj.bin> [vmlinux]
"""
import lzma
import os
import struct
import subprocess
import sys
import tempfile

HWID = 0x36000001
FW_MAX = 0x1FD0000
FLASH_FW_START = 0x20000
ART_OFS = 0x1FF0000
PARTS = "/ahb/spi@1f000000/flash@0/partitions"


def fdtget(dtb, node, prop):
    r = subprocess.run(["fdtget", "-t", "x", dtb, node, prop], capture_output=True, text=True)
    return r.stdout.split() if r.returncode == 0 else None


def main(img_path, vmlinux_path=None):
    d = open(img_path, "rb").read()
    hwid, = struct.unpack(">I", d[0x40:0x44])
    fw_length, kofs, klen, rofs, rlen = struct.unpack(">5I", d[0x7C:0x90])
    errors = []

    print(f"Imaj        : {os.path.basename(img_path)} ({len(d):,} bayt)")
    print(f"Sürüm       : {d[0x1c:0x40].rstrip(bytes(1)).decode(errors='replace')}")
    print(f"HWID        : {hwid:#010x}  fw_length: {fw_length:#x}")
    if hwid != HWID:
        errors.append("HWID WDR3600 v1 değil")
    if fw_length != FW_MAX:
        errors.append(f"fw_length {fw_length:#x}, beklenen {FW_MAX:#x} (32Mlzma düzeni kullanılmamış)")

    dec = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(d[kofs:kofs + klen])
    dtb_at = dec.rfind(b"\xd0\x0d\xfe\xed")
    dtb_size, = struct.unpack(">I", dec[dtb_at + 4:dtb_at + 8])
    if dtb_at < 0 or dtb_at + dtb_size != len(dec):
        sys.exit("HATA: çekirdeğin sonunda ekli DTB bulunamadı")
    print(f"Çekirdek    : {klen:,} bayt LZMA, açılmış {len(dec):,} (vmlinux {dtb_at:,} + DTB {dtb_size:,})")

    if vmlinux_path:
        vml = open(vmlinux_path, "rb").read()
        if vml == dec[:dtb_at]:
            print("vmlinux     : ImageBuilder vmlinux ile bayt bayt AYNI (çekirdek kodu bozulmamış)")
        else:
            diff = sum(1 for a, b in zip(vml, dec) if a != b) + abs(len(vml) - dtb_at)
            errors.append(f"vmlinux ImageBuilder'dakinden {diff} baytta farklı: çekirdek kodu yamalanmış!")

    with tempfile.NamedTemporaryFile(suffix=".dtb", delete=False) as t:
        t.write(dec[dtb_at:])
    fw = fdtget(t.name, PARTS + "/partition@20000", "reg")
    art = fdtget(t.name, PARTS + f"/partition@{ART_OFS:x}", "reg")
    old_art = fdtget(t.name, PARTS + "/partition@7f0000", "reg")
    os.unlink(t.name)
    print(f"DTB firmware: {fw}")
    print(f"DTB art     : {art if art else old_art}")
    if fw != ["20000", f"{FW_MAX:x}"]:
        errors.append("DTB firmware bölümü 32 MB değil")
    if art != [f"{ART_OFS:x}", "10000"]:
        errors.append("DTB art bölümü 0x1ff0000'da değil: Wi-Fi kalibrasyonu yanlış yerden okunur!")

    sq = d.find(b"hsqs", rofs)
    sq_size, = struct.unpack("<Q", d[sq + 40:sq + 48])
    rootfs_end = FLASH_FW_START + sq + sq_size
    data_start = (rootfs_end + 0xFFFF) & ~0xFFFF
    overlay = ART_OFS - data_start
    print(f"rootfs      : squashfs {sq_size / 2**20:.2f} MB, flash'ta {rootfs_end:#x}'e kadar")
    print(f"/overlay    : ~{overlay / 2**20:.2f} MB ({data_start:#x} - {ART_OFS:#x})")

    if errors:
        print("\nHATALAR:")
        for e in errors:
            print("  - " + e)
        sys.exit(1)
    print("\nTAMAM: imaj 32 MB düzenine uygun.")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(*sys.argv[1:])
