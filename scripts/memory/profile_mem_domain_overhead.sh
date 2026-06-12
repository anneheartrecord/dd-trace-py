#!/usr/bin/env bash
# Profile MEM-domain overhead: flamegraph + diff comparing OBJ-only vs OBJ+MEM.
#
# Answers the key question: is the ~3% CPU overhead from MEM domain in
#   (a) should_sample_no_cpython  — called on EVERY allocation (irreducible hook cost)
#   (b) traceback_collect/add_sample_no_cpython — called only on sampled allocs
#
# If (a) dominates: the overhead is inherent to interception; sampling rate
#   tuning won't help. Reduce via per-domain counters + lower hook overhead.
# If (b) dominates: raise the MEM-domain sample threshold (§3b in plan).
#
# Two perf+flamegraph runs against the same SHA/venv:
#   A (obj-only)  : DD_PROFILING_MEMORY_MEM_DOMAIN_ENABLED=false
#   B (mem-on)    : DD_PROFILING_MEMORY_MEM_DOMAIN_ENABLED=true
#
# Outputs:
#   $WORK_DIR/obj_only.svg          — flamegraph, OBJ domain only
#   $WORK_DIR/mem_on.svg            — flamegraph, OBJ+MEM domains
#   $WORK_DIR/diff-mem-vs-obj.svg   — diff (red = added by MEM domain, blue = removed)
#
# Usage:
#   ./scripts/profile_mem_domain_overhead.sh [--work-dir DIR] [--sha SHA] [--no-build]
#
# Requirements (Linux only):
#   - perf installed (perf_event_paranoid ≤ 1 recommended; 2 works with user-space only)
#   - FlameGraph scripts on PATH: stackcollapse-perf.pl, flamegraph.pl, difffolded.pl
#     Install: git clone https://github.com/brendangregg/FlameGraph ~/FlameGraph
#              export PATH="$HOME/FlameGraph:$PATH"
#   - Python 3.12+, gcc/g++ with C++17 support
#
# Notes:
#   - Uses a git worktree so your active branch is untouched.
#   - Builds with -O2 -g -fno-omit-frame-pointer for realistic perf + readable symbols.
#   - The workload is scripts/memory/synthetic_domain_workload.py (100 MB per domain).
#     Override with WORKLOAD env var.

set -euo pipefail

REPO="${REPO:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}"
WORK_DIR="${WORK_DIR:-/tmp/mem-domain-profile}"
SHA="${SHA:-HEAD}"
PERF_FREQ="${PERF_FREQ:-999}"
WORKLOAD="${WORKLOAD:-scripts/memory/synthetic_domain_workload.py}"
DO_BUILD=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir)    WORK_DIR="$2";  shift 2 ;;
    --work-dir=*)  WORK_DIR="${1#--work-dir=}"; shift ;;
    --sha)         SHA="$2";       shift 2 ;;
    --sha=*)       SHA="${1#--sha=}"; shift ;;
    --no-build)    DO_BUILD=false; shift ;;
    -h|--help)     sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
  esac
done

# ── Resolve SHA early so we can use it in dir names ──────────────────────────
# Try local ref first, then origin/<ref> (handles the case where the branch
# exists remotely but hasn't been checked out on this machine).
RESOLVED_SHA=$(git -C "$REPO" rev-parse --short "$SHA" 2>/dev/null) \
  || RESOLVED_SHA=$(git -C "$REPO" rev-parse --short "origin/$SHA" 2>/dev/null) \
  || {
    echo "  '$SHA' not found locally — fetching from origin..."
    git -C "$REPO" fetch origin "$SHA"
    RESOLVED_SHA=$(git -C "$REPO" rev-parse --short FETCH_HEAD)
  }
echo "Profiling SHA: $RESOLVED_SHA  (from '$SHA')"

mkdir -p "$WORK_DIR"

# ── Sanity checks ─────────────────────────────────────────────────────────────
for tool in perf python3 git gcc g++; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not on PATH" >&2; exit 1; }
done
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$HOME/FlameGraph}"
if ! command -v stackcollapse-perf.pl >/dev/null 2>&1; then
  if [[ ! -d "$FLAMEGRAPH_DIR" ]]; then
    echo "FlameGraph tools not on PATH — cloning into $FLAMEGRAPH_DIR ..."
    git clone --depth=1 https://github.com/brendangregg/FlameGraph "$FLAMEGRAPH_DIR"
  fi
  export PATH="$FLAMEGRAPH_DIR:$PATH"
fi
for tool in stackcollapse-perf.pl flamegraph.pl difffolded.pl; do
  command -v "$tool" >/dev/null || {
    echo "ERROR: $tool not found in $FLAMEGRAPH_DIR" >&2; exit 1
  }
