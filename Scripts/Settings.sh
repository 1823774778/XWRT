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

# The stock CN database only exposes 5.2G and 5.8G and disables DFS channels,
# so a phone cannot discover a 5G AP left on a DFS channel by auto selection.
WIFI_UC=package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc
if [ -f "$WIFI_UC" ]; then
  python3 - "$WIFI_UC" <<'PY'
from pathlib import Path
import sys

uc = Path(sys.argv[1])
source = uc.read_text()
old = "set ${s}.country='${country || 'CN'}'"
new = "set ${s}.country='CN'"
if new not in source:
    if old not in source:
        raise SystemExit('Unsupported wifi-scripts country default')
    uc.write_text(source.replace(old, new, 1))
PY
fi

# Upgrades keep their old wireless config, so fix the 5G country at boot too.
WIFI_DEFAULTS=files/etc/uci-defaults/98-xwrt-wifi
mkdir -p files/etc/uci-defaults
cat > "$WIFI_DEFAULTS" <<'EOF'
#!/bin/sh
[ -f /etc/config/wireless ] || exit 0
changed=
for radio in $(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-device$/\1/p'); do
  [ "$(uci -q get "wireless.$radio.band")" = "5g" ] || continue
  [ "$(uci -q get "wireless.$radio.country")" = "CN" ] && continue
  uci -q set "wireless.$radio.country=CN" && changed=1
done
[ -z "$changed" ] || uci -q commit wireless
exit 0
EOF
chmod 0755 "$WIFI_DEFAULTS"

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

# A kept configuration can still select a theme this image no longer ships,
# which leaves LuCI failing over to a template runtime that is not installed.
THEME_DEFAULTS=files/etc/uci-defaults/99-xwrt-theme
mkdir -p files/etc/uci-defaults
cat > "$THEME_DEFAULTS" <<EOF
#!/bin/sh
for key in \$(uci -q show luci.themes 2>/dev/null | sed -n 's/^luci\.themes\.\([^.=]*\)=.*/\1/p'); do
  value="\$(uci -q get "luci.themes.\$key")"
  [ -d "/www/luci-static/\${value##*/}" ] || uci -q delete "luci.themes.\$key"
done
base="\$(uci -q get luci.main.mediaurlbase)"
if [ -z "\$base" ] || [ ! -d "/www/luci-static/\${base##*/}" ]; then
  uci -q set luci.themes.${WRT_THEME^}=/luci-static/$WRT_THEME
  uci -q set luci.main.mediaurlbase=/luci-static/$WRT_THEME
fi
uci -q commit luci
exit 0
EOF
chmod 0755 "$THEME_DEFAULTS"

# Keep the overview and release filenames tied to the same build timestamp.
python3 - "$WRT_NAME" <<'PY'
from datetime import datetime
import json
from pathlib import Path
import sys
from zoneinfo import ZoneInfo

build_time = Path('files/etc/xwrt-build-time')
build_time.parent.mkdir(parents=True, exist_ok=True)
if not build_time.exists():
    build_time.write_text(datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(timespec='seconds') + '\n')
timestamp = datetime.fromisoformat(build_time.read_text().strip()).astimezone(ZoneInfo('Asia/Shanghai'))
label = f'{sys.argv[1]}-{timestamp:%y.%m.%d-%H.%M.%S}'
status = Path('feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js')
source = status.read_text()
old = "(luciversion || '')"
new = old + ' + ' + json.dumps(' / ' + label)
if new not in source:
    if source.count(old) != 1:
        raise SystemExit('Unsupported LuCI firmware version display')
    status.write_text(source.replace(old, new, 1))
PY

OTA_BACKEND=package/luci-app-xwrt-ota/root/usr/libexec/xwrt-ota
if [ -f "$OTA_BACKEND" ]; then
  python3 - "$OTA_BACKEND" <<'PY'
from pathlib import Path
import sys

backend = Path(sys.argv[1])
source = backend.read_text()
date_pattern = '-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
old = f'.bin|{date_pattern}.bin) ;;'
new = f'.bin|{date_pattern}.bin|{date_pattern}-[0-9][0-9].[0-9][0-9].[0-9][0-9].bin) ;;'
if new not in source:
    if old not in source:
        raise SystemExit('Unsupported XWRT OTA firmware filename matcher')
    backend.write_text(source.replace(old, new, 1))
PY
fi

# APK reads this configuration for both CLI and LuCI package operations.
APK_CONFIG=files/etc/apk/config
mkdir -p files/etc/apk files/lib/upgrade/keep.d
touch "$APK_CONFIG"
if ! grep -Fqx 'allow-untrusted' "$APK_CONFIG"; then
  printf '\nallow-untrusted\n' >> "$APK_CONFIG"
fi
printf '%s\n' '/etc/apk/config' > files/lib/upgrade/keep.d/apk-config
