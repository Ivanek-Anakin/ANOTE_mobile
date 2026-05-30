#!/usr/bin/env python3
"""Summarize all evaluation results."""
import json
import os

files = {
    'v0 Demo': 'evaluation_results_demo.json',
    'v0 Hurv': 'evaluation_results.json',
    'v1 Demo': 'eval_v1_demo.json',
    'v1 Hurv': 'eval_v1_hurvinek.json',
    'v2 Demo': 'eval_v2_demo.json',
    'v2 Hurv': 'eval_v2_hurvinek.json',
    'v3 Demo': 'eval_v3_demo.json',
    'v3 Hurv': 'eval_v3_hurvinek.json',
}

PREFERRED_ORDER = [
    'factual_accuracy',
    'completeness',
    'structure',
    'negation_handling',
    'clinical_language',
    'noise_resilience',
    'brevity',
    'hallucinated_negation',
]
DIM_SHORT = {
    'factual_accuracy': 'Fact',
    'completeness': 'Comp',
    'structure': 'Strc',
    'negation_handling': 'Neg',
    'clinical_language': 'Lang',
    'noise_resilience': 'Noise',
    'brevity': 'Brev',
    'hallucinated_negation': 'HalNeg',
}


def _discover_dimensions(results):
    discovered = set()
    for scenario in results:
        scores = scenario.get('evaluation', {}).get('scores', {})
        discovered.update(key.lower() for key in scores.keys())
    ordered = [dim for dim in PREFERRED_ORDER if dim in discovered]
    ordered.extend(sorted(discovered - set(ordered)))
    return ordered


def _score_value(scores, dim):
    value = scores.get(dim)
    if value is None:
        value = scores.get(dim.upper())
    if isinstance(value, dict):
        return value.get('score')
    return value


def _deterministic_rate(scenario):
    value = scenario.get('deterministic_pass_rate')
    if value is None:
        value = scenario.get('evaluation', {}).get('deterministic_pass_rate')
    return value if isinstance(value, (int, float)) else None

for label, path in files.items():
    if not os.path.exists(path):
        print(f'{label:12s}  FILE NOT FOUND')
        continue
    with open(path) as f:
        data = json.load(f)
    results = data.get('results', data.get('scenarios', []))
    dims = _discover_dimensions(results)
    if not dims:
        print(f'{label:12s}  NO SCORES FOUND')
        continue
    scores = {d: [] for d in dims}
    det_rates = []
    for s in results:
        ev = s.get('evaluation', {})
        sc = ev.get('scores', {})
        for d in dims:
            val = _score_value(sc, d)
            if isinstance(val, (int, float)):
                scores[d].append(val)
        det_rate = _deterministic_rate(s)
        if det_rate is not None:
            det_rates.append(det_rate)
    avgs = {d: sum(v)/len(v) if v else 0 for d,v in scores.items()}
    overall = sum(avgs.values())/len(avgs)
    parts = '  '.join(f'{DIM_SHORT.get(d, d[:6])}={avgs[d]:.2f}' for d in dims)
    det = f"  DET={sum(det_rates)/len(det_rates):.0%}" if det_rates else ''
    print(f'{label:12s}  {parts}  AVG={overall:.2f}{det}')
