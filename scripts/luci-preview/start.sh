#!/bin/sh
set -eu
case "${SUB_STORE_PREVIEW_STATE:-running}" in running|exited|not-created) ;; *) exit 1 ;; esac
echo "${SUB_STORE_PREVIEW_STATE:-running}" > /tmp/sub-store-preview-state
cat > /etc/config/sub-store <<'EOF'
config settings 'main'
 option frontend_port '3001'
 option backend_port '3000'
 option image 'xream/sub-store:latest'
 option api_path 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
 option sync_cron '0 0 * * *'
EOF
passwd -d root >/dev/null
mkdir -p /var/run /var/lock
ubusd &
until ubus list >/dev/null 2>&1; do sleep 1; done
rpcd &
exec uhttpd -f -h /www -r OpenWrt -x /cgi-bin -u /ubus -p 0.0.0.0:80
