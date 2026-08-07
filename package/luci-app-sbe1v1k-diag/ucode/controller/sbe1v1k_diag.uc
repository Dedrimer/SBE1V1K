'use strict';

/*
 * SBE1V1K (IPQ9574) hardware diagnostics backend.
 * Reads the PPE / EIP debugfs, proc and sysfs nodes, extracts the
 * important counters and returns them as compact JSON.
 */

import { open, glob, stat, popen, basename } from 'fs';
import { cursor } from 'uci';

const MAX_READ = 65536;

function read_text(path, maxlen)
{
	if (maxlen == null)
		maxlen = MAX_READ;

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

function pick_int(text, re)
{
	let m = match(text ?? '', re);

	return m != null ? int(m[1]) : null;
}

/*
 * Parse lines of the form "key = value", "key: value" or "key - value"
 * and return { total, nonzero: [{ name, value }] }.
 */
function parse_counter_stats(text)
{
	let out = { total: 0, nonzero: [] };

	for (let line in split(text ?? '', '\n')) {
		let m = match(line, /^[[:space:]]*(.+)[[:space:]]*(=|:|-)[[:space:]]*(\d+)[[:space:]]*$/);

		if (m != null) {
			let value = int(m[3]);

			out.total++;

			if (value != 0)
				push(out.nonzero, { name: trim(m[1]), value });
		}
	}

	return out;
}

function parse_qm(text)
{
	let out = { total: { tx: 0, pend: 0, drop: 0 }, queues: [] };

	for (let m in (match(text ?? '', /(\d+)\/(\d+)\/(\d+)\(queue=([0-9a-fA-F]+)\)/g) ?? [])) {
		let q = { queue: m[4], tx: int(m[1]), pend: int(m[2]), drop: int(m[3]) };

		out.total.tx += q.tx;
		out.total.pend += q.pend;
		out.total.drop += q.drop;
		push(out.queues, q);
	}

	return out;
}

function parse_cpu_code(text)
{
	let out = [];

	for (let m in (match(text ?? '', /(\d+)\(port=([0-9a-fA-F]+)\),dropcode:(\d+)/g) ?? []))
		push(out, { port: m[2], code: int(m[1]), dropcode: int(m[3]) });

	return out;
}

function parse_port_stats(text)
{
	let out = { ports: [], vports: [] };

	for (let line in split(text ?? '', '\n')) {
		let m = match(line, /^(PORT|VPORT)\s+\S+\/\S+:\s*(.*)$/);

		if (m == null)
			continue;

		let items = [];

		for (let n in (match(m[2], /(\d+)\/(\d+)\(port=([0-9a-fA-F]+)\)/g) ?? []))
			push(items, { port: n[3], count: int(n[1]), drop: int(n[2]) });

		if (m[1] == 'PORT')
			out.ports = items;
		else
			out.vports = items;
	}

	return out;
}

function parse_direct_switch(text)
{
	let out = { flow_enqueue_map: [], port_qmaps: [], nodes: [] };

	for (let line in split(text ?? '', '\n')) {
		let m;

		if ((m = match(line, /^flow_enqueue_map\s+(.*)$/)) != null) {
			out.flow_enqueue_map = split(m[1], ' ');
		}
		else if ((m = match(line, /^(port\d+_qmap)\s+(.*)$/)) != null) {
			push(out.port_qmaps, m[1] + ' ' + m[2]);
		}
		else if ((m = match(line, /^node(\d+)\s+state=(\d+)\s+ring=(\d+)\s+map=([0-9\/]+)\s+queues=([0-9\-]+)\s+enqueue_vp=(\d+)\s+profile=(\d+)/)) != null) {
			push(out.nodes, {
				node: int(m[1]),
				state: int(m[2]),
				ring: int(m[3]),
				queues: m[5],
				enqueue_vp: int(m[6]),
				profile: int(m[7]),
				start: pick_int(line, /start=(\d+)/),
				stop: pick_int(line, /stop=(\d+)/)
			});
		}
	}

	return out;
}

function parse_flows(text)
{
	let m = match(text ?? '', /bound:(\d+) replace:(\d+) unsupported:(\d+) failed:(\d+) destroy:(\d+) zombies:(\d+)/);

	return m != null
		? { bound: int(m[1]), replace: int(m[2]), unsupported: int(m[3]), failed: int(m[4]), destroy: int(m[5]), zombies: int(m[6]) }
		: null;
}

function parse_ds_summary(text)
{
	let out = {
		registered: pick_int(text, /registered:\s*(\d+)/),
		started: pick_int(text, /started:\s*(\d+)/),
		quiesced: pick_int(text, /quiesced:\s*(\d+)/),
		reuse: pick_int(text, /reuse:\s*(\d+)/),
		ppe2tcl_prod: null,
		ppe2tcl_cons: null,
		reo2ppe_prod: null,
		reo2ppe_cons: null,
		tx_alloc: null,
		tx_alloc_fail: null,
		tx_complete: null,
		rx_complete: null,
		rx_requeue: null,
		rx_drop: null
	};
	let m;

	if ((m = match(text, /ppe2tcl_updates:\s*prod=(\d+) cons=(\d+)/)) != null) {
		out.ppe2tcl_prod = int(m[1]);
		out.ppe2tcl_cons = int(m[2]);
	}

	if ((m = match(text, /reo2ppe_updates:\s*prod=(\d+) cons=(\d+)/)) != null) {
		out.reo2ppe_prod = int(m[1]);
		out.reo2ppe_cons = int(m[2]);
	}

	out.tx_alloc = pick_int(text, /tx_alloc:\s*(\d+)/);
	out.tx_alloc_fail = pick_int(text, /tx_alloc_fail:\s*(\d+)/);
	out.tx_complete = pick_int(text, /tx_complete:\s*(\d+)/);
	out.rx_complete = pick_int(text, /rx_complete:\s*(\d+)/);
	out.rx_requeue = pick_int(text, /rx_requeue:\s*(\d+)/);
	out.rx_drop = pick_int(text, /rx_drop:\s*(\d+)/);

	return out;
}

function parse_ath12k(text)
{
	let out = { rx: null, tx: null, direct_switch: null };
	let rx_start = index(text, 'DEVICE RX STATS:');
	let tx_start = index(text, 'DEVICE TX STATS:');
	let ds_start = index(text, 'PPE DIRECT-SWITCH STATS:');

	if (rx_start >= 0 && tx_start > rx_start)
		out.rx = parse_counter_stats(substr(text, rx_start, tx_start - rx_start));

	if (tx_start >= 0 && ds_start > tx_start)
		out.tx = parse_counter_stats(substr(text, tx_start, ds_start - tx_start));

	if (ds_start >= 0)
		out.direct_switch = parse_ds_summary(substr(text, ds_start));

	return out;
}

function parse_ring(text)
{
	let out = {};

	for (let line in split(text ?? '', '\n')) {
		let m = match(line, /^(Tx|Rx) ([A-Za-z ]+)[[:space:]]*-[[:space:]]*(\d+)$/);

		if (m != null)
			out[lc(m[1]) + '_' + replace(lc(trim(m[2])), / /g, '_')] = int(m[3]);
	}

	return out;
}

function parse_flow_table(text)
{
	return {
		max_buckets: pick_int(text, /Maximum Buckets:\s*(\d+)/),
		active_flows: pick_int(text, /Total Active Flows\s*=\s*(\d+)/)
	};
}

function parse_interrupts(text)
{
	let out = [];

	for (let line in split(text ?? '', '\n')) {
		let m = match(line, /^\s*(\d+):\s+([0-9 ]+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(.+)$/);

		if (m != null) {
			let count = 0;

			for (let c in split(m[2], ' ')) {
				if (length(c))
					count += int(c);
			}

			push(out, { irq: int(m[1]), count, name: m[6] });
		}
	}

	return out;
}

function parse_modules(text)
{
	let out = [];

	for (let line in split(text ?? '', '\n')) {
		let m = match(line, /^(\S+)\s+(\d+)\s+(\d+)\s+(.*)\s+Live\s+(0x[0-9a-fA-F]+)\s*(\(O\))?\s*$/);

		if (m != null) {
			let deps = trim(replace(m[4] ?? '', /,$/g, ''));

			push(out, {
				name: m[1],
				size: int(m[2]),
				refs: int(m[3]),
				deps: length(deps) ? deps : '-',
				live: true,
				out_of_tree: m[6] != null
			});
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
	let cu = cursor();
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

	cu.load('firewall');

	for (let key in ppe_paths)
		ppe_nodes[key] = read_text(ppe_paths[key]);

	let ath12k = [];

	for (let path in (glob('/sys/kernel/debug/ath12k/*/device_dp_stats') ?? [])) {
		let data = read_text(path);

		if (data != null) {
			let parts = split(path, '/');
			let id = parts[length(parts) - 2] ?? basename(path);

			push(ath12k, { id, stats: parse_ath12k(data) });
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
	eip.interrupts = parse_interrupts(run('grep -Ei "eip.*ring|ring.*eip" /proc/interrupts'));
	eip.flow_table = parse_flow_table(read_text('/sys/kernel/debug/qca-nss-eip/eip197/eip_flow_table'));

	eip.rings = [];
	eip.ipsec_ctx = [];
	eip.service_stats = [];

	for (let path in (glob('/sys/kernel/debug/qca-nss-eip/eip197/ring_*') ?? [])) {
		if (stat(path))
			push(eip.rings, { name: basename(path), stats: parse_ring(read_text(path)) });
	}

	for (let pat in [ 'eip_ipsec_ctx@*', 'eip_hy_ipsec_ctx@*' ]) {
		for (let path in (glob('/sys/kernel/debug/qca-nss-eip/eip197/' + pat) ?? [])) {
			if (stat(path))
				push(eip.ipsec_ctx, { name: basename(path), stats: parse_counter_stats(read_text(path)) });
		}
	}

	for (let svc in [ 'aead', 'skcipher', 'ahash' ]) {
		let data = read_text('/sys/kernel/debug/qca-nss-eip/eip197/' + svc + '/stats');

		if (data != null)
			push(eip.service_stats, { name: svc, stats: parse_counter_stats(data) });
	}

	let uptime = read_text('/proc/uptime');
	let uptime_up = null;

	if (uptime != null) {
		let m = match(uptime, /^([0-9]+(\.[0-9]+)?)/);

		if (m != null)
			uptime_up = int(m[1]);
	}

	let ppe = {
		qm: parse_qm(ppe_nodes.qm),
		cpu_code: parse_cpu_code(ppe_nodes.cpu_code),
		port_rx: parse_port_stats(ppe_nodes.port_rx),
		port_tx: parse_port_stats(ppe_nodes.port_tx),
		direct_switch: parse_direct_switch(ppe_nodes.direct_switch),
		flows: parse_flows(ppe_nodes.flows),
		eip_outer_flows: ppe_nodes.eip_outer_flows != null,
		edma: {
			err: parse_counter_stats(ppe_nodes.edma_err_stats),
			rx: parse_counter_stats(ppe_nodes.edma_rx_ring_stats),
			tx: parse_counter_stats(ppe_nodes.edma_tx_ring_stats)
		},
		ath12k
	};

	return {
		generated: time(),
		model: read_text('/tmp/sysinfo/model'),
		uptime: { raw: uptime, up: uptime_up },
		firewall: {
			flow_offloading: cu.get_first('firewall', 'defaults', 'flow_offloading'),
			flow_offloading_hw: cu.get_first('firewall', 'defaults', 'flow_offloading_hw')
		},
		modules: parse_modules(run('grep -E "(^| )(qcom_ppe|qca_nss_eip|nf_flow_table|nft_flow_offload|nft_flow_table) " /proc/modules')),
		abi: {
			qcom_ppe_ds_start: ks != null && match(ks, /qcom_ppe_ds_start/) != null,
			qcom_ppe_ds_vp_alloc: ks != null && match(ks, /qcom_ppe_ds_vp_alloc/) != null,
			qcom_ppe_ds_queue_start: ks != null && match(ks, /qcom_ppe_ds_queue_start/) != null,
			qcom_ppe_eip_provider: ks != null && match(ks, /qcom_ppe_eip_provider_register/) != null
		},
		ppe,
		eip
	};
}

return {
	action_status: function()
	{
		http.prepare_content('application/json');
		http.write_json(collect());
	}
};