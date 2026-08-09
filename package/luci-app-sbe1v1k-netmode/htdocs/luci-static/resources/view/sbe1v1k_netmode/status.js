'use strict';

'require view';

/*
 * SBE1V1K 网络模式快速切换前端。
 * 支持 主路由 / 旁路由 / 中继 三种模式的一键切换，
 * 应用后会自动启用回滚看门狗，避免切换失败导致设备失联。
 */

const BASE = L.url('admin/network/sbe1v1k_netmode');

const MODE_LABELS = {
	router:   _('主路由'),
	bypass:   _('旁路由'),
	repeater: _('中继')
};

const MODE_DESCS = {
	router:   _('标准 OpenWrt 主路由：LAN 桥接 + DHCP，WAN 接上级光猫/交换机'),
	bypass:   _('关闭 DHCP，可从上游 DHCP 自动读取地址后转为固定配置'),
	repeater: _('扫描并选择上游 Wi-Fi，有线 + 无线客户端共享上游网络')
};

const BAND_LABELS = {
	'2g': '2.4 GHz',
	'5g': '5 GHz',
	'6g': '6 GHz'
};

const ENC_LABELS = {
	'none':      _('无加密 (开放)'),
	'owe':       _('OWE (增强型开放)'),
	'psk2':      'WPA2-PSK',
	'sae':       'WPA3-SAE',
	'sae-mixed': 'WPA2/WPA3 混合'
};

function plain(s)
{
	return String(s ?? '');
}

function csrfToken()
{
	return (typeof L !== 'undefined' && L.env && L.env.token) ? L.env.token : '';
}

function api(url, params)
{
	var body = new URLSearchParams();
	body.append('token', csrfToken());

	if (params)
		for (var k in params)
			body.append(k, params[k]);

	return fetch(BASE + url, {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest' },
		body: body.toString()
	}).then(function(r) {
		if (!r.ok)
			throw new Error('HTTP ' + r.status);
		return r.json();
	});
}

function fetchStatus()
{
	return fetch(BASE + '/status', {
		headers: { 'X-Requested-With': 'XMLHttpRequest' }
	}).then(function(r) {
		if (!r.ok)
			throw new Error('HTTP ' + r.status);
		return r.json();
	});
}

function badge(ok, text)
{
	return E('span', { 'class': ok ? 'sbe1v1k-ok' : 'sbe1v1k-bad' }, [ text ]);
}

function section(title, body)
{
	return E('div', { 'class': 'cbi-section-node' }, [
		E('h3', {}, [ title ])
	].concat(Array.isArray(body) ? body : [ body ]));
}

function kvRows(rows)
{
	return rows.map(function(row) {
		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ row[0] ]),
			E('div', { 'class': 'cbi-value-field' }, [ row[1] ])
		]);
	});
}

function fmtMode(mode)
{
	return MODE_LABELS[mode] || plain(mode || '-');
}

function modeBadge(mode)
{
	return badge(true, fmtMode(mode));
}

/* ---------------- status summary ---------------- */

function buildStatus(d)
{
	var lan = d.lan || {};
	var wan = d.wan || {};
	var wwan = d.wwan || {};
	var dhcp = d.dhcp_lan || {};
	var relay = d.relay || {};

	var rows = [
		[ _('当前模式'), modeBadge(d.mode) ],
		[ _('LAN 地址'), plain((lan.ipaddrs && lan.ipaddrs.length) ? lan.ipaddrs.join(', ') : '-') ],
		[ _('LAN 运行'), (lan.runtime && lan.runtime.up) ? badge(true, _('已连接')) : badge(false, _('未连接')) ],
		[ _('DHCP 服务'), dhcp.ignore ? badge(false, _('已关闭（由上游分配）')) : badge(true, _('开启')) ]
	];

	if (d.stored && d.stored.mode && d.stored.mode !== d.mode)
		rows.push([ _('已保存目标模式'), modeBadge(d.stored.mode) ]);

	if (wan && wan.exists) {
		rows.push([ _('WAN'), wan.disabled
			? badge(false, _('已禁用'))
			: E('span', {}, [ plain(wan.proto || '-'), ' · ',
				(wan.runtime && wan.runtime.up) ? badge(true, _('已连接')) : badge(false, _('未连接')) ]) ]);
	}
	else {
		rows.push([ _('WAN'), badge(false, _('未配置')) ]);
	}

	if (wwan && wwan.exists) {
		rows.push([ _('上行 Wi-Fi'), E('span', {}, [
			 plain(wwan.ssid || '-'),
			 wwan.bssid ? ' · ' + plain(wwan.bssid) : '',
			' · ' + ((wwan.runtime && wwan.runtime.up) ? _('已连接') : _('未连接'))
		]) ]);
	}

	if (relay && relay.exists)
		rows.push([ _('relayd 中继'), badge(true, _('启用')) ]);

	return section(_('当前状态'), kvRows(rows));
}

