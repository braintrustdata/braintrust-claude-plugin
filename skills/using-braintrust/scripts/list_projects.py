#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["braintrust", "python-dotenv"]
# ///
"""
List Braintrust projects.

Usage:
    uv run list_projects.py
    uv run list_projects.py --limit 20

Environment variables:
    BRAINTRUST_API_KEY: Your Braintrust API key (required)
    BRAINTRUST_APP_URL: Braintrust app URL (default: https://www.braintrust.dev)
"""

import argparse

from _common import get_api_conn, init_braintrust


def main():
    parser = argparse.ArgumentParser(description="List Braintrust projects")
    parser.add_argument("--limit", type=int, default=50, help="Maximum number of projects to list")
    args = parser.parse_args()

    init_braintrust()
    conn = get_api_conn()

    resp = conn.get("v1/project", params={"limit": args.limit})

    if resp.status_code != 200:
        print(f"Error: {resp.status_code} - {resp.text}")
        return

    projects = resp.json().get("objects", [])

    if not projects:
        print("No projects found.")
        return

    print(f"Found {len(projects)} projects:\n")
    for p in projects:
        name = p.get("name", "unnamed")
        project_id = p.get("id", "")
        created = p.get("created", "")[:10] if p.get("created") else ""
        print(f"  - {name}")
        print(f"    ID: {project_id}")
        if created:
            print(f"    Created: {created}")
        print()


if __name__ == "__main__":
    main()
