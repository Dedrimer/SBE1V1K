'use strict';

'require baseclass';

const FAN_STATUS = L.url('admin/status/overview/sbe1v1k_fan');

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

function currentTemperature(fan)
{
	var temp = Number(fan.temperature);
	var hot = (fan.trips || []).find(function(t) { return t.type === 'hot'; });
	var critical = (fan.trips || []).find(function(t) { return t.type === 'critical'; });
	var style = 'success';

	if (critical && temp >= Number(critical.temperature))
		style = 'important';
	else if (hot && temp >= Number(hot.temperature))
		style = 'warning';
	else if (temp >= 80000)
		style = 'notice';

	return badge(style, fmtTemp(fan.temperature));
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

		if (!fan || !fan.present) {
			addRow(table, _('状态'), badge('important', _('未检测到 pwm-fan 温控节点')));
			return table;
		}

		addRow(table, _('当前温度'), currentTemperature(fan));
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
