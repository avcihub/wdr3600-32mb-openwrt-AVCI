#!/bin/sh
# Telegram'a doğrudan gönderim.
#   tg-gonder.sh ALL "metin"      -> huawei.modem.telegram_chat_id listesindeki herkese
#   tg-gonder.sh <chat_id> "metin" -> tek kişiye/gruba (bot cevapları)
# Kişiler arasında 1 sn bekler (Telegram hız sınırı). Birine gönderim başarısız olursa diğerleri
# yine denenir. En az bir kişiye ulaştıysa 0 döner. Token ve ID'ler loglanmaz.
T=$(uci -q get huawei.modem.telegram_bot_token)
[ -n "$T" ] || exit 1
if [ "$1" = ALL ]; then
	IDS=$(uci -q get huawei.modem.telegram_chat_id | tr ',;' '  ')
else
	IDS="$1"
fi
[ -n "$IDS" ] || exit 1

ok=0; n=0
for id in $IDS; do
	[ $n -gt 0 ] && sleep 1
	n=$((n + 1))
	curl -s --connect-timeout 8 --max-time 20 -X POST "https://api.telegram.org/bot${T}/sendMessage" \
		-d "chat_id=${id}" --data-urlencode "text=$2" 2>/dev/null | grep -q '"ok":true' && ok=$((ok + 1))
done
[ $ok -gt 0 ]
