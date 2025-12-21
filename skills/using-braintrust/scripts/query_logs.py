#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["requests", "python-dotenv"]
# ///
"""
Query Braintrust logs using BTQL.

Usage:
    uv run query_logs.py --project "My Project" --limit 10
    uv run query_logs.py --project "My Project" --query "select: input, output | limit: 5"
    uv run query_logs.py --project "My Project" --filter "created > now() - interval 1 day"
    uv run query_logs.py --project "My Project" --last-day --count
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
    # Try loading .env from current directory and parent directories
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
    assert api_key is not None  # Type narrowing after sys.exit
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


def query_logs(project_id: str, query: str, api_key: str) -> list[dict]:
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
        return []


def main():
    parser = argparse.ArgumentParser(description="Query Braintrust logs")
    parser.add_argument("--project", required=True, help="Project name")
    parser.add_argument("--query", help="Full BTQL query (after from clause)")
    parser.add_argument("--filter", help="Filter condition")
    parser.add_argument(
        "--select",
        default="input, output, created",
        help="Fields to select (default: input, output, created)",
    )
    parser.add_argument("--limit", type=int, default=10, help="Limit results (default: 10)")
    parser.add_argument(
        "--format", choices=["json", "table"], default="table", help="Output format"
    )
    parser.add_argument(
        "--last-day", action="store_true", help="Filter to logs from the last 24 hours"
    )
    parser.add_argument("--count", action="store_true", help="Just count the results")
    args = parser.parse_args()

    api_key = load_api_key()
    project_id = get_project_id(args.project, api_key)

    # Build query
    if args.query:
        query = args.query
    else:
        query = "select: count(1) as count" if args.count else f"select: {args.select}"

        filters = []
        if args.last_day:
            filters.append("created > now() - interval 1 day")
        if args.filter:
            filters.append(args.filter)

        if filters:
            query += f" | filter: {' AND '.join(filters)}"

        if not args.count:
            query += f" | limit: {args.limit}"

    # Execute query
    results = query_logs(project_id, query, api_key)

    # Output
    if args.format == "json":
        print(json.dumps(results, indent=2, default=str))
    else:
        if args.count and results:
            print(f"Count: {results[0].get('count', len(results))}")
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
