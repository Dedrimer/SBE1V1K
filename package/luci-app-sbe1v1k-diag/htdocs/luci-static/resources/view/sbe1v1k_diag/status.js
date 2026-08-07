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

function preBlock(text)
{
	if (text == null || text === '')
		return E('div', { 'class': 'sbe1v1k-missing' }, [ _('节点不可用') ]);

	return E('pre', { 'class': 'sbe1v1k-pre' }, [ String(text) ]);
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

function statusBadge(ok, text)
{
	return E('span', { 'class': ok ? 'sbe1v1k-ok' : 'sbe1v1k-bad' }, [ text ]);
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

		var led = d.led || {};
		var fw = d.firewall || {};
		var eip = d.eip || {};
		var ppe = d.ppe || {};
		var abi = d.abi || {};

		var ledState = led.configured
			? statusBadge(true, _('已配置') + ' · ' + esc(led.name) + ' · ' + esc(led.trigger) + (led.inverted === '1' ? ' · ' + _('反转') : ''))
			: statusBadge(false, _('未配置'));

		var offload = fw.flow_offloading_hw === '1'
			? statusBadge(true, _('硬件卸载已启用'))
			: statusBadge(false, _('硬件卸载未启用'));

		var ppeNodes = Object.keys(ppe.nodes || {});
		var ppeOk = ppeNodes.some(function(k) { return ppe.nodes[k] != null; });

		var eipOk = eip.dt && eip.dt.status !== 'missing';

		return E('div', {}, [
			E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, [ _('概览') ]),
				section(_('设备'), kvRows([
					[ _('型号'), esc(d.model || 'unknown') ],
					[ _('运行时间'), esc((d.uptime || '').trim()) ],
					[ _('状态 LED'), ledState ],
					[ _('防火墙卸载'), offload ],
					[ _('PPE 驱动'), ppeOk ? statusBadge(true, _('节点可读')) : statusBadge(false, _('无 PPE 节点')) ],
					[ _('EIP 加密'), eipOk ? statusBadge(true, _('DT 节点存在')) : statusBadge(false, _('无 EIP 节点')) ]
				])),
				section(_('内核模块'), preBlock((d.modules || []).filter(function(l) { return l; }).join('\n'))),
				section(_('PPE/EIP ABI 符号'), kvRows([
					[ 'qcom_ppe_ds_start', statusBadge(!!abi.qcom_ppe_ds_start, abi.qcom_ppe_ds_start ? 'present' : 'missing') ],
					[ 'qcom_ppe_ds_vp_alloc', statusBadge(!!abi.qcom_ppe_ds_vp_alloc, abi.qcom_ppe_ds_vp_alloc ? 'present' : 'missing') ],
					[ 'qcom_ppe_ds_queue_start', statusBadge(!!abi.qcom_ppe_ds_queue_start, abi.qcom_ppe_ds_queue_start ? 'present' : 'missing') ],
					[ 'qcom_ppe_eip_provider', statusBadge(!!abi.qcom_ppe_eip_provider, abi.qcom_ppe_eip_provider ? 'present' : 'missing') ]
				]))
			]),

			E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, [ _('状态 LED (green:status)') ]),
				section(_('UCI 配置'), kvRows([
					[ _('名称'), esc(led.name || '-') ],
					[ _('触发器'), esc(led.trigger || '-') ],
					[ _('默认亮'), led.default === '1' ? _('是') : _('否') ],
					[ _('反转闪烁'), led.inverted === '1' ? _('是') : _('否') ]
				])),
				section(_('Sysfs 状态'), kvRows([
					[ _('当前触发器'), preBlock(led.sysfs_trigger) ],
					[ _('亮度'), esc((led.brightness || '').trim() + ' / ' + (led.max_brightness || '').trim()) ]
				]))
			]),

			E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, [ _('PPE 硬件加速节点') ]),
				section(_('/sys/kernel/debug/ppe'), [
					E('div', { 'class': 'sbe1v1k-nodes' }, ppeNodes.map(function(k) {
						return E('div', { 'class': 'sbe1v1k-node' }, [
							E('div', { 'class': 'sbe1v1k-node-name' }, [ esc(k) ]),
							preBlock(ppe.nodes[k])
						]);
					})),
					ppeNodes.length ? null : E('div', {}, [ _('未找到 PPE debugfs 节点') ])
				]),
				section(_('ath12k DP 统计'), (function() {
					var keys = Object.keys(ppe.ath12k_dp_stats || {});
					var nodes = keys.map(function(k) {
						return E('div', { 'class': 'sbe1v1k-node' }, [
							E('div', { 'class': 'sbe1v1k-node-name' }, [ esc(k) ]),
							preBlock(ppe.ath12k_dp_stats[k])
						]);
					});

					if (!keys.length)
						nodes.push(E('div', {}, [ _('未找到 ath12k DP 统计节点') ]));

					return E('div', { 'class': 'sbe1v1k-nodes' }, nodes);
				})())
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
				section(_('统计'), kvRows([
					[ _('EIP 算法数'), esc(String(eip.algorithms ?? 0)) ],
					[ _('中断'), preBlock(eip.interrupts) ],
					[ _('流表'), preBlock(eip.flow_table) ]
				])),
				section(_('EIP 节点'), (function() {
					var keys = Object.keys(eip.stats || {});
					var nodes = keys.map(function(k) {
						return E('div', { 'class': 'sbe1v1k-node' }, [
							E('div', { 'class': 'sbe1v1k-node-name' }, [ esc(k) ]),
							preBlock(eip.stats[k])
						]);
					});

					if (!keys.length)
						nodes.push(E('div', {}, [ _('未找到 EIP 统计节点') ]));

					return E('div', { 'class': 'sbe1v1k-nodes' }, nodes);
				})())
			]),

			E('div', { 'class': 'cbi-page-actions' }, [ btn ])
		]);
	}
});
