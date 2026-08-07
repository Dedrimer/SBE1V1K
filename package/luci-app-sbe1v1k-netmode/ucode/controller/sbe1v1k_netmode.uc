'use strict';

/*
 * SBE1V1K network mode switch backend.
 *
 * Modes:
 *   router   - classic OpenWrt main router (LAN bridge + DHCP + WAN)
 *   bypass   - LAN bridge with static IP + gateway pointing at the main
 *              router, DHCP handled by the upstream router
 *   repeater - one radio joins the upstream Wi-Fi (station), LAN is relayed
 *              onto the same subnet through relayd
 *
 * Applying a mode stores the parameters in /etc/config/sbe1v1k_netmode and
 * runs /usr/sbin/sbe1v1k-netmode-apply in the background.  The apply script
 * takes a snapshot of network/wireless/dhcp and arms a rollback watchdog so
 * a broken switch can never lock the user out permanently.
 */

import { popen, open, stat } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';

const CFG = 'sbe1v1k_netmode';
const STATE_DIR = '/tmp/sbe1v1k-netmode';
const PENDING = STATE_DIR + '/pending';
const WATCHDOG_PID = STATE_DIR + '/watchdog.pid';
const BACKUP_DIR = '/etc/sbe1v1k-netmode-backup';
const APPLY_SCRIPT = '/usr/sbin/sbe1v1k-netmode-apply';
const RESTORE_SCRIPT = '/usr/sbin/sbe1v1k-netmode-restore';
const DEFAULT_TIMEOUT = 180;

const MODES = [ 'router', 'bypass', 'repeater' ];
const BANDS = [ '2g', '5g', '6g' ];
const ENCS = [ 'none', 'psk2', 'sae', 'sae-mixed' ];

function run(cmd)
{
	let fd = popen(cmd);

	if (!fd)
		return null;

	let data = fd.read(65536);

	fd.close();
	return data ?? '';
}

function read_text(path)
{
	let fd = open(path, 'r');

	if (!fd)
		return null;

	let data = fd.read(4096);

	fd.close();
	return data;
}

function valid_ip(s)
{
	if (type(s) != 'string' || s == '')
		return false;

	let m = match(s, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);

	if (m == null)
		return false;

	for (let i = 1; i <= 4; i++)
		if (int(m[i]) > 255)
			return false;

	return true;
}

function valid_prefix(s)
{
	if (type(s) != 'string' || !match(s, /^[0-9]+$/))
		return false;

	let n = int(s);

	return n >= 8 && n <= 30;
}

function valid_band(s)
{
	for (let b in BANDS)
		if (s == b)
			return true;

	return false;
}

function valid_enc(s)
{
	for (let e in ENCS)
		if (s == e)
			return true;

	return false;
}

function array_contains(arr, val)
{
	for (let x in arr)
		if (x == val)
			return true;

	return false;
}

/*
 * Detect the effective mode from the live UCI config, independently of what
 * the plugin previously stored.
 */
function detect_mode(cu)
{
	let has_sta = false;
	let has_relay = false;
	let has_gw = false;

	cu.load('network');
	cu.foreach('network', 'interface', function(s) {
		let name = s['.name'];

		if (cu.get('network', name, 'proto') == 'relay')
			has_relay = true;
		else if (name == 'lan' && cu.get('network', 'lan', 'gateway') != null)
			has_gw = true;
	});

	cu.load('wireless');
	cu.foreach('wireless', 'wifi-iface', function(s) {
		if (cu.get('wireless', s['.name'], 'mode') == 'sta')
			has_sta = true;
	});

	if (has_relay || has_sta)
		return 'repeater';

	if (has_gw)
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

	for (let r in out) {
		let ifaces = [];

		cu.load('wireless');
		cu.foreach('wireless', 'wifi-iface', function(s) {
			let name = s['.name'];

			if (cu.get('wireless', name, 'device') != r.name)
				return;

			push(ifaces, {
				mode: cu.get('wireless', name, 'mode') ?? 'ap',
				ssid: cu.get('wireless', name, 'ssid'),
				encryption: cu.get('wireless', name, 'encryption'),
				disabled: cu.get('wireless', name, 'disabled') == '1',
				network: cu.get('wireless', name, 'network')
			});
		});

		r.ifaces = ifaces;
	}

	return out;
}

