#!/bin/sh
# eWeLink (Sonoff) bulut kontrolü — CoolKit Open API v2 (dev.ewelink.cc kişisel uygulama).
# Ayarlar /etc/config/ewelink (izin 600): app_id, app_secret, region, redirect_url ve tokenlar.
# Hesap şifresi saklanmaz; OAuth ile alınan erişim/yenileme anahtarları saklanır.
#
#   ewelink.sh authurl             -> eWeLink giriş linki (tarayıcıda açılıp onaylanır)
#   ewelink.sh code <kod|URL>      -> girişten dönen kodu tokena çevir
#   ewelink.sh refresh             -> token süresi yaklaştıysa yenile (bekçi her turda çağırır)
#   ewelink.sh list                -> "deviceid<TAB>ad<TAB>online<TAB>on|off|on,off.." (60 sn önbellek)
#   ewelink.sh set <deviceid> on|off
#   ewelink.sh match "<metin>"     -> metindeki cihaz adını bulur: "deviceid<TAB>ad" (birden çoksa hepsi)
#   ewelink.sh oner "<metin>"      -> eşleşme yoksa benzer cihaz adları
#   ewelink.sh norm "<metin>"      -> Türkçe karakter/büyük harf normalize (test için)

CFG=ewelink.main
APPID=$(uci -q get $CFG.app_id)
SECRET=$(uci -q get $CFG.app_secret)
REGION=$(uci -q get $CFG.region || echo eu)
REDIRECT=$(uci -q get $CFG.redirect_url || echo "https://127.0.0.1/ewelink")
API="https://${REGION}-apia.coolkit.cc"
CACHE=/tmp/ewelink-cihazlar.tsv

now_ms() { echo "$(date +%s)000"; }
sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$SECRET" -binary | openssl base64 -A; }
need_app() { [ -n "$APPID" ] && [ -n "$SECRET" ] || { echo "HATA: eWeLink App ID / Secret girilmemiş (LuCI > Services > eWeLink)"; exit 2; }; }
need_token() { AT=$(uci -q get $CFG.access_token); [ -n "$AT" ] || { echo "HATA: eWeLink girişi yapılmamış (/ewelink_baglan)"; exit 3; }; }

save_tokens() {   # $1 = API cevabı (data.accessToken/refreshToken/atExpiredTime/rtExpiredTime)
	at=$(echo "$1" | jq -r '.data.accessToken // .data.at // empty')
	rt=$(echo "$1" | jq -r '.data.refreshToken // .data.rt // empty')
	[ -n "$at" ] && [ -n "$rt" ] || return 1
	uci set $CFG.access_token="$at"
	uci set $CFG.refresh_token="$rt"
	ate=$(echo "$1" | jq -r '.data.atExpiredTime // empty'); [ -n "$ate" ] || ate=$(( $(date +%s) + 29*86400 ))000
	uci set $CFG.at_expiry="${ate%???}"
	uci commit ewelink; chmod 600 /etc/config/ewelink
}

api_get() { curl -s --connect-timeout 8 --max-time 20 "$API$1" -H "X-CK-Appid: $APPID" -H "Authorization: Bearer $AT"; }
api_post() { curl -s --connect-timeout 8 --max-time 20 -X POST "$API$1" -H "X-CK-Appid: $APPID" \
	-H "Authorization: Bearer $AT" -H "Content-Type: application/json" -d "$2"; }

norm() {   # küçük harf, Türkçe karakterler ASCII, harf/rakam dışı -> boşluk, tek boşluk
	printf '%s' "$1" | sed -e 's/İ/i/g; s/I/ı/g' | tr 'A-Z' 'a-z' |
		sed -e 's/ı/i/g; s/ğ/g/g; s/Ğ/g/g; s/ü/u/g; s/Ü/u/g; s/ş/s/g; s/Ş/s/g; s/ö/o/g; s/Ö/o/g; s/ç/c/g; s/Ç/c/g; s/â/a/g; s/î/i/g; s/û/u/g' \
		    -e 's/[^a-z0-9]/ /g; s/  */ /g; s/^ //; s/ $//'
}

case "$1" in
authurl)
	need_app
	seq=$(now_ms)
	auth=$(sign "${APPID}_${seq}")
	enc() { printf '%s' "$1" | jq -sRr @uri; }
	echo "https://c2ccdn.coolkit.cc/oauth/index.html?clientId=${APPID}&seq=${seq}&authorization=$(enc "$auth")&redirectUrl=$(enc "$REDIRECT")&grantType=authorization_code&state=wdr3600&nonce=$(head -c 6 /dev/urandom | md5sum | cut -c1-8)&showQRCode=false"
	;;
code)
	need_app
	c="$2"
	case "$c" in *code=*) r=$(echo "$c" | sed -n 's/.*[?&]region=\([a-z]*\).*/\1/p'); c=$(echo "$c" | sed 's/.*[?&]code=\([^&]*\).*/\1/');
		[ -n "$r" ] && { uci set $CFG.region="$r"; uci commit ewelink; REGION=$r; API="https://${REGION}-apia.coolkit.cc"; } ;; esac
	[ -n "$c" ] || { echo "HATA: kod yok"; exit 1; }
	body=$(jq -nc --arg c "$c" --arg r "$REDIRECT" '{code:$c, redirectUrl:$r, grantType:"authorization_code"}')
	res=$(curl -s --connect-timeout 8 --max-time 20 -X POST "$API/v2/user/oauth/token" -H "X-CK-Appid: $APPID" \
		-H "Authorization: Sign $(sign "$body")" -H "Content-Type: application/json" -d "$body")
	if save_tokens "$res"; then rm -f $CACHE; echo "OK"; else echo "HATA: $(echo "$res" | jq -r '.msg // .error // "bilinmeyen"')"; exit 1; fi
	;;
