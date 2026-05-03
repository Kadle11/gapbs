#!/bin/bash
# run.sh – GAPBS benchmark runner
# Mirrors apps/silo/run.sh: same prologue/cleanup, same monitoring tools
# (mpstat, pgstat, optional bpftrace), same DAMON-steer integration via
# helpers.sh.
#
# Remote-memory loading strategy: numactl --membind=RSOC places all graph
# allocations on the remote NUMA node at startup.  After MB_WARMUP seconds,
# damo-steer begins promoting hot pages to local memory.
#
# Usage:
#   ./run.sh <type> <threads> [kernel] [graph] [trials] [prefix_dir] \
#            [damon_bw_mb_s] [damon_nr_kdamonds]
#
# Types:
#   0: NoTier   1: TPP   2: DAMON   3: Nomad   4: Colloid
#   6: ARMS     9: TIDE  10: Ripple-TPP         11: Ripple
#
# kernel: pr|bfs|sssp|bc|tc|cc  (default: pr)
# graph:  /path/to/graph.sg  OR  gNN for Kronecker 2^NN  (default: g22)
# trials: number of kernel iterations (default: 16)

set -o pipefail

export RIPPLE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GAPBSDIR="$(cd "$(dirname "$0")" && pwd)"
RSTDIR="$GAPBSDIR/results"
NODE_NAME=$(hostname | awk -F. '{print $1}')

export LSOC=0
export RSOC=1

MB_WARMUP=60

source "$RIPPLE_ROOT/scripts/helpers.sh"

export TPP_DEMOTE_SCALE_FACTOR=500
export TPP_SCAN_SIZE_MB=512
export TPP_SCAN_PERIOD_MIN_MS=500
export TPP_SCAN_PERIOD_MAX_MS=500
export TPP_SCAN_DELAY_MS=100

export NOMAD_DEMOTE_SCALE_FACTOR=500
export NOMAD_SCAN_SIZE_MB=512
export NOMAD_SCAN_PERIOD_MIN_MS=500
export NOMAD_SCAN_PERIOD_MAX_MS=500
export NOMAD_SCAN_DELAY_MS=100

export RIPPLE_TPP_SCAN_SIZE_MB=16384

# --------------------------------------------------------------------------
# Args
# --------------------------------------------------------------------------
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <type> <threads> [kernel] [graph] [trials] [prefix_dir] [damon_bw_mb_s] [damon_nr_kdamonds]"
  echo ""
  echo "  type              Tier management policy"
  echo "  threads           Worker thread count (and CPU count for pinning)"
  echo "  kernel            GAPBS kernel: pr|bfs|sssp|bc|tc|cc (default: pr)"
  echo "  graph             File path (/path/to/graph.sg)"
  echo "  trials            Number of kernel iterations (default: 16)"
  echo "  prefix_dir        Optional result directory prefix"
  echo "  damon_bw_mb_s     DAMON migrate bandwidth budget in MB/s (default: 16384)"
  echo "  damon_nr_kdamonds Number of kdamond workers (default: 16)"
  echo ""
  echo "Types:"
  for k in $(echo "${!sysmap[@]}" | tr ' ' '\n' | sort -n); do
    echo "    $k: ${sysmap[$k]}"
  done
  exit 1
fi

ttype=$1
pthreads=$2
GAPBS_KERNEL=${3:-pr}
GAPBS_GRAPH=${4:-g22}
GAPBS_TRIALS=${5:-16}
PREFIX_DIR=${6:-}
DAMON_BW_MB_S=${7:-16384}
DAMON_NR_KDAMONDS=${8:-16}

case "$GAPBS_KERNEL" in
  pr|bfs|sssp|bc|tc|cc) ;;
  *) echo "Invalid kernel '$GAPBS_KERNEL' (expected pr|bfs|sssp|bc|tc|cc)"; exit 1 ;;
esac

if [[ -f "$GAPBS_GRAPH" ]]; then
  GRAPH_ARGS="-f $GAPBS_GRAPH"
  # Derive SIZE_MB from file size.
  SIZE_MB=$(( $(stat -c%s "$GAPBS_GRAPH") / 1048576 ))
else
  echo "graph must be a file path or Kronecker scale gNN (got: $GAPBS_GRAPH)"
  exit 1
fi

KERNEL_BIN="$GAPBSDIR/$GAPBS_KERNEL"
TIME_SUFFIX=$(date +"%Y%m%d-%H%M%S")
DAMO_STEER_SCRIPT="$RIPPLE_ROOT/tier-sys/damon/damo-steer.sh"

all_pids=()

# --------------------------------------------------------------------------
# Validate
# --------------------------------------------------------------------------
cps=$(cores_per_socket)
if (( pthreads < 1 || pthreads > cps )); then
  echo "threads[$pthreads] out of range 1..${cps}"
  exit 1
fi

if (( ttype == 2 )); then
  if ! [[ "$DAMON_BW_MB_S" =~ ^[0-9]+$ && "$DAMON_NR_KDAMONDS" =~ ^[0-9]+$ ]]; then
    echo "For DAMON type, damon_bw_mb_s and damon_nr_kdamonds must be positive integers"
    exit 1
  fi
fi

[[ -e "$KERNEL_BIN" ]]        || { echo "GAPBS binary not found: $KERNEL_BIN"; exit 1; }
[[ -e "$DAMO_STEER_SCRIPT" ]] || { echo "DAMON steering script not found: $DAMO_STEER_SCRIPT"; exit 1; }
export DAMO_STEER_SCRIPT

