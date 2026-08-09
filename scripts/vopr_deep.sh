#!/usr/bin/env bash
# Parallel VOPR sweep: disjoint seed ranges per worker, every 4th worker runs
# the deep profile (more nodes, longer op schedules) with a quarter of the
# per-worker seed count to balance wall time. Scenarios are fully in-process,
# so workers cannot interfere with each other.
#
# Machine safety: two cores are left for the OS, workers run at lowest
# priority, and each worker restarts its process every batch so any residual
# per-process memory growth stays bounded.
set -u

total=${1:-100000}
cores=$(nproc)
mem_gb=$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024))
cpu_cap=$((cores > 2 ? cores - 2 : 1))
mem_cap=$((mem_gb / 2))
((mem_cap < 1)) && mem_cap=1
default_jobs=$((cpu_cap < mem_cap ? cpu_cap : mem_cap))
jobs=${VOPR_JOBS:-$default_jobs}
if ((jobs > default_jobs)); then
  jobs=$default_jobs
fi
base=${VOPR_BASE:-$(date +%s)}
batch=${VOPR_BATCH:-1000}
per=$((total / jobs))
logdir=bin/vopr
mkdir -p "$logdir"

deep_workers=$(((jobs + 3) / 4))
executed=$((deep_workers * (per / 4) + (jobs - deep_workers) * per))
echo "VOPR deep run: $executed scenarios ($deep_workers of $jobs workers on the deep profile at quarter count), $cores cores / ${mem_gb}GB RAM with 2 cores reserved, base $base (logs in $logdir/)"

worker() {
  local id=$1 worker_base=$2 count=$3 ops=$4 nodes=$5
  local done=0
  while ((done < count)); do
    local n=$((count - done))
    ((n > batch)) && n=$batch
    if ! ACTOD_VOPR_OPS=$ops ACTOD_VOPR_NODES=$nodes \
      ACTOD_TEST_RUN=test_sim_vopr ACTOD_VOPR_BASE=$((worker_base + done)) ACTOD_VOPR_COUNT=$n \
      nice -n 19 bin/integration_test >>"$logdir/worker_$id.log" 2>&1; then
      return 1
    fi
    done=$((done + n))
  done
}

pids=()
for i in $(seq 0 $((jobs - 1))); do
  : >"$logdir/worker_$i.log"
  worker_base=$((base + i * per * 7919))
  if ((i % 4 == 0)); then
    worker "$i" "$worker_base" $((per / 4)) 200 8 &
  else
    worker "$i" "$worker_base" "$per" 50 4 &
  fi
  pids+=($!)
done

fail=0
for i in $(seq 0 $((jobs - 1))); do
  if ! wait "${pids[$i]}"; then
    fail=1
    echo "worker $i FAILED:"
    grep -h "VOPR seed" "$logdir/worker_$i.log" | head -2
  fi
done

if ((fail)); then
  echo "VOPR deep run FAILED; full logs in $logdir/"
  exit 1
fi

echo "batches green: $(grep -h -c "all invariants held" "$logdir"/worker_*.log | awk '{s += $1} END {print s}')"
echo "VOPR deep run: all workers green"
