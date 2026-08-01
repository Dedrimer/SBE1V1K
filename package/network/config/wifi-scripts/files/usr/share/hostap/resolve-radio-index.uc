#!/usr/bin/env ucode
'use strict';

let nl = require('nl80211');

let phy_name = shift(ARGV);
let band_name = lc(shift(ARGV) ?? '');
let fallback = shift(ARGV);

const band_ranges = {
	'2g': [ 2400000, 2500000 ],
	'5g': [ 4900000, 5924999 ],
	'6g': [ 5925000, 7125000 ]
};

function ranges_overlap(a, b) {
	return a.end >= b[0] && a.start <= b[1];
}

let wanted = band_ranges[band_name];
let phys = nl.request(
	nl.const.NL80211_CMD_GET_WIPHY,
	nl.const.NLM_F_DUMP,
	{ split_wiphy_dump: true }
);

if (wanted && phys) {
	for (let phy in phys) {
		if (!phy || phy.wiphy_name != phy_name)
			continue;

		for (let radio in phy.radios ?? []) {
			for (let range in radio.freq_ranges ?? []) {
				if (!ranges_overlap(range, wanted))
					continue;

				print(`${radio.index}\n`);
				exit(0);
			}
		}
	}
}

if (fallback != null)
	print(`${fallback}\n`);
