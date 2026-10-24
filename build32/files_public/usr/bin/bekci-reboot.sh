#!/bin/sh
# Nedenini kaydedip router'ı yeniden başlatır. Açılışta uzak-bekci.sh bu nedeni Telegram'a bildirir.
#   bekci-reboot.sh "neden"
# watchcat (run_script modu, internet 30 dk yok) ve Telegram /router_reboot bunu kullanır.
echo "${1:-bilinmeyen}" > /etc/son-reboot-nedeni
sync
logger -t uzak-bekci "REBOOT: ${1:-bilinmeyen}"
sleep 2
reboot
