"""Classify a joint solution's WS strategy against the reference structure
the paper reports for Blackwell forward FMHA (its Fig 9):

  * one variable-latency group holding the TMA loads;
  * one Tensor-Core group holding all tcgen05 MMAs;
  * TWO distinct softmax groups (one per M-sub-tile exp2 chain);
  * a separate accumulator-rescale group (TMEM traffic + rescale mults);
  * softmax chains anti-phased (ping-pong) in the steady state.

Usage: python -m paper_joint_solver.strategy_report <ddg.json> <solution.json>
       --baseline-graph <schedule_graph.json>
"""

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

from .ddg import Problem
from .schedule_plan import load_schedule_context


def classify(prob: Problem, warp: dict[int, int],
             cycles: dict[int, int] | None = None) -> dict:
    groups = defaultdict(list)
    for v, w in warp.items():
        groups[w].append(prob.nodes[v])

    def group_of(pred):
        return {w for w, members in groups.items()
                if any(pred(n) for n in members)}

    tma_groups = group_of(lambda n: n.pipeline == "TMA" and "load" in n.op_kind)
    mma_groups = group_of(lambda n: "mma" in n.op_kind)
    exp_nodes = [n for n in prob.nodes.values() if "exp2" in n.op_kind]
    exp_groups = {warp[n.id] for n in exp_nodes}
    tmem_groups = group_of(lambda n: n.pipeline == "TMEM")

    # Sub-tile chains: connected components over non-shared nodes (mirrors
    # the DDG construction — chains meet only at K/V staging).
    report = {
        "num_groups_used": len({w for w, m in groups.items() if m}),
        "group_sizes": {w: len(m) for w, m in sorted(groups.items())},
        "tma_isolated": tma_groups and all(
            n.pipeline == "TMA" or n.occupancy == 0
            for w in tma_groups for n in groups[w]),
        "tma_groups": sorted(tma_groups),
        "mma_groups": sorted(mma_groups),
        "mma_single_group": len(mma_groups) == 1,
        "exp_groups": sorted(exp_groups),
        "softmax_two_groups": len(exp_groups) == 2,
        "tmem_groups": sorted(tmem_groups),
        "rescale_separate": bool(tmem_groups - exp_groups - mma_groups),
    }
    if cycles and len(exp_nodes) >= 2:
        by_group = defaultdict(list)
        for n in exp_nodes:
            by_group[warp[n.id]].append(cycles[n.id])
        report["softmax_phase_offsets"] = {
            str(w): sorted(v) for w, v in by_group.items()}
    report["fa4_like"] = bool(report["tma_isolated"]
                              and report["mma_single_group"]
                              and report["softmax_two_groups"]
                              and report["rescale_separate"])
    return report


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description="Classify a joint solution's warp-specialization strategy"
    )
    parser.add_argument("ddg")
    parser.add_argument("solution")
    parser.add_argument(
        "--baseline-graph",
        required=True,
        help="schedule_graph.json carrying emitter-infrastructure ownership",
    )
    args = parser.parse_args(argv)

    prob, plan = load_schedule_context(
        args.solution,
        args.ddg,
        args.baseline_graph,
    )
    sol = json.loads(Path(args.solution).read_text())
    warp = plan.warp
    cycles = plan.cycles
    rep = classify(prob, warp, cycles)
    rep["ii"] = plan.ii
    rep["length"] = plan.length
    rep["wall_s"] = sol.get("wall_s")
    print(json.dumps(rep, indent=1))
    per_group = defaultdict(Counter)
    for v, w in warp.items():
        per_group[w][prob.nodes[v].op_kind.split(".")[-1]] += 1
    for w in sorted(per_group):
        print(f"group {w}: {dict(per_group[w])}")


if __name__ == "__main__":
    main()
