#!/bin/bash
# nft ruleset memory bench: one cgroup (v2) + one netns per test, side by side.
# Run as root in the VM (colima ssh, sudo -i). Needs nft (apt install nftables)
# and GNU time (apt install time). Meant to be sourced, so no set -e here.
#
#   source nftbench.sh
#   bench nft-old /Users/adrian/kube-proxy-benchmark/kube-proxy-nft-45k.commands
#   bench nft-new /path/to/new-rules.commands
#   summary nft-old nft-new
#   teardown nft-old nft-new
#
# Numbers:
#   kernel     resident kernel memory of the ruleset (slab + vmalloc + percpu), stays after nft exits
#   max RSS    peak userspace memory of the nft process itself (GNU time %M)
#   peak       cgroup high-water mark: nft anon + kernel incl. transient commit state
#   transient  peak - kernel: what the load needed on top of the resident ruleset

CG=/sys/fs/cgroup

[[ $EUID -eq 0 ]]              || echo "warning: not root" >&2
[[ -f $CG/cgroup.controllers ]] || echo "warning: cgroup v2 not mounted at $CG" >&2
command -v nft >/dev/null      || echo "warning: nft not found (apt install nftables)" >&2
[[ -x /usr/bin/time ]]         || echo "warning: /usr/bin/time not found (apt install time)" >&2

# setup <name>...: fresh cgroup + netns per test
setup() {
  local n
  for n in "$@"; do
    mkdir "$CG/$n" && ip netns add "$n"
  done
}

# teardown <name>...: deleting the netns frees the ruleset; rmdir works even while RCU frees are pending
teardown() {
  local n
  for n in "$@"; do
    ip netns del "$n"
    rmdir "$CG/$n"
  done
}

# load <name> <file>: only nft runs inside the cgroup. The file is streamed via
# stdin so its page cache is charged to `cat`, not to the test cgroup.
load() {
  local n="$1" f="$2"
  cat "$f" | bash -c 'echo $$ > "$2/$1/cgroup.procs"; exec ip netns exec "$1" /usr/bin/time -f "%M KiB max RSS, %e s elapsed" nft -f -' _ "$n" "$CG"
  echo "$n: nft exit=$?"
}

# chains <name>...: sanity check that the batch was committed (old design ≈ 45k)
chains() {
  local n
  for n in "$@"; do
    printf '%-10s %s chains\n' "$n" "$(ip netns exec "$n" nft -t list table ip kube-proxy | grep -cE '^\s+chain ')"
  done
}

# st <name>...: raw counters
st() {
  local n
  for n in "$@"; do
    echo "== $n"
    grep -E '^(anon|file|kernel|slab_unreclaimable|vmalloc|percpu) ' "$CG/$n/memory.stat"
    echo "peak $(cat "$CG/$n/memory.peak")"
  done
}

# summary <name>...: one line per test in MiB
summary() {
  local n k p
  printf '%-10s %12s %12s %12s\n' test kernel peak transient
  for n in "$@"; do
    k=$(awk '$1=="kernel"{print $2}' "$CG/$n/memory.stat")
    p=$(cat "$CG/$n/memory.peak")
    awk -v n="$n" -v k="$k" -v p="$p" \
      'BEGIN{printf "%-10s %8.1f MiB %8.1f MiB %8.1f MiB\n", n, k/1048576, p/1048576, (p-k)/1048576}'
  done
}

# sample <name> [interval]: run in a second shell during a load; Ctrl-C to stop.
# anon = nft userspace (rises while parsing), slab_unreclaimable = kernel objects (jumps at commit)
sample() {
  local n="$1" i="${2:-0.5}"
  while :; do
    awk '$1=="anon"||$1=="slab_unreclaimable"{printf "%s=%.1fMiB ", $1, $2/1048576} END{print ""}' "$CG/$n/memory.stat"
    sleep "$i"
  done
}

# bench <name> <file>: setup + load + verify + report for one test
bench() {
  setup "$1" && load "$1" "$2" && chains "$1" && st "$1"
}
