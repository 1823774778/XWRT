'use strict';

import { equal } from './snapshot.uc';

function array(value) {
	return type(value) == 'array' ? value : value == null ? [] : [ value ];
}

function section_values(section) {
	let result = {};
	for (let key, value in section || {})
		if (substr(key, 0, 1) != '.') result[key] = value;
	return result;
}

function sections(uci, config, type_name) {
	let result = [];
	uci.foreach(config, type_name, section => push(result, section));
	return result;
}

function configuration(uci) {
	let result = {};
	for (let config in [ 'network', 'dhcp', 'firewall', 'wireless' ])
		result[config] = uci.get_all(config) || {};
	return result;
}

function set_option(uci, config, sid, key, value) {
	let previous = uci.get(config, sid, key);
	if (equal(previous, value)) return;
	if (value == null) {
		if (previous != null && !uci.delete(config, sid, key))
			die(`Cannot remove ${config}.${sid}.${key}`);
	}
	else if (!uci.set(config, sid, key, value)) {
		die(`Cannot set ${config}.${sid}.${key}`);
	}
}

function set_options(uci, config, sid, values) {
	if (sid == null) return;
	for (let key, value in values)
		set_option(uci, config, sid, key, value);
}

function ensure(uci, config, type_name, sid) {
	let section = uci.get_all(config, sid);
	if (section && section['.type'] != type_name)
		die(`Relay AP refused: section type changed at ${config}.${sid}`);
	if (!section && !uci.set(config, sid, type_name))
		die(`Cannot create ${config}.${sid}`);
	return sid;
}

function find_unique(uci, config, type_name, predicate) {
	let found = filter(sections(uci, config, type_name), predicate);
	if (length(found) > 1)
		die(`Relay AP refused: ambiguous ${config}.${type_name} sections`);
	return found[0]?.['.name'];
}

function reserve(uci, config, type_name, sid) {
	if (uci.get_all(config, sid))
		die(`Relay AP refused: reserved section already exists at ${config}.${sid}`);
	return ensure(uci, config, type_name, sid);
}

function append_unique(result, value) {
	if (value && index(result, value) < 0) push(result, value);
}

function board_ports(board, name) {
	let section = board?.network?.[name];
	return array(section?.ports || section?.device);
}

function topology(uci, board) {
	let device = uci.get('network', 'lan', 'device') || 'br-lan';
	let bridge_id = find_unique(uci, 'network', 'device', section => section.name == device && section.type == 'bridge');
	let bridge = bridge_id ? uci.get_all('network', bridge_id) : null;
	let bridge_name = bridge ? device : 'br-lan';
	let wan = uci.get('network', 'wan', 'device') || board_ports(board, 'wan')[0];
	let ports = [];
	if (bridge) {
		for (let port in array(bridge.ports)) append_unique(ports, port);
	}
	else {
		for (let port in board_ports(board, 'lan')) append_unique(ports, port);
		if (device != bridge_name) append_unique(ports, device);
	}
	for (let name in keys(board?.network || {}))
		for (let port in board_ports(board, name)) append_unique(ports, port);
	append_unique(ports, wan);
	return { bridge, bridge_name, wan, ports };
}

function validate_topology(uci, board, topo) {
	if (!length(keys(board?.network || {})))
		die('Relay AP refused: board Ethernet assignments are unavailable');
	if (!topo.wan || substr(topo.wan, 0, 1) == '@')
		die('Relay AP refused: the Ethernet WAN device is unknown');
	if (!length(topo.ports))
		die('Relay AP refused: no Ethernet ports were found');
	if (length(sections(uci, 'network', 'switch')) || length(sections(uci, 'network', 'switch_vlan')))
		die('Relay AP refused: switch VLAN topology requires manual configuration');
	for (let section in sections(uci, 'network', 'bridge-vlan'))
		if (section.device == topo.bridge_name)
			die('Relay AP refused: bridge VLAN topology requires manual configuration');
	for (let section in sections(uci, 'network', 'device')) {
		if (section.name == topo.bridge_name) continue;
		for (let port in array(section.ports))
			if (index(topo.ports, port) >= 0)
				die('Relay AP refused: an Ethernet port belongs to another device');
		if (index(topo.ports, section.name) >= 0 && section.type &&
			index([ '8023', 'ethernet' ], section.type) < 0)
			die('Relay AP refused: an Ethernet port has an incompatible device type');
	}
	for (let port in topo.ports)
		if (match(port, /[.@:]/) || port == topo.bridge_name || match(port, /^(br-|wlan|phy)/))
			die('Relay AP refused: the Ethernet topology is not a plain bridge');
}

