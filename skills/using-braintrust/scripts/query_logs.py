#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["braintrust", "python-dotenv"]
# ///
"""
Execute a SQL query against Braintrust project logs.

Usage:
    uv run query_logs.py --project "My Project" --query "SELECT input, output FROM logs LIMIT 10"
    uv run query_logs.py --project "My Project" --query "SELECT count(*) as count FROM logs WHERE created > now() - interval '1 day'"

Environment variables:
    BRAINTRUST_API_KEY: Your Braintrust API key (required)
    BRAINTRUST_APP_URL: Braintrust app URL (default: https://www.braintrust.dev)
"""

import argparse
import json
import re
import sys

from _common import get_api_conn, init_braintrust


def get_project_id(project_name: str) -> str:
    """Get project ID from name using the SDK's API connection."""
    conn = get_api_conn()

    # Try to get by name
    resp = conn.get("v1/project", params={"project_name": project_name})
    if resp.status_code == 200:
        projects = resp.json().get("objects", [])
        if projects:
            return projects[0]["id"]

    # Try listing all projects and matching by name
    resp = conn.get("v1/project")
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


def run_sql(project_id: str, query: str) -> list[dict]:
    """Execute SQL query against Braintrust logs using the SDK's API connection."""
    conn = get_api_conn()

    # Replace "FROM logs" with the project-scoped source
    full_query = re.sub(
        r"\bFROM\s+logs\b", f"FROM project_logs('{project_id}')", query, flags=re.IGNORECASE
    )

    resp = conn.post("btql", json={"query": full_query, "fmt": "json"})

    if resp.status_code == 200:
        return resp.json().get("data", [])
    else:
        print(f"Error: {resp.status_code} - {resp.text}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Execute SQL query against Braintrust logs")
    parser.add_argument("--project", required=True, help="Project name")
    parser.add_argument(
        "--query", required=True, help="SQL query (use 'FROM logs' for the project)"
    )
    parser.add_argument(
        "--format", choices=["json", "table"], default="table", help="Output format"
    )
    args = parser.parse_args()

    init_braintrust()

    project_id = get_project_id(args.project)

    # Show the SQL query being executed
    executed_query = re.sub(
        r"\bFROM\s+logs\b", f"FROM project_logs('{project_id}')", args.query, flags=re.IGNORECASE
    )
    print(f"Executing SQL: {executed_query}\n", file=sys.stderr)

    results = run_sql(project_id, args.query)

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
