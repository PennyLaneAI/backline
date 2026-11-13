#!/usr/bin/env bash
# Runtime low-jitter tuning for the GPU box — the half that GRUB/isolcpus can't do.
# Run AFTER each boot (needs root). isolcpus/nohz_full/rcu_nocbs must already be on
# the kernel cmdline (see inspect_topology.sh + /etc/default/grub).
#
#   sudo ./rt_tune.sh <isolated-cpu-list> <nic-ifname>
#   e.g. sudo ./rt_tune.sh 4,16 enp1s0f1
set -euo pipefail

ISO="${1:?usage: rt_tune.sh <isolated-cpu-list e.g. 4,16> <nic-ifname>}"
NIC="${2:?need nic ifname}"

echo "[rt_tune] isolated CPUs = $ISO   NIC = $NIC"

# Online CPU list from sysfs (nproc --all is wrong when SMT is off / CPUs offline).
ONLINE="$(cat /sys/devices/system/cpu/online | tr -d '\n')"
ONLINE_CSV="$(python3 - "$ONLINE" <<'PY'
import sys
out=[]
for part in sys.argv[1].split(','):
    if '-' in part:
        a,b=map(int,part.split('-')); out.extend(range(a,b+1))
    else:
        out.append(int(part))
print(','.join(map(str,out)))
PY
)"
echo "[rt_tune] online CPUs = $ONLINE_CSV"

# Reject isolated CPUs that are not online (e.g. old SMT IDs after Logical Processor=Disabled).
python3 - "$ONLINE_CSV" "$ISO" <<'PY'
import sys
online=set(int(x) for x in sys.argv[1].split(',') if x!='')
iso=set(int(x) for x in sys.argv[2].split(',') if x!='')
bad=sorted(iso-online)
if bad:
    print(f"[rt_tune] ERROR: isolated CPUs not online: {bad}", file=sys.stderr)
    print(f"  online={sorted(online)}", file=sys.stderr)
    print("  After disabling SMT, renumber — use lscpu -e / numactl -H.", file=sys.stderr)
    sys.exit(1)
PY

# (a) no RT throttling — let SCHED_FIFO run 100% without the ~50ms/s forced yield.
sysctl -w kernel.sched_rt_runtime_us=-1

# (b) lock freq / EPP to performance when the kernel exposes cpufreq.
#     Dell/EPYC often has NO /sys/.../cpufreq at all (firmware/BIOS owns P-states) —
#     cpupower then always errors; that is OK if BIOS already pins High Performance.
if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance > "$g" 2>/dev/null || true
        done
        echo "[rt_tune] scaling_governor -> performance"
    fi
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
        for e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            echo performance > "$e" 2>/dev/null || true
        done
        echo "[rt_tune] energy_performance_preference -> performance"
    fi
else
    echo "[rt_tune] no cpufreq sysfs — OS cannot set governor (BIOS/firmware owns freq); skipping"
fi
# Deep C-states off when possible (reduces wake latency jitter).
if command -v cpupower >/dev/null; then
    cpupower idle-set -D 0 >/dev/null 2>&1 && echo "[rt_tune] cpupower idle-set -D 0" || true
fi

# (c) stop irqbalance and steer NIC IRQs off the isolated cores. irqbalance would
#     otherwise migrate them right back.
systemctl stop irqbalance 2>/dev/null || true
# housekeeping = every online CPU except the isolated ones
HOUSE="$(python3 - "$ONLINE_CSV" "$ISO" <<'PY'
import sys
allc=set(int(x) for x in sys.argv[1].split(',') if x!='')
iso=set(int(x) for x in sys.argv[2].split(',') if x!='')
print(','.join(str(x) for x in sorted(allc-iso)))
PY
)"
echo "[rt_tune] housekeeping CPUs = $HOUSE"
# mlx5 (ConnectX) IRQs are named "mlx5_comp*@pci:<bdf>", NOT the ifname. Derive the
# NIC's PCI BDF and match interrupts by ifname OR that BDF OR the mlx5_ prefix.
BDF="$(basename "$(readlink -f /sys/class/net/$NIC/device 2>/dev/null)" 2>/dev/null || true)"
echo "[rt_tune] NIC PCI BDF = ${BDF:-<unknown>}"
matched=0
for irq in $(awk -F: -v nic="$NIC" -v bdf="$BDF" \
        '$0 ~ nic || (bdf!="" && index($0,bdf)>0) {print $1}' /proc/interrupts | tr -d ' '); do
    if echo "$HOUSE" > /proc/irq/$irq/smp_affinity_list 2>/dev/null; then
        echo "  IRQ $irq -> $HOUSE"; matched=$((matched+1))
    fi
done
[ "$matched" -eq 0 ] && echo "  [warn] no NIC IRQs matched — check: grep -E '$NIC|mlx5' /proc/interrupts"

# (d) keep unbound kernel workqueues off the isolated cores.
echo "$HOUSE" > /sys/devices/virtual/workqueue/cpumask 2>/dev/null || true

# (e) kill background scanners that cause periodic stalls.
sysctl -w kernel.numa_balancing=0
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

echo "[rt_tune] done. verify with: cyclictest -m -p99 -a${ISO%%,*} -t1 -n -D30"
