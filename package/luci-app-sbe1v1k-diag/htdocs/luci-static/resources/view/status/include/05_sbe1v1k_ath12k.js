'use strict';

'require baseclass';

const ATH12K_STATUS = L.url('admin/status/overview/sbe1v1k_ath12k');

function fetchAth12kStatus()
{
	return fetch(ATH12K_STATUS, {
		headers: { 'X-Requested-With': 'XMLHttpRequest' }
	}).then(function(r) {
		if (!r.ok)
			throw new Error('HTTP ' + r.status);

		return r.json();
	});
}

function badge(style, text, title)
{
	return E('span', {
		'class': 'label ' + style,
		'title': title || null
	}, [ text ]);
}

function bandLabel(band)
{
	switch (band) {
	case '2g':
		return '2.4 GHz';
	case '5g':
		return '5 GHz';
	case '6g':
		return '6 GHz';
	default:
		return band || '-';
	}
}

function bandBadge(radio)
{
	var label = bandLabel(radio.band);
	var phy = radio.phy ? '%s radio%d'.format(radio.phy, Number(radio.radio_index || 0)) : null;
	var detail = [ phy, radio.device, radio.driver, radio.mac ].filter(Boolean).join(' · ');

	if (!radio.detected)
		return badge('important', label + ' · ' + _('未检测'), detail);
	if (!radio.configured)
		return badge('warning', label + ' · ' + _('未配置'), detail);
	if (radio.disabled)
		return badge('warning', label + ' · ' + _('已关闭'), detail);
	if (radio.up)
		return badge('success', label + ' · ' + _('运行中'), detail);
	if (radio.pending)
		return badge('warning', label + ' · ' + _('启动中'), detail);

	return badge('important', label + ' · ' + _('未启动'), detail);
}

function addRow(table, title, value)
{
	table.appendChild(E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, [ title ]),
		E('td', { 'class': 'td left' }, [ value ])
	]));
}

return baseclass.extend({
	title: _('ath12k 无线驱动'),

	load: function()
	{
		return L.resolveDefault(fetchAth12kStatus(), { unavailable: true });
	},

	render: function(status)
	{
		var table = E('table', { 'class': 'table' });
		var radios = Array.isArray(status.bands) ? status.bands : [];

		if (status.unavailable) {
			addRow(table, _('驱动状态'), badge('important', _('状态读取失败')));
			return table;
		}

		addRow(table, _('驱动状态'), status.working
			? badge('success', _('已加载并正常工作'))
			: status.driver_loaded
				? badge('warning', _('已加载但工作异常'))
				: badge('important', _('ath12k 未加载')));
		addRow(table, _('三频 radio'), badge(status.detected === 3 ? 'success' : 'important',
			_('%d / 3 已检测').format(Number(status.detected || 0))));
		addRow(table, _('频段状态'), E('div', {
			'style': 'display:flex;flex-wrap:wrap;gap:.35em .45em'
		}, radios.map(bandBadge)));
		addRow(table, _('运行情况'), _('%d 个已启用，%d 个运行中').format(
			Number(status.enabled || 0), Number(status.running || 0)));
		addRow(table, _('ath12k debugfs'), status.debugfs_devices > 0 && status.dp_stats > 0
			? badge('success', _('%d 个设备，%d 个 DP 节点').format(
				Number(status.debugfs_devices), Number(status.dp_stats)))
			: badge('warning', _('DP 统计节点不可用')));

		return table;
	}
});