function buildPending(p)
{
	if (countdownTimer) {
		clearInterval(countdownTimer);
		countdownTimer = null;
	}

	if (!p || !p.active)
		return null;

	var remaining = (p.remaining != null) ? p.remaining : null;
	var phase = p.phase || 'unknown';
	var phaseText = {
		queued: _('任务已排队，正在等待执行…'),
		applying: _('正在应用并检查网络配置…'),
		applied: _('配置已应用，等待确认'),
		reverting: _('正在恢复应用前的配置…')
	}[phase] || _('正在处理网络配置…');

	var left = E('span', { 'id': 'sbe1v1k-countdown' }, [ remaining != null ? String(remaining) : '-' ]);
	var ticks = 0;

	countdownTimer = setInterval(function() {
		ticks++;
		if (remaining != null)
			remaining--;

		if (remaining != null && remaining <= 0) {
			clearInterval(countdownTimer);
			countdownTimer = null;
			refresh();
			return;
		}

		left.textContent = remaining != null ? String(remaining) : '-';
		if (phase !== 'applied' && ticks % 2 === 0)
			refresh();
	}, 1000);

	var actions = [];

	if (phase === 'applied')
		actions.push(E('button', {
			'class': 'cbi-button cbi-button-apply',
			'click': function(ev) { ev.preventDefault(); confirmApply(p.request_id); }
		}, [ _('保留配置') ]));

	actions.push(E('button', {
		'class': 'cbi-button cbi-button-reset',
		'click': function(ev) { ev.preventDefault(); revertApply(p.request_id); }
	}, [ _('立即回滚') ]));

	return E('div', { 'class': 'alert-message warning' }, [
		E('h4', {}, [ phaseText ]),
		E('p', {}, [ _('自动回滚剩余时间：'), left, _(' 秒。只有应用任务完成后才能保留配置。') ]),
		E('div', { 'class': 'right' }, actions)
	]);
}

function buildResult(result)
{
	if (!result || result.status === 'applied')
		return null;

	var messages = {
		error: _('上次网络切换失败：') + plain(result.message),
		reverted: _('已恢复应用前的网络配置。'),
		confirmed: _('网络配置已确认并保留。')
	};

	return E('div', {
		'class': result.status === 'error' ? 'alert-message error' : 'alert-message notice'
	}, [ messages[result.status] || plain(result.message) ]);
}

/* ---------------- mode cards & forms ---------------- */

function buildModeCards(selected)
{
	return E('div', { 'class': 'sbe1v1k-cards' }, [ 'router', 'bypass', 'repeater' ].map(function(m) {
		return E('div', {
			'class': 'sbe1v1k-card' + (m === selected ? ' sbe1v1k-card-active' : ''),
			'data-mode': m,
			'click': function(ev) {
				ev.preventDefault();
				selectMode(m);
			}
		}, [
			E('div', { 'class': 'sbe1v1k-card-title' }, [ fmtMode(m) ]),
			E('div', { 'class': 'sbe1v1k-card-desc' }, [ MODE_DESCS[m] ])
		]);
	}));
}

