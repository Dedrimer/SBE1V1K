#!/bin/sh

. /lib/functions.sh

/usr/libexec/network/packet-steering.uc "$@" || exit $?

[ "$(board_name)" = "askey,sbe1v1k" ] || exit 0

# EDMA already spreads receive traffic across four hardware rings whose
# interrupts are affined to separate CPUs. Software RPS would move every
# queue back to one CPU and undo that distribution.
for queue in /sys/class/net/eth*/queues/rx-*/rps_cpus; do
	[ -e "$queue" ] || continue
	echo 0 > "$queue"
done