function iface_runtime(ubus, name)
{
	let out = { up: false, addrs: [] };

	if (ubus == null)
		return out;

	let dump = ubus.call('network.interface', 'dump', {});

	if (type(dump) != 'array')
		return out;

	for (let i in dump) {
		if (dump[i].interface != name)
			continue;

		out.up = !!dump[i].up;
		out.pending = !!dump[i].pending;

		for (let a in (dump[i]['ipv4-address'] ?? []))
			push(out.addrs, a.address + '/' + a.mask);

		break;
	}

	return out;
}

function collect_pending()
{
	let data = read_text(PENDING);

	if (data == null || trim(data) == '')
		return { active: false };

	let m = match(data, /mode=([a-z]+) timeout=([0-9]+) started=([0-9]+)/);
	let timeout = 0;
	let remaining = null;

	if (m == null) {
		m = match(data, /mode=([a-z]+) timeout=([0-9]+)/);

		if (m == null)
			return { active: true };

		timeout = int(m[2]);
	}
	else {
		timeout = int(m[2]);
		remaining = max(0, timeout - int(time() - int(m[3])));
	}

	return {
		active: true,
		mode: m[1],
		timeout,
		remaining
	};
}

function collect(cu, ubus)
{
	let stored = {
		mode: cu.get(CFG, 'settings', 'mode'),
		lan_ip: cu.get(CFG, 'settings', 'lan_ip'),
		lan_prefix: cu.get(CFG, 'settings', 'lan_prefix'),
		gateway: cu.get(CFG, 'settings', 'gateway'),
		dns: cu.get(CFG, 'settings', 'dns'),
		ssid: cu.get(CFG, 'settings', 'ssid'),
		key: cu.get(CFG, 'settings', 'key'),
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
	let wwan = {
		exists: cu.get('network', 'wwan') != null,
		proto: cu.get('network', 'wwan', 'proto')
	};
	let relay = {
		exists: cu.get('network', 'relay') != null,
		networks: cu.get('network', 'relay', 'network')
	};

	cu.load('dhcp');
	let dhcp_lan = {
		exists: cu.get('dhcp', 'lan') != null,
		ignore: cu.get('dhcp', 'lan', 'ignore') == '1'
	};

	let mode = stored.mode != null && (stored.mode == 'router' || stored.mode == 'bypass' || stored.mode == 'repeater')
		? stored.mode
		: detect_mode(cu);

	return {
		generated: time(),
		mode,
		stored,
		lan: { ...lan, runtime: iface_runtime(ubus, 'lan') },
		wan: { ...wan, runtime: iface_runtime(ubus, 'wan') },
		wwan: { ...wwan, runtime: iface_runtime(ubus, 'wwan'), ssid: null },
		relay,
		dhcp_lan,
		radios: collect_radios(cu),
		pending: collect_pending(),
		backup: stat(BACKUP_DIR) != null
	};
}

return {
	action_status: function()
	{
		let cu = cursor();
		let ubus = connect();

		cu.load(CFG);

		let data = collect(cu, ubus);

		// enrich wwan with the sta ssid from wireless config
		cu.load('wireless');
		cu.foreach('wireless', 'wifi-iface', function(s) {
			if (cu.get('wireless', s['.name'], 'mode') == 'sta')
				data.wwan.ssid = cu.get('wireless', s['.name'], 'ssid');
		});

		http.prepare_content('application/json');
		http.write_json(data);
	},

	action_apply: function()
	{
		http.prepare_content('application/json');

		let mode = http.formvalue('mode');
		let lan_ip = http.formvalue('lan_ip');
		let lan_prefix = http.formvalue('lan_prefix');
		let gateway = http.formvalue('gateway');
		let dns = http.formvalue('dns');
		let ssid = http.formvalue('ssid');
		let key = http.formvalue('key');
		let encryption = http.formvalue('encryption');
		let band = http.formvalue('band');
		let timeout = int(http.formvalue('timeout') ?? '');

		if (type(timeout) != 'int' || timeout < 30)
			timeout = DEFAULT_TIMEOUT;

		if (!array_contains(MODES, mode)) {
			http.write_json({ ok: false, error: '无效的网络模式' });
			return;
		}

		if (!valid_ip(lan_ip)) {
			http.write_json({ ok: false, error: 'LAN IP 地址格式不正确' });
			return;
		}

		if (!valid_prefix(lan_prefix)) {
			http.write_json({ ok: false, error: '子网前缀长度无效（8-30）' });
			return;
		}

		if (mode == 'bypass') {
			if (!valid_ip(gateway)) {
				http.write_json({ ok: false, error: '请填写主路由的网关 IP' });
				return;
			}

			if (dns != null && dns != '' && !valid_ip(dns)) {
				http.write_json({ ok: false, error: 'DNS 地址格式不正确' });
				return;
			}
		}

		if (mode == 'repeater') {
			if (ssid == null || ssid == '') {
				http.write_json({ ok: false, error: '请填写要连接的上游 Wi-Fi SSID' });
				return;
			}

			if (!valid_band(band)) {
				http.write_json({ ok: false, error: '请选择用于中继的频段' });
				return;
			}

			if (!valid_enc(encryption)) {
				http.write_json({ ok: false, error: '加密方式无效' });
				return;
			}

			if (encryption != 'none' && (key == null || length(key) < 8)) {
				http.write_json({ ok: false, error: 'Wi-Fi 密码至少需要 8 个字符' });
				return;
			}
		}

		let cu = cursor();

		cu.load(CFG);
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
			cu.set(CFG, 'settings', 'key', key ?? '');
			cu.set(CFG, 'settings', 'encryption', encryption);
			cu.set(CFG, 'settings', 'band', band);
		}

		cu.save(CFG);
		cu.commit(CFG);

		// Cancel any previous rollback and arm the pending marker immediately,
		// so confirm/revert work even before the apply script starts.
		run('rm -f ' + PENDING + '; [ -f ' + WATCHDOG_PID + ' ] && kill $(cat ' + WATCHDOG_PID + ') 2>/dev/null; rm -f ' + WATCHDOG_PID);
		run('echo "mode=' + mode + ' timeout=' + timeout + ' started=' + time() + '" > ' + PENDING);

		// Run the apply script detached one second later so the HTTP
		// response reaches the browser before the network is restarted.
		system('(sleep 1; setsid ' + APPLY_SCRIPT + ' >/dev/null 2>&1 &)');

		http.write_json({ ok: true, timeout });
	},

	action_confirm: function()
	{
		http.prepare_content('application/json');

		if (read_text(PENDING) == null) {
			http.write_json({ ok: true, already: true });
			return;
		}

		let pid = read_text(WATCHDOG_PID);

		if (pid != null)
			run('kill ' + trim(pid) + ' 2>/dev/null');

		run('rm -f ' + PENDING + ' ' + WATCHDOG_PID);
		run('rm -rf ' + BACKUP_DIR);

		http.write_json({ ok: true });
	},

	action_revert: function()
	{
		http.prepare_content('application/json');

		if (read_text(PENDING) == null) {
			http.write_json({ ok: true, already: true });
			return;
		}

		system('setsid ' + RESTORE_SCRIPT + ' >/dev/null 2>&1 &');

		http.write_json({ ok: true });
	}
};