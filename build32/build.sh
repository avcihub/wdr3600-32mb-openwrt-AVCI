#!/usr/bin/env bash
# TL-WDR3600 v1 / 32 MB flash için temiz ve tekrarlanabilir OpenWrt 23.05.5 derlemesi.
#
# Her çalıştırmada ImageBuilder sıfırdan açılır, yamalar tek tek uygulanır ve
# doğrulanır. Elle değiştirilmiş eski bir ImageBuilder klasörü kullanılmaz.
#
# Kullanım (WSL/Ubuntu):   bash build32/build.sh
# Ayarlanabilir:           WORK=~/wdr3600-32m  FILES_DIR=...  OUT=...  PACKAGES_FILE=...
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

VER=23.05.5
IB_NAME="openwrt-imagebuilder-${VER}-ath79-generic.Linux-x86_64"
IB_URL="https://downloads.openwrt.org/releases/${VER}/targets/ath79/generic"
PROFILE=tplink_tl-wdr3600-v1
DTS_NAME=ar9344_tplink_tl-wdr3600-v1

# OpenWrt 23.05.5'in tools/firmware-utils sürümü (mktplinkfw buradan derlenir)
FWU_COMMIT=f3b636d0ee478ee8d757cb42d469e0a40d07627a
FWU_URL="https://raw.githubusercontent.com/openwrt/firmware-utils/${FWU_COMMIT}/src"
FWU_SHA256="
eaa3be955cfb42702fd804f5ecc3ebea4dd23878b57ab63b343822dc273a5655  md5.c
2f7fd79f1a8ec20e8f7febccbc445eddc25a654f4d6503f289561178e5aea781  md5.h
3f519b4abe7a9d43c9579aad48d0816d667da1cf84c0f775d149cc5ecf9fe78e  mktplinkfw-lib.c
4d8df01aae5f629ca1112dfacbfda5a494439f6c218b452141236b518cc105fa  mktplinkfw-lib.h
f85bc4114937a90e027038c95cd573bd6841fc5e81d5db4fe211088eff12f482  mktplinkfw.c
"

# Linux dosya sisteminde çalış (/mnt/f altında ImageBuilder yavaş ve izinler bozuk olur)
WORK="${WORK:-$HOME/build_wdr3600_32m}"
FILES_DIR="${FILES_DIR:-$HERE/files_public}"
OUT="${OUT:-$HERE/out}"
PACKAGES_FILE="${PACKAGES_FILE:-$HERE/packages.txt}"

# WSL, Windows PATH'ini (boşluklu) ekler; ImageBuilder bununla bozulur.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nHATA: %s\n' "$*" >&2; exit 1; }

step "0/8 Gerekli araçlar"
missing=()
for c in make gcc patch curl tar xz python3 dtc fdtget sha256sum rsync gawk unzip; do
	command -v "$c" >/dev/null || missing+=("$c")