function textRow(id, label, value, placeholder, type, onInput)
{
	var attrs = { 'id': id, 'type': type || 'text', 'value': value ?? '', 'placeholder': placeholder || '' };

	if (typeof onInput === 'function')
		attrs.input = onInput;

	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title', 'for': id }, [ label ]),
		E('div', { 'class': 'cbi-value-field' }, [
			E('input', attrs)
		])
	]);
}

function selectRow(id, label, options, value, onChange)
{
	var attrs = { 'id': id };

	if (typeof onChange === 'function')
		attrs.change = onChange;

	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title', 'for': id }, [ label ]),
		E('div', { 'class': 'cbi-value-field' }, [
			E('select', attrs, options.map(function(o) {
				return E('option', { 'value': o[0], 'selected': (o[0] === value) || null }, [ o[1] ]);
			}))
		])
	]);
}

function prefixOptions()
{
	var out = [];

	for (var p = 8; p <= 30; p++)
		out.push([ String(p), '/' + p ]);

	return out;
}

function clearWifiSelection()
{
	var bssid = document.getElementById('sbe1v1k-bssid');
	var results = document.getElementById('sbe1v1k-wifi-results');

	if (bssid)
		bssid.value = '';
	if (results)
		results.value = '';
}

function buildForm(mode, d)
{
	var s = d.stored || {};
	var curLan = (d.lan && d.lan.ipaddrs && d.lan.ipaddrs.length) ? d.lan.ipaddrs[0].split('/')[0] : '192.168.1.1';
	var bands = [];

	(d.radios || []).forEach(function(r) {
		if (BAND_LABELS[r.band] && bands.indexOf(r.band) < 0)
			bands.push(r.band);
	});

	if (!bands.length)
		bands = [ '5g', '2g', '6g' ];

	var common = [
		textRow('sbe1v1k-lan-ip', _('LAN IP 地址'), s.lan_ip || curLan, '192.168.1.1'),
		selectRow('sbe1v1k-lan-prefix', _('子网前缀'), prefixOptions(), s.lan_prefix || '24')
	];

	var extra;

	if (mode === 'bypass') {
		extra = [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('上游 DHCP') ]),
				E('div', { 'class': 'cbi-value-field sbe1v1k-inline-actions' }, [
					E('button', {
						'id': 'sbe1v1k-dhcp-probe-btn',
						'class': 'cbi-button cbi-button-action',
						'click': function(ev) { ev.preventDefault(); probeDhcp(); }
					}, [ _('自动获取配置') ]),
					E('span', { 'id': 'sbe1v1k-dhcp-probe-status', 'class': 'sbe1v1k-action-status' }, [])
				])
			]),
			textRow('sbe1v1k-gateway', _('主路由网关 IP'), s.gateway || '', '例如 192.168.1.1'),
			textRow('sbe1v1k-dns', _('DNS（可选）'), s.dns || '', '留空则使用网关'),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field', 'style': 'color:#666' }, [ _('自动获取前请将上游网线接入任一 LAN 口；探测只读取 DHCP 租约而不修改当前网络，应用前仍建议在主路由中为该地址建立静态租约。') ])
			])
		];
	}
	else if (mode === 'repeater') {
		extra = [
			selectRow('sbe1v1k-band', _('上行频段'), bands.map(function(b) {
				return [ b, BAND_LABELS[b] ];
			}), s.band || '5g', clearWifiSelection),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('可用 Wi-Fi') ]),
				E('div', { 'class': 'cbi-value-field sbe1v1k-inline-actions' }, [
					E('button', {
						'id': 'sbe1v1k-wifi-scan-btn',
						'class': 'cbi-button cbi-button-action',
						'click': function(ev) { ev.preventDefault(); scanWifi(); }
					}, [ _('扫描所选频段') ]),
					E('span', { 'id': 'sbe1v1k-wifi-scan-status', 'class': 'sbe1v1k-action-status' }, [])
				])
			]),
			selectRow('sbe1v1k-wifi-results', _('扫描结果'), [ [ '', _('请先扫描并选择上游 Wi-Fi') ] ], '', function(ev) {
				chooseWifiResult(ev.target);
			}),
			E('input', { 'id': 'sbe1v1k-bssid', 'type': 'hidden', 'value': s.bssid || '' }),
			textRow('sbe1v1k-ssid', _('上游 Wi-Fi 名称 (SSID)'), s.ssid || '', _('也可手动填写隐藏网络'), 'text', clearWifiSelection),
			selectRow('sbe1v1k-enc', _('加密方式'), [ 'psk2', 'sae-mixed', 'sae', 'owe', 'none' ].map(function(e) {
				return [ e, ENC_LABELS[e] ];
			}), s.encryption || 'psk2'),
			textRow('sbe1v1k-key', _('Wi-Fi 密码'), '', s.key_set ? _('留空保持已保存密码') : '', 'password'),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field', 'style': 'color:#666' }, [ _('扫描会自动填写 SSID、BSSID 和加密方式；企业认证与 WEP 网络不支持。LAN IP 仍须与上游同网段且未被占用。') ])
			])
		];
	}
	else {
		extra = [ E('div', { 'class': 'cbi-value' }, [
			E('div', { 'class': 'cbi-value-field', 'style': 'color:#666' }, [ _('WAN 将保持现有配置（DHCP / PPPoE 等），仅恢复 LAN 与 DHCP 的默认行为。') ])
		]) ];
	}

	return E('div', { 'id': 'sbe1v1k-form' }, [
		section(_('模式参数'), common.concat(extra))
	]);
}

