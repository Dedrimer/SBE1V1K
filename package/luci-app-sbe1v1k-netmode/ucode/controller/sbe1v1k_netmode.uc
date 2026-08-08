'use strict';

import { popen, open, stat } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';

const CFG = 'sbe1v1k_netmode';
const STATE_DIR = '/tmp/sbe1v1k-netmode';
const PENDING = STATE_DIR + '/pending';
const RESULT = STATE_DIR + '/result';
const SUBMIT_LOCK = STATE_DIR + '/submit.lock';
const BACKUP_DIR = '/etc/sbe1v1k-netmode-backup';
const APPLY_SCRIPT = '/usr/sbin/sbe1v1k-netmode-apply';
const RESTORE_SCRIPT = '/usr/sbin/sbe1v1k-netmode-restore';
const DHCP_PROBE_SCRIPT = '/usr/libexec/sbe1v1k-dhcp-probe';
const DEFAULT_TIMEOUT = 180;
const MAX_TIMEOUT = 600;
const UPLINK = 'sbe1v1k_wwan';
const RELAY = 'sbe1v1k_relay';

const MODES = [ 'router', 'bypass', 'repeater' ];
const BANDS = [ '2g', '5g', '6g' ];
const ENCS = [ 'none', 'owe', 'psk2', 'sae', 'sae-mixed' ];

function run(cmd)
{
	let fd = popen(cmd);
	let data = '';

	if (!fd)
		return null;

	while (length(data) < 262144) {
		let chunk = fd.read(min(65536, 262144 - length(data)));

		if (chunk == null || chunk == '')
			break;

		data += chunk;
	}

	fd.close();
	return data;
}

function read_text(path)
{
	let fd = open(path, 'r');

	if (!fd)
		return null;

	let data = fd.read(65536);

	fd.close();
	return data;
}

function write_text(path, data)
{
	let fd = open(path, 'w');

	if (!fd)
		return false;

	fd.write(data);
	fd.close();
	return true;
}

function parse_state(data)
{
	let out = {};

	for (let line in split(data ?? '', '\n')) {
		let pos = index(line, '=');

		if (pos > 0)
			out[substr(line, 0, pos)] = substr(line, pos + 1);
	}

	return out;
}

function array_contains(arr, val)
{
	for (let item in arr)
		if (item == val)
			return true;

	return false;
}

function ipv4_parts(s)
{
	if (type(s) != 'string' || s == '')
		return null;

	let m = match(s, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);

	if (m == null)
		return null;

	let out = [];

	for (let i = 1; i <= 4; i++) {
		let octet = int(m[i]);

		if (octet < 0 || octet > 255)
			return null;

		push(out, octet);
	}

	return out;
}

function valid_unicast_ip(s)
{
	let p = ipv4_parts(s);

	return p != null && p[0] > 0 && p[0] < 224 && p[0] != 127;
}

function valid_prefix(s)
{
	if (type(s) != 'string' || !match(s, /^[0-9]+$/))
		return false;

	let n = int(s);

	return n >= 8 && n <= 30;
}

function ip_number(parts)
{
	return parts[0] * 16777216 + parts[1] * 65536 + parts[2] * 256 + parts[3];
}

function subnet_block(prefix)
{
	let block = 1;

	for (let i = int(prefix); i < 32; i++)
		block *= 2;

	return block;
}

function valid_host_ip(s, prefix)
{
	let parts = ipv4_parts(s);

	if (parts == null || !valid_unicast_ip(s))
		return false;

	let block = subnet_block(prefix);
	let host = ip_number(parts) % block;

	return host != 0 && host != block - 1;
}

function same_subnet(a, b, prefix)
{
	let pa = ipv4_parts(a);
	let pb = ipv4_parts(b);

	if (pa == null || pb == null)
		return false;

	let block = subnet_block(prefix);

	return int(ip_number(pa) / block) == int(ip_number(pb) / block);
}

function valid_key(enc, key)
{
	if (enc == 'none' || enc == 'owe')
		return key == null || key == '';

	if (type(key) != 'string')
		return false;

	if (enc == 'psk2' && length(key) == 64)
		return match(key, /^[0-9a-fA-F]{64}$/) != null;

	return length(key) >= 8 && length(key) <= 63;
}

function valid_request_id(id)
{
	return type(id) == 'string' && match(id, /^[0-9a-fA-F-]+$/) != null;
}

function valid_bssid(id)
{
	return type(id) == 'string' && match(id, /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/) != null;
}

function valid_ssid(ssid)
{
	return type(ssid) == 'string' && length(ssid) >= 1 && length(ssid) <= 32 &&
		match(ssid, /[[:cntrl:]]/) == null;
}

function valid_ifname(name)
{
	return type(name) == 'string' && length(name) >= 1 && length(name) <= 15 &&
		match(name, /^[A-Za-z0-9_.-]+$/) != null;
}

function mask_octet_bits(n)
{
	switch (n) {
	case 255: return 8;
	case 254: return 7;
	case 252: return 6;
	case 248: return 5;
	case 240: return 4;
	case 224: return 3;
	case 192: return 2;
	case 128: return 1;
	case 0: return 0;
	default: return null;
	}
}

function netmask_prefix(mask)
{
	let parts = ipv4_parts(mask);
	let prefix = 0;
	let ended = false;

	if (parts == null)
		return null;

	for (let octet in parts) {
		let bits = mask_octet_bits(octet);

		if (bits == null || (ended && bits != 0))
			return null;

		prefix += bits;
		if (bits < 8)
			ended = true;
	}

	return prefix;
}

function radio_for_band(cu, band)
{
	let found = null;

	cu.load('wireless');
	cu.foreach('wireless', 'wifi-device', function(s) {
		let name = s['.name'];

		if (found == null && cu.get('wireless', name, 'band') == band)
			found = name;
	});

	return found;
}

function radio_scan_ifname(ubus, radio)
{
	if (ubus == null || radio == null)
		return null;

	let status = ubus.call('network.wireless', 'status', {});
	let data = type(status) == 'object' ? status[radio] : null;

	if (type(data) != 'object' || type(data.interfaces) != 'array')
		return null;

	for (let iface in data.interfaces)
		if (type(iface.ifname) == 'string' && iface.ifname != '')
			return iface.ifname;

	return null;
}

function scan_encryption(cell)
{
	let methods = cell?.crypto?.key_mgmt ?? [];
	let has_psk = false;
	let has_sae = false;
	let has_owe = false;
	let unsupported = false;

	if (type(methods) != 'array' || length(methods) == 0)
		return 'none';

	for (let method in methods) {
		if (match(method, /OWE/) != null)
			has_owe = true;
		else if (match(method, /SAE/) != null)
			has_sae = true;
		else if (match(method, /PSK/) != null)
			has_psk = true;
		else
			unsupported = true;
	}

	if (unsupported)
		return null;
	if (has_owe)
		return 'owe';
	if (has_sae && has_psk)
		return 'sae-mixed';
	if (has_sae)
		return 'sae';
	if (has_psk)
		return 'psk2';

	return null;
}

function scan_networks(cells, band)
{
	let out = [];
	let iw_band = band == '2g' ? '2.4' : substr(band, 0, 1);

	if (type(cells) != 'array')
		return out;

	for (let cell in cells) {
		let encryption = scan_encryption(cell);
		let supported = encryption != null &&
			(band != '6g' || encryption == 'sae' || encryption == 'owe');

		if (cell.band != iw_band || cell.mode != 'Master' || !valid_ssid(cell.ssid) ||
		    !valid_bssid(cell.bssid))
			continue;

		push(out, {
			ssid: cell.ssid,
			bssid: uc(cell.bssid),
			encryption,
			supported,
			channel: int(cell.channel ?? 0),
			signal: int(cell.dbm ?? -100)
		});

		if (length(out) >= 128)
			break;
	}

	return out;
}