function firewall_zone(uci, name) {
	let existing = find_unique(uci, 'firewall', 'zone', section => section.name == name);
	return existing || reserve(uci, 'firewall', 'zone', 'router_tool_' + name);
}

function configure_firewall(uci, role, data) {
	let lan = firewall_zone(uci, 'lan');
	let wan = firewall_zone(uci, 'wan');
	for (let section in sections(uci, 'firewall', 'zone')) {
		let networks = filter(array(uci.get('firewall', section['.name'], 'network')),
			name => index([ 'lan', 'wan', 'wan6' ], name) < 0);
		if (section['.name'] == lan) {
			push(networks, 'lan');
			if (role == 'relay_ap') push(networks, 'wan6');
		}
		if (section['.name'] == wan && role != 'relay_ap') push(networks, 'wan', 'wan6');
		set_option(uci, 'firewall', section['.name'], 'network', length(networks) ? networks : null);
	}
	for (let name, sid in { lan, wan })
		set_options(uci, 'firewall', sid, { name, ...data.zones[name], ...(role == 'relay_ap' ? { masq: '0' } : {}) });
	for (let section in sections(uci, 'firewall', 'defaults'))
		set_option(uci, 'firewall', section['.name'], 'disable_ipv6', null);
	let forwarding = find_unique(uci, 'firewall', 'forwarding', section => section.src == 'lan' && section.dest == 'wan');
	forwarding = forwarding || reserve(uci, 'firewall', 'forwarding', 'router_tool_lan_wan');
	set_options(uci, 'firewall', forwarding, { src: 'lan', dest: 'wan', enabled: role == 'relay_ap' ? '0' : '1', family: null });
	for (let name, values in data.rules || {}) {
		let existing = find_unique(uci, 'firewall', 'rule', section => section.name == name);
		if (!existing && role == 'relay_ap') continue;
		let sid = existing || reserve(uci, 'firewall', 'rule', 'router_tool_' + lc(replace(name, /-/g, '_')));
		if (role == 'relay_ap') set_option(uci, 'firewall', sid, 'enabled', '0');
		else set_options(uci, 'firewall', sid, { name, enabled: '1', src: 'wan', target: 'ACCEPT', src_ip: null, dest_ip: null, ...values });
	}
}

function subnet(value, netmask) {
	let parts = split('' + value, '/');
	if (length(parts) > 2) return null;
	let octets = split(parts[0], '.');
	if (length(octets) != 4 || length(filter(octets, part => !match(part, /^\d+$/) || int(part) > 255))) return null;
	if (length(parts) > 1 && !match(parts[1], /^\d+$/)) return null;
	let prefix = length(parts) > 1 ? int(parts[1]) : 32;
	if (length(parts) < 2 && netmask) {
		let masks = split(netmask, '.');
		if (length(masks) != 4) return null;
		let mask = 0;
		for (let part in masks) {
			if (!match(part, /^\d+$/) || int(part) > 255) return null;
			mask = (mask << 8) | int(part);
		}
		prefix = 0;
		while (prefix < 32 && (mask & (1 << (31 - prefix)))) prefix++;
		if ((mask & 0xffffffff) != (prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff)) return null;
	}
	if (prefix < 0 || prefix > 32) return null;
	let address = 0;
	for (let part in octets) address = (address << 8) | int(part);
	return { address: address & 0xffffffff, prefix };
}

function overlap(a, b) {
	let prefix = min(a.prefix, b.prefix);
	let mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;
	return (a.address & mask) == (b.address & mask);
}

export function has_conflict(uci, upstream4) {
	if (uci.get('network', 'lan', 'proto') != 'static') return false;
	let upstream = filter(map(upstream4 || [], address => subnet(address)), address => address != null);
	let lan = filter(map(array(uci.get('network', 'lan', 'ipaddr')),
		address => subnet(address, uci.get('network', 'lan', 'netmask'))), address => address != null);
	return length(lan) && length(upstream) && length(filter(lan, local => length(filter(upstream, remote => overlap(local, remote)))));
}

