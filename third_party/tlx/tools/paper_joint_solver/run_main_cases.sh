#!/bin/bash
# Reproduce the four paper-fidelity Phase-3 solves and their manual-CUDA
# handoff scaffolds. Run this script from third_party/tlx/tools/paper_joint_solver.
# Outputs are append-never: remove stale targets or choose a fresh OUT directory.
set -euo pipefail

PYTHON_REQUESTED=${PYTHON:-../../../../.venv/bin/python}
SOLVER_LIB_PATH="${SOLVER_LIB_PATH:?set SOLVER_LIB_PATH to <yices>/lib:<cudd>/lib}"
OUT=${OUT:-solutions}

if [[ ! -f paper_joint_solver/__main__.py || ! -f skc/__main__.py ]]; then
  echo "run from third_party/tlx/tools/paper_joint_solver" >&2
  exit 1
fi
if [[ ! -x "$PYTHON_REQUESTED" ]]; then
  echo "PYTHON must name an executable with PySCIPOpt and Yices" >&2
  exit 1
fi
PYTHON=$PYTHON_REQUESTED

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

FWD_SUB_DDG=../sched2tlx/examples/case3_FA_fp16_subtiled/ddg.json
FWD_SUB_GRAPH=../sched2tlx/examples/case3_FA_fp16_subtiled/schedule_graph.json
FWD_DDG=../sched2tlx/examples/case3_FA_fp16/ddg.json
FWD_GRAPH=../sched2tlx/examples/case3_FA_fp16/schedule_graph.json
BWD_DDG=../sched2tlx/examples/case4_FA_bwd/ddg_hd128.json
BWD_GRAPH=../sched2tlx/examples/case4_FA_bwd/schedule_graph_hd128.json

for input in \
  "$FWD_SUB_DDG" "$FWD_SUB_GRAPH" \
  "$FWD_DDG" "$FWD_GRAPH" \
  "$BWD_DDG" "$BWD_GRAPH"; do
  if [[ ! -f "$input" ]]; then
    echo "required input does not exist: $input" >&2
    exit 1
  fi
done

if [[ -e "$OUT" && ! -d "$OUT" ]]; then
  echo "OUT exists but is not a directory: $OUT" >&2
  exit 1
fi

stems=(fwd_subtiled_v7 fwd_v7 bwd_v7 bwd_lr4096_v7)
reserved=(
  "$OUT/run_main_cases_environment.log"
  "$OUT/run_main_cases_validation.log"
)
for stem in "${stems[@]}"; do
  reserved+=(
    "$OUT/$stem.json"
    "$OUT/${stem}_ir.json"
    "$OUT/${stem}_handoff.json"
    "$OUT/${stem}_manual"
    "$OUT/$stem.solve.command"
    "$OUT/$stem.solve.log"
    "$OUT/$stem.scaffold.command"
    "$OUT/$stem.scaffold.log"
    "$OUT/$stem.audit.command"
    "$OUT/$stem.audit.log"
  )
done
for target in "${reserved[@]}"; do
  if [[ -e "$target" ]]; then
    echo "refusing to overwrite existing target: $target" >&2
    exit 1
  fi
done

mkdir -p "$OUT"
ENVIRONMENT_LOG="$OUT/run_main_cases_environment.log"
VALIDATION_LOG="$OUT/run_main_cases_validation.log"

{
  printf 'working_directory=%s\n' "$(pwd -P)"
  printf 'python_requested=%s\n' "$PYTHON_REQUESTED"
  printf 'SOLVER_LIB_PATH=%s\n' "$SOLVER_LIB_PATH"
  printf 'effective_LD_LIBRARY_PATH=%s\n' "$SOLVER_LIB_PATH"
  printf 'PYTHONPATH=%s\n' "${PYTHONPATH-<unset>}"
  printf 'PYTHONUSERBASE=%s\n' "${PYTHONUSERBASE-<unset>}"
  env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH" \
    "$PYTHON" - <<'PY'
import importlib
import sys

print(f"python_executable={sys.executable}")
print(f"python_version={sys.version.replace(chr(10), ' ')}")
for name in ("pyscipopt", "yices", "paper_joint_solver", "skc"):
    module = importlib.import_module(name)
    print(f"module_{name}_file={getattr(module, '__file__', '<unset>')}")
    print(f"module_{name}_version={getattr(module, '__version__', '<unset>')}")
PY
} >"$ENVIRONMENT_LOG"

write_command() {
  local destination=$1
  shift
  {
    printf '%q ' "$@"
    printf '\n'
  } >"$destination"
}

run_logged() {
  local expected_rc=$1
  local command_log=$2
  local output_log=$3
  shift 3
  local rc
  local -a command=("$@")

  write_command "$command_log" "${command[@]}"
  if "${command[@]}" >"$output_log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if ((rc != expected_rc)); then
    cat "$output_log" >&2
    echo "command returned $rc; expected $expected_rc (see $command_log)" >&2
    return 1
  fi
}

