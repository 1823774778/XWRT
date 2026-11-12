#!/usr/bin/env bash
# XWRT build-time defaults. This script is intentionally independent from OpenWRT-CI.
set -euo pipefail

: "${WRT_THEME:=vantage}"
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

  python3 - "$ROUTER_TOOL_ROOT/usr/share/router-tool/wireless.uc" <<'PY'
from pathlib import Path
import sys

wireless = Path(sys.argv[1])
source = wireless.read_text()
old = "\t\tlet mode = htmode(caps, width);\n"
new = r"""		if (band == '5G') {
			let model = board?.model?.id;
			let path = radio.path || array(board.wlan[radio.phy]?.path)[0];
			if (model == 'jdcloud,re-ss-01')
				suffix = '5G';
			else if (model == 'jdcloud,re-cs-02' && path) {
				// Athena's PCIe radio is 5.2 GHz; its integrated 5 GHz radio uses the generic 5G suffix.
				let pci = match(path, /(^|\/)pci[0-9a-f]{4}:[0-9a-f]{2}\//);
				suffix = pci ? '5.2G' : '5G';
			}
			// CN only allows 5150-5350 and 5725-5850. Prefer the radio's own
			// default channel, but never let auto selection pick a DFS channel.
			let preferred = '' + (caps.first_channel ?? '');
			channel = match(preferred, /^[0-9]+$/) && !match(preferred, /^(1[0-3][0-9]|14[0-4])$/) ?
				preferred : (suffix == '5.2G' ? '36' : '149');
			// 160 MHz is only available below 5725 MHz (UNII-3 is 80 MHz wide).
			width = min(width, int(channel) >= 149 ? 80 : 160);
		}
""" + old
patches = [
    (old, new),
    (r"""function default_ssid(uci, board, suffix, custom_ssid) {
	let hostname = custom_ssid || uci.get_first('system', 'system', 'hostname') || 'OWRT';
	let tail = suffix;
	if (!custom_ssid) {
		let vendor = split(board?.model?.id, ',')?.[0] || 'unknown';
		vendor = uc(substr(vendor, 0, 1)) + substr(vendor, 1);
		// Keep the vendor and band visible within the 32-byte SSID limit.
		tail = substr(vendor, 0, 32 - length(suffix) - 3) + '-' + suffix;
	}
	let size = min(length(hostname), 31 - length(tail));
	// Ucode string offsets count bytes. Avoid cutting a UTF-8 code point.
	while (size > 0 && (ord(hostname, size) & 0xc0) == 0x80) size--;
	return substr(hostname, 0, size) + '-' + tail;
}""", r"""function format_ssid(hostname, suffix) {
	let size = min(length(hostname), 31 - length(suffix));
	// Ucode string offsets count bytes. Avoid cutting a UTF-8 code point.
	while (size > 0 && size < length(hostname) && (ord(hostname, size) & 0xc0) == 0x80) size--;
	return substr(hostname, 0, size) + '-' + suffix;
}

function default_ssid(suffix) {
	return 'XWRT-' + (suffix == '5.8G' ? '5G' : suffix);
}"""),
    (r"""		set('wireless', radio['.name'], { country: 'US', channel, htmode: mode });""",
     r"""		set('wireless', radio['.name'], { country: band == '6G' ? '00' : 'CN', channel, htmode: mode });"""),
    ('let defaults_loaded = false, custom_ssid, custom_key;',
     'let defaults_loaded = false, custom_key;'),
    (r"""		custom_ssid = defaults?.ssid;
		custom_key = defaults?.key;
		let use_custom = type(custom_ssid) == 'string' && type(custom_key) == 'string' &&
			length(custom_ssid) && length(custom_key);
		if (use_custom && (length(custom_ssid) > 32 || match(custom_ssid, /[[:cntrl:]]/)))
			die('Wireless SSID must contain 1 to 32 bytes without control characters');
		if (use_custom && (length(custom_key) < 8 || length(custom_key) > 63 || match(custom_key, /[^ -~]/)))
			die('Wireless password must contain 8 to 63 printable ASCII characters');
		if (!use_custom) {
			custom_ssid = null;
			custom_key = '12345678';
		}""", r"""		custom_key = defaults?.key || '12345678';
		if (type(custom_key) != 'string' || length(custom_key) < 8 || length(custom_key) > 63 || match(custom_key, /[^ -~]/))
			die('Wireless password must contain 8 to 63 printable ASCII characters');"""),
    (r"""	for (let radio in radios) {
		if (uci.get('router-tool', radio['.name'], 'defaults_done') == '1') continue;
		let attached = filter(interfaces, iface => index(array(iface.device), radio['.name']) >= 0);
		// Decide once as soon as a radio has interfaces. Custom SSIDs and
		// station/mesh/WDS backhauls are explicit user configuration.
		if (!length(attached)) continue;
		if (length(filter(attached, iface => iface.mode != 'ap' || iface.wds == '1' || length(array(iface.device)) != 1 || iface.mlo == '1'))) {""", r"""	function plain_ap(iface) {
		return iface.mode == 'ap' && iface.wds != '1' && length(array(iface.device)) == 1 && iface.mlo != '1';
	}
	// Adopt a matching legacy default once; preserve names changed by the user.
	for (let ap in interfaces) {
		if (!plain_ap(ap)) continue;
		let saved = ap.xwrt_managed_ssid;
		let suffix = match(ap.ssid || '', /-(2\.4G|5\.2G|5\.8G|5G|6G)$/)?.[1];
		if (!suffix) continue;
		if (!saved) {
			let radio = filter(radios, entry => entry['.name'] == array(ap.device)[0])[0];
			let bands = { '2g': [ '2.4G' ], '5g': [ '5G', '5.2G', '5.8G' ], '6g': [ '6G' ] }[radio?.band] || [];
			let prefixes = [ uci.get('router-tool', 'defaults', 'ssid'), uci.get_first('system', 'system', 'hostname') ];
			if (index(bands, suffix) < 0 || uci.get('router-tool', radio['.name'], 'defaults_done') != '1' ||
				!length(filter(prefixes, prefix => type(prefix) == 'string' && length(prefix) && ap.ssid == format_ssid(prefix, suffix))))
				continue;
			saved = ap.ssid;
		}
		if (ap.ssid != saved) continue;
		let ssid = default_ssid(suffix);
		set('wireless', ap['.name'], { ssid, xwrt_managed_ssid: ssid });
	}
	for (let radio in radios) {
		if (uci.get('router-tool', radio['.name'], 'defaults_done') == '1') continue;
		let attached = filter(interfaces, iface => index(array(iface.device), radio['.name']) >= 0);
		// Decide once as soon as a radio has interfaces. Custom SSIDs and
		// station/mesh/WDS backhauls are explicit user configuration.
		if (!length(attached)) continue;
		if (length(filter(attached, iface => !plain_ap(iface)))) {"""),
    (r"""		for (let ap in aps)
			set('wireless', ap['.name'], { ssid: default_ssid(uci, board, suffix, custom_ssid), key: custom_key, encryption: band == '6G' ? 'sae+ccmp' : 'psk2+ccmp', ieee80211w: band == '6G' ? '2' : null });""", r"""		let ssid = default_ssid(suffix);
		for (let ap in aps)
			set('wireless', ap['.name'], { ssid, xwrt_managed_ssid: ssid, key: custom_key, encryption: band == '6G' ? 'sae+ccmp' : 'psk2+ccmp', ieee80211w: band == '6G' ? '2' : null });"""),
]
for old, new in patches:
    if new not in source:
        if source.count(old) != 1:
            raise SystemExit('Unsupported Router Tool wireless naming logic')
        source = source.replace(old, new, 1)
