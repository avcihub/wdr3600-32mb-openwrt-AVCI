# Breed telnet ile temiz 32 MB OpenWrt imajını yazar (imaj ve art.bin bu klasörde ya da argüman olarak).
# breed_flash_clean.bat (yönetici) çalıştırır; Ethernet 192.168.1.2 olmalı.
# 0x0-0x20000 (Breed) bölgesine ASLA dokunmaz. ART yalnızca farklıysa yazılır.
import glob
import http.server
import os
import re
import socket
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LOG = os.path.join(HERE, "breed_flash_log.txt")

BREED_IP = "192.168.1.1"
PC_IP = "192.168.1.2"
HTTP_PORT = 8000

FW_START, FW_LEN = 0x20000, 0x1fd0000
ART_START, ART_LEN = 0x1ff0000, 0x10000
RAM = 0x80000000

# Kullanım: breed_flash_clean.py [sysupgrade.bin] [art.bin]
# Verilmezse bu klasördeki tek *sysupgrade*.bin ve art.bin (cihazın KENDİ ART yedeği) kullanılır.
fw_list = sys.argv[1:2] or glob.glob(os.path.join(HERE, "*sysupgrade*.bin"))
FW_PATH = fw_list[0] if len(fw_list) == 1 else None
ART_PATH = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "art.bin")

logf = open(LOG, "a", encoding="utf-8")


def log(msg=""):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    logf.write(line + "\n")
    logf.flush()


def die(msg):
    log(f"HATA: {msg}")
    log("Flash'a yazılmadıysa router Breed'de kalır; tekrar denemek güvenlidir.")
    sys.exit(1)


log("=" * 60)
log("WDR3600 32 MB temiz imaj - Breed telnet flash")
if not FW_PATH:
    die(f"tek bir sysupgrade.bin bulunamadı (bu klasöre koyun ya da argüman verin): {fw_list}")
fw = open(FW_PATH, "rb").read()
art = open(ART_PATH, "rb").read()
fw_size = len(fw)
log(f"Imaj: {os.path.basename(FW_PATH)} ({fw_size} bayt)")
if fw_size > FW_LEN:
    die("imaj firmware bölümünden büyük")
if fw[4:11] != b"OpenWrt" or fw[0x40:0x44] != bytes.fromhex("36000001"):
    die("imaj başlığı beklenen TP-Link/WDR3600 başlığı değil")
if len(art) != ART_LEN:
    die("art_original.bin 64 KB değil")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = {"/firmware.bin": fw, "/art.bin": art}.get(self.path)
        if data is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        log(f"[HTTP] {self.path} gönderildi ({len(data)} bayt)")

    def log_message(self, *args):
        pass


try:
    httpd = http.server.HTTPServer((PC_IP, HTTP_PORT), Handler)
except OSError as e:
    die(f"HTTP sunucu {PC_IP}:{HTTP_PORT} açılamadı ({e}). Ethernet IP 192.168.1.2 mi?")
threading.Thread(target=httpd.serve_forever, daemon=True).start()
log(f"HTTP sunucu {PC_IP}:{HTTP_PORT} hazır")

# Breed telnet bekle (en fazla 20 dk)
log(f"Breed telnet {BREED_IP}:23 bekleniyor (router'ı WPS/Reset basılı açın)...")
tn = None
deadline = time.time() + 1200
while time.time() < deadline:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind((PC_IP, 0))
        s.settimeout(1.0)
        s.connect((BREED_IP, 23))
        tn = s
        break
    except OSError:
        s.close()
        time.sleep(0.5)
if tn is None:
    die("20 dakikada Breed telnet'e bağlanılamadı")
log("Breed telnet bağlandı")


def read_until_prompt(timeout, echo=None):
    # echo verilirse istem ancak komutun yankısından sonra gelirse kabul edilir
    out = b""
    end = time.time() + timeout
    tn.settimeout(1.0)
    while time.time() < end:
        try:
            chunk = tn.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        out += chunk
        if out.rstrip().endswith(b"breed>") and (echo is None or echo in out):
            return out.decode("ascii", "replace"), True
    return out.decode("ascii", "replace"), False


time.sleep(1.0)
tn.sendall(b"\r\n")
banner, ok = read_until_prompt(10)
if not ok:
    die(f"breed> istemi gelmedi: {banner!r}")
# Bekleyen fazladan istemleri boşalt (Breed zaten açıksa banner + istem önceden gelir)
time.sleep(1.5)
tn.settimeout(0.5)
try:
    while tn.recv(4096):
        pass
except socket.timeout:
    pass


def cmd(c, timeout=30):
    log(f"breed> {c}")
    tn.sendall(c.encode() + b"\r\n")
    out, ok = read_until_prompt(timeout, echo=c.encode())
    for l in out.splitlines():
        l = l.strip()
        if l and l != c and not l.startswith("breed>"):
            logf.write(f"    {l}\n")
    logf.flush()
    if not ok:
        die(f"'{c}' {timeout} sn içinde bitmedi")
    return out