function setFieldValue(id, value)
{
	var field = document.getElementById(id);

	if (field)
		field.value = value ?? '';
}

function probeDhcp()
{
	var btn = document.getElementById('sbe1v1k-dhcp-probe-btn');
	var status = document.getElementById('sbe1v1k-dhcp-probe-status');

	if (!btn)
		return;

	btn.disabled = true;
	if (status)
		status.textContent = _('正在等待上游 DHCP…');

	api('/dhcp_probe').then(function(r) {
		if (!r.ok)
			throw new Error(r.error || _('DHCP 探测失败'));

		setFieldValue('sbe1v1k-lan-ip', r.lan_ip);
		setFieldValue('sbe1v1k-lan-prefix', r.lan_prefix);
		setFieldValue('sbe1v1k-gateway', r.gateway);
		setFieldValue('sbe1v1k-dns', r.dns);
		if (status)
			status.textContent = _('已获取租约');
		showMessage(_('已从上游 DHCP 自动填写地址、前缀、网关和 DNS。'), false);
	}).catch(function(err) {
		if (status)
			status.textContent = _('获取失败');
		showMessage(_('DHCP 探测失败: ') + plain(err.message), true);
	}).finally(function() {
		btn.disabled = false;
	});
}

function wifiResultLabel(network)
{
	var enc = network.encryption ? (ENC_LABELS[network.encryption] || network.encryption) : _('不支持的加密');
	return plain(network.ssid) + ' · ' + plain(network.signal) + ' dBm · ' + enc +
		' · CH ' + plain(network.channel) + ' · ' + plain(network.bssid);
}

function chooseWifiResult(select)
{
	var index = parseInt(select.value, 10);
	var network = select._sbe1v1kNetworks && select._sbe1v1kNetworks[index];

	if (!network || !network.supported)
		return;

	setFieldValue('sbe1v1k-ssid', network.ssid);
	setFieldValue('sbe1v1k-bssid', network.bssid);
	setFieldValue('sbe1v1k-enc', network.encryption);

	var key = document.getElementById('sbe1v1k-key');
	var saved = lastData && lastData.stored;
	if (key) {
		key.value = '';
		key.placeholder = saved && saved.key_set && saved.ssid === network.ssid
			? _('留空保持已保存密码')
			: ((network.encryption === 'none' || network.encryption === 'owe') ? '' : _('请输入此 Wi-Fi 的密码'));
	}
}

