#!/usr/bin/env python3
"""Summarize all evaluation results."""
import json, os

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
dims = ['FACTUAL_ACCURACY','COMPLETENESS','STRUCTURE','NEGATION_HANDLING','CLINICAL_LANGUAGE','NOISE_RESILIENCE']
short = ['Fact','Comp','Strc','Neg','Lang','Noise']

for label, path in files.items():
    if not os.path.exists(path):
        print(f'{label:12s}  FILE NOT FOUND')
        continue
    with open(path) as f:
        data = json.load(f)
    results = data.get('results', data.get('scenarios', []))
    scores = {d: [] for d in dims}
    for s in results:
        ev = s.get('evaluation', {})
        sc = ev.get('scores', {})
        for d in dims:
            dl = d.lower()
            if dl in sc:
                val = sc[dl]
                if isinstance(val, dict):
                    scores[d].append(val['score'])
                else:
                    scores[d].append(val)
            elif d in sc:
                val = sc[d]
                if isinstance(val, dict):
                    scores[d].append(val['score'])
                else:
                    scores[d].append(val)
    avgs = {d: sum(v)/len(v) if v else 0 for d,v in scores.items()}
    overall = sum(avgs.values())/len(avgs)
    parts = '  '.join(f'{s}={avgs[d]:.2f}' for s,d in zip(short, dims))
    print(f'{label:12s}  {parts}  AVG={overall:.2f}')
