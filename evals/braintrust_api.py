"""
Shared Braintrust API utilities for evals.

This module provides helper functions for making Braintrust API calls
using the SDK's built-in connection handling, which properly supports
alternate data planes via the login endpoint.
"""

import os

import braintrust


def _ensure_logged_in():
    """Ensure we're logged in to Braintrust."""
    braintrust.login()  # No-op if already logged in


def get_or_create_project(project_name: str) -> str | None:
    """Get or create a Braintrust project and return its ID."""
    api_key = os.environ.get("BRAINTRUST_API_KEY")
    if not api_key:
        return None

    logger = braintrust.init_logger(project=project_name)
    return logger.project.id


def get_experiments(project_id: str) -> list[dict]:
    """Get all experiments for a project."""
    api_key = os.environ.get("BRAINTRUST_API_KEY")
    if not api_key or not project_id:
        return []

    _ensure_logged_in()
    conn = braintrust.api_conn()

    resp = conn.get("v1/experiment", params={"project_id": project_id, "limit": 100})

    if resp.status_code == 200:
        return resp.json().get("objects", [])
    return []


def get_experiment_summary(experiment_id: str, summarize_scores: bool = True) -> dict | None:
    """
    Get summary stats for an experiment using the summarize API endpoint.

    Returns experiment metadata, scores, and metrics compared to the baseline.
    """
    api_key = os.environ.get("BRAINTRUST_API_KEY")
    if not api_key:
        return None

    _ensure_logged_in()
    conn = braintrust.api_conn()

    resp = conn.get(
        f"v1/experiment/{experiment_id}/summarize",
        params={"summarize_scores": summarize_scores},
    )

    if resp.status_code == 200:
        return resp.json()
    return None


def query_project_logs(project_id: str, test_id: str | None = None) -> list[dict]:
    """Query project logs from Braintrust using SQL."""
    api_key = os.environ.get("BRAINTRUST_API_KEY")
    if not api_key or not project_id:
        return []

    _ensure_logged_in()
    conn = braintrust.api_conn()

    # Build SQL query - filter by test_id if provided
    if test_id:
        query = f"SELECT id, created, input, output, metadata, scores FROM project_logs('{project_id}') WHERE metadata.test_id = '{test_id}' LIMIT 100"
    else:
        query = f"SELECT id, created, input, output, metadata, scores FROM project_logs('{project_id}') LIMIT 100"

    resp = conn.post("btql", json={"query": query, "fmt": "json"})

    if resp.status_code == 200:
        return resp.json().get("data", [])
    return []


def count_logs_with_test_id(project_id: str, test_id: str) -> int:
    """Count logs with a specific test_id."""
    logs = query_project_logs(project_id, test_id)
    return len(logs)
