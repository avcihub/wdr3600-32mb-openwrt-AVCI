#!/usr/bin/env python3
"""TL-WDR3600 v1 DTB'sini 32 MB flash düzenine göre yamalar.

Kör bayt araması yapmaz: DTB'yi dtc ile metne açar, yalnızca
flash@0/partitions altındaki iki bölümü değiştirir, yeniden derler ve
sonucu fdtget ile tam düğüm yolundan doğrular.

  firmware: 0x20000 + 0x7d0000   ->  0x20000 + 0x1fd0000
  art:      0x7f0000 + 0x10000   ->  0x1ff0000 + 0x10000   (Wi-Fi kalibrasyonu)

Kullanım: patch_dtb.py <giriş.dtb> <çıkış.dtb>
"""
import re
import subprocess
import sys

FLASH = "/ahb/spi@1f000000/flash@0"
PARTS = FLASH + "/partitions"

FW_SIZE = 0x1FD0000   # 32 MB - 128 KB (u-boot/breed) - 64 KB (art)
ART_OFS = 0x1FF0000   # çipin son 64 KB'ı


def run(*cmd, data=None):
    return subprocess.run(cmd, input=data, capture_output=True, check=True).stdout


def fdtget(dtb, node, prop):
    return run("fdtget", "-t", "x", dtb, node, prop).decode().split()


def replace_once(text, old, new):
    n = text.count(old)
    if n != 1:
        sys.exit(f"HATA: '{old.strip()}' DTS içinde {n} kez bulundu (1 bekleniyordu)")
    return text.replace(old, new)


def main(src, dst):
    # Giriş stok DTB olmalı; yamalı bir DTB'yi tekrar yamamayı reddet.
    if fdtget(src, PARTS + "/partition@20000", "reg") != ["20000", "7d0000"]:
        sys.exit("HATA: giriş DTB stok 8 MB düzeninde değil (firmware reg beklenmiyor)")
    if fdtget(src, PARTS + "/partition@7f0000", "reg") != ["7f0000", "10000"]:
        sys.exit("HATA: giriş DTB'de art@7f0000 yok")

    dts = run("dtc", "-q", "-I", "dtb", "-O", "dts", src).decode()

    dts = replace_once(dts, "reg = <0x20000 0x7d0000>;", f"reg = <0x20000 {FW_SIZE:#x}>;")
    dts = replace_once(dts, "partition@7f0000 {", f"partition@{ART_OFS:x} {{")
    dts = replace_once(dts, "reg = <0x7f0000 0x10000>;", f"reg = <{ART_OFS:#x} 0x10000>;")
    # Linux yeniden başlarken çipi 3-byte adres moduna geri alsın (warm reboot güvenliği).
    dts, n = re.subn(r'(flash@0 \{\n(\s*)compatible = "jedec,spi-nor";\n)',
                     r'\1\2broken-flash-reset;\n', dts)
    if n != 1:
        sys.exit("HATA: flash@0 düğümü bulunamadı")

    open(dst, "wb").write(run("dtc", "-q", "-I", "dts", "-O", "dtb", "-o", "-", "-", data=dts.encode()))

    # Doğrulama: tam düğüm yolları üzerinden
    fw = fdtget(dst, PARTS + "/partition@20000", "reg")
    art = fdtget(dst, PARTS + f"/partition@{ART_OFS:x}", "reg")
    assert fw == ["20000", f"{FW_SIZE:x}"], fw
    assert art == [f"{ART_OFS:x}", "10000"], art
    # Wi-Fi kalibrasyon hücreleri art bölümünün içinde kalmalı ve phandle'lar korunmalı
    for cell in ("cal@1000", "cal@5000"):
        node = PARTS + f"/partition@{ART_OFS:x}/{cell}"
        assert fdtget(src, PARTS + f"/partition@7f0000/{cell}", "phandle") == fdtget(dst, node, "phandle")
    # Eski art düğümü kalmamalı
    if subprocess.run(["fdtget", dst, PARTS + "/partition@7f0000", "reg"], capture_output=True).returncode == 0:
        sys.exit("HATA: eski art@7f0000 düğümü hâlâ duruyor")

    print(f"DTB yamalandı: firmware=0x20000+{FW_SIZE:#x}, art={ART_OFS:#x}+0x10000, broken-flash-reset eklendi")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