function scanWifi()
{
	var btn = document.getElementById('sbe1v1k-wifi-scan-btn');
	var status = document.getElementById('sbe1v1k-wifi-scan-status');
	var select = document.getElementById('sbe1v1k-wifi-results');
	var band = document.getElementById('sbe1v1k-band');

	if (!btn || !select || !band)
		return;

	btn.disabled = true;
	select.disabled = true;
	if (status)
		status.textContent = _('正在扫描…');

	api('/wifi_scan', { band: band.value }).then(function(r) {
		if (!r.ok)
			throw new Error(r.error || _('无线扫描失败'));

		var networks = Array.isArray(r.results) ? r.results : [];
		networks.sort(function(a, b) {
			return (Number(b.signal) || -100) - (Number(a.signal) || -100) || plain(a.ssid).localeCompare(plain(b.ssid));
		});

		select.innerHTML = '';
		select._sbe1v1kNetworks = networks;
		select.appendChild(E('option', { 'value': '' }, [
			networks.length ? _('请选择上游 Wi-Fi') : _('未发现可见 Wi-Fi')
		]));

		networks.forEach(function(network, index) {
			select.appendChild(E('option', {
				'value': String(index),
				'disabled': network.supported ? null : true
			}, [ wifiResultLabel(network) ]));
		});

		select.disabled = false;
		if (status)
			status.textContent = _('发现网络：') + networks.length;
	}).catch(function(err) {
		if (status)
			status.textContent = _('扫描失败');
		showMessage(_('Wi-Fi 扫描失败: ') + plain(err.message), true);
		select.disabled = false;
	}).finally(function() {
		btn.disabled = false;
	});
}

/* ---------------- apply / confirm / revert ---------------- */

function collectParams(mode)
{
	function val(id) { return document.getElementById(id) ? document.getElementById(id).value : ''; }

	var p = {
		mode: mode,
		lan_ip: val('sbe1v1k-lan-ip'),
		lan_prefix: val('sbe1v1k-lan-prefix')
	};

	if (mode === 'bypass') {
		p.gateway = val('sbe1v1k-gateway');
		p.dns = val('sbe1v1k-dns');
	}
	else if (mode === 'repeater') {
		p.band = val('sbe1v1k-band');
		p.ssid = val('sbe1v1k-ssid');
		p.bssid = val('sbe1v1k-bssid');
		p.encryption = val('sbe1v1k-enc');
		p.key = val('sbe1v1k-key');
	}

	return p;
}

function doApply()
{
	var mode = selectedMode;

	if (!confirm(_('确定要切换到「' + fmtMode(mode) + '」模式吗？\n\n网络会立即重启，切换失败时将在超时后自动回滚。')))
		return;

	var btn = document.getElementById('sbe1v1k-apply-btn');
	btn.disabled = true;
	btn.innerHTML = _('正在应用…');

	api('/apply', collectParams(mode)).then(function(r) {
		if (!r.ok)
			throw new Error(r.error || _('应用失败'));
		return fetchStatus();
	}).then(function(d) {
		rebuild(d);
	}).catch(function(err) {
		if (btn) {
			btn.disabled = false;
			btn.innerHTML = _('应用当前模式');
		}
		showMessage(_('应用失败: ') + plain(err.message), true);
	});
}

function confirmApply(requestId)
{
	api('/confirm', { request_id: requestId }).then(function(r) {
		if (!r.ok)
			throw new Error(r.error || _('确认失败'));
		return fetchStatus();
	}).then(rebuild).catch(function(err) {
		showMessage(_('确认失败: ') + plain(err.message), true);
	});
}

function revertApply(requestId)
{
	if (!confirm(_('立即回滚到应用前的网络配置？')))
		return;

	api('/revert', { request_id: requestId }).then(function(r) {
		if (!r.ok)
			throw new Error(r.error || _('回滚失败'));
		return fetchStatus();
	}).then(rebuild).catch(function(err) {
		showMessage(_('回滚失败: ') + plain(err.message), true);
	});
}

/* ---------------- rendering ---------------- */

