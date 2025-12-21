#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["braintrust", "python-dotenv"]
# ///
"""
Log data to a Braintrust project.

Usage:
    uv run log_data.py --project "My Project" --input "hello" --output "world"
    uv run log_data.py --project "My Project" --data '[{"input": "a", "output": "b"}]'
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


def main():
    parser = argparse.ArgumentParser(description="Log data to Braintrust")
    parser.add_argument("--project", required=True, help="Project name")
    parser.add_argument("--input", help="Input value")
    parser.add_argument("--output", help="Output value")
    parser.add_argument("--expected", help="Expected value (optional)")
    parser.add_argument("--metadata", help="JSON metadata (optional)")
    parser.add_argument("--scores", help="JSON scores (optional)")
    parser.add_argument("--data", help="JSON array of log entries")
    parser.add_argument("--data-file", help="Path to JSON file with log entries")
    args = parser.parse_args()

    load_api_key()

    # Import after loading env so braintrust picks up the key
    import braintrust

    logger = braintrust.init_logger(project=args.project)

    # Batch logging
    if args.data or args.data_file:
        if args.data:
            entries = json.loads(args.data)
        else:
            with open(args.data_file) as f:
                entries = json.load(f)

        if not isinstance(entries, list):
            entries = [entries]

        for entry in entries:
            logger.log(**entry)

        logger.flush()
        print(f"Logged {len(entries)} entries to project: {args.project}")
        return

    # Single entry logging
    if not args.input:
        print("Error: Provide --input or --data/--data-file", file=sys.stderr)
        sys.exit(1)

    log_kwargs = {"input": args.input}

    if args.output:
        log_kwargs["output"] = args.output
    if args.expected:
        log_kwargs["expected"] = args.expected
    if args.metadata:
        log_kwargs["metadata"] = json.loads(args.metadata)
    if args.scores:
        log_kwargs["scores"] = json.loads(args.scores)

    logger.log(**log_kwargs)
    logger.flush()

    print(f"Logged entry to project: {args.project}")
    print(f"  Input: {args.input}")
    if args.output:
        print(f"  Output: {args.output}")


if __name__ == "__main__":
    main()
