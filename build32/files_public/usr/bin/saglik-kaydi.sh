#!/bin/sh
# Saatte bir sağlık satırı: /tmp/saglik.log (RAM'de, 7 gün).
# Günde bir kez (03:15) son 24 satırın özeti flash'a: /etc/saglik-ozet.log (en fazla 30 gün, ~10 KB).
# Kullanım: saglik-kaydi.sh       -> saatlik satır
#           saglik-kaydi.sh ozet  -> günlük özet

T=/tmp/saglik.log; O=/etc/saglik-ozet.log

if [ "$1" = ozet ]; then
	[ -s $T ] || exit 0
	{
		echo "== $(date '+%Y-%m-%d') $(tail -n 24 $T | wc -l) kayıt"
		tail -n 24 $T | awk '{
			split($4,a,"="); f=a[2]+0; if(n==0||f<mn)mn=f; s+=f; n++
			if($0 !~ /ts=Running/)tsx++; if($0 !~ /zt=ONLINE/)ztx++; if($0 !~ /dns=doh/)dx++
		} END { printf "  RAM boş min %d MB, ort %d MB | ts sorunlu %d saat, zt %d, doh %d\n", mn, s/n, tsx, ztx, dx }'
		tail -n 1 $T
		[ -s /tmp/bekci.log ] && grep -c . /tmp/bekci.log | sed 's/^/  bekçi olayı: /'
	} >> $O
	tail -n 120 $O > $O.t && mv $O.t $O
	/usr/bin/tg-bildir.sh "📊 Günlük özet
$(tail -n 3 $O | sed -n '2p')
Son durum: $(tail -n 1 $T | cut -d' ' -f3-)" >/dev/null 2>&1
	exit 0
fi

avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
swap=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)
up=$(awk '{printf "%dsa", $1/3600}' /proc/uptime)
load=$(cut -d' ' -f1 /proc/loadavg)
ts=$(tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' 2>/dev/null); ts=${ts:-yok}
zt=$(zerotier-cli info 2>/dev/null | awk '{print $5}'); zt=${zt:-yok}
dns=plain; uci -q get dhcp.@dnsmasq[0].server | grep -q '127.0.0.1#505' && dns=doh
ab=$(pidof dnsmasq >/dev/null && [ -s /var/run/adblock-fast/dnsmasq.servers ] && grep -c . /var/run/adblock-fast/dnsmasq.servers || echo 0)
tsr=0; for p in $(pidof tailscaled); do tsr=$(awk '/VmRSS/{print int($2/1024)}' /proc/$p/status); done
net=yok; ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && net=var

echo "$(date '+%m-%d %H:%M') up=$up bos=${avail}MB swap=${swap}MB yuk=$load ts=$ts(${tsr}MB) zt=$zt dns=$dns adblock=$ab net=$net" >> $T
tail -n 168 $T > $T.t && mv $T.t $T