done

# ── Build once (shared venv for both runs) ────────────────────────────────────
VENV="$WORK_DIR/venv"
WT="$WORK_DIR/wt-$RESOLVED_SHA"

if [[ "$DO_BUILD" == "true" ]]; then
  echo
  echo "================================================================="
  echo "  Building $RESOLVED_SHA  →  $WT"
  echo "================================================================="

  if [[ -d "$WT" ]]; then
    git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
  fi
  git -C "$REPO" worktree add --detach "$WT" "$RESOLVED_SHA"

  rm -rf "$VENV"
  python3 -m venv "$VENV"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  pip install -U pip wheel
  pip install pytest

  # Build with debug symbols + frame pointers for readable flamegraphs.
  # -O2 rather than -O3: matches a realistic release build while keeping symbols.
  export CFLAGS="-O2 -g -fno-omit-frame-pointer"
  export CXXFLAGS="$CFLAGS"
  cd "$WT"
  pip install -e . -v 2>&1 | tail -30
  deactivate
else
  echo "Skipping build (--no-build). Using existing $WT and $VENV."
  [[ -d "$WT" ]]   || { echo "ERROR: worktree $WT not found; run without --no-build first." >&2; exit 1; }
  [[ -d "$VENV" ]] || { echo "ERROR: venv $VENV not found; run without --no-build first." >&2; exit 1; }
fi

# ── Profile one run ───────────────────────────────────────────────────────────
# Args: label  mem_domain_enabled(true|false)
profile_one() {
  local label="$1"
  local mem_domain="$2"
  local perf_data="$WORK_DIR/${label}.perf.data"
  local folded="$WORK_DIR/${label}.folded"
  local svg="$WORK_DIR/${label}.svg"

  echo
  echo "================================================================="
  echo "  $label  (DD_PROFILING_MEMORY_MEM_DOMAIN_ENABLED=$mem_domain)"
  echo "================================================================="

  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  cd "$WT"

  # --call-graph=dwarf: more reliable than fp across Python + C extensions.
  # -F PERF_FREQ: samples per second (999 Hz = just under 1 kHz, avoids lockstep).
  # We run the workload directly (not pytest) so perf doesn't sample pytest overhead.
  DD_PROFILING_MEMORY_MEM_DOMAIN_ENABLED="$mem_domain" \
    perf record -F "$PERF_FREQ" -g --call-graph=dwarf -o "$perf_data" -- \
      python -c "
import sys, os
sys.path.insert(0, '$WT')
os.environ.setdefault('DD_PROFILING_MEMORY_MEM_DOMAIN_ENABLED', '$mem_domain')
exec(open('$WT/$WORKLOAD').read())
" || { echo "WARN: workload exited non-zero (may still have useful samples)"; }

  echo
  echo "  Folding + generating flamegraph → $svg"
  perf script -i "$perf_data" | stackcollapse-perf.pl > "$folded"
  flamegraph.pl --title "$label (mem_domain=$mem_domain)" "$folded" > "$svg"
  echo "  → $svg"

  deactivate
}

# ── Run both profiles ─────────────────────────────────────────────────────────
profile_one "obj_only" "false"
profile_one "mem_on"   "true"

# ── Diff flamegraph ───────────────────────────────────────────────────────────
echo
echo "================================================================="
echo "  diff flamegraph  (red = frames added by MEM domain)"
echo "================================================================="
DIFF_SVG="$WORK_DIR/diff-mem-vs-obj.svg"
difffolded.pl \
  "$WORK_DIR/obj_only.folded" \
  "$WORK_DIR/mem_on.folded" \
  | flamegraph.pl \
      --title "MEM domain overhead  (red=added, blue=removed vs OBJ-only)" \
      --negate > "$DIFF_SVG"
echo "  → $DIFF_SVG"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "================================================================="
echo "  Results in $WORK_DIR/"
echo "================================================================="
echo "  obj_only.svg          — OBJ domain only baseline"
echo "  mem_on.svg            — OBJ + MEM domains"
echo "  diff-mem-vs-obj.svg   — red = CPU added by MEM domain"
echo
echo "  What to look for in the diff flamegraph:"
echo "    * If should_sample_no_cpython dominates the red frames:"
echo "        → overhead is inherent hook cost; tuning sample rate won't help."
echo "          Next: reduce per-alloc hook work (per-domain counters, lighter guard)."
echo "    * If traceback_collect / add_sample_no_cpython dominates:"
echo "        → overhead is from higher sample frequency; raise MEM-domain threshold."
echo "          Next: implement per-domain sample counters (§3b in plan)."
echo