function detect_mode(cu)
{
	let has_relay = false;
	let has_gateway = false;
	let dhcp_ignored = false;

	cu.load('network');
	cu.foreach('network', 'interface', function(s) {
		let name = s['.name'];

		if (cu.get('network', name, 'proto') == 'relay')
			has_relay = true;
	});

	has_gateway = cu.get('network', 'lan', 'gateway') != null;
	cu.load('dhcp');
	dhcp_ignored = cu.get('dhcp', 'lan', 'ignore') == '1';

	if (has_relay)
		return 'repeater';

	if (has_gateway && dhcp_ignored)
		return 'bypass';

	return 'router';
}

function collect_radios(cu)
{
	let out = [];

	cu.load('wireless');
	cu.foreach('wireless', 'wifi-device', function(s) {
		let name = s['.name'];

		push(out, {
			name,
			band: cu.get('wireless', name, 'band'),
			channel: cu.get('wireless', name, 'channel'),
			htmode: cu.get('wireless', name, 'htmode'),
			disabled: cu.get('wireless', name, 'disabled') == '1'
		});
	});

	for (let radio in out) {
		let ifaces = [];

		cu.foreach('wireless', 'wifi-iface', function(s) {
			let name = s['.name'];

			if (cu.get('wireless', name, 'device') != radio.name)
				return;

			push(ifaces, {
				name,
				mode: cu.get('wireless', name, 'mode') ?? 'ap',
				ssid: cu.get('wireless', name, 'ssid'),
				encryption: cu.get('wireless', name, 'encryption'),
				disabled: cu.get('wireless', name, 'disabled') == '1',
				network: cu.get('wireless', name, 'network')
			});
		});

		radio.ifaces = ifaces;
	}

	return out;
}

function interface_dump(ubus)
{
	if (ubus == null)
		return [];

	let response = ubus.call('network.interface', 'dump', {});
	let interfaces = type(response) == 'object' ? response.interface : response;

	return type(interfaces) == 'array' ? interfaces : [];
}

function iface_runtime(interfaces, name)
{
	let out = { up: false, pending: false, addrs: [] };

	if (type(interfaces) != 'array')
		return out;

	for (let iface in interfaces) {
		if (iface.interface != name)
			continue;

		out.up = !!iface.up;
		out.pending = !!iface.pending;

		for (let addr in (iface['ipv4-address'] ?? []))
			push(out.addrs, addr.address + '/' + addr.mask);

		break;
	}

	return out;
}

function collect_pending()
{
	let state = parse_state(read_text(PENDING));

	if (!valid_request_id(state.request_id))
		return { active: false };

	let timeout = int(state.timeout ?? 0);
	let started = int(state.started ?? 0);
	let remaining = null;

	if (timeout > 0 && started > 0)
		remaining = max(0, timeout - int(time() - started));

	return {
		active: true,
		request_id: state.request_id,
		mode: state.mode,
		phase: state.phase ?? 'unknown',
		timeout,
		started,
		remaining
	};
}

function collect_result()
{
	let state = parse_state(read_text(RESULT));

	if (!valid_request_id(state.request_id) || state.status == null)
		return null;

	return {
		request_id: state.request_id,
		status: state.status,
		updated: int(state.updated ?? 0),
		message: state.message ?? ''
	};
}

