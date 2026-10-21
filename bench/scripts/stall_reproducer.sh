#!/bin/bash
# Stall reproducer (docs/benchmarks.md "Latency stalls on 1 GB boards"): catch a stall and the kernel stack where
# cyclictest blocks (state D). Works on KOS (user klipper) and stock images (user biqu/pi); needs rt-tests + stress-ng.
#   sudo bash bench/scripts/stall_reproducer.sh <label> <runs>      results in ~/stall-<label>/
# Before each run: write 300 MB of fresh data (left dirty, like apt in the bench). Then the bench's load +
# cyclictest; core-3 events go to the trace buffer and cyclictest -b 3000 stops tracing at the first
# wakeup later than 3 ms. Stops at the first caught run.
set -u
LABEL=${1:?label}; RUNS=${2:?runs}
H=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6); OUT=$H/stall-$LABEL; mkdir -p "$OUT"
T=/sys/kernel/tracing; DIRTY=$H/printer_data/stall-dirty.bin
restore() { echo '!stacktrace' > $T/events/sched/sched_switch/trigger 2>/dev/null; echo 0 > $T/tracing_on; echo 0 > $T/events/enable; echo f > $T/tracing_cpumask; echo 1408 > $T/buffer_size_kb; }
trap restore EXIT

echo 0 > $T/tracing_on; echo nop > $T/current_tracer; echo 0 > $T/events/enable
echo 8 > $T/tracing_cpumask; echo 16384 > $T/buffer_size_kb
for e in sched/sched_switch sched/sched_wakeup sched/sched_migrate_task irq/irq_handler_entry irq/irq_handler_exit \
         irq/softirq_entry irq/softirq_exit workqueue/workqueue_execute_start workqueue/workqueue_execute_end \
         ipi timer/hrtimer_expire_entry timer/hrtimer_expire_exit; do
    [ -e $T/events/$e/enable ] && echo 1 > $T/events/$e/enable
done
for f in migrate/enable compaction/enable; do [ -e $T/events/$f ] && echo 1 > $T/events/$f; done

echo 'stacktrace if prev_comm == "cyclictest" && prev_state & 2' > $T/events/sched/sched_switch/trigger
echo "label=$LABEL $(date -Is)" > "$OUT/summary.txt"
for r in $(seq "$RUNS"); do
    dd if=/dev/urandom of=$DIRTY bs=1M count=300 status=none     # no sync: leave it dirty
    echo > $T/trace; echo 1 > $T/tracing_on
    stress-ng --cpu "$(nproc)" --vm 1 --vm-bytes 256M --io 1 -t 65s >/dev/null 2>&1 & s=$!
    sleep 2
    res=$(cyclictest -q -m --policy=other -p 0 -a 3 -t 1 -i 1000 -D 60 -b 3000 --tracemark 2>&1 | tail -3 | tr '\n' ' ')
    kill $s 2>/dev/null; wait $s 2>/dev/null
    if [ "$(cat $T/tracing_on)" = 0 ]; then
        cp $T/trace "$OUT/run$r-trace.txt"
        echo "run $r: CAUGHT $res" >> "$OUT/summary.txt"; break
    fi
    echo 0 > $T/tracing_on
    echo "run $r: no stall >3 ms $res" >> "$OUT/summary.txt"
done
echo "done $(date -Is)" >> "$OUT/summary.txt"
