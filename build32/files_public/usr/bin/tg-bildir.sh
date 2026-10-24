#!/bin/sh
# Telegram bildirimi (kuyruklu), listedeki tüm kişi/gruplara (tg-gonder.sh ALL). Ayar boşsa sessizce çıkar.
#   tg-bildir.sh "mesaj"   -> kuyruğa ekle ve göndermeyi dene
#   tg-bildir.sh           -> yalnızca bekleyen kuyruğu göndermeyi dene (bekçi her turda çağırır)
# Kuyruk /tmp'de (en fazla 20 olay). İnternet yokken birikir, gelince tek mesajda gönderilir.
# Aynı olay metni 30 dk içinde tekrar gelirse eklenmez (flood önleme).

Q=/tmp/tg-kuyruk; SEEN=/tmp/tg-gorulen
T=$(uci -q get huawei.modem.telegram_bot_token)
C=$(uci -q get huawei.modem.telegram_chat_id)
[ -n "$T" ] && [ -n "$C" ] || exit 0

now=$(cut -d. -f1 /proc/uptime)
if [ -n "$1" ]; then
	key=$(echo "$1" | md5sum | cut -c1-12)
	last=$(sed -n "s/^$key //p" $SEEN 2>/dev/null | tail -n1)
	if [ -n "$last" ] && [ $((now - last)) -lt 1800 ]; then exit 0; fi
	{ grep -v "^$key " $SEEN 2>/dev/null; echo "$key $now"; } | tail -n 50 > $SEEN.t && mv $SEEN.t $SEEN
	# Saat henüz eşitlenmediyse (açılış) tarih yazma
	if [ "$(date +%Y)" -ge 2025 ]; then ts="$(date '+%d.%m %H:%M') "; else ts=""; fi
	echo "$ts$1" >> $Q
	tail -n 20 $Q > $Q.t && mv $Q.t $Q
fi
[ -s $Q ] || exit 0

mkdir /tmp/tg-kilit 2>/dev/null || exit 0
trap 'rmdir /tmp/tg-kilit 2>/dev/null' EXIT INT TERM

H=$(uci -q get system.@system[0].hostname)
# Listedeki herkese (kişiler arası 1 sn); en az birine ulaştıysa kuyruk boşalır
if /usr/bin/tg-gonder.sh ALL "📡 ${H}
$(cat $Q)"; then
	: > $Q
fi
exit 0