function collect(cu, ubus)
{
	let interfaces = interface_dump(ubus);
	let saved_key = cu.get(CFG, 'settings', 'key');
	let stored = {
		mode: cu.get(CFG, 'settings', 'mode'),
		lan_ip: cu.get(CFG, 'settings', 'lan_ip'),
		lan_prefix: cu.get(CFG, 'settings', 'lan_prefix'),
		gateway: cu.get(CFG, 'settings', 'gateway'),
		dns: cu.get(CFG, 'settings', 'dns'),
		ssid: cu.get(CFG, 'settings', 'ssid'),
		bssid: cu.get(CFG, 'settings', 'bssid'),
		key_set: type(saved_key) == 'string' && saved_key != '',
		encryption: cu.get(CFG, 'settings', 'encryption'),
		band: cu.get(CFG, 'settings', 'band'),
		timeout: cu.get(CFG, 'settings', 'timeout')
	};

	cu.load('network');
	let lan_ipaddrs = cu.get_all('network', 'lan')?.ipaddr ?? [];

	if (type(lan_ipaddrs) != 'array')
		lan_ipaddrs = [ lan_ipaddrs ];

	let lan = {
		proto: cu.get('network', 'lan', 'proto'),
		device: cu.get('network', 'lan', 'device'),
		gateway: cu.get('network', 'lan', 'gateway'),
		ipaddrs: lan_ipaddrs
	};
	let wan = {
		exists: cu.get('network', 'wan') != null,
		proto: cu.get('network', 'wan', 'proto'),
		disabled: cu.get('network', 'wan', 'disabled') == '1'
	};
	let uplink_name = cu.get('network', UPLINK) != null ? UPLINK : 'wwan';
	let relay_name = cu.get('network', RELAY) != null ? RELAY : 'relay';
	let wwan = {
		exists: cu.get('network', uplink_name) != null,
		proto: cu.get('network', uplink_name, 'proto'),
		ssid: null,
		bssid: null
	};
	let relay = {
		exists: cu.get('network', relay_name) != null,
		networks: cu.get('network', relay_name, 'network')
	};

	cu.load('dhcp');
	let dhcp_lan = {
		exists: cu.get('dhcp', 'lan') != null,
		ignore: cu.get('dhcp', 'lan', 'ignore') == '1'
	};

	cu.load('wireless');
	cu.foreach('wireless', 'wifi-iface', function(s) {
		let name = s['.name'];

		if (name == 'sbe1v1k_sta' || (wwan.ssid == null && cu.get('wireless', name, 'mode') == 'sta')) {
			wwan.ssid = cu.get('wireless', name, 'ssid');
			wwan.bssid = cu.get('wireless', name, 'bssid');
		}
	});

	return {
		generated: time(),
		mode: detect_mode(cu),
		stored,
		lan: { ...lan, runtime: iface_runtime(interfaces, 'lan') },
		wan: { ...wan, runtime: iface_runtime(interfaces, 'wan') },
		wwan: { ...wwan, runtime: iface_runtime(interfaces, uplink_name) },
		relay,
		dhcp_lan,
		radios: collect_radios(cu),
		pending: collect_pending(),
		result: collect_result(),
		backup: stat(BACKUP_DIR) != null
	};
}

function json_error(message)
{
	http.write_json({ ok: false, error: message });
}