function keys_unique(a, b) {
	let result = [];
	for (let key in keys(a || {})) if (index(result, key) < 0) push(result, key);
	for (let key in keys(b || {})) if (index(result, key) < 0) push(result, key);
	return result;
}

function make_snapshot(before, uci) {
	let state = { version: 1, mode: 'ap', options: [], created: [], subnet_done: true };
	for (let config in [ 'network', 'dhcp', 'firewall', 'wireless' ]) {
		let old_config = before[config] || {};
		let new_config = uci.get_all(config) || {};
		for (let sid, section in new_config) {
			let old_section = old_config[sid];
			if (!old_section) {
				push(state.created, { config, sid, type: section['.type'], values: section_values(section) });
				continue;
			}
			if (old_section['.type'] != section['.type'])
				die(`Relay AP refused: section type changed at ${config}.${sid}`);
			let old_values = section_values(old_section);
			let new_values = section_values(section);
			for (let key in keys_unique(old_values, new_values)) {
				let old_value = old_values[key];
				let new_value = new_values[key];
				if (equal(old_value, new_value)) continue;
				push(state.options, { config, sid, key, type: section['.type'], value: old_value ?? null, expected: new_value ?? null });
			}
		}
	}
	if (!length(state.options) && !length(state.created))
		die('Relay AP refused: no configuration changes were generated');
	return state;
}

export function enable(uci, board, data) {
	let before = configuration(uci);
	let topo = topology(uci, board);
	validate_topology(uci, board, topo);
	for (let name in [ 'lan', 'wan', 'wan6' ]) ensure(uci, 'network', 'interface', name);
	let bridge = topo.bridge?.['.name'] || ensure(uci, 'network', 'device', 'router_tool_bridge');
	set_options(uci, 'network', bridge, { name: topo.bridge_name, type: 'bridge', ports: topo.ports });
	set_options(uci, 'network', 'wan', { proto: 'none', device: null, disabled: '1', auto: '0' });
	for (let section in sections(uci, 'network', 'interface'))
		if (index([ 'lan', 'wan', 'wan6' ], section['.name']) < 0 && index(topo.ports, uci.get('network', section['.name'], 'device')) >= 0)
			set_options(uci, 'network', section['.name'], { disabled: '1', auto: '0' });
	set_options(uci, 'network', 'lan', { device: topo.bridge_name, proto: 'dhcp', ipaddr: null, netmask: null, gateway: null, dns: null,
		ip6addr: null, ip6gw: null, ip6assign: null, ip6class: null, ip6ifaceid: null, ipv6: '0', delegate: '0', disabled: null,
		peerdns: '1', defaultroute: '1', auto: '1' });
	set_options(uci, 'network', 'wan6', { proto: 'dhcpv6', device: topo.bridge_name, reqaddress: 'try', reqprefix: 'no', delegate: '0',
		defaultroute: '1', peerdns: '1', noslaaconly: '0', forceprefix: '0', disabled: null, auto: '1' });
	for (let name in [ 'lan', 'wan', 'wan6' ]) {
		ensure(uci, 'dhcp', 'dhcp', name);
		set_options(uci, 'dhcp', name, { interface: name, ignore: '1', dhcpv4: 'disabled', ra: 'disabled', dhcpv6: 'disabled', ndp: 'disabled', master: '0', ndproxy_routing: null });
	}
	for (let section in sections(uci, 'wireless', 'wifi-iface')) {
		let networks = array(uci.get('wireless', section['.name'], 'network'));
		if (index([ 'ap', 'ap-wds' ], uci.get('wireless', section['.name'], 'mode')) >= 0 &&
			length(filter(networks, name => index([ 'lan', 'wan', 'wan6' ], name) >= 0))) {
			let mapped = [];
			for (let name in networks) append_unique(mapped, index([ 'wan', 'wan6' ], name) >= 0 ? 'lan' : name);
			set_option(uci, 'wireless', section['.name'], 'network', mapped);
		}
	}
	configure_firewall(uci, 'relay_ap', data.firewall);
	let state = make_snapshot(before, uci);
	uci.set('router-tool', 'main', 'ap_state', sprintf('%J', state));
	uci.set('router-tool', 'main', 'ap_mode', '1');
	return [ 'network', 'dhcp', 'firewall', 'wireless', 'router-tool' ];
}
