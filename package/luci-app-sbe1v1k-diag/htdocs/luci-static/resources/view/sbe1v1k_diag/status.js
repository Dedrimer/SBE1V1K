'use strict';

'require view';

function esc(s)
{
	return String(s ?? '').replace(/[&<>"']/g, function(ch) {
		return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch];
	});
}

function fetchData()
{
	return fetch('/cgi-bin/luci/admin/system/sbe1v1k_diag/status', {
		headers: { 'X-Requested-With': 'XMLHttpRequest' }
	}).then(function(r) {
		if (!r.ok)
			throw new Error('HTTP ' + r.status);
		return r.json();
	});
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

function table(headers, rows)
{
	return E('table', { 'class': 'sbe1v1k-table' }, [
		E('thead', {}, [
			E('tr', {}, headers.map(function(h) { return E('th', {}, [ h ]); }))
		]),
		E('tbody', {}, rows.map(function(r) {
			return E('tr', {}, r.map(function(c) { return E('td', {}, [ c ]); }));
		}))
	]);
}

function preBlock(text)
{
	if (text == null || text === '')
		return E('div', { 'class': 'sbe1v1k-missing' }, [ _('节点不可用') ]);

	return E('pre', { 'class': 'sbe1v1k-pre' }, [ String(text) ]);
}
function statusBadge(ok, text)
{
	return E('span', { 'class': ok ? 'sbe1v1k-ok' : 'sbe1v1k-bad' }, [ text ]);
}

function fmtNum(n)
{
	return (n == null) ? '-' : String(n);
}

function fmtUptime(sec)
{
	if (sec == null)
		return '-';

	sec = Math.floor(sec);

	var d = Math.floor(sec / 86400);
	var h = Math.floor((sec % 86400) / 3600);
	var m = Math.floor((sec % 3600) / 60);
	var s = sec % 60;

	if (d > 0) return d + ' ' + _('天') + ' ' + h + ' ' + _('小时');
	if (h > 0) return h + ' ' + _('小时') + ' ' + m + ' ' + _('分钟');
	if (m > 0) return m + ' ' + _('分钟') + ' ' + s + ' ' + _('秒');
	return s + ' ' + _('秒');
}

function counterSummary(c)
{
	if (!c)
		return statusBadge(false, _('不可用'));

	if (!c.nonzero.length)
		return statusBadge(true, _('正常') + ' · ' + fmtNum(c.total) + ' 项全部为 0');

	return E('div', {}, c.nonzero.map(function(n) {
		return E('div', { 'class': 'sbe1v1k-nonzero' }, [ esc(n.name) + ' = ' + fmtNum(n.value) ]);
	}));
}

function qmSection(qm)
{
	if (!qm || !qm.queues.length)
		return E('div', {}, [ _('队列信息不可用') ]);

	var rows = qm.queues.map(function(q) {
		return [
			esc(q.queue),
			fmtNum(q.tx),
			fmtNum(q.pend),
			fmtNum(q.drop),
			(q.pend > 0 || q.drop > 0) ? statusBadge(false, _('积压/丢弃')) : statusBadge(true, _('正常'))
		];
	});

	rows.push([
		E('strong', {}, [ _('合计') ]),
		E('strong', {}, [ fmtNum(qm.total.tx) ]),
		E('strong', {}, [ fmtNum(qm.total.pend) ]),
		E('strong', {}, [ fmtNum(qm.total.drop) ]),
		(qm.total.pend > 0 || qm.total.drop > 0) ? statusBadge(false, _('积压/丢弃')) : statusBadge(true, _('正常'))
	]);

	return table([ _('队列'), _('TX'), _('PEND'), _('DROP'), _('状态') ], rows);
}

function portSection(rx, tx)
{
	var ports = {};
	var rxPorts = (rx && rx.ports) || [];
	var txPorts = (tx && tx.ports) || [];

	rxPorts.forEach(function(p) {
		ports[p.port] = { port: p.port, rx: p.count, rx_drop: p.drop, tx: 0, tx_drop: 0 };
	});

	txPorts.forEach(function(p) {
		if (!ports[p.port])
			ports[p.port] = { port: p.port, rx: 0, rx_drop: 0, tx: 0, tx_drop: 0 };
		ports[p.port].tx = p.count;
		ports[p.port].tx_drop = p.drop;
	});

	var list = Object.keys(ports).map(function(k) { return ports[k]; });

	if (!list.length)
		return E('div', {}, [ _('端口统计不可用') ]);

	return table([ _('端口'), _('RX'), _('RX_DROP'), _('TX'), _('TX_DROP') ],
		list.map(function(p) {
			return [
				esc('0x' + p.port),
				fmtNum(p.rx),
				fmtNum(p.rx_drop),
				fmtNum(p.tx),
				fmtNum(p.tx_drop)
			];
		}));
}

function flowsSection(flows)
{
	if (!flows)
		return E('div', {}, [ _('节点不可用') ]);

	return kvRows([
		[ _('已绑定'), fmtNum(flows.bound) ],
		[ _('替换'), fmtNum(flows.replace) ],
		[ _('不支持'), fmtNum(flows.unsupported) ],
		[ _('失败'), fmtNum(flows.failed) ],
		[ _('已销毁'), fmtNum(flows.destroy) ],
		[ _('僵尸'), fmtNum(flows.zombies) ]
	]);
}

function dsSection(ds)
{
	if (!ds)
		return E('div', {}, [ _('节点不可用') ]);

	var children = [];

	if (ds.flow_enqueue_map && ds.flow_enqueue_map.length)
		children = children.concat(kvRows([
			[ _('flow_enqueue_map'), esc(ds.flow_enqueue_map.join(', ')) ]
		]));

	if (ds.port_qmaps && ds.port_qmaps.length)
		children.push(E('pre', { 'class': 'sbe1v1k-pre' }, [ ds.port_qmaps.join('\n') ]));

	if (ds.nodes && ds.nodes.length)
		children.push(table([ _('节点'), _('状态'), _('Ring'), _('队列'), _('enqueue_vp'), _('Profile'), _('运行') ],
			ds.nodes.map(function(n) {
				return [
					fmtNum(n.node),
					fmtNum(n.state),
					fmtNum(n.ring),
					esc(n.queues),
					fmtNum(n.enqueue_vp),
					fmtNum(n.profile),
					n.start === 1 ? _('是') : _('否')
				];
			})));

	return E('div', {}, children);
}

function edmaSection(edma)
{
	if (!edma)
		return E('div', {}, [ _('不可用') ]);

	return kvRows([
		[ _('错误统计'), counterSummary(edma.err) ],
		[ _('RX Ring'), counterSummary(edma.rx) ],
		[ _('TX Ring'), counterSummary(edma.tx) ]
	]);
}

function ath12kSection(list)
{
	list = list || [];

	if (!list.length)
		return E('div', {}, [ _('未找到 ath12k DP 统计') ]);

	return E('div', {}, list.map(function(a) {
		var s = a.stats || {};
		var rows = [
			[ _('RX 错误'), counterSummary(s.rx) ],
			[ _('TX 错误'), counterSummary(s.tx) ]
		];

		if (s.direct_switch) {
			var ds = s.direct_switch;

			rows.push([ _('直通开关'), statusBadge(ds.started === 1, _('已注册') + ' ' + fmtNum(ds.registered) + ' · ' + _('已启动') + ' ' + fmtNum(ds.started)) ]);
			rows.push([ _('ppe2tcl 更新'), fmtNum(ds.ppe2tcl_cons) ]);
			rows.push([ _('TX 分配'), fmtNum(ds.tx_alloc) + ' / ' + _('失败') + ' ' + fmtNum(ds.tx_alloc_fail) ]);
			rows.push([ _('RX 完成 / 丢弃'), fmtNum(ds.rx_complete) + ' / ' + fmtNum(ds.rx_drop) ]);
		}

		return E('div', { 'class': 'sbe1v1k-node' }, [
			E('div', { 'class': 'sbe1v1k-node-name' }, [ esc(a.id) ])
		].concat(kvRows(rows)));
	}));
}

function ringTable(rings)
{
	rings = rings || [];

	if (!rings.length)
		return E('div', {}, [ _('无 Ring 数据') ]);

	return table([ _('Ring'), _('Tx Pkts'), _('Tx Err'), _('Rx Pkts'), _('Rx Err'), _('Rx Drop') ],
		rings.map(function(r) {
			var s = r.stats || {};

			return [
				esc(r.name),
				fmtNum(s.tx_packets),
				fmtNum(s.tx_error),
				fmtNum(s.rx_packets),
				fmtNum(s.rx_error),
				fmtNum(s.rx_dropped)
			];
		}));
}

function ctxSection(ctxs)
{
	ctxs = ctxs || [];

	if (!ctxs.length)
		return E('div', {}, [ _('无 IPSec 上下文') ]);

	return E('div', {}, ctxs.map(function(c) {
		return E('div', { 'class': 'sbe1v1k-node' }, [
			E('div', { 'class': 'sbe1v1k-node-name' }, [ esc(c.name) ]),
			counterSummary(c.stats)
		]);
	}));
}

function svcSection(svcs)
{
	svcs = svcs || [];

	if (!svcs.length)
		return E('div', {}, [ _('无算法服务统计') ]);

	return kvRows(svcs.map(function(s) {
		return [ esc(s.name), counterSummary(s.stats) ];
	}));
}

function irqTable(irqs)
{
	irqs = irqs || [];

	if (!irqs.length)
		return E('div', {}, [ _('无 EIP 中断') ]);

	return table([ _('IRQ'), _('计数'), _('Ring') ],
		irqs.map(function(i) {
			return [ fmtNum(i.irq), fmtNum(i.count), esc(i.name) ];
		}));
}

return view.extend({
	load: function()
	{
		return fetchData();
	},

	render: function(data)
	{
		this.page = E('div', {}, [ this.build(data) ]);
		return this.page;
	},

	refresh: function()
	{
		var old = this.page;
		var loading = E('div', { 'class': 'sbe1v1k-loading' }, [ _('正在读取节点信息…') ]);

		old.parentNode.replaceChild(loading, old);

		fetchData().then((function(d) {
			var fresh = E('div', {}, [ this.build(d) ]);

			loading.parentNode.replaceChild(fresh, loading);
			this.page = fresh;
		}).bind(this)).catch((function(err) {
			loading.innerHTML = '';
			loading.appendChild(E('div', { 'class': 'alert-message warning' }, [
				_('读取失败: ') + esc(err.message)
			]));
			this.page = loading;
		}).bind(this));
	},

	build: function(d)
	{
		var btn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'click': (function(ev) {
				ev.preventDefault();
				this.refresh();
			}).bind(this)
		}, [ _('刷新') ]);

		var fw = d.firewall || {};
		var eip = d.eip || {};
		var ppe = d.ppe || {};
		var abi = d.abi || {};

		var offload = fw.flow_offloading_hw === '1'
			? statusBadge(true, _('硬件卸载已启用'))
			: statusBadge(false, _('硬件卸载未启用'));

		var ppeOk = !!(ppe.qm && ppe.qm.queues.length) || !!(ppe.flows);
		var eipOk = eip.dt && eip.dt.status !== 'missing';

		return E('div', {}, [
			E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, [ _('概览') ]),
				section(_('设备'), kvRows([
					[ _('型号'), esc(d.model || 'unknown') ],
					[ _('运行时间'), esc(d.uptime ? fmtUptime(d.uptime.up) : '-') ],
					[ _('防火墙卸载'), offload ],
					[ _('PPE 驱动'), ppeOk ? statusBadge(true, _('节点可读')) : statusBadge(false, _('无 PPE 节点')) ],
					[ _('EIP 加密'), eipOk ? statusBadge(true, _('DT 节点存在')) : statusBadge(false, _('无 EIP 节点')) ]
				])),
				section(_('内核模块'), (function() {
					var mods = d.modules || [];

					if (!mods.length)
						return E('div', {}, [ _('无模块信息') ]);

					return table([ _('模块'), _('大小'), _('引用'), _('依赖'), _('类型') ],
						mods.map(function(m) {
							return [
								esc(m.name),
								fmtNum(m.size),
								fmtNum(m.refs),
								esc(m.deps || '-'),
								m.out_of_tree ? 'O' : '-'
							];
						}));
				})()),
				section(_('PPE/EIP ABI 符号'), kvRows([
					[ 'qcom_ppe_ds_start', statusBadge(!!abi.qcom_ppe_ds_start, abi.qcom_ppe_ds_start ? 'present' : 'missing') ],
					[ 'qcom_ppe_ds_vp_alloc', statusBadge(!!abi.qcom_ppe_ds_vp_alloc, abi.qcom_ppe_ds_vp_alloc ? 'present' : 'missing') ],
					[ 'qcom_ppe_ds_queue_start', statusBadge(!!abi.qcom_ppe_ds_queue_start, abi.qcom_ppe_ds_queue_start ? 'present' : 'missing') ],
					[ 'qcom_ppe_eip_provider', statusBadge(!!abi.qcom_ppe_eip_provider, abi.qcom_ppe_eip_provider ? 'present' : 'missing') ]
				]))
			]),

			E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, [ _('PPE 硬件加速') ]),
				section(_('队列 QM'), qmSection(ppe.qm)),
				section(_('端口收发'), portSection(ppe.port_rx, ppe.port_tx)),
				section(_('流表'), flowsSection(ppe.flows)),
				section(_('直通开关'), dsSection(ppe.direct_switch)),
				section(_('EDMA'), edmaSection(ppe.edma)),
				section(_('ath12k DP'), ath12kSection(ppe.ath12k))
			]),

			E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, [ _('EIP 加密加速器') ]),
				section(_('设备树节点'), kvRows([
					[ _('路径'), esc(eip.dt ? eip.dt.node || '-' : '-') ],
					[ _('状态'), eipOk ? statusBadge(true, esc(eip.dt.status)) : statusBadge(false, _('缺失')) ],
					[ _('inline 使能'), esc(eip.dt ? eip.dt.inline_enabled : '-') ],
					[ _('外层卸载'), esc(eip.dt ? eip.dt.outer_offload : '-') ],
					[ _('内层卸载'), esc(eip.dt ? eip.dt.inner_offload : '-') ]
				])),
				section(_('固件'), preBlock((function() {
					var f = eip.firmware || {};

					return Object.keys(f).map(function(k) { return k + '=' + f[k]; }).join('\n');
				})())),
				section(_('Ring 统计'), ringTable(eip.rings)),
				section(_('IPSec 上下文'), ctxSection(eip.ipsec_ctx)),
				section(_('算法服务统计'), svcSection(eip.service_stats)),
				section(_('中断'), irqTable(eip.interrupts)),
				section(_('流表'), kvRows([
					[ _('桶数'), fmtNum(eip.flow_table ? eip.flow_table.max_buckets : null) ],
					[ _('活动流'), fmtNum(eip.flow_table ? eip.flow_table.active_flows : null) ]
				]))
			]),

			E('div', { 'class': 'cbi-page-actions' }, [ btn ])
		]);
	}
});