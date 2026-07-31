#!/bin/bash
# Ablation reruns (paper sec 6.2.2) on the sub-tiled forward fixture:
#   1. reduced physical warps  (--num-warps: baseline-1 and half)
#   2. no sub-tiling           (the non-subtiled fwd ddg as input)
#   3. no cross-warp traffic   (--no-cross-warp)
# Run from the package directory. Each solve gets the same search/time limits.
# The JSON status is authoritative. Neither unknown nor resource_limited is
# promoted to an UNSAT proof.
set -euo pipefail
PYTHON=${PYTHON:-../../../../.venv/bin/python}
if [[ ! -x "$PYTHON" ]]; then
  echo "PYTHON must name an executable with PySCIPOpt and Yices" >&2
  exit 1
fi
# SOLVER_LIB_PATH: colon-separated lib dirs holding yices/cudd shared objects
SOLVER_LIB_PATH="${SOLVER_LIB_PATH:?set SOLVER_LIB_PATH to <yices>/lib:<cudd>/lib}"
if [[ "$SOLVER_LIB_PATH" == :* || "$SOLVER_LIB_PATH" == *: || \
      "$SOLVER_LIB_PATH" == *::* ]]; then
  echo "SOLVER_LIB_PATH must contain non-empty colon-separated directories" >&2
  exit 1
fi
IFS=: read -r -a solver_lib_dirs <<<"$SOLVER_LIB_PATH"
for directory in "${solver_lib_dirs[@]}"; do
  if [[ ! -d "$directory" ]]; then
    echo "solver library directory does not exist: $directory" >&2
    exit 1
  fi
done
SUB=../sched2tlx/examples/case3_FA_fp16_subtiled/ddg.json
FWD=../sched2tlx/examples/case3_FA_fp16/ddg.json
SUB_GRAPH=../sched2tlx/examples/case3_FA_fp16_subtiled/schedule_graph.json
FWD_GRAPH=../sched2tlx/examples/case3_FA_fp16/schedule_graph.json
OUT=${OUT:-ablations_v7}
FIXED_WARPS=4  # sched2tlx emits a four-warp default task outside the loop DDG
if [[ -e "$OUT" ]]; then
  echo "refusing to overwrite existing output directory: $OUT" >&2
  exit 1
fi

for input in "$SUB" "$FWD" "$SUB_GRAPH" "$FWD_GRAPH"; do
  if [[ ! -f "$input" ]]; then
    echo "required input does not exist: $input" >&2
    exit 1
  fi
done

