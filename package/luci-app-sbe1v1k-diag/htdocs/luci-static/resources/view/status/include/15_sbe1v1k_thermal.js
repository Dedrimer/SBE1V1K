'use strict';

'require baseclass';

const FAN_STATUS = L.url('admin/status/overview/sbe1v1k_fan');
const SENSOR_ORDER = [ 'cpu', 'soc', 'eth2', 'eth3', 'wifi-2g', 'wifi-5g', 'wifi-6g' ];

function fetchFanStatus()
{
	return fetch(FAN_STATUS, {
		headers: { 'X-Requested-With': 'XMLHttpRequest' }
	}).then(function(r) {
		if (!r.ok)
			throw new Error('HTTP ' + r.status);

		return r.json();
	});
}

function fmtTemp(milli)
{
	return milli == null ? '-' : (Number(milli) / 1000).toFixed(1) + ' °C';
}

function fmtPwm(value)
{
	if (value == null)
		return '-';

	return '%d / 255 (%d%%)'.format(value, Math.round(Number(value) * 100 / 255));
}

function badge(style, text)
{
	return E('span', { 'class': 'label ' + style }, [ text ]);
}

function sensorName(sensor)
{
	switch (sensor.id) {
	case 'cpu':
		return _('CPU（最高核心）');
	case 'soc':
		return _('SoC');
	case 'eth2':
		return _('2.5G LAN');
	case 'eth3':
		return _('10G WAN');
	case 'wifi-2g':
		return _('2.4 GHz');
	case 'wifi-5g':
		return _('5 GHz');
	case 'wifi-6g':
		return _('6 GHz');
	default:
		return sensor.label || sensor.id || _('传感器');
	}
}

function sensorBadge(sensor, fan)
{
	var temp = Number(sensor.temperature);
	var limit = Number(sensor.max_temperature);
	var style = 'success';
	var title = sensor.source || '';

	if (sensor.id === 'soc') {
		var hot = (fan.trips || []).find(function(t) { return t.type === 'hot'; });
		var critical = (fan.trips || []).find(function(t) { return t.type === 'critical'; });

		if (critical && temp >= Number(critical.temperature))
			style = 'important';
		else if (hot && temp >= Number(hot.temperature))
			style = 'warning';
	}

	if (style === 'success' && isFinite(limit) && sensor.max_temperature != null && temp >= limit)
		style = 'important';
	else if (style === 'success' && isFinite(limit) && sensor.max_temperature != null && temp >= limit - 10000)
		style = 'warning';
	else if (style === 'success' && temp >= 95000)
		style = 'important';
	else if (style === 'success' && temp >= 80000)
		style = 'warning';

	if (sensor.max_temperature != null)
		title += (title ? ' · ' : '') + _('上限') + ' ' + fmtTemp(sensor.max_temperature);

	return E('span', {
		'class': 'label ' + style,
		'title': title || null
	}, [ '%s %s'.format(sensorName(sensor), fmtTemp(sensor.temperature)) ]);
}

function hardwareTemperatures(fan)
{
	var sensors = Array.isArray(fan.sensors) ? fan.sensors.slice() : [];

	/* Keep the include compatible with an older backend during upgrades. */
	if (!sensors.length && fan.temperature != null)
		sensors.push({ id: 'soc', temperature: fan.temperature, source: fan.zone_type });

	if (!sensors.length)
		return badge('warning', _('未检测到可读温度传感器'));

	sensors.sort(function(a, b) {
		var ai = SENSOR_ORDER.indexOf(a.id);
		var bi = SENSOR_ORDER.indexOf(b.id);

		return (ai < 0 ? SENSOR_ORDER.length : ai) -
			(bi < 0 ? SENSOR_ORDER.length : bi);
	});

	return E('div', {
		'style': 'display:flex;flex-wrap:wrap;gap:.35em .45em'
	}, sensors.map(function(sensor) {
		return sensorBadge(sensor, fan);
	}));
}

function fanCurve(fan)
{
	var levels = fan.levels || [];
	var active = (fan.trips || []).filter(function(t) {
		return t.type === 'active';
	}).sort(function(a, b) {
		return Number(a.temperature) - Number(b.temperature);
	});

	if (!active.length)
		return '-';

	return active.map(function(t, i) {
		return '%s → %s'.format(fmtTemp(t.temperature),
			levels[i] == null ? _('档位 %d').format(i) : '%d / 255'.format(levels[i]));
	}).join(' · ');
}

function protection(fan)
{
	var values = [];

	(fan.trips || []).forEach(function(t) {
		if (t.type === 'hot')
			values.push('hot ' + fmtTemp(t.temperature));
		else if (t.type === 'critical')
			values.push('critical ' + fmtTemp(t.temperature));
	});

	return values.length ? values.join(' · ') : '-';
}

function hysteresis(fan)
{
	var values = [];

	(fan.trips || []).forEach(function(t) {
		if (t.type !== 'active' || t.hysteresis == null)
			return;

		var value = fmtTemp(t.hysteresis);
		if (values.indexOf(value) < 0)
			values.push(value);
	});

	return values.length ? values.join(' · ') : '-';
}

function addRow(table, title, value)
{
	table.appendChild(E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, [ title ]),
		E('td', { 'class': 'td left' }, [ value ])
	]));
}

return baseclass.extend({
	title: _('温度与风扇'),

	load: function()
	{
		return L.resolveDefault(fetchFanStatus(), {});
	},

	render: function(fan)
	{
		var table = E('table', { 'class': 'table' });
		fan = fan || {};

		addRow(table, _('硬件温度'), hardwareTemperatures(fan));

		if (!fan.present) {
			addRow(table, _('状态'), badge('important', _('未检测到 pwm-fan 温控节点')));
			return table;
		}

		addRow(table, _('pwm-fan 驱动'), fan.module_loaded
			? badge('success', _('已加载'))
			: badge('important', _('未加载')));
		addRow(table, _('风扇档位'), '%s / %s'.format(
			fan.cooling_state == null ? '-' : fan.cooling_state,
			fan.max_state == null ? '-' : fan.max_state));
		addRow(table, _('PWM 占空比'), fmtPwm(fan.pwm));
		addRow(table, _('内核控制'), fan.policy === 'step_wise'
			? badge('success', 'step_wise · ' + _('自动调速'))
			: badge('warning', fan.policy || _('策略不可用')));
		addRow(table, _('温控区域'), '%s (%s)'.format(fan.zone_type || '-', fan.zone || '-'));
		addRow(table, _('调速曲线'), fanCurve(fan));
		addRow(table, _('温控回差'), hysteresis(fan));
		addRow(table, _('过热保护'), protection(fan));
		addRow(table, _('转速反馈'), _('无 TACH/RPM 节点，仅显示 PWM'));

		return table;
	}
});
