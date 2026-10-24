#!/bin/sh
# Uzak erişim bekçisi: cron ile 5 dakikada bir çalışır (fiziksel erişim olmayan kurulum için).
#  * İnternet (1.1.1.1 / 8.8.8.8 / 9.9.9.9) yoksa: 15 dk -> ifup wan, 20 dk -> network restart.
#    Sıralama: 5 dk Huawei watchdog modemi yeniden başlatır (10 dk arayla), 15/20 dk bu betik,
#    30 dk watchcat router'ı reboot eder (internet kesintisi reboot'u yalnızca watchcat'te).
#  * İnternet varken Tailscale veya ZeroTier takılmışsa 10 dk sonra o servisi yeniden başlatır;
#    ikisi birden 30 dk ulaşılamazsa reboot.
#  * Reboot döngüsü koruması: yalnızca uptime yeterliyse reboot eder; her bekçi reboot'unda
#    gereken süre ikiye katlanır (30 dk, 1 sa, 2 sa, 4 sa, en fazla 6 sa). Tailscale veya
#    ZeroTier'den biri çalışınca sıfırlanır.
#  * Olaylar Telegram'a bildirilir (tg-bildir.sh; huawei.modem telegram ayarı boşsa sessizce atlanır):
#    açılış + nedeni, internet geri geldi, Tailscale/ZeroTier yeniden başlatıldı, bekçi reboot.
# Kapatmak için: /etc/crontabs/root içindeki uzak-bekci satırını silin, /etc/init.d/cron restart.

S=/tmp/bekci; mkdir -p $S
C=/etc/bekci.count      # reboot sayacı (yalnızca reboot ederken ve sıfırlarken yazılır)
LOG=/tmp/bekci.log

log() {
	logger -t uzak-bekci "$*"
	echo "$(date '+%m-%d %H:%M') $*" >> $LOG
	[ "$(wc -l < $LOG)" -gt 300 ] && tail -n 150 $LOG > $LOG.t && mv $LOG.t $LOG
}
get() { cat "$S/$1" 2>/dev/null || echo 0; }
put() { echo "$2" > "$S/$1"; }
inc() { put "$1" $(( $(get "$1") + 1 )); }
tg() { /usr/bin/tg-bildir.sh "$*" >/dev/null 2>&1; }

up_min=$(( $(cut -d. -f1 /proc/uptime) / 60 ))
rcount=$(cat $C 2>/dev/null || echo 0)

safe_reboot() {
	need=$(( 30 << rcount )); [ $need -gt 360 ] && need=360
	if [ $up_min -lt $need ]; then
		log "reboot gerekli ($1) ama uptime ${up_min} dk < ${need} dk, bekleniyor"
		return
	fi
	echo $(( rcount + 1 )) > $C
	log "REBOOT: $1 (bekçi reboot no $(( rcount + 1 )))"
	/usr/bin/bekci-reboot.sh "bekçi: $1 (bekçi reboot no $(( rcount + 1 )))"
	exit 0
}

# Açılış bildirimi (her açılışta bir kez). Neden bekci-reboot.sh tarafından flash'a yazılır;
# yoksa reboot beklenmedik: elektrik kesintisi veya donanım watchdog'u.
if [ ! -f /tmp/tg-acilis ]; then
	touch /tmp/tg-acilis
	neden=$(cat /etc/son-reboot-nedeni 2>/dev/null)
	[ -n "$neden" ] && rm -f /etc/son-reboot-nedeni || neden="beklenmedik (elektrik kesintisi veya donanım watchdog)"
	tg "🔌 Router açıldı ($(awk '{printf "%d dk", $1/60}' /proc/uptime) önce). Neden: $neden"
fi
tg   # bekleyen bildirimleri her turda dene (açılış mesajı 10 dk beklemesin)

# Açılıştan sonraki ilk 10 dk karışma (servisler ayağa kalkıyor)
[ $up_min -lt 10 ] && exit 0

net_ok=0
for h in 1.1.1.1 8.8.8.8 9.9.9.9; do
	ping -c 1 -W 3 $h >/dev/null 2>&1 && { net_ok=1; break; }
done

if [ $net_ok = 0 ]; then
	inc net; n=$(get net)
	case $n in
		3) log "internet yok (15 dk): ifup wan"; ifup wan ;;
		4) log "internet yok (20 dk): network restart"; /etc/init.d/network restart ;;
	esac
	exit 0
fi

if [ "$(get net)" -ge 2 ]; then
	dk=$(( $(get net) * 5 ))
	log "internet geri geldi (~$dk dk)"
	modem=""
	lr=$(cat /tmp/huawei_last_reboot 2>/dev/null)
	[ -n "$lr" ] && [ $(( $(cut -d. -f1 /proc/uptime) - lr )) -lt $(( dk * 60 + 300 )) ] && modem=" (4G modem yeniden başlatıldı)"
	tg "🌐 İnternet ~$dk dk yoktu, geri geldi$modem"
fi
put net 0
tg   # bekleyen bildirimleri gönder
# eWeLink anahtarını süresi dolmadan yenile (bağlıysa; 3 günden az kaldıysa)
[ -n "$(uci -q get ewelink.main.access_token)" ] && /usr/bin/ewelink.sh refresh >/dev/null 2>&1

# Tailscale (yapılandırılmışsa: durum dosyası varsa veya backend çalışıyorsa)
ts_ok=0
ts_configured=0
[ -s /etc/tailscale/tailscaled.state ] && ts_configured=1
if pidof tailscaled >/dev/null; then
	ts_state=$(tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' 2>/dev/null)
	[ "$ts_state" = "Running" ] && { ts_ok=1; ts_configured=1; }
fi
if [ $ts_configured = 1 ]; then
	if [ $ts_ok = 1 ]; then put ts 0; else
		inc ts; [ $(( $(get ts) % 6 )) = 2 ] && { log "Tailscale çalışmıyor (10 dk): yeniden başlatılıyor"; /etc/init.d/tailscale restart; tg "🔁 Tailscale çalışmıyordu, yeniden başlatıldı"; }
	fi
fi

# ZeroTier (yapılandırılmışsa)
zt_ok=0
zt_configured=0
if [ "$(uci -q get zerotier.global.enabled)" = 1 ]; then
	zt_configured=1
	zerotier-cli info 2>/dev/null | grep -q ONLINE && zt_ok=1
	if [ $zt_ok = 1 ]; then put zt 0; else
		inc zt; [ $(( $(get zt) % 6 )) = 2 ] && { log "ZeroTier çalışmıyor (10 dk): yeniden başlatılıyor"; /etc/init.d/zerotier restart; tg "🔁 ZeroTier çalışmıyordu, yeniden başlatıldı"; }
	fi
fi

# Yapılandırılmış tünellerden hiçbiri çalışmıyorsa (internet varken) 30 dk sonra reboot
tunnel_configured=0
tunnel_working=0
[ $ts_configured = 1 ] && { tunnel_configured=1; [ $ts_ok = 1 ] && tunnel_working=1; }
[ $zt_configured = 1 ] && { tunnel_configured=1; [ $zt_ok = 1 ] && tunnel_working=1; }

if [ $tunnel_configured = 1 ] && [ $tunnel_working = 0 ]; then
	inc both; [ "$(get both)" -ge 6 ] && safe_reboot "Uzak erişim tünelleri (TS/ZT) 30 dk ulaşılamaz"
else
	put both 0
	# En az bir uzak erişim yolu çalışıyor: reboot geri sayımını sıfırla
	[ "$rcount" != 0 ] && echo 0 > $C
fi
exit 0
