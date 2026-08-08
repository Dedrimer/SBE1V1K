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
	bypass:   _('关闭 DHCP，使用主路由网段静态 IP，网关指向主路由'),
	repeater: _('通过 Wi-Fi 连接上游路由器，有线 + 无线客户端共享上游网络')
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

function textRow(id, label, value, placeholder, type)
{
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title', 'for': id }, [ label ]),
		E('div', { 'class': 'cbi-value-field' }, [
			E('input', { 'id': id, 'type': type || 'text', 'value': value ?? '', 'placeholder': placeholder || '' })
		])
	]);
}

function selectRow(id, label, options, value)
{
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title', 'for': id }, [ label ]),
		E('div', { 'class': 'cbi-value-field' }, [
			E('select', { 'id': id }, options.map(function(o) {
				return E('option', { 'value': o[0], 'selected': (o[0] === value) || null }, [ o[1] ]);
			}))
		])
	]);
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
		selectRow('sbe1v1k-lan-prefix', _('子网前缀'), [ '24', '23', '22', '25', '26' ].map(function(p) {
			return [ p, '/' + p ];
		}), s.lan_prefix || '24')
	];

	var extra;

	if (mode === 'bypass') {
		extra = [
			textRow('sbe1v1k-gateway', _('主路由网关 IP'), s.gateway || '', '例如 192.168.1.1'),
			textRow('sbe1v1k-dns', _('DNS（可选）'), s.dns || '', '留空则使用网关'),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field', 'style': 'color:#666' }, [ _('提示：本机将使用主路由网段的固定 IP，请确保该 IP 未被占用。') ])
			])
		];
	}
	else if (mode === 'repeater') {
		extra = [
			selectRow('sbe1v1k-band', _('上行频段'), bands.map(function(b) {
				return [ b, BAND_LABELS[b] ];
			}), s.band || '5g'),
			textRow('sbe1v1k-ssid', _('上游 Wi-Fi 名称 (SSID)'), s.ssid || '', ''),
			selectRow('sbe1v1k-enc', _('加密方式'), [ 'psk2', 'sae-mixed', 'sae', 'owe', 'none' ].map(function(e) {
				return [ e, ENC_LABELS[e] ];
			}), s.encryption || 'psk2'),
			textRow('sbe1v1k-key', _('Wi-Fi 密码'), '', s.key_set ? _('留空保持已保存密码') : '', 'password'),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field', 'style': 'color:#666' }, [ _('提示：LAN IP 必须与主路由同网段且未被占用，例如主路由为 192.168.1.1 时填 192.168.1.2。') ])
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
	'#sbe1v1k-form input[type="text"], #sbe1v1k-form input[type="password"], #sbe1v1k-form select { width: 100%; box-sizing: border-box; }'
].join('\n');

return view.extend({
	load: function()
	{
		return fetchStatus();
	},

	render: function(data)
	{
		selectedMode = data.mode || 'router';
		lastData = data;

		this.page = E('div', { 'id': 'sbe1v1k-root' }, [ this.build(data) ]);
		return this.page;
	},

	refresh: function()
	{
		refresh();
	},

	build: function(d)
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
});