PYTHON_EXECUTABLE=$(env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH" \
  "$PYTHON" -c 'import os, sys; print(os.path.realpath(sys.executable))')
PYTHON_VERSION=$(env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH" \
  "$PYTHON" -c 'import sys; print(sys.version.replace("\n", " "))')
mkdir -p "$OUT"

{
  printf 'working_directory=%s\n' "$(pwd -P)"
  printf 'python_requested=%s\n' "$PYTHON"
  printf 'python_executable=%s\n' "$PYTHON_EXECUTABLE"
  printf 'python_version=%s\n' "$PYTHON_VERSION"
  printf 'SOLVER_LIB_PATH=%s\n' "$SOLVER_LIB_PATH"
  printf 'effective_LD_LIBRARY_PATH=%s\n' "$SOLVER_LIB_PATH"
  printf 'PYTHONPATH=%s\n' "${PYTHONPATH-<unset>}"
  printf 'PYTHONUSERBASE=%s\n' "${PYTHONUSERBASE-<unset>}"
  env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH" \
    "$PYTHON" - <<'PY'
import importlib

from yices import Yices

for name in ("pyscipopt", "yices", "paper_joint_solver"):
    module = importlib.import_module(name)
    print(f"module_{name}_file={getattr(module, '__file__', '<unset>')}")
    print(f"module_{name}_version={getattr(module, '__version__', '<unset>')}")
print(f"libyices_version={Yices.version}")
PY
} >"$OUT/environment.log"
: >"$OUT/commands.log"

run_case() {
  local name=$1
  local expected_rc=$2
  shift 2
  local output="$OUT/$name.json"
  local log="$OUT/$name.log"
  local rc
  local -a command=(
    env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH"
    "$PYTHON" -m paper_joint_solver "$@" -o "$output"
    --warp-fixed-overhead "$FIXED_WARPS"
    --ilp-seconds 240 --smt-seconds 300 --max-wall-s 3600
  )

  {
    printf 'case=%s\n' "$name"
    printf 'expected_rc=%d\n' "$expected_rc"
    printf 'command='
    printf '%q ' "${command[@]}"
    printf '\n'
  } >"$log"
  {
    printf 'case=%s\n' "$name"
    printf 'expected_rc=%d\n' "$expected_rc"
    printf 'command='
    printf '%q ' "${command[@]}"
    printf '\n\n'
  } >>"$OUT/commands.log"

  if "${command[@]}" >>"$log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  printf '\nactual_rc=%d\n' "$rc" >>"$log"
  printf 'case=%s actual_rc=%d\n' "$name" "$rc" >>"$OUT/commands.log"
  cat "$log"
  if ((rc != expected_rc)); then
    echo "$name returned $rc; expected $expected_rc" >&2
    return 1
  fi
}

# Derive physical-warp ablations from a baseline produced by this exact model.
run_case baseline 0 "$SUB" --baseline-graph "$SUB_GRAPH"
BASE_WARPS=$(env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH" \
  "$PYTHON" - "$OUT/baseline.json" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as handle:
        result = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid baseline JSON: {error}") from error
if not isinstance(result, dict):
    raise SystemExit("baseline JSON is not an object")
if result.get("status") != "sat" or result.get("satisfiable") is not True:
    raise SystemExit("baseline did not produce a SAT solution")
stats = result.get("stats")
warps = stats.get("num_warps") if isinstance(stats, dict) else None
if isinstance(warps, bool) or not isinstance(warps, int) or warps < 2:
    raise SystemExit("baseline stats.num_warps must be an integer >= 2")
print(warps)
PY
)
run_case warps_minus_one 0 "$SUB" --baseline-graph "$SUB_GRAPH" \
  --num-warps "$((BASE_WARPS - 1))"
run_case warps_half 0 "$SUB" --baseline-graph "$SUB_GRAPH" \
  --num-warps "$((BASE_WARPS / 2))"
run_case no_subtiling 0 "$FWD" --baseline-graph "$FWD_GRAPH"
run_case no_cross_warp 2 "$SUB" --baseline-graph "$SUB_GRAPH" --no-cross-warp

if ! env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH" \
  "$PYTHON" - "$OUT" >"$OUT/validation.log" 2>&1 <<'PY'
import json
import hashlib
import os
import re
import sys

from paper_joint_solver.machine import MachineModel
from paper_joint_solver.schedule_plan import solver_sources_sha256

out = sys.argv[1]
expected = {
    "baseline": ("sat", True),
    "warps_minus_one": ("sat", True),
    "warps_half": ("sat", True),
    "no_subtiling": ("sat", True),
    "no_cross_warp": ("unsat", False),
}
source_hashes = set()
results = {}
actual_json = {name for name in os.listdir(out) if name.endswith(".json")}
expected_json = {f"{name}.json" for name in expected}
if actual_json != expected_json:
    raise SystemExit(
        "unexpected ablation JSON set: "
        f"missing={sorted(expected_json - actual_json)}, "
        f"extra={sorted(actual_json - expected_json)}"
    )
for name, (expected_status, expected_satisfiable) in expected.items():
    path = os.path.join(out, f"{name}.json")
    if not os.path.isfile(path):
        raise SystemExit(f"missing required result: {path}")
    try:
        with open(path) as handle:
            result = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"malformed result {path}: {error}") from error
    if not isinstance(result, dict):
        raise SystemExit(f"result is not a JSON object: {path}")
    status = result.get("status")
    satisfiable = result.get("satisfiable")
    if status != expected_status or satisfiable is not expected_satisfiable:
        raise SystemExit(
            f"unexpected result for {name}: status={status!r}, "
            f"satisfiable={satisfiable!r}"
        )
    provenance = result.get("provenance")
    source_hash = (
        provenance.get("solver_sources_sha256")
        if isinstance(provenance, dict)
        else None
    )
    if not isinstance(source_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", source_hash):
        raise SystemExit(f"invalid solver_sources_sha256 in {path}")
    source_hashes.add(source_hash)
    results[name] = result
    print(f"{path}: status={status} satisfiable={satisfiable}")

current_source_hash = solver_sources_sha256()
if source_hashes != {current_source_hash}:
    raise SystemExit(
        "ablation solver_sources_sha256 does not match the current toolchain: "
        + ", ".join(sorted(source_hashes))
    )
baseline_stats = results["baseline"].get("stats")
baseline_warps = (
    baseline_stats.get("num_warps") if isinstance(baseline_stats, dict) else None
)
if isinstance(baseline_warps, bool) or not isinstance(baseline_warps, int):
    raise SystemExit("baseline stats.num_warps is not an integer")

sub_ddg = "../sched2tlx/examples/case3_FA_fp16_subtiled/ddg.json"
sub_graph = "../sched2tlx/examples/case3_FA_fp16_subtiled/schedule_graph.json"
fwd_ddg = "../sched2tlx/examples/case3_FA_fp16/ddg.json"
fwd_graph = "../sched2tlx/examples/case3_FA_fp16/schedule_graph.json"
default_warps = MachineModel().num_warps
case_inputs = {
    "baseline": (sub_ddg, sub_graph, default_warps),
    "warps_minus_one": (sub_ddg, sub_graph, baseline_warps - 1),
    "warps_half": (sub_ddg, sub_graph, baseline_warps // 2),
    "no_subtiling": (fwd_ddg, fwd_graph, default_warps),
    "no_cross_warp": (sub_ddg, sub_graph, default_warps),
}
for name, (ddg, graph, warp_budget) in case_inputs.items():
    provenance = results[name]["provenance"]
    for field, source in (
        ("ddg_sha256", ddg),
        ("baseline_graph_sha256", graph),
    ):
        with open(source, "rb") as handle:
            expected_hash = hashlib.sha256(handle.read()).hexdigest()
        if provenance.get(field) != expected_hash:
            raise SystemExit(f"{name} {field} does not match {source}")
    if provenance.get("normalization_u") != 300:
        raise SystemExit(f"{name} normalization_u is not 300")
    machine = provenance.get("machine")
    if not isinstance(machine, dict):
        raise SystemExit(f"{name} has no machine provenance")
    if machine.get("num_warps") != warp_budget:
        raise SystemExit(f"{name} physical warp budget mismatch")
    if machine.get("warp_fixed_overhead") != 4:
        raise SystemExit(f"{name} fixed warp overhead mismatch")

attempts = results["no_cross_warp"].get("attempts")
if attempts != [
    {
        "stage": "structural",
        "result": "unsat",
        "reason": "VARIABLELATENCY conflicts with no-cross-warp",
        "edge": 3,
    }
]:
    raise SystemExit("no_cross_warp is not the expected structural proof")
print(f"solver_sources_sha256={current_source_hash}")
PY
then
  cat "$OUT/validation.log" >&2
  exit 1
fi
cat "$OUT/validation.log"