# --------------------------------------------------------------------------
# Topology — SMT off so numactl reports physical cores only.
# --------------------------------------------------------------------------
disable_smt
LSOC_CORES=$(node_cores "$LSOC")
RSOC_CORES=$(node_cores "$RSOC")
export RSOC_CORES

MB_CORES=$(core_slice "$LSOC_CORES" 2 $((pthreads + 1)))

DAMON_CORES=$(core_slice "$LSOC_CORES" $((pthreads + 2)))
if (( ttype == 2 )) && [[ -z "$DAMON_CORES" ]]; then
  echo "No remaining cores to pin DAMON kdamonds after benchmark core allocation"
  exit 1
fi
export DAMON_CORES DAMON_BW_MB_S DAMON_NR_KDAMONDS

enable_smt

echo "=== GAPBS Run Configuration ==="
echo "  type:             $ttype (${sysmap[$ttype]})"
echo "  threads:          $pthreads  (cpus $MB_CORES)"
echo "  kernel:           $GAPBS_KERNEL"
echo "  graph:            $GAPBS_GRAPH  ($GRAPH_ARGS)"
echo "  trials:           $GAPBS_TRIALS"
echo "  size_est:         ${SIZE_MB} MB"
echo "  remote_numa:      $RSOC  (graph loaded via --membind)"
if (( ttype == 2 )); then
  echo "  damon_bw_mb_s:    $DAMON_BW_MB_S"
  echo "  damon_nr_kdamonds:$DAMON_NR_KDAMONDS"
  echo "  damon_pin_cores:  $DAMON_CORES"
fi
echo "================================"

# --------------------------------------------------------------------------
# Prologue dispatch
# --------------------------------------------------------------------------
prologue() {
  prologue_base
  case "$ttype" in
    1)  setup_tpp        ;;
    2)  setup_damon      ;;
    3)  setup_nomad      ;;
    4)  setup_colloid    ;;
    6)  setup_arms       ;;
    9)  setup_tide       ;;
    10) setup_ripple_tpp ;;
    11) setup_ripple     ;;
  esac
}

trap "cleanup_base; exit" SIGINT SIGTERM

# --------------------------------------------------------------------------
# Main run
# --------------------------------------------------------------------------
run() {
  local output_dir
  output_dir=$(make_output_dir "gapbs-${GAPBS_KERNEL}")

  local perff="${output_dir}/perf.log"
  local pgf="${output_dir}/pgstat.log"
  local outf="${output_dir}/out.log"
  local timef="${output_dir}/time.log"
  local sarf="${output_dir}/sar.log"
  local pgmapf="${output_dir}/pgmap.log"
  local zonef="${output_dir}/zone.log"
  local minorf="${output_dir}/minor_faults.log"

  truncate_logs "$outf" "$pgf" "$perff" "$timef" "$sarf" "$pgmapf" "$zonef" "$minorf"

  {
    echo "type=$ttype (${sysmap[$ttype]})"
    echo "bench=gapbs"
    echo "kernel=$GAPBS_KERNEL"
    echo "binary=$KERNEL_BIN"
    echo "graph=$GAPBS_GRAPH"
    echo "graph_args=$GRAPH_ARGS"
    echo "threads=$pthreads"
    echo "trials=$GAPBS_TRIALS"
    echo "size_est_mb=$SIZE_MB"
    echo "cpus=$MB_CORES"
    echo "remote_numa=$RSOC"
    if [[ $ttype == 2 || $ttype == 11 || $ttype == 9 || $ttype == 6 ]]; then
      echo "damon_local_numa=$LSOC"
      echo "damon_remote_numa=$RSOC"
      echo "damon_bw_mb_s=$DAMON_BW_MB_S"
      echo "damon_nr_kdamonds=$DAMON_NR_KDAMONDS"
      echo "damon_pin_cores=$DAMON_CORES"
      echo "damon_steer_script=$DAMO_STEER_SCRIPT"
    fi
    echo "timestamp=$TIME_SUFFIX"
  } > "${output_dir}/config.txt"

  echo "START ..."
  prologue

  local start_time
  start_time=$(date +%s)

  start_mpstat "$sarf"
  start_pgstat "$pgf" "$zonef" "$pgmapf" 0

  echo "Running GAPBS $GAPBS_KERNEL ..."

  set -x
  numactl -C "$MB_CORES" \
    env OMP_NUM_THREADS="$pthreads" GAPBS_REMOTE_NODE="$RSOC" \
    "$KERNEL_BIN" \
      $GRAPH_ARGS \
      -n "$GAPBS_TRIALS" \
  > "$outf" 2>&1 &
  set +x

  local gapbs_pid=$!
  track_pid "$gapbs_pid"

  # Estimate total runtime from per-trial wall time; show_progress uses it.
  local est_runtime=$(( GAPBS_TRIALS * 30 ))
  show_progress "$est_runtime" "${sysmap[$ttype]}" &
  track_pid $!

  if [[ $ttype == 2 || $ttype == 11 || $ttype == 9 || $ttype == 6 ]]; then
    sleep "$MB_WARMUP"
    start_damon_steer "$output_dir" --promote-only
  fi

  wait "$gapbs_pid"

  local end_time
  end_time=$(date +%s)
  echo "Elapsed time: $((end_time - start_time)) seconds" | tee "$timef"

  cleanup_base
  echo "Results written to: ${output_dir}"
}

main() {
  run
}

main
echo "DONE"