run_case() {
  local stem=$1
  local ddg=$2
  local graph=$3
  shift 3
  local solution="$OUT/$stem.json"
  local ir="$OUT/${stem}_ir.json"
  local handoff="$OUT/${stem}_handoff.json"
  local manual="$OUT/${stem}_manual"
  local -a solver_command=(
    env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH"
    "$PYTHON" -m paper_joint_solver "$ddg"
    --baseline-graph "$graph"
    -o "$solution"
    --ir-out "$ir"
    --handoff-manifest-out "$handoff"
    --ilp-seconds 240
    --smt-seconds 300
    --max-wall-s 3600
    "$@"
  )
  local -a scaffold_command=(
    env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH"
    "$PYTHON" -m skc scaffold
    --ir "$ir"
    --handoff "$handoff"
    --out-dir "$manual"
  )
  local -a audit_command=(
    env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH"
    "$PYTHON" -m skc audit-bundle
    --ir "$ir"
    --handoff "$handoff"
    --authoring "$manual/manual_cuda_authoring.json"
    --mapping "$manual/mapping_manifest.json"
    --memory "$manual/memory_plan.json"
    --sync "$manual/sync_manifest.json"
  )

  echo "running $stem"
  run_logged 0 "$OUT/$stem.solve.command" "$OUT/$stem.solve.log" \
    "${solver_command[@]}"
  run_logged 0 "$OUT/$stem.scaffold.command" "$OUT/$stem.scaffold.log" \
    "${scaffold_command[@]}"
  run_logged 2 "$OUT/$stem.audit.command" "$OUT/$stem.audit.log" \
    "${audit_command[@]}"
  if [[ "$(<"$OUT/$stem.audit.log")" != \
        *"skc: authoring status must be approved"* ]]; then
    cat "$OUT/$stem.audit.log" >&2
    echo "$stem draft audit did not fail at the authoring approval gate" >&2
    return 1
  fi
}

# Runs are serial to bound solver memory pressure. Every model-affecting case
# choice is explicit even where it matches the current CLI default.
run_case fwd_subtiled_v7 "$FWD_SUB_DDG" "$FWD_SUB_GRAPH" \
  --normalization-u 300 --reg-budget 8160 --warp-fixed-overhead 4
run_case fwd_v7 "$FWD_DDG" "$FWD_GRAPH" \
  --normalization-u 150 --reg-budget 8160 --warp-fixed-overhead 4
run_case bwd_v7 "$BWD_DDG" "$BWD_GRAPH" \
  --normalization-u 300 --reg-budget 8160 --warp-fixed-overhead 0
run_case bwd_lr4096_v7 "$BWD_DDG" "$BWD_GRAPH" \
  --normalization-u 300 --reg-budget 4096 --warp-fixed-overhead 0

if ! env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$SOLVER_LIB_PATH" \
  "$PYTHON" - "$OUT" >"$VALIDATION_LOG" 2>&1 <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

from skc._schema import (
    AUTHORING_SCHEMA,
    MAPPING_SCHEMA,
    MEMORY_PLAN_SCHEMA,
    PIPELINED_IR_SCHEMA,
    SYNC_PLAN_SCHEMA,
    load_handoff,
    load_json_artifact,
    load_pipelined_ir,
    validate_plan_header,
)

out = Path(sys.argv[1])
cases = {
    "fwd_subtiled_v7": {
        "ddg": Path("../sched2tlx/examples/case3_FA_fp16_subtiled/ddg.json"),
        "graph": Path(
            "../sched2tlx/examples/case3_FA_fp16_subtiled/schedule_graph.json"
        ),
        "normalization_u": 300,
        "regs_per_warp": 8160,
        "warp_fixed_overhead": 4,
    },
    "fwd_v7": {
        "ddg": Path("../sched2tlx/examples/case3_FA_fp16/ddg.json"),
        "graph": Path("../sched2tlx/examples/case3_FA_fp16/schedule_graph.json"),
        "normalization_u": 150,
        "regs_per_warp": 8160,
        "warp_fixed_overhead": 4,
    },
    "bwd_v7": {
        "ddg": Path("../sched2tlx/examples/case4_FA_bwd/ddg_hd128.json"),
        "graph": Path(
            "../sched2tlx/examples/case4_FA_bwd/schedule_graph_hd128.json"
        ),
        "normalization_u": 300,
        "regs_per_warp": 8160,
        "warp_fixed_overhead": 0,
    },
    "bwd_lr4096_v7": {
        "ddg": Path("../sched2tlx/examples/case4_FA_bwd/ddg_hd128.json"),
        "graph": Path(
            "../sched2tlx/examples/case4_FA_bwd/schedule_graph_hd128.json"
        ),
        "normalization_u": 300,
        "regs_per_warp": 4096,
        "warp_fixed_overhead": 0,
    },
}
scaffold_files = {
    "kernel.cu",
    "manual_cuda_authoring.json",
    "mapping_manifest.json",
    "memory_plan.json",
    "sync_manifest.json",
}
schemas = {
    "manual_cuda_authoring.json": AUTHORING_SCHEMA,
    "mapping_manifest.json": MAPPING_SCHEMA,
    "memory_plan.json": MEMORY_PLAN_SCHEMA,
    "sync_manifest.json": SYNC_PLAN_SCHEMA,
}
solver_source_hashes = set()

