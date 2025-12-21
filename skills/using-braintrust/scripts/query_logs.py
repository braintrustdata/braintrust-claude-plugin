#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["requests", "python-dotenv"]
# ///
"""
Execute a BTQL query against Braintrust project logs.

Usage:
    uv run query_logs.py --project "My Project" --query "select: input, output | limit: 10"
    uv run query_logs.py --project "My Project" --query "select: count(1) as count | filter: created > now() - interval 1 day"
"""

import argparse
import json
import os
import sys
from pathlib import Path

import requests
from dotenv import load_dotenv


def load_api_key() -> str:
    """Load API key from environment or .env file."""
    for path in [Path.cwd(), *Path.cwd().parents]:
        env_file = path / ".env"
        if env_file.exists():
            load_dotenv(env_file)
            break

    api_key = os.environ.get("BRAINTRUST_API_KEY")
    if not api_key:
        print("Error: BRAINTRUST_API_KEY not found.", file=sys.stderr)
        print("Set it via environment variable or create a .env file with:", file=sys.stderr)
        print('  BRAINTRUST_API_KEY="your-api-key"', file=sys.stderr)
        sys.exit(1)
    assert api_key is not None
    return api_key


def get_project_id(project_name: str, api_key: str) -> str:
    """Get project ID from name."""
    headers = {"Authorization": f"Bearer {api_key}"}
    resp = requests.get(
        "https://api.braintrust.dev/v1/project",
        headers=headers,
        params={"project_name": project_name},
    )
    if resp.status_code == 200:
        projects = resp.json().get("objects", [])
        if projects:
            return projects[0]["id"]

    # Try listing all projects and matching by name
    resp = requests.get("https://api.braintrust.dev/v1/project", headers=headers)
    if resp.status_code == 200:
        projects = resp.json().get("objects", [])
        for p in projects:
            if p.get("name", "").lower() == project_name.lower():
                return p["id"]

    print(f"Error: Project '{project_name}' not found", file=sys.stderr)
    print("Available projects:", file=sys.stderr)
    if resp.status_code == 200:
        for p in resp.json().get("objects", [])[:10]:
            print(f"  - {p.get('name')}", file=sys.stderr)
    sys.exit(1)


def run_btql(project_id: str, query: str, api_key: str) -> list[dict]:
    """Execute BTQL query."""
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    full_query = f'from: project_logs("{project_id}") | {query}'

    resp = requests.post(
        "https://api.braintrust.dev/btql",
        headers=headers,
        json={"query": full_query, "fmt": "json"},
    )

    if resp.status_code == 200:
        return resp.json().get("data", [])
    else:
        print(f"Error: {resp.status_code} - {resp.text}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Execute BTQL query against Braintrust logs")
    parser.add_argument("--project", required=True, help="Project name")
    parser.add_argument("--query", required=True, help="BTQL query (after the from clause)")
    parser.add_argument(
        "--format", choices=["json", "table"], default="table", help="Output format"
    )
    args = parser.parse_args()

    api_key = load_api_key()
    project_id = get_project_id(args.project, api_key)
    results = run_btql(project_id, args.query, api_key)

    if args.format == "json":
        print(json.dumps(results, indent=2, default=str))
    else:
        if not results:
            print("No results")
        elif len(results) == 1 and len(results[0]) == 1:
            # Single value result (like count)
            key, value = list(results[0].items())[0]
            print(f"{key}: {value}")
        else:
            print(f"Found {len(results)} results:\n")
            for i, row in enumerate(results):
                print(f"--- Result {i+1} ---")
                for key, value in row.items():
                    val_str = str(value)[:200] if value else "null"
                    print(f"  {key}: {val_str}")
                print()


if __name__ == "__main__":
    main()
