#!/usr/bin/env bash
# XWRT build-time defaults. This script is intentionally independent from OpenWRT-CI.
set -euo pipefail

: "${WRT_THEME:=vantage}"
: "${WRT_NAME:=XWRT}"
: "${WRT_SSID:=XWRT}"
: "${WRT_WORD:=12345678}"
: "${WRT_IP:=192.168.10.1}"

if [[ ! "$WRT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] ||
   [[ ! "$WRT_THEME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  printf '%s\n' 'Invalid WRT_NAME or WRT_THEME' >&2
  exit 1
fi
if [[ ! "$WRT_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  printf '%s\n' 'Invalid WRT_IP' >&2
  exit 1
fi
IFS=. read -r -a ip_octets <<< "$WRT_IP"
for octet in "${ip_octets[@]}"; do
  if (( 10#$octet > 255 )) || [[ "$octet" != "$((10#$octet))" ]]; then
    printf '%s\n' 'Invalid WRT_IP' >&2
    exit 1
  fi
done
for value in "$WRT_SSID" "$WRT_WORD"; do
  if [[ "$value" =~ [[:cntrl:]] || "$value" == *"'"* || "$value" == *"\\"* ]]; then
    printf '%s\n' 'Wi-Fi defaults cannot contain control characters, single quotes or backslashes' >&2
    exit 1
  fi
done
if [[ ${#WRT_WORD} -lt 8 || ${#WRT_WORD} -gt 63 || "$WRT_WORD" == *[!\ -\~]* ]]; then
  printf '%s\n' 'WRT_WORD must contain 8 to 63 printable ASCII characters' >&2
  exit 1
fi

for collection in feeds/luci/collections/*/Makefile; do
  [ -f "$collection" ] || continue
  sed -i '/luci-app-attendedsysupgrade/d; s/luci-theme-bootstrap/luci-theme-'"$WRT_THEME"'/g' "$collection"
done

CFG_FILE=package/base-files/files/bin/config_generate
if [ -f "$CFG_FILE" ]; then
  sed -i "s/192\\.168\\.[0-9]*\\.[0-9]*/$WRT_IP/g; s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"
fi

WIFI_CONFIG=package/emortal/luci-app-router-tool/root/etc/config/router-tool
if [ -f "$WIFI_CONFIG" ]; then
  ssid_sed=${WRT_SSID//&/\\&}
  ssid_sed=${ssid_sed//|/\\|}
  word_sed=${WRT_WORD//&/\\&}
  word_sed=${word_sed//|/\\|}
  sed -i "s|option ssid '.*'|option ssid '$ssid_sed'|; s|option key '.*'|option key '$word_sed'|" "$WIFI_CONFIG"
fi

FLASH_JS=feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js
if [ -f "$FLASH_JS" ]; then
  sed -i "/awaitReconnect(/ { s/'192\\.168\\.1\\.1'/'$WRT_IP'/g; s/'immortalwrt\\.lan'/'${WRT_NAME,,}.lan'/g; }" "$FLASH_JS"
fi

touch .config
sed -i '/^CONFIG_PACKAGE_luci=/d; /^CONFIG_LUCI_LANG_zh_Hans=/d; /^CONFIG_PACKAGE_luci-theme-'"$WRT_THEME"'=/d; /^CONFIG_IMAGEOPT=/d; /^# CONFIG_IMAGEOPT is not set$/d; /^CONFIG_VERSIONOPT=/d; /^# CONFIG_VERSIONOPT is not set$/d; /^CONFIG_VERSION_DIST=/d; /^CONFIG_PACKAGE_luci-app-vantage=/d' .config
cat >> .config <<EOF
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-theme-$WRT_THEME=y
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="$WRT_NAME"
EOF
if [ "$WRT_THEME" = vantage ]; then
  printf '%s\n' 'CONFIG_PACKAGE_luci-app-vantage=y' >> .config
fi
