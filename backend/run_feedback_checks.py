#!/usr/bin/env python3
"""Run deterministic checks across doctor-annotated feedback reports."""

from __future__ import annotations

import json
from pathlib import Path

from check_report import check_feedback_dir, format_feedback_summary


def main() -> int:
    backend_dir = Path(__file__).resolve().parent
    feedback_dir = backend_dir.parent / "feedback"
    output_path = feedback_dir / "feedback_check_results.json"

    dataset_result = check_feedback_dir(feedback_dir)
    output_path.write_text(json.dumps(dataset_result, ensure_ascii=False, indent=2), encoding="utf-8")

    print(format_feedback_summary(dataset_result))
    print(f"\nSaved JSON results to: {output_path}")

    failed = any(result["failed"] for result in dataset_result["results"])
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())