'use strict';

/*
 * SBE1V1K (IPQ9574) hardware diagnostics backend.
 * Reads the same debugfs / proc / sysfs / DT nodes used by
 * ppe-diag, eip-diag and wifi-rate-diag and returns them as JSON.
 */

import { open, glob, stat, popen, basename } from 'fs';
import { uci } from 'uci';

const MAX_READ = 65536;

function read_text(path, maxlen = MAX_READ)
{
	let fd = open(path, 'r');

	if (!fd)
		return null;

	let data = fd.read(maxlen);

	fd.close();
	return data;
}

function run(cmd)
{
	let fd = popen(cmd);

	if (!fd)
		return null;

	let data = fd.read(MAX_READ);

	fd.close();
	return data ?? '';
}

function grep_files(pattern)
{
	let out = {};
	let root = '/sys/kernel/debug/qca-nss-eip/eip197';

	for (let pat in pattern) {
		for (let path in (glob(root + '/' + pat) ?? [])) {
			if (stat(path))
				out[basename(path)] = read_text(path);
		}
	}

	return out;
}

function find_eip_node()
{
	for (let base in [ '/sys/firmware/devicetree/base/soc@0', '/proc/device-tree/soc@0' ]) {
		for (let node in (glob(base + '/*@39800000') ?? [])) {
			let compat = read_text(node + '/compatible');

			if (compat != null && match(compat, /qcom,eip/))
				return node;
		}
	}

	return null;
}

function collect()
{
	let cu = uci.cursor();
	let ppe_nodes = {};
	let ppe_paths = {
		qm: '/sys/kernel/debug/ppe/qm',
		cpu_code: '/sys/kernel/debug/ppe/cpu_code',
		port_rx: '/sys/kernel/debug/ppe/port_rx',
		port_tx: '/sys/kernel/debug/ppe/port_tx',
		direct_switch: '/sys/kernel/debug/ppe/direct_switch',
		flows: '/sys/kernel/debug/ppe/flows',
		eip_outer_flows: '/sys/kernel/debug/ppe/eip_outer_flows',
		edma_err_stats: '/sys/kernel/debug/ppe/edma/stats/err_stats',
		edma_rx_ring_stats: '/sys/kernel/debug/ppe/edma/stats/rx_ring_stats',
		edma_tx_ring_stats: '/sys/kernel/debug/ppe/edma/stats/tx_ring_stats'
	};
	let eip = {};
	let eip_node = find_eip_node();
	let ks = run('grep -Ew "qcom_ppe_ds_start|qcom_ppe_ds_vp_alloc|qcom_ppe_ds_queue_start|qcom_ppe_eip_provider_register|qcom_ppe_eip_provider_unregister" /proc/kallsyms');
	let crypto = read_text('/proc/crypto');
	let eip_algorithms = 0;

	if (crypto != null) {
		for (let line in split(crypto, '\n')) {
			if (match(line, /^driver\s*:/) && match(line, /eip-/))
				eip_algorithms++;
		}
	}

	cu.load('system');
	cu.load('firewall');

	for (let key in ppe_paths)
		ppe_nodes[key] = read_text(ppe_paths[key]);

	let ath12k = {};

	for (let path in (glob('/sys/kernel/debug/ath12k/*/device_dp_stats') ?? [])) {
		let data = read_text(path);

		if (data != null) {
			let parts = split(path, '/');
			let id = parts[length(parts) - 2] ?? basename(path);

			ath12k[id] = data;
		}
	}

	if (eip_node != null) {
		let status = read_text(eip_node + '/status');

		eip.dt = {
			node: eip_node,
			status: status != null ? status : 'okay',
			inline_enabled: stat(eip_node + '/qcom,inline-enabled') ? 'yes' : 'no',
			outer_offload: stat(eip_node + '/qcom,outer-offload') ? 'yes' : 'no',
			inner_offload: stat(eip_node + '/qcom,inner-offload') ? 'yes' : 'no'
		};
	}
	else {
		eip.dt = { node: null, status: 'missing' };
	}

	let firmware = {};

	for (let file in [ 'ifpp.bin', 'ipue.bin', 'ofpp.bin', 'opue.bin' ]) {
		let st = stat('/lib/firmware/' + file);

		firmware[file] = st ? 'present size=' + (st.size ?? '?') : 'missing';
	}

	eip.firmware = firmware;
	eip.algorithms = eip_algorithms;
	eip.interrupts = run('grep -Ei "eip.*ring|ring.*eip" /proc/interrupts');
	eip.stats = grep_files([ 'ring_*', 'eip_ipsec_ctx@*', 'eip_hy_ipsec_ctx@*', 'ipsectun*', 'aead/stats', 'skcipher/stats', 'ahash/stats' ]);
	eip.flow_table = read_text('/sys/kernel/debug/qca-nss-eip/eip197/eip_flow_table');

	let led = {
		configured: false,
		name: cu.get('system', 'green_status', 'name'),
		trigger: cu.get('system', 'green_status', 'trigger'),
		inverted: cu.get('system', 'green_status', 'inverted'),
		default: cu.get('system', 'green_status', 'default'),
		sysfs_trigger: read_text('/sys/class/leds/green:status/trigger'),
		brightness: read_text('/sys/class/leds/green:status/brightness'),
		max_brightness: read_text('/sys/class/leds/green:status/max_brightness')
	};

	led.configured = led.name != null;

	return {
		generated: time(),
		model: read_text('/tmp/sysinfo/model'),
		uptime: read_text('/proc/uptime'),
		led: led,
		firewall: {
			flow_offloading: cu.get_first('firewall', 'defaults', 'flow_offloading'),
			flow_offloading_hw: cu.get_first('firewall', 'defaults', 'flow_offloading_hw')
		},
		modules: split(run('grep -E "(^| )(qcom_ppe|qca_nss_eip|nf_flow_table|nft_flow_offload|nft_flow_table) " /proc/modules') ?? '', '\n'),
		abi: {
			qcom_ppe_ds_start: ks != null && match(ks, /qcom_ppe_ds_start/) != null,
			qcom_ppe_ds_vp_alloc: ks != null && match(ks, /qcom_ppe_ds_vp_alloc/) != null,
			qcom_ppe_ds_queue_start: ks != null && match(ks, /qcom_ppe_ds_queue_start/) != null,
			qcom_ppe_eip_provider: ks != null && match(ks, /qcom_ppe_eip_provider_register/) != null
		},
		ppe: {
			nodes: ppe_nodes,
			ath12k_dp_stats: ath12k
		},
		eip: eip
	};
}

return {
	action_status: function()
	{
		http.prepare_content('application/json');
		http.write_json(collect());
	}
};
