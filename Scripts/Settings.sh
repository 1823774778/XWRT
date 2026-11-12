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

ROUTER_TOOL_ROOT=package/emortal/luci-app-router-tool/root
WIFI_CONFIG=$ROUTER_TOOL_ROOT/etc/config/router-tool
if [ -f "$WIFI_CONFIG" ]; then
  ssid_sed=${WRT_SSID//&/\\&}
  ssid_sed=${ssid_sed//|/\\|}
  word_sed=${WRT_WORD//&/\\&}
  word_sed=${word_sed//|/\\|}
  sed -i "s|option ssid '.*'|option ssid '$ssid_sed'|; s|option key '.*'|option key '$word_sed'|" "$WIFI_CONFIG"

  python3 - "$ROUTER_TOOL_ROOT/usr/share/router-tool/wireless.uc" <<'PY'
from pathlib import Path
import sys

wireless = Path(sys.argv[1])
source = wireless.read_text()
old = "\t\tlet mode = htmode(caps, width);\n"
new = r"""		if (band == '5G') {
			let model = board?.model?.id;
			if (model == 'jdcloud,re-ss-01')
				suffix = '5.8G';
			else if (model == 'jdcloud,re-cs-02') {
				// Athena's PCIe radio is 5.2 GHz; its integrated 5 GHz radio is 5.8 GHz.
				let path = radio.path || array(board.wlan[radio.phy]?.path)[0];
				if (path)
					suffix = match(path, /(^|\/)pci[0-9a-f]{4}:[0-9a-f]{2}\//) ? '5.2G' : '5.8G';
			}
		}
""" + old
if new not in source:
    if source.count(old) != 1:
        raise SystemExit('Unsupported Router Tool wireless naming logic')
    wireless.write_text(source.replace(old, new, 1))
PY
fi

if grep -q '^CONFIG_TARGET_qualcommax_ipq60xx=y$' .config; then
  RELAY_AP_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/RouterToolRelayAP.uc"
  RELAY_AP_TARGET=$ROUTER_TOOL_ROOT/usr/share/router-tool/relay_ap.uc
  ROUTER_AUTO_UC=$ROUTER_TOOL_ROOT/usr/share/router-tool/auto.uc
  ROUTER_TOOL_AUTO=$ROUTER_TOOL_ROOT/usr/libexec/router-tool-auto
  ROUTER_TOOL_JS=package/emortal/luci-app-router-tool/htdocs/luci-static/resources/tools/router-tool.js
  [ -f "$RELAY_AP_SOURCE" ] || { printf '%s\n' 'Missing Relay AP source' >&2; exit 1; }
  [ -f "$ROUTER_AUTO_UC" ] || { printf '%s\n' 'Missing Router Tool auto.uc' >&2; exit 1; }
  [ -f "$ROUTER_TOOL_AUTO" ] || { printf '%s\n' 'Missing Router Tool auto runner' >&2; exit 1; }
  [ -f "$ROUTER_TOOL_JS" ] || { printf '%s\n' 'Missing Router Tool LuCI integration' >&2; exit 1; }
  mkdir -p "$(dirname "$RELAY_AP_TARGET")"
  cp "$RELAY_AP_SOURCE" "$RELAY_AP_TARGET"

  python3 - "$WIFI_CONFIG" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
marker = "option auto_relay_ap '1'"
if marker not in source:
    anchor = "config settings 'main'\n"
    if source.count(anchor) != 1:
        raise SystemExit('Unsupported Router Tool settings config')
    source = source.replace(anchor, anchor + "\t" + marker + "\n", 1)
    path.write_text(source)
PY

  python3 - "$ROUTER_AUTO_UC" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
import_line = "import { read_snapshot, record_option, custom_option, tracked_option, lan_context, equal, finish_snapshot } from './snapshot.uc';\n"
if "import * as relay_ap from './relay_ap.uc';" not in source:
    if source.count(import_line) != 1:
        raise SystemExit('Unsupported Router Tool auto.uc imports')
    source = source.replace(import_line, import_line + "import * as relay_ap from './relay_ap.uc';\n", 1)
signature = 'export function synchronize(uci, data, upstream4, target) {'
new_signature = 'export function synchronize(uci, data, upstream4, target, board, before) {'
if new_signature not in source:
    if source.count(signature) != 1:
        raise SystemExit('Unsupported Router Tool synchronize signature')
    source = source.replace(signature, new_signature, 1)
old = """\t\trecorder = null;
\t\tset('router-tool', 'main', { auto_role: role });
\t}
\t// Await the first lease, then check the LAN subnet once for this mode.
"""
new = """\t\trecorder = null;
\t\tset('router-tool', 'main', { auto_role: role });
\t}
\tif (previous != role)
\t\tset('router-tool', 'main', { state: finish_snapshot(state) });
\tlet relay_enabled = false;
\tif (role == 'sub' && !ap && uci.get('network', 'wan', 'proto') != 'pppoe' &&
\t\tuci.get('router-tool', 'main', 'auto_relay_ap') != '0' &&
\t\tuci.get('router-tool', 'main', 'auto_relay_ap_disabled') != '1' &&
\t\tstate && !state.manual_lan && length(upstream4 || []) && board && relay_ap.has_conflict(uci, upstream4)) {
\t\tstate.subnet_done = true;
\t\tset('router-tool', 'main', { state: finish_snapshot(state) });
\t\tfor (let config in relay_ap.enable(uci, board, data))
\t\t\tchanged[config] = true;
\t\trelay_enabled = true;
\t}
\tif (relay_enabled)
\t\treturn keys(changed);
\t// Await the first lease, then check the LAN subnet once for this mode.
"""
if new not in source:
    if source.count(old) != 1:
        raise SystemExit('Unsupported Router Tool role transition anchor')
    source = source.replace(old, new, 1)
old_call = """\tif (role == 'sub' && !state.subnet_done && length(upstream4 || [])) {
"""
new_call = """\tif (!relay_enabled && role == 'sub' && !state.subnet_done && length(upstream4 || [])) {
"""
if new_call not in source:
    if source.count(old_call) != 1:
        raise SystemExit('Unsupported Router Tool subnet conflict anchor')
    source = source.replace(old_call, new_call, 1)
path.write_text(source)
PY

  python3 - "$ROUTER_TOOL_AUTO" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = "\tlet before = configuration(uci);\n\tlet changed = [];\n"
new = """\tlet before = configuration(uci);
\tlet changed = [];
\tlet board = null;
\ttry {
\t\tlet board_text = readfile('/etc/board.json');
\t\tif (board_text) board = json(board_text);
\t}
\tcatch (e) {
\t\tlog_once(LOG_WARNING, 'relay-ap-board', 'Board capabilities unavailable; automatic Relay AP is deferred: ' + e.message);
\t}
"""
if new not in source:
    if source.count(old) != 1:
        raise SystemExit('Unsupported Router Tool auto runner state anchor')
    source = source.replace(old, new, 1)
old_call = 'for (let config in synchronize(uci, data, upstream, target))'
new_call = 'for (let config in synchronize(uci, data, upstream, target, board, before))'
if new_call not in source:
    if source.count(old_call) != 1:
        raise SystemExit('Unsupported Router Tool auto runner synchronize call')
    source = source.replace(old_call, new_call, 1)
old_after_sync = "\tfor (let config in synchronize(uci, data, upstream, target, board, before))\n\t\tif (index(changed, config) < 0) push(changed, config);\n"
new_after_sync = old_after_sync + "\tap = uci.get('router-tool', 'main', 'ap_mode') == '1';\n"
if new_after_sync not in source:
    if source.count(old_after_sync) != 1:
        raise SystemExit('Unsupported Router Tool auto runner post-sync state')
    source = source.replace(old_after_sync, new_after_sync, 1)
old_wireless_board = "\t\tlet board = null;\n\t\tlet text = readfile('/etc/board.json');"
new_wireless_board = "\t\tlet text = readfile('/etc/board.json');"
if old_wireless_board in source:
    if source.count(old_wireless_board) != 1:
        raise SystemExit('Unsupported Router Tool wireless board loader')
    source = source.replace(old_wireless_board, new_wireless_board, 1)
path.write_text(source)
PY

  python3 - "$ROUTER_TOOL_JS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old_enable = "\tuci.set('router-tool', 'main', 'ap_mode', '1');\n"
new_enable = "\tuci.unset('router-tool', 'main', 'auto_relay_ap_disabled');\n\tuci.set('router-tool', 'main', 'ap_mode', '1');\n"
if new_enable not in source:
    if source.count(old_enable) != 1:
        raise SystemExit('Unsupported Router Tool AP enable marker')
    source = source.replace(old_enable, new_enable, 1)
old_disable = "\tuci.unset('router-tool', 'main', 'ap_state');\n\tuci.set('router-tool', 'main', 'ap_mode', '0');\n"
new_disable = "\tif (uci.get('router-tool', 'main', 'auto_relay_ap') != '0')\n\t\tuci.set('router-tool', 'main', 'auto_relay_ap_disabled', '1');\n\tuci.unset('router-tool', 'main', 'ap_state');\n\tuci.set('router-tool', 'main', 'ap_mode', '0');\n"
if new_disable not in source:
    if source.count(old_disable) != 1:
        raise SystemExit('Unsupported Router Tool AP disable marker')
    source = source.replace(old_disable, new_disable, 1)
path.write_text(source)
PY
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

# APK reads these files for both CLI and LuCI package operations.
APK_CONFIG=files/etc/apk/config
APK_CUSTOM_FEEDS=files/etc/apk/repositories.d/customfeeds.list
mkdir -p files/etc/apk/repositories.d files/lib/upgrade/keep.d
touch "$APK_CONFIG"
if ! grep -Fqx 'allow-untrusted' "$APK_CONFIG"; then
  printf '\nallow-untrusted\n' >> "$APK_CONFIG"
fi
if [ ! -f "$APK_CUSTOM_FEEDS" ]; then
  cat > "$APK_CUSTOM_FEEDS" <<'EOF'
# Add trusted custom APK repositories here.
# Official target and feed repositories are generated in distfeeds.list.
EOF
fi
printf '%s\n' '/etc/apk/config' '/etc/apk/repositories.d/customfeeds.list' > files/lib/upgrade/keep.d/apk-config