refresh)
	need_app; need_token
	exp=$(uci -q get $CFG.at_expiry || echo 0)
	[ "$2" != force ] && [ $(( exp - $(date +%s) )) -gt 259200 ] && exit 0   # 3 günden fazla varsa dokunma
	[ "$(date +%Y)" -lt 2025 ] && exit 0
	rt=$(uci -q get $CFG.refresh_token)
	res=$(api_post /v2/user/refresh "$(jq -nc --arg rt "$rt" '{rt:$rt}')")
	save_tokens "$res" && echo "OK" || { echo "HATA: $(echo "$res" | jq -r '.msg // "yenileme başarısız"')"; exit 1; }
	;;
list)
	need_app; need_token
	if [ -s $CACHE ] && [ $(( $(date +%s) - $(date -r $CACHE +%s) )) -lt 60 ] && [ "$2" != fresh ]; then cat $CACHE; exit 0; fi
	res=$(api_get "/v2/device/thing?num=0")
	[ "$(echo "$res" | jq -r '.error')" = 0 ] || { echo "HATA: $(echo "$res" | jq -r '.msg // "liste alınamadı"')"; exit 1; }
	# Çok kanallı cihazlarda (4CH) eWeLink'te kanal adı verilmişse her kanal ayrı satır: deviceid#kanal
	echo "$res" | jq -r '.data.thingList[] | select(.itemType <= 2) | .itemData |
		(if .online then "acik" else "cevrimdisi" end) as $on |
		([.deviceid, .name, $on,
		  (if .params.switch then .params.switch elif .params.switches then ([.params.switches[].switch] | join(",")) else "?" end)] | @tsv),
		(. as $d | (.tags.ck_channel_name // {}) | to_entries[] | select(.value != "") | .key as $k |
		  [($d.deviceid + "#" + $k), .value, $on,
		   ([$d.params.switches[]? | select(.outlet == ($k | tonumber))][0].switch // "?")] | @tsv)' > $CACHE
	cat $CACHE
	;;
set)
	need_app; need_token
	id="$2"; st="$3"; case "$st" in on|off) ;; *) echo "HATA: on|off"; exit 1;; esac
	line=$(grep "^$id	" $CACHE 2>/dev/null)
	nsw=$(echo "$line" | cut -f4 | tr ',' '\n' | grep -c .)
	if echo "$id" | grep -q '#'; then
		ch=${id#*#}; id=${id%%#*}
		params=$(jq -nc --arg s "$st" --argjson o "$ch" '{switches: [{outlet: $o, switch: $s}]}')
	elif echo "$line" | cut -f4 | grep -q ','; then
		params=$(jq -nc --arg s "$st" --argjson n "$nsw" '{switches: [range(0;$n) | {outlet: ., switch: $s}]}')
	else
		params=$(jq -nc --arg s "$st" '{switch: $s}')
	fi
	res=$(api_post /v2/device/thing/status "$(jq -nc --arg id "$id" --argjson p "$params" '{type:1, id:$id, params:$p}')")
	if [ "$(echo "$res" | jq -r '.error')" = 0 ]; then rm -f $CACHE; echo "OK"; else echo "HATA: $(echo "$res" | jq -r '.msg // "komut başarısız"')"; exit 1; fi
	;;
match)
	# Metindeki cihaz adını bul: tam eşleşme, ya da Türkçe ek (ön ışıkları -> ön ışıklar): ad metnin başında
	# ve kalan kısım en fazla 4 harf. En uzun ad kazanır.
	q=$(norm "$2")
	best=""; blen=0; hits=""
	"$0" list >/dev/null 2>&1
	while IFS='	' read -r id name rest; do
		n=$(norm "$name"); [ -n "$n" ] || continue
		case "$q" in
			"$n") ok=1 ;;
			"$n"*) suf=${q#"$n"}; [ ${#suf} -le 4 ] && ok=1 || ok=0 ;;
			*) ok=0 ;;
		esac
		[ $ok = 1 ] || continue
		if [ ${#n} -gt $blen ]; then best="$id	$name"; blen=${#n}; hits="$id	$name"
		elif [ ${#n} -eq $blen ]; then hits="$hits
$id	$name"; fi
	done < $CACHE
	[ -n "$hits" ] && echo "$hits"
	;;
oner)
	# Eşleşme yoksa: sorgudaki kelimelerden birinin ilk 4 harfini içeren cihaz adları
	"$0" list >/dev/null 2>&1
	for w in $(norm "$2"); do
		[ ${#w} -ge 3 ] || continue
		w4=$(echo "$w" | cut -c1-4)
		while IFS='	' read -r id name rest; do norm "$name" | grep -q "$w4" && echo "$name"; done < $CACHE
	done | sort -u | head -n 5
	;;
norm) norm "$2"; echo ;;
*) sed -n '2,14p' "$0" ;;
esac
