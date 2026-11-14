#!/usr/bin/env bash
# XWRT build-time defaults. This script is intentionally independent from OpenWRT-CI.
set -euo pipefail

: "${WRT_THEME:=7dollar}"
: "${WRT_NAME:=XWRT}"
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
if [[ "$WRT_WORD" == *"'"* || "$WRT_WORD" == *"\\"* ]]; then
  printf '%s\n' 'WRT_WORD cannot contain single quotes or backslashes' >&2
  exit 1
fi
if [[ ${#WRT_WORD} -lt 8 || ${#WRT_WORD} -gt 63 || "$WRT_WORD" == *[!\ -\~]* ]]; then
  printf '%s\n' 'WRT_WORD must contain 8 to 63 printable ASCII characters' >&2
  exit 1
fi

for collection in feeds/luci/collections/*/Makefile; do
  [ -f "$collection" ] || continue
  sed -i '/luci-app-attendedsysupgrade/d; s/luci-theme-bootstrap/luci-theme-'"$WRT_THEME"'/g' "$collection"
done

# 7Dollar ships its own ucode module and its templates import luci.7dollar.
# The host ucode compiler used for template precompilation cannot resolve it,
# so extend LuCI's default dynlink list with that runtime import.
LUCI_MK=feeds/luci/luci.mk
if [ -f "$LUCI_MK" ] && ! grep -q 'dynlink=luci.7dollar' "$LUCI_MK"; then
  sed -i '/^LUCI_UT_CFLAGS?=/ s/$/,dynlink=luci.7dollar/' "$LUCI_MK"
fi

CFG_FILE=package/base-files/files/bin/config_generate
if [ -f "$CFG_FILE" ]; then
  sed -i "s/192\\.168\\.[0-9]*\\.[0-9]*/$WRT_IP/g; s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"
fi

ROUTER_TOOL_ROOT=package/emortal/luci-app-router-tool/root
WIFI_CONFIG=$ROUTER_TOOL_ROOT/etc/config/router-tool
if [ -f "$WIFI_CONFIG" ]; then
  word_sed=${WRT_WORD//&/\\&}
  word_sed=${word_sed//|/\\|}
  sed -i "s|option ssid '.*'|option ssid 'XWRT'|; s|option key '.*'|option key '$word_sed'|" "$WIFI_CONFIG"
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
new_signature = 'export function synchronize(uci, data, upstream4, target, board, wireless_pending) {'
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
\tif (role == 'sub' && uci.get('router-tool', 'main', 'auto_relay_ap') != '0' &&
\t\tuci.get('router-tool', 'main', 'auto_relay_ap_disabled') != '1' && relay_ap.has_conflict(uci, upstream4)) {
\t\tlet ready = length(keys(board?.network || {})) && !wireless_pending;
\t\t// Save the routed LAN before bridging, including manually configured addresses.
\t\tif (ready) state.subnet_done = true;
\t\tif (ready || previous != role)
\t\t\tset('router-tool', 'main', { state: finish_snapshot(uci, state) });
\t\tif (ready) {
\t\t\tfor (let config in relay_ap.enable(uci, board, data))
\t\t\t\tchanged[config] = true;
\t\t\tuci.set('router-tool', 'main', 'ap_auto', '1');
\t\t}
\t\t// Do not move the LAN to a different subnet while AP conversion is deferred.
\t\treturn keys(changed);
\t}
\t// Await the first lease, then check the LAN subnet once for this mode.
"""
if new not in source:
    if source.count(old) != 1:
        raise SystemExit('Unsupported Router Tool role transition anchor')
    source = source.replace(old, new, 1)
path.write_text(source)
PY

  python3 - "$ROUTER_TOOL_AUTO" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
import_anchor = "import { synchronize } from '/usr/share/router-tool/auto.uc';\n"
relay_import = "import * as relay_ap from '/usr/share/router-tool/relay_ap.uc';\n"
board_loader = """\t\tlet board = null;
\t\tlet text = readfile('/etc/board.json');
\t\ttry {
\t\t\tif (text) board = json(text);
\t\t\tunlink('/var/run/router-tool-log-wireless-board');
\t\t}
\t\tcatch (e) {
\t\t\tlog_once(LOG_WARNING, 'wireless-board', 'Wireless board capabilities are invalid; defaults deferred: ' + e.message);
\t\t}
"""
old = """\tfor (let config in synchronize(uci, data, upstream, target))
\t\tif (index(changed, config) < 0) push(changed, config);
"""
new = """\tlet board = null;
\ttry {
\t\tlet text = readfile('/etc/board.json');
\t\tif (text) board = json(text);
\t\tunlink('/var/run/router-tool-log-wireless-board');
\t}
\tcatch (e) {
\t\tlog_once(LOG_WARNING, 'wireless-board', 'Board data is invalid; Relay AP and wireless defaults are deferred: ' + e.message);
\t}
\tlet wireless_pending = stat('/tmp/.uci/wireless')?.size;
\tif (!wireless_pending && ap && uci.get('router-tool', 'main', 'ap_auto') == '1') {
\t\tlet restore = false;
\t\tlet reason = null;
\t\tlet bus = connect();
\t\tlet status = bus?.call('network.interface.lan', 'status', {});
\t\tbus?.disconnect();
\t\tif (status) {
\t\t\tlet lan_up = status.up == true;
\t\t\tlet lan_upstream = lan_up ? map(status['ipv4-address'] || [], address => `${address.address}/${address.mask}`) : [];
\t\t\treason = relay_ap.restore_needed(uci, lan_upstream);
\t\t\tlet uptime = +split(readfile('/proc/uptime') || '0', ' ')[0];
\t\t\tif (reason == 'moved')
\t\t\t\trestore = true;
\t\t\telse if (reason == 'lost' && uptime > 90) {
\t\t\t\tif (!lan_up)
\t\t\t\t\trestore = true;
\t\t\t\telse {
\t\t\t\t\tlet since = +readfile('/var/run/router-tool-ap-lost') || 0;
\t\t\t\t\tif (!since) writefile('/var/run/router-tool-ap-lost', sprintf('%d\\n', uptime));
\t\t\t\t\telse if (uptime - since >= 20) restore = true;
\t\t\t\t}
\t\t\t}
\t\t}
\t\tif (restore) {
\t\t\tfor (let config in relay_ap.disable(uci))
\t\t\t\tif (index(changed, config) < 0) push(changed, config);
\t\t\tap = false;
\t\t\tunlink('/var/run/router-tool-ap-lost');
\t\t\tlog_once(LOG_NOTICE, 'ap-restore', 'Relay AP mode restored after upstream ' + reason);
\t\t}
\t\telse if (reason != 'lost')
\t\t\tunlink('/var/run/router-tool-ap-lost');
\t}
\tfor (let config in synchronize(uci, data, upstream, target, board, wireless_pending))
\t\tif (index(changed, config) < 0) push(changed, config);
\tap = uci.get('router-tool', 'main', 'ap_mode') == '1';
"""
if relay_import not in source:
    if source.count(import_anchor) != 1:
        raise SystemExit('Unsupported Router Tool auto runner imports')
    source = source.replace(import_anchor, import_anchor + relay_import, 1)
if new not in source:
    if source.count(old) != 1 or source.count(board_loader) != 1:
        raise SystemExit('Unsupported Router Tool auto runner synchronization')
    source = source.replace(board_loader, '', 1).replace(old, new, 1)
path.write_text(source)
PY

  python3 - "$ROUTER_TOOL_JS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old_conflict = "\tif (!lan.some(a => upstream.some(b => overlaps(a, b)))) return;\n"
new_conflict = old_conflict + """	// Leave the overlap in place for the backend's automatic Relay AP switch.
	if (uci.get('router-tool', 'main', 'auto_relay_ap') !== '0' &&
		uci.get('router-tool', 'main', 'auto_relay_ap_disabled') !== '1') return;
"""
if new_conflict not in source:
    if source.count(old_conflict) != 1:
        raise SystemExit('Unsupported Router Tool LuCI subnet conflict logic')
    source = source.replace(old_conflict, new_conflict, 1)
old_enable = "\tuci.set('router-tool', 'main', 'ap_mode', '1');\n"
new_enable = "\tuci.unset('router-tool', 'main', 'auto_relay_ap_disabled');\n\tuci.unset('router-tool', 'main', 'ap_auto');\n\tuci.set('router-tool', 'main', 'ap_mode', '1');\n"
if new_enable not in source:
    if source.count(old_enable) != 1:
        raise SystemExit('Unsupported Router Tool AP enable marker')
    source = source.replace(old_enable, new_enable, 1)
old_disable = "\tuci.unset('router-tool', 'main', 'ap_state');\n\tuci.set('router-tool', 'main', 'ap_mode', '0');\n"
new_disable = "\tif (uci.get('router-tool', 'main', 'auto_relay_ap') != '0')\n\t\tuci.set('router-tool', 'main', 'auto_relay_ap_disabled', '1');\n\tuci.unset('router-tool', 'main', 'ap_auto');\n\tuci.unset('router-tool', 'main', 'ap_state');\n\tuci.set('router-tool', 'main', 'ap_mode', '0');\n"
if new_disable not in source:
    if source.count(old_disable) != 1:
        raise SystemExit('Unsupported Router Tool AP disable marker')
    source = source.replace(old_disable, new_disable, 1)
path.write_text(source)
PY
fi

FLASH_JS=feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js
if [ -f "$FLASH_JS" ]; then
  sed -i "/awaitReconnect(/ { s/'192\\.168\\.1\\.1'/'$WRT_IP'/g; s/'immortalwrt\\.lan'/'${WRT_NAME,,}.lan'/g; }" "$FLASH_JS"
fi

touch .config
sed -i '/^CONFIG_PACKAGE_luci=/d; /^CONFIG_LUCI_LANG_zh_Hans=/d; /^CONFIG_PACKAGE_luci-theme-'"$WRT_THEME"'=/d; /^CONFIG_IMAGEOPT=/d; /^# CONFIG_IMAGEOPT is not set$/d; /^CONFIG_VERSIONOPT=/d; /^# CONFIG_VERSIONOPT is not set$/d; /^CONFIG_VERSION_DIST=/d' .config
cat >> .config <<EOF
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-theme-$WRT_THEME=y
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="$WRT_NAME"
EOF

# A kept configuration can still select a theme this image no longer ships,
# which leaves LuCI failing over to a template runtime that is not installed.
THEME_KEY="${WRT_THEME^}"
[ "$WRT_THEME" = 7dollar ] && THEME_KEY=7Dollar
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
  uci -q set luci.themes.$THEME_KEY=/luci-static/$WRT_THEME
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