# flash dump bayt bayt ("01ff1000: 02 02 00 02 ..."), mem dump 32-bit kelime
# ("80000000: 01000000 4f70656e ...") yazar; ikisi de bellekteki bayt sırasıdır.
LINE_RE = re.compile(r"^\s*(?:0x)?[0-9a-fA-F]{8}:\s+(.*)$", re.M)
TOKEN_RE = re.compile(r"^(?:[0-9a-fA-F]{2}|[0-9a-fA-F]{4}|[0-9a-fA-F]{8})$")


def dump(kind, addr, n=16):
    for _ in range(3):
        out = cmd(f"{kind} dump {hex(addr)} {n}")
        data = b""
        for m in LINE_RE.finditer(out):
            for tok in m.group(1).replace("-", " ").split():
                if not TOKEN_RE.match(tok):
                    break
                data += bytes.fromhex(tok)
        if len(data) >= n:
            return data[:n]
        log("dump çözümlenemedi, tekrar deneniyor")
    die(f"{kind} dump {hex(addr)} çözümlenemedi: {out!r}")


def spot_offsets(size):
    offs = {0, 0x40, 0x200, size // 4, size // 2, (3 * size) // 4, size - 16}
    return sorted(o & ~0xF for o in offs)


# 1) ART kontrolü (salt okuma)
log("[1/6] ART kontrolü (0x1ff0000)")
art_ok = all(dump("flash", ART_START + o) == art[o:o + 16] for o in (0x0, 0x1000, 0x1010, 0x5000, 0x5010))
log("ART flash'taki ile art_original.bin AYNI" if art_ok else "ART FARKLI -> yazılacak")

# 2) İmajı RAM'e al ve doğrula
log("[2/6] Imaj RAM'e indiriliyor")
cmd(f"wget http://{PC_IP}:{HTTP_PORT}/firmware.bin {hex(RAM)}", timeout=120)
for o in spot_offsets(fw_size):
    if dump("mem", RAM + o) != fw[o:o + 16]:
        die(f"RAM'deki imaj dosyadan farklı (offset {hex(o)}). Windows Güvenlik Duvarı HTTP'yi engellemiş olabilir.")
log("RAM'deki imaj doğrulandı (başlık OpenWrt, HWID 36000001)")

# 3) Firmware bölümünü sil (0x20000 + 0x1fd0000, ART'a ve Breed'e dokunmaz)
log("[3/6] flash erase 0x20000 0x1fd0000 (birkaç dakika sürebilir)")
cmd(f"flash erase {hex(FW_START)} {hex(FW_LEN)}", timeout=900)

# 4) Yaz ve geri oku
log("[4/6] flash write")
cmd(f"flash write {hex(FW_START)} {hex(RAM)} {hex(fw_size)}", timeout=900)
for o in spot_offsets(fw_size):
    if dump("flash", FW_START + o) != fw[o:o + 16]:
        die(f"flash geri okuma farklı (offset {hex(o)})")
log("Flash geri okuma doğrulandı")

# 5) ART yalnızca farklıysa
if art_ok:
    log("[5/6] ART zaten doğru, yazılmadı")
else:
    log("[5/6] ART yazılıyor (0x1ff0000)")
    cmd(f"wget http://{PC_IP}:{HTTP_PORT}/art.bin {hex(RAM)}", timeout=60)
    if dump("mem", RAM + 0x1000) != art[0x1000:0x1010]:
        die("ART RAM'e doğru inmedi")
    cmd(f"flash erase {hex(ART_START)} {hex(ART_LEN)}", timeout=120)
    cmd(f"flash write {hex(ART_START)} {hex(RAM)} {hex(ART_LEN)}", timeout=120)
    for o in (0x0, 0x1000, 0x1010, 0x5000, 0x5010, 0xfff0):
        if dump("flash", ART_START + o) != art[o:o + 16]:
            die(f"ART geri okuma farklı (offset {hex(o)})")
    log("ART yazıldı ve doğrulandı")

# 5b) Breed env: autoboot.command yoksa ayarla (yoksa Breed açılışta 4-byte modda takılabilir)
AB_KEY = "autoboot.command"
AB_VALUE = "flash dump 0x20000 16; autoboot"
log("[5b/6] Breed env kontrolü (autoboot.command)")
env_needs_bootfix = False
listing = cmd("env list")
if "not available" in listing:
    env_needs_bootfix = True
    log("UYARI: Breed ortam değişkenleri kapalı. Flash sonrası breed_bootfix.bat çalıştırın.")
elif AB_VALUE in listing:
    log(f"{AB_KEY} zaten var: {AB_VALUE!r}")
else:
    cmd(f'env set {AB_KEY} "{AB_VALUE}"')
    cmd("env save", timeout=30)
    if AB_VALUE not in cmd("env list"):
        env_needs_bootfix = True
        log("UYARI: autoboot.command kaydedilemedi. breed_bootfix.bat çalıştırın.")
    else:
        log(f"{AB_KEY} ayarlandı ve kaydedildi")

# 6) Boot
log("[6/6] autoboot")
tn.sendall(b"autoboot\r\n")
time.sleep(3)
tn.close()
httpd.shutdown()
log("BASARILI: imaj yazıldı, OpenWrt açılıyor (ilk açılış ~2-3 dk).")
if env_needs_bootfix:
    log("SONRAKİ ADIM: Breed env ayarı eksik -> build32/breed_bootfix.bat çalıştırın.")
    sys.exit(3)