done
[ ${#missing[@]} -eq 0 ] || die "eksik: ${missing[*]}
  sudo apt install build-essential libncurses-dev zlib1g-dev gawk git gettext libssl-dev xsltproc rsync wget unzip python3 file device-tree-compiler patch curl xz-utils"
[ -d "$FILES_DIR" ] || die "FILES_DIR yok: $FILES_DIR"
mkdir -p "$WORK/dl" "$OUT"

step "1/8 ImageBuilder indir ve sha256 doğrula"
cd "$WORK/dl"
curl -fsSL -o sha256sums "$IB_URL/sha256sums"
[ -f "$IB_NAME.tar.xz" ] || curl -fL -o "$IB_NAME.tar.xz" "$IB_URL/$IB_NAME.tar.xz"
grep " \*\?$IB_NAME.tar.xz\$" sha256sums | sed 's/ \*/  /' | sha256sum -c - || die "ImageBuilder sha256 tutmuyor (dosyayı silip tekrar dene)"

step "2/8 ImageBuilder'ı sıfırdan aç"
IB="$WORK/$IB_NAME"
rm -rf "$IB"
tar -C "$WORK" -xJf "$WORK/dl/$IB_NAME.tar.xz"
KDIR="$IB/build_dir/target-mips_24kc_musl/linux-ath79_generic"
DTB="$KDIR/image-$DTS_NAME.dtb"
KERNEL="$KDIR/$PROFILE-kernel.bin"
LZMA="$IB/staging_dir/host/bin/lzma"
for f in "$KDIR/vmlinux" "$DTB" "$KERNEL" "$LZMA"; do [ -f "$f" ] || die "ImageBuilder'da yok: $f"; done

step "3/8 Çekirdek tarifini doğrula (vmlinux + DTB | lzma == hazır kernel.bin)"
# ImageBuilder çekirdeği derlemez, hazır kernel.bin'i kullanır. Aynı tarifle stok
# kernel.bin'i bayt bayt üretebiliyorsak, yamalı DTB ile ürettiğimiz de güvenilirdir.
cat "$KDIR/vmlinux" "$DTB" > "$WORK/kernel.stock"
"$LZMA" e "$WORK/kernel.stock" -lc1 -lp2 -pb2 "$WORK/kernel.stock.lzma" >/dev/null
cmp -s "$WORK/kernel.stock.lzma" "$KERNEL" || die "stok kernel.bin yeniden üretilemedi; tarif farklı, devam etmek güvenli değil"
echo "stok kernel.bin bayt bayt yeniden üretildi"

step "4/8 DTB'yi 32 MB düzenine yamala ve kernel.bin'i yeniden üret"
python3 -I "$HERE/patch_dtb.py" "$DTB" "$WORK/$DTS_NAME-32m.dtb"
cp "$WORK/$DTS_NAME-32m.dtb" "$DTB"
cat "$KDIR/vmlinux" "$DTB" > "$WORK/kernel.32m"
"$LZMA" e "$WORK/kernel.32m" -lc1 -lp2 -pb2 "$KERNEL" >/dev/null
echo "kernel.bin: $(stat -c %s "$KERNEL") bayt"

step "5/8 mktplinkfw'yi 32Mlzma düzeniyle kaynaktan derle"
FWU="$WORK/firmware-utils"
rm -rf "$FWU"; mkdir -p "$FWU/src"
for f in md5.c md5.h mktplinkfw-lib.c mktplinkfw-lib.h mktplinkfw.c; do
	curl -fsSL -o "$FWU/src/$f" "$FWU_URL/$f"
done
(cd "$FWU/src" && echo "$FWU_SHA256" | sed '/^$/d' | sha256sum -c --quiet -) || die "firmware-utils kaynak sha256 tutmuyor"
patch -d "$FWU" -p1 < "$HERE/mktplinkfw-32Mlzma.patch"
gcc -O2 -fgnu89-inline -w -o "$FWU/mktplinkfw" "$FWU/src/mktplinkfw.c" "$FWU/src/mktplinkfw-lib.c" "$FWU/src/md5.c"
cp "$FWU/mktplinkfw" "$IB/staging_dir/host/bin/mktplinkfw"

step "6/8 Cihaz tanımını 32 MB yap (yalnızca tplink_tl-wdr3600-v1)"
python3 -I - "$IB/target/linux/ath79/image/generic-tp-link.mk" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
old = "define Device/tplink_tl-wdr3600-v1\n  $(Device/tplink-8mlzma)\n"
new = old + "  TPLINK_FLASHLAYOUT := 32Mlzma\n  IMAGE_SIZE := 32576k\n"
assert t.count(old) == 1, "wdr3600 cihaz tanımı bulunamadı"
open(p, "w").write(t.replace(old, new))
print("generic-tp-link.mk: TPLINK_FLASHLAYOUT := 32Mlzma, IMAGE_SIZE := 32576k")
PY

step "7/8 make image"
PACKAGES="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PACKAGES_FILE" | tr '\n' ' ')"
# FILES_DIR Windows/NTFS'ten gelirse her şey 777 olur: Linux tarafında temiz izinlerle kopyala
FILES_STAGE="$WORK/files"
rm -rf "$FILES_STAGE"
rsync -a --no-owner --no-group --chmod=D755,F644 "$FILES_DIR"/ "$FILES_STAGE"/
find "$FILES_STAGE" -type f -exec sed -i 's/\r$//' {} +
for d in etc/init.d etc/uci-defaults usr/bin usr/sbin etc/hotplug.d; do
	[ -d "$FILES_STAGE/$d" ] && find "$FILES_STAGE/$d" -type f -exec chmod 755 {} +
done
for f in etc/config/zerotier etc/config/huawei etc/shadow; do
	[ -f "$FILES_STAGE/$f" ] && chmod 600 "$FILES_STAGE/$f"
done
make -C "$IB" image PROFILE="$PROFILE" PACKAGES="$PACKAGES" FILES="$FILES_STAGE" 2>&1 | tee "$WORK/make.log"
BIN="$IB/bin/targets/ath79/generic"
SYSUP="$BIN/openwrt-$VER-ath79-generic-$PROFILE-squashfs-sysupgrade.bin"
FACTORY="$BIN/openwrt-$VER-ath79-generic-$PROFILE-squashfs-factory.bin"
# ImageBuilder mktplinkfw hatasını yutar ('-' öneki); imaj yoksa sebep log'dadır.
if [ ! -f "$SYSUP" ]; then
	grep -n -i "too big\|error\|cannot\|unknown package" "$WORK/make.log" | tail -20 >&2 || true
	die "sysupgrade imajı oluşmadı (log: $WORK/make.log)"
fi

step "8/8 İmajı doğrula ve kopyala"
python3 -I "$HERE/verify_image.py" "$SYSUP" "$KDIR/vmlinux"
cp "$SYSUP" "$FACTORY" "$BIN/"*.manifest "$OUT/" 2>/dev/null || cp "$SYSUP" "$OUT/"
(cd "$OUT" && sha256sum *.bin > sha256sums)
echo; echo "Çıktılar: $OUT"; cat "$OUT/sha256sums"