wireless.write_text(source)
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
\t\tif (ready)
\t\t\tfor (let config in relay_ap.enable(uci, board, data))
\t\t\t\tchanged[config] = true;
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
\tfor (let config in synchronize(uci, data, upstream, target, board, wireless_pending))
\t\tif (index(changed, config) < 0) push(changed, config);
\tap = uci.get('router-tool', 'main', 'ap_mode') == '1';
"""
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
old_channel = "\t\tlet channel = rband.default_channel ?? \"auto\";\n"
new_channel = old_channel + """\t\t// 5470-5730 MHz (channels 100-144) is unavailable in the CN database.
\t\tif (band_name == \"5G\" && match('' + channel, /^(1[0-3][0-9]|14[0-4])$/))
\t\t\tchannel = 149;
"""
if new not in source:
    if old not in source:
        raise SystemExit('Unsupported wifi-scripts country default')
    source = source.replace(old, new, 1)
if new_channel not in source:
    if source.count(old_channel) != 1:
        raise SystemExit('Unsupported wifi-scripts channel default')
    source = source.replace(old_channel, new_channel, 1)
uc.write_text(source)
PY
fi

# Upgrades keep their old wireless config, so fix 5G country and invalid channels at boot.
WIFI_DEFAULTS=files/etc/uci-defaults/98-xwrt-wifi
mkdir -p files/etc/uci-defaults
cat > "$WIFI_DEFAULTS" <<'EOF'
#!/bin/sh
[ -f /etc/config/wireless ] || exit 0
board="$(cat /tmp/sysinfo/board_name 2>/dev/null)"
changed=
for radio in $(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-device$/\1/p'); do
  [ "$(uci -q get "wireless.$radio.band")" = "5g" ] || continue
  if [ "$(uci -q get "wireless.$radio.country")" != "CN" ]; then
    uci -q set "wireless.$radio.country=CN" && changed=1
  fi
  channel="$(uci -q get "wireless.$radio.channel")"
  case "$channel" in
    ''|auto)
      case "$board" in
        jdcloud,re-cs-02)
          case "$(uci -q get "wireless.$radio.path")" in
            *pci*) channel=36 ;;
            *) channel=149 ;;
          esac
          ;;
        jdcloud,re-ss-01) channel=149 ;;
        *) continue ;;
      esac
      uci -q set "wireless.$radio.channel=$channel" && changed=1
      ;;
    *[!0-9]*) continue ;;
  esac
  if { [ "$channel" -ge 36 ] && [ "$channel" -le 64 ]; } ||
     { [ "$channel" -ge 149 ] && [ "$channel" -le 165 ]; }; then
    :
  else
    uci -q set "wireless.$radio.channel=149" && channel=149 && changed=1
  fi
  htmode="$(uci -q get "wireless.$radio.htmode")"
  if [ "$channel" -ge 149 ]; then
    case "$htmode" in
      *160) uci -q set "wireless.$radio.htmode=${htmode%160}80" && changed=1 ;;
    esac
  elif [ "$board" = "jdcloud,re-cs-02" ]; then
    case "$(uci -q get "wireless.$radio.path")" in
      *pci*)
        case "$htmode" in
          *80) uci -q set "wireless.$radio.htmode=${htmode%80}160" && changed=1 ;;
        esac
        ;;
    esac
  fi
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
