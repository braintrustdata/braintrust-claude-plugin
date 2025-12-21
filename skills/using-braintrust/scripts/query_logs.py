#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["braintrust", "requests"]
# ///
"""
Query Braintrust logs using BTQL.

Usage:
    uv run scripts/query_logs.py --project "My Project" --limit 10
    uv run scripts/query_logs.py --project "My Project" --query "select: input, output | limit: 5"
    uv run scripts/query_logs.py --project "My Project" --filter "metadata.user_id = 'user123'"
"""

import argparse
import json
import os
import sys

import requests


def get_project_id(project_name: str, api_key: str) -> str | None:
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
    return None


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
    parser.add_argument("--limit", type=int, default=10, help="Limit results")
    parser.add_argument(
        "--format", choices=["json", "table"], default="table", help="Output format"
    )
    args = parser.parse_args()

    api_key = os.environ.get("BRAINTRUST_API_KEY")
    if not api_key:
        print("Error: BRAINTRUST_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    assert api_key is not None  # Type narrowing for type checker

    # Get project ID
    project_id = get_project_id(args.project, api_key)
    if not project_id:
        print(f"Error: Project '{args.project}' not found", file=sys.stderr)
        sys.exit(1)
    assert project_id is not None  # Type narrowing for type checker

    # Build query
    if args.query:
        query = args.query
    else:
        query = f"select: {args.select}"
        if args.filter:
            query += f" | filter: {args.filter}"
        query += f" | limit: {args.limit}"

    # Execute query
    results = query_logs(project_id, query, api_key)

    # Output
    if args.format == "json":
        print(json.dumps(results, indent=2, default=str))
    else:
        print(f"Found {len(results)} results:\n")
        for i, row in enumerate(results):
            print(f"--- Result {i+1} ---")
            for key, value in row.items():
                val_str = str(value)[:100] if value else "null"
                print(f"  {key}: {val_str}")
            print()


if __name__ == "__main__":
    main()
