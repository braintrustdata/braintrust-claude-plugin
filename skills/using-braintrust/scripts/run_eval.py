#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["braintrust", "autoevals", "python-dotenv"]
# ///
"""
Run a Braintrust evaluation with custom data.

Usage:
    uv run run_eval.py --project "My Project" --data '[{"input": "test", "expected": "test"}]'
    uv run run_eval.py --project "My Project" --data-file data.json
"""

import argparse
import json
import os
import sys
from pathlib import Path

from dotenv import load_dotenv


def load_api_key() -> None:
    """Load API key from environment or .env file."""
    # Try loading .env from current directory and parent directories
    for path in [Path.cwd(), *Path.cwd().parents]:
        env_file = path / ".env"
        if env_file.exists():
            load_dotenv(env_file)
            break

    if not os.environ.get("BRAINTRUST_API_KEY"):
        print("Error: BRAINTRUST_API_KEY not found.", file=sys.stderr)
        print("Set it via environment variable or create a .env file with:", file=sys.stderr)
        print('  BRAINTRUST_API_KEY="your-api-key"', file=sys.stderr)
        sys.exit(1)


def simple_task(input_data):
    """Default task that just echoes input. Replace with your LLM call."""
    if isinstance(input_data, dict):
        return str(input_data.get("input", input_data))
    return str(input_data)


def main():
    parser = argparse.ArgumentParser(description="Run a Braintrust evaluation")
    parser.add_argument("--project", required=True, help="Project name")
    parser.add_argument("--data", help="JSON string of data")
    parser.add_argument("--data-file", help="Path to JSON file with data")
    parser.add_argument("--experiment", help="Experiment name (optional)")
    parser.add_argument(
        "--scorer", default="exact", choices=["exact", "factuality"], help="Scorer to use"
    )
    args = parser.parse_args()

    load_api_key()

    # Import after loading env so braintrust picks up the key
    import braintrust
    from autoevals import Factuality, Score

    def exact_match_scorer(input, output, expected=None, **kwargs):
        """Scorer that checks for exact match with expected."""
        if expected is None:
            return Score(name="Exact Match", score=1.0, metadata={"reason": "no expected"})

        match = str(output).strip().lower() == str(expected).strip().lower()
        return Score(
            name="Exact Match",
            score=1.0 if match else 0.0,
            metadata={"output": str(output)[:100], "expected": str(expected)[:100]},
        )

    # Load data
    if args.data:
        data = json.loads(args.data)
    elif args.data_file:
        with open(args.data_file) as f:
            data = json.load(f)
    else:
        print("Error: Provide --data or --data-file", file=sys.stderr)
        sys.exit(1)

    # Ensure data is a list
    if not isinstance(data, list):
        data = [data]

    # Select scorer
    scorers = [Factuality] if args.scorer == "factuality" else [exact_match_scorer]

    # Run eval
    print(f"Running evaluation on project: {args.project}")
    print(f"Data: {len(data)} items")
    print(f"Scorer: {args.scorer}")

    braintrust.Eval(
        args.project,
        data=lambda: data,
        task=simple_task,
        scores=scorers,
        experiment_name=args.experiment,
    )


if __name__ == "__main__":
    main()
