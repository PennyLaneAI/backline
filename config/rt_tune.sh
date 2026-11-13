#!/usr/bin/env bash
# Low-jitter settings for the coprocessor host's polling cores. Run as root after every boot, with
# the cores already isolated on the kernel command line (isolcpus, nohz_full, rcu_nocbs).
#
#   sudo ./rt_tune.sh <isolated-cpus> <nic>      e.g. sudo ./rt_tune.sh 24,25,26 enp1s0f1np1
set -euo pipefail

ISO="${1:?usage: rt_tune.sh <isolated-cpu-list e.g. 4,16> <nic-ifname>}"
NIC="${2:?need nic ifname}"

echo "[rt_tune] isolated CPUs = $ISO   NIC = $NIC"

# Online CPUs from sysfs, as a comma list (nproc --all also counts offline ones).
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

# Refuse isolated CPUs that are not online.
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

# No RT throttling, so a SCHED_FIFO poller is never made to yield.
sysctl -w kernel.sched_rt_runtime_us=-1

# Performance governor and EPP, where the kernel exposes cpufreq; otherwise the firmware owns them.
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
# Deep C-states off, where cpupower can do it.
if command -v cpupower >/dev/null; then
    cpupower idle-set -D 0 >/dev/null 2>&1 && echo "[rt_tune] cpupower idle-set -D 0" || true
fi

# Stop irqbalance, then move the NIC's IRQs to the housekeeping CPUs.
systemctl stop irqbalance 2>/dev/null || true
# Housekeeping CPUs: every online CPU but the isolated ones.
HOUSE="$(python3 - "$ONLINE_CSV" "$ISO" <<'PY'
import sys
allc=set(int(x) for x in sys.argv[1].split(',') if x!='')
iso=set(int(x) for x in sys.argv[2].split(',') if x!='')
print(','.join(str(x) for x in sorted(allc-iso)))
PY
)"
echo "[rt_tune] housekeeping CPUs = $HOUSE"
# mlx5 names its IRQs by PCI address rather than interface, so match either.
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

# Unbound kernel workqueues on the housekeeping CPUs.
echo "$HOUSE" > /sys/devices/virtual/workqueue/cpumask 2>/dev/null || true

# No NUMA balancing or transparent huge pages, which scan memory in the background.
sysctl -w kernel.numa_balancing=0
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

# Machine-check polling off. CPU 0's interval applies to every CPU.
MCE_IV=/sys/devices/system/machinecheck/machinecheck0/check_interval
if [[ -f $MCE_IV ]]; then
    echo 0 > "$MCE_IV" && echo "[rt_tune] machine-check polling off"
fi

# Kernel threads allowed on several CPUs, such as kcompactd, off the isolated cores.
python3 - "$ISO" "$HOUSE" <<'PY'
import os, sys
def cpus(s):
    out = set()
    for part in s.strip().split(','):
        if '-' in part:
            a, b = map(int, part.split('-')); out.update(range(a, b + 1))
        elif part:
            out.add(int(part))
    return out
iso, house = cpus(sys.argv[1]), cpus(sys.argv[2])
for pid in filter(str.isdigit, os.listdir('/proc')):
    try:
        ppid = int(open(f'/proc/{pid}/stat').read().rsplit(')', 1)[1].split()[1])
        allowed = os.sched_getaffinity(int(pid))
        comm = open(f'/proc/{pid}/comm').read().strip()
    except OSError:
        continue
    if ppid != 2 or len(allowed) < 2 or not allowed & iso:  # kernel threads are kthreadd's children
        continue
    keep = (allowed - iso) or house
    try:
        os.sched_setaffinity(int(pid), keep)
        print(f"  {comm} -> {','.join(map(str, sorted(keep)))}")
    except OSError:
        pass  # per-CPU and rescuer threads refuse a new affinity
PY

# Report IRQs still on an isolated CPU; the kernel manages some and does not let them move.
python3 - "$ISO" <<'PY'
import glob, sys
iso = {int(c) for c in sys.argv[1].split(',') if c}
names = {}
for line in open('/proc/interrupts'):
    f = line.split()
    if f and f[0].rstrip(':').isdigit():
        names[f[0].rstrip(':')] = f[-1]
for path in sorted(glob.glob('/proc/irq/*/effective_affinity_list')):
    irq = path.split('/')[3]
    cpus = set()
    for part in open(path).read().strip().split(','):
        if '-' in part:
            a, b = map(int, part.split('-')); cpus.update(range(a, b + 1))
        elif part:
            cpus.add(int(part))
    if cpus & iso:
        print(f"  [warn] IRQ {irq} ({names.get(irq, '?')}) fires on {sorted(cpus & iso)}")
PY

echo "[rt_tune] done. verify with: cyclictest -m -p99 -a${ISO%%,*} -t1 -n -D30"