return {
	action_status: function()
	{
		let cu = cursor();
		let ubus = connect();

		cu.load(CFG);
		http.prepare_content('application/json');
		http.write_json(collect(cu, ubus));
	},

	action_dhcp_probe: function()
	{
		http.prepare_content('application/json');

		if (collect_pending().active) {
			json_error('网络切换进行中，暂时不能探测 DHCP');
			return;
		}

		let offer = parse_state(run(DHCP_PROBE_SCRIPT) ?? '');

		if (offer.error != null) {
			let message = offer.error == 'busy'
				? '另一个 DHCP 探测正在进行'
				: (offer.error == 'unavailable'
					? '系统缺少 DHCP 客户端，无法执行探测'
					: '未收到上游 DHCP 响应，请确认上游网线已接入 LAN 口');
			json_error(message);
			return;
		}

		let prefix = netmask_prefix(offer.subnet);
		let prefix_text = prefix == null ? '' : '' + prefix;
		let gateway = offer.router;
		let dns = offer.dns ?? '';

		if (!valid_prefix(prefix_text) || !valid_host_ip(offer.ip, prefix_text) ||
		    !valid_host_ip(gateway, prefix_text) ||
		    !same_subnet(offer.ip, gateway, prefix_text) || offer.ip == gateway ||
		    (dns != '' && !valid_unicast_ip(dns))) {
			json_error('上游 DHCP 返回了无效或不兼容的 IPv4 配置');
			return;
		}

		let interfaces = interface_dump(connect());
		let local = iface_runtime(interfaces, 'lan');

		for (let address in local.addrs) {
			let slash = index(address, '/');
			let ip = slash > 0 ? substr(address, 0, slash) : address;

			if (offer.serverid == ip || gateway == ip) {
				json_error('探测到了本机 DHCP 服务而不是上游路由器，请检查接线');
				return;
			}
		}

		http.write_json({
			ok: true,
			lan_ip: offer.ip,
			lan_prefix: prefix_text,
			gateway,
			dns: dns != '' ? dns : gateway,
			server: offer.serverid ?? '',
			lease: int(offer.lease ?? 0)
		});
	},

	action_wifi_scan: function()
	{
		http.prepare_content('application/json');

		if (collect_pending().active) {
			json_error('网络切换进行中，暂时不能扫描 Wi-Fi');
			return;
		}

		let band = http.formvalue('band');
		if (!array_contains(BANDS, band)) {
			json_error('无线频段无效');
			return;
		}

		let cu = cursor();
		let ubus = connect();
		let radio = radio_for_band(cu, band);
		let ifname = radio_scan_ifname(ubus, radio);

		if (!valid_ifname(ifname)) {
			json_error('所选频段没有正在运行的无线接口，请先启用该频段');
			return;
		}

		let raw = run('/usr/bin/iwinfo -j ' + ifname + ' scan 2>/dev/null');
		let cells = raw == null || trim(raw) == '' ? null : json(raw);
		if (type(cells) != 'array') {
			json_error('无线扫描失败，请稍后重试');
			return;
		}

		http.write_json({ ok: true, band, radio, results: scan_networks(cells, band) });
	},

	action_apply: function()
	{
		http.prepare_content('application/json');

		if (collect_pending().active) {
			json_error('已有网络切换正在进行，请先确认或回滚');
			return;
		}

		let mode = http.formvalue('mode');
		let lan_ip = http.formvalue('lan_ip');
		let lan_prefix = http.formvalue('lan_prefix');
		let gateway = http.formvalue('gateway');
		let dns = http.formvalue('dns');
		let ssid = http.formvalue('ssid');
		let bssid = http.formvalue('bssid');
		let key = http.formvalue('key');
		let encryption = http.formvalue('encryption');
		let band = http.formvalue('band');
		let timeout = int(http.formvalue('timeout') ?? '');
		let cu = cursor();

		cu.load(CFG);
		if (type(timeout) != 'int' || timeout < 30 || timeout > MAX_TIMEOUT)
			timeout = DEFAULT_TIMEOUT;

		if (!array_contains(MODES, mode)) {
			json_error('无效的网络模式');
			return;
		}

		if (!valid_prefix(lan_prefix) || !valid_host_ip(lan_ip, lan_prefix)) {
			json_error('LAN IP 必须是所选子网中的有效主机地址');
			return;
		}

		if (mode == 'bypass') {
			if (!valid_host_ip(gateway, lan_prefix) || !same_subnet(lan_ip, gateway, lan_prefix) || gateway == lan_ip) {
				json_error('主路由网关必须与 LAN IP 同网段且不能相同');
				return;
			}

			if (dns != null && dns != '' && !valid_unicast_ip(dns)) {
				json_error('DNS 地址格式不正确');
				return;
			}
		}

		if (mode == 'repeater') {
			if (!valid_ssid(ssid)) {
				json_error('上游 Wi-Fi SSID 必须为 1–32 字节且不能包含控制字符');
				return;
			}

			if (!array_contains(BANDS, band) || !array_contains(ENCS, encryption)) {
				json_error('无线频段或加密方式无效');
				return;
			}

			if (bssid != null && bssid != '' && !valid_bssid(bssid)) {
				json_error('所选 Wi-Fi BSSID 格式无效');
				return;
			}

			if (band == '6g' && encryption != 'sae' && encryption != 'owe') {
				json_error('6 GHz 上行仅支持 WPA3-SAE 或 OWE');
				return;
			}

			if ((key == null || key == '') && encryption != 'none' && encryption != 'owe' &&
			    ssid == cu.get(CFG, 'settings', 'ssid'))
				key = cu.get(CFG, 'settings', 'key');

			if (!valid_key(encryption, key)) {
				json_error('Wi-Fi 密码无效：应为 8–63 字符，WPA2 也可使用 64 位十六进制 PSK');
				return;
			}

			if (encryption == 'none' || encryption == 'owe')
				key = '';
		}

		system('mkdir -p ' + STATE_DIR);
		if (system('mkdir ' + SUBMIT_LOCK + ' 2>/dev/null') != 0) {
			json_error('另一个网络切换请求正在提交，请稍后重试');
			return;
		}

		if (collect_pending().active) {
			system('rmdir ' + SUBMIT_LOCK + ' 2>/dev/null');
			json_error('已有网络切换正在进行，请先确认或回滚');
			return;
		}

		cu.set(CFG, 'settings', 'mode', mode);
		cu.set(CFG, 'settings', 'lan_ip', lan_ip);
		cu.set(CFG, 'settings', 'lan_prefix', lan_prefix);
		cu.set(CFG, 'settings', 'timeout', '' + timeout);

		if (mode == 'bypass') {
			cu.set(CFG, 'settings', 'gateway', gateway);
			cu.set(CFG, 'settings', 'dns', dns ?? '');
		}

		if (mode == 'repeater') {
			cu.set(CFG, 'settings', 'ssid', ssid);
			cu.set(CFG, 'settings', 'bssid', bssid ?? '');
			cu.set(CFG, 'settings', 'key', key ?? '');
			cu.set(CFG, 'settings', 'encryption', encryption);
			cu.set(CFG, 'settings', 'band', band);
		}

		cu.save(CFG);
		cu.commit(CFG);
		system('chmod 600 /etc/config/' + CFG + ' 2>/dev/null');

		let request_id = trim(run('cat /proc/sys/kernel/random/uuid 2>/dev/null') ?? '');

		if (!valid_request_id(request_id))
			request_id = sprintf('%x-%x', time(), time() % 65535);

		system('rm -f ' + RESULT);

		let pending = 'request_id=' + request_id + '\n' +
			'mode=' + mode + '\n' +
			'timeout=' + timeout + '\n' +
			'started=0\nphase=queued\n';

		if (!write_text(PENDING, pending)) {
			system('rmdir ' + SUBMIT_LOCK + ' 2>/dev/null');
			json_error('无法创建网络切换状态');
			return;
		}

		let rc = system('(sleep 2; setsid ' + APPLY_SCRIPT + ' ' + request_id + ' >/dev/null 2>&1) &');

		if (rc != 0) {
			system('rm -f ' + PENDING);
			system('rmdir ' + SUBMIT_LOCK + ' 2>/dev/null');
			json_error('无法启动网络切换任务');
			return;
		}

		system('rmdir ' + SUBMIT_LOCK + ' 2>/dev/null');
		http.write_json({ ok: true, timeout, request_id });
	},

	action_confirm: function()
	{
		http.prepare_content('application/json');
		let request_id = http.formvalue('request_id');
		let pending = collect_pending();

		if (!pending.active) {
			http.write_json({ ok: true, already: true });
			return;
		}

		if (!valid_request_id(request_id) || request_id != pending.request_id) {
			json_error('请求已过期，请刷新页面');
			return;
		}

		if (pending.phase != 'applied') {
			json_error('配置尚未完成应用，暂时不能确认');
			return;
		}

		let rc = system(RESTORE_SCRIPT + ' --confirm ' + request_id + ' >/dev/null 2>&1');

		if (rc != 0) {
			json_error('确认失败，回滚保护仍保持启用');
			return;
		}

		http.write_json({ ok: true });
	},

	action_revert: function()
	{
		http.prepare_content('application/json');
		let request_id = http.formvalue('request_id');
		let pending = collect_pending();

		if (!pending.active) {
			http.write_json({ ok: true, already: true });
			return;
		}

		if (!valid_request_id(request_id) || request_id != pending.request_id) {
			json_error('请求已过期，请刷新页面');
			return;
		}

		let rc = system('(setsid ' + RESTORE_SCRIPT + ' ' + request_id + ' manual >/dev/null 2>&1) &');

		if (rc != 0) {
			json_error('无法启动回滚任务');
			return;
		}

		http.write_json({ ok: true });
	}
};
