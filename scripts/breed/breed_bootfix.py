# Breed açılış düzeltmesi: Breed'in kendi ortam değişkeni alanını (Breed iç, 0x1e000 + 0x1000)
# açar ve autoboot.command = "flash dump 0x20000 16; autoboot" yapar. Böylece Breed açılışta
# çipi 3 bayt moduna döndürüp firmware'i öyle açar.
# Flash'a yalnızca Breed'in kendisi yazar (envconf + env save). Firmware/ART/MAC'e dokunulmaz.
# breed_bootfix.bat (yönetici) çalıştırır; Ethernet 192.168.1.2 olmalı.
import http.client
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "breed_bootfix_log.txt")
BREED_IP = "192.168.1.1"
PC_IP = "192.168.1.2"
KEY = "autoboot.command"
VALUE = "flash dump 0x20000 16; autoboot"
SAFE_BOOT = b"flash dump 0x20000 16; autoboot\r\n"   # elle doğrulandı (breed_boottest)

logf = open(LOG, "a", encoding="utf-8")
tn = None


def log(msg=""):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    logf.write(line + "\n")
    logf.flush()


def connect(wait=1200):
    global tn
    deadline = time.time() + wait
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
        log("HATA: Breed telnet'e bağlanılamadı")
        sys.exit(1)
    time.sleep(1.0)
    tn.sendall(b"\r\n")
    read_until_prompt(10)
    time.sleep(1.5)
    tn.settimeout(0.5)
    try:
        while tn.recv(4096):
            pass
    except socket.timeout:
        pass
    log("Breed telnet bağlandı")


def read_until_prompt(timeout, echo=None):
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


def cmd(c, timeout=20):
    tn.sendall(c.encode() + b"\r\n")
    out, ok = read_until_prompt(timeout, echo=c.encode())
    log(f"breed> {c}\n{out}" + ("" if ok else "\n(istem gelmedi)"))
    return out


def boot_and_exit(rc, line=SAFE_BOOT):
    log(f"açılış: {line.decode().strip()}")
    tn.sendall(line)
    out = b""
    end = time.time() + 40
    tn.settimeout(1.0)
    while time.time() < end:
        try:
            chunk = tn.recv(4096)
        except (socket.timeout, OSError):
            continue
        if not chunk:
            break
        out += chunk
    log("çıktı:\n" + out.decode("ascii", "replace"))
    tn.close()
    log("BOOTFIX BITTI" if rc == 0 else "BOOTFIX HATA")
    sys.exit(rc)


def env_value():
    out = cmd(f"env get {KEY}")
    lines = [l.strip() for l in out.splitlines()]
    lines = [l for l in lines if l and not l.startswith("env get") and not l.startswith("breed>")]
    return lines[0] if lines else ""


log("=" * 60)
log("Breed açılış düzeltmesi")
log(f"Breed telnet {BREED_IP}:23 bekleniyor (router'ı kapatıp açın, reset gerekmez)...")
connect()
cmd("abstatus")
listing = cmd("env list")

if "not available" in listing:
    cmd("envconf")
    log("Ortam değişkenleri kapalı -> web arayüzünden açılıyor (Breed iç, 0x1e000 + 0x1000)")
    boundary = "----wdr3600bootfix"
    fields = {"control": "1", "position": "breed", "offset": "0x1e000", "size": "0x1000", "submit": "Modify"}
    body = "".join(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n' for k, v in fields.items())
    body += f"--{boundary}--\r\n"
    conn = http.client.HTTPConnection(BREED_IP, 80, timeout=15, source_address=(PC_IP, 0))
    conn.request("POST", "/envconf.html", body.encode(),
                 {"Content-Type": f"multipart/form-data; boundary={boundary}"})
    r = conn.getresponse()
    page = r.read().decode("utf-8", "replace")
    open(os.path.join(HERE, "breed_bootfix_envconf_resp.html"), "w", encoding="utf-8").write(page)
    ok = r.status == 200 and 'var enabled = "1"' in page and 'var success = "1"' in page
    log(f"envconf POST: HTTP {r.status}, enabled=1/success=1: {ok}")
    if not ok:
        log("HATA: Breed ortam değişkeni açılamadı, hiçbir şey değişmedi")
        boot_and_exit(1)
    # Ayar yeniden başlatınca geçerli. Yeniden başlatmadan önce çipi 3 bayt moduna al,
    # yoksa işlemci Breed'i flash'tan okuyamaz.
    cmd("flash dump 0x20000 16")
    log("Breed yeniden başlatılıyor (reset)")
    tn.sendall(b"reset\r\n")
    time.sleep(2)
    tn.close()
    tn = None
    time.sleep(5)
    connect(wait=180)
    listing = cmd("env list")
    if "not available" in listing:
        log("HATA: reset sonrası ortam değişkenleri hâlâ kapalı")
        boot_and_exit(1)

cmd("flash dump 0x1e000 64")
cmd(f'env set {KEY} "{VALUE}"')
got = env_value()
if got != VALUE and not got.endswith(f"= {VALUE}") and not got.endswith(f": {VALUE}"):
    log(f"HATA: değer beklenen gibi değil: {got!r}; geri alınıyor")
    cmd(f"env unset {KEY}")
    boot_and_exit(1)
cmd("env save", timeout=30)
cmd("env list")
cmd("flash dump 0x1e000 64")
cmd("flash dump 0x1fc00 16")
log(f"{KEY} kaydedildi: {VALUE!r}. Şimdi aynı komutla açılış deneniyor.")
# Değeri elle çalıştır: 'boot' yanlışsa çıktıda görünür, sonra güvenli açılış yapılır.
tn.sendall(VALUE.encode() + b"\r\n")
out, ok = read_until_prompt(40, echo=VALUE.encode())
log("çıktı:\n" + out)
if ok:
    log("UYARI: 'boot' Breed'de kaldı (yukarıdaki çıktıya bak); güvenli açılış yapılıyor")
    boot_and_exit(2)
tn.close()
log("BOOTFIX BITTI")