for stem, expected in cases.items():
    solution_path = out / f"{stem}.json"
    solution_bytes = solution_path.read_bytes()
    solution = json.loads(solution_bytes)
    if not isinstance(solution, dict):
        raise SystemExit(f"{solution_path} root is not an object")
    if solution.get("status") != "sat" or solution.get("satisfiable") is not True:
        raise SystemExit(f"{solution_path} is not a SAT solution")

    provenance = solution.get("provenance")
    if not isinstance(provenance, dict):
        raise SystemExit(f"{solution_path} has no provenance object")
    source_hash = provenance.get("solver_sources_sha256")
    if not isinstance(source_hash, str) or not re.fullmatch(
        r"[0-9a-f]{64}", source_hash
    ):
        raise SystemExit(f"{solution_path} has an invalid solver source hash")
    solver_source_hashes.add(source_hash)
    for field, path in (
        ("ddg_sha256", expected["ddg"]),
        ("baseline_graph_sha256", expected["graph"]),
    ):
        actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        if provenance.get(field) != actual_hash:
            raise SystemExit(f"{solution_path} {field} does not match {path}")
    if provenance.get("normalization_u") != expected["normalization_u"]:
        raise SystemExit(f"{solution_path} normalization_u mismatch")
    machine = provenance.get("machine")
    if not isinstance(machine, dict):
        raise SystemExit(f"{solution_path} has no machine provenance")
    for field in ("regs_per_warp", "warp_fixed_overhead"):
        if machine.get(field) != expected[field]:
            raise SystemExit(f"{solution_path} machine.{field} mismatch")

    solution_sha256 = hashlib.sha256(solution_bytes).hexdigest()
    ir = load_pipelined_ir(out / f"{stem}_ir.json")
    if PIPELINED_IR_SCHEMA != "twill-pipelined-warp-ir-v2":
        raise SystemExit(f"unexpected current IR schema: {PIPELINED_IR_SCHEMA}")
    if ir.payload.get("schema_version") != "twill-pipelined-warp-ir-v2":
        raise SystemExit(f"{stem} did not emit v2 pipelined IR")
    if ir.payload.get("solution_sha256") != solution_sha256:
        raise SystemExit(f"{stem} IR does not reference its exact solution bytes")
    handoff = load_handoff(out / f"{stem}_handoff.json", ir)

    manual = out / f"{stem}_manual"
    present = {path.name for path in manual.iterdir()}
    if present != scaffold_files:
        raise SystemExit(
            f"{manual} has the wrong files: "
            f"missing={sorted(scaffold_files - present)}, "
            f"extra={sorted(present - scaffold_files)}"
        )
    kernel = (manual / "kernel.cu").read_text(encoding="utf-8")
    if '#error "Manual CUDA lowering is required' not in kernel:
        raise SystemExit(f"{manual}/kernel.cu is not a fail-closed scaffold")

    plans = {}
    for filename, schema in schemas.items():
        artifact = load_json_artifact(manual / filename, filename)
        validate_plan_header(artifact.payload, schema, ir)
        if artifact.payload.get("status") != "manual_completion_required":
            raise SystemExit(f"{manual}/{filename} is not a draft")
        plans[filename] = artifact
    authoring = plans["manual_cuda_authoring.json"].payload
    if authoring.get("solution_sha256") != solution_sha256:
        raise SystemExit(f"{stem} authoring record solution hash mismatch")
    handoff_ref = authoring.get("handoff")
    if not isinstance(handoff_ref, dict) or handoff_ref.get("sha256") != handoff.sha256:
        raise SystemExit(f"{stem} authoring record handoff hash mismatch")
    manifest_refs = authoring.get("manifests")
    if not isinstance(manifest_refs, dict):
        raise SystemExit(f"{stem} authoring record has no manifest references")
    for kind, filename in (
        ("mapping", "mapping_manifest.json"),
        ("memory", "memory_plan.json"),
        ("synchronization", "sync_manifest.json"),
    ):
        reference = manifest_refs.get(kind)
        if not isinstance(reference, dict):
            raise SystemExit(f"{stem} has no {kind} manifest reference")
        if reference.get("path") != filename:
            raise SystemExit(f"{stem} {kind} manifest path mismatch")
        if reference.get("sha256") != plans[filename].sha256:
            raise SystemExit(f"{stem} {kind} manifest hash mismatch")
    print(f"{stem}: solution, v2 IR, handoff, and draft scaffold validated")

if len(solver_source_hashes) != 1:
    raise SystemExit(
        "solutions have different solver_sources_sha256 values: "
        + ", ".join(sorted(solver_source_hashes))
    )
print(f"solver_sources_sha256={solver_source_hashes.pop()}")
print("all draft audit-bundle checks rejected at the authoring approval gate")
PY
then
  cat "$VALIDATION_LOG" >&2
  exit 1
fi

cat "$VALIDATION_LOG"