var selectedMode = 'router';
var lastData = null;
var countdownTimer = null;
var messageBox = null;

function showMessage(text, isError)
{
	if (!messageBox)
		return;

	messageBox.innerHTML = '';
	messageBox.appendChild(E('div', { 'class': isError ? 'alert-message error' : 'alert-message' }, [ text ]));
}

function selectMode(m)
{
	selectedMode = m;

	var cards = document.querySelectorAll('.sbe1v1k-card');

	for (var i = 0; i < cards.length; i++)
		cards[i].classList.toggle('sbe1v1k-card-active', cards[i].getAttribute('data-mode') === m);

	if (lastData) {
		var wrap = document.getElementById('sbe1v1k-form-wrap');

		if (wrap) {
			wrap.innerHTML = '';
			wrap.appendChild(buildForm(m, lastData));
		}
	}
}

function rebuild(d)
{
	var root = document.getElementById('sbe1v1k-root');

	if (!root)
		return;

	if ((!d.pending || !d.pending.active) && d.result &&
	    [ 'error', 'reverted' ].indexOf(d.result.status) >= 0)
		selectedMode = d.mode || 'router';

	root.innerHTML = '';
	root.appendChild(build(d));
}

function refresh()
{
	fetchStatus().then(rebuild).catch(function(err) {
		showMessage(_('读取状态失败: ') + plain(err.message), true);
	});
}

const SBE1V1K_CSS = [
	'.sbe1v1k-table th, .sbe1v1k-table td { text-align: center; }',
	'.sbe1v1k-ok { color: #188038; font-weight: bold; }',
	'.sbe1v1k-bad { color: #d93025; font-weight: bold; }',
	'.sbe1v1k-cards { display: flex; gap: 10px; flex-wrap: wrap; margin: 10px 0 20px; }',
	'.sbe1v1k-card { flex: 1 1 200px; border: 1px solid #ccc; border-radius: 6px; padding: 14px; cursor: pointer; background: #fafafa; }',
	'.sbe1v1k-card-active { border-color: #188038; background: #e8f5e9; box-shadow: 0 0 0 1px #188038; }',
	'.sbe1v1k-card-title { font-size: 16px; font-weight: bold; margin-bottom: 6px; text-align: center; }',
	'.sbe1v1k-card-desc { font-size: 12px; color: #666; text-align: center; }',
	'.sbe1v1k-inline-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }',
	'.sbe1v1k-action-status { color: #666; }',
	'#sbe1v1k-form input[type="text"], #sbe1v1k-form input[type="password"], #sbe1v1k-form select { width: 100%; box-sizing: border-box; }'
].join('\n');

function build(d)
{
	lastData = d;
	messageBox = E('div', {}, []);
	var pending = d.pending && d.pending.active;

	var applyBtn = E('button', {
		'id': 'sbe1v1k-apply-btn',
		'class': 'cbi-button cbi-button-apply',
		'disabled': pending || null,
		'click': function(ev) { ev.preventDefault(); doApply(); }
	}, [ pending ? _('切换进行中…') : _('应用当前模式') ]);

	return E('div', {}, [
		E('style', {}, [ SBE1V1K_CSS ]),
		buildPending(d.pending),
		buildResult(d.result),
		E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('网络模式切换') ]),
			buildStatus(d),
			section(_('选择模式'), buildModeCards(selectedMode)),
			E('div', { 'id': 'sbe1v1k-form-wrap' }, [ buildForm(selectedMode, d) ])
		]),
		E('div', { 'class': 'cbi-page-actions' }, [
			applyBtn,
			E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function(ev) { ev.preventDefault(); refresh(); } }, [ _('刷新') ])
		]),
		messageBox
	]);
}

return view.extend({
	load: function()
	{
		return fetchStatus();
	},

	render: function(data)
	{
		selectedMode = data.mode || 'router';
		lastData = data;

		this.page = E('div', { 'id': 'sbe1v1k-root' }, [ build(data) ]);
		return this.page;
	},

	refresh: function()
	{
		refresh();
	}
});
