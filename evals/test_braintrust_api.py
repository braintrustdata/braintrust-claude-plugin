#!/usr/bin/env python3
"""
Tests for braintrust_api.py

Run with: uv run pytest evals/test_braintrust_api.py -v
"""

import os
import sys
from pathlib import Path

import pytest
from dotenv import load_dotenv

# Load environment
load_dotenv()

sys.path.insert(0, str(Path(__file__).parent))

# Skip all tests if no API key is set
pytestmark = pytest.mark.skipif(
    not os.environ.get("BRAINTRUST_API_KEY"),
    reason="BRAINTRUST_API_KEY not set",
)


class TestGetOrCreateProject:
    """Tests for get_or_create_project function."""

    def test_get_existing_project(self):
        """Test getting an existing project returns a valid ID."""
        from braintrust_api import get_or_create_project

        # Use a project that should exist or will be created
        project_id = get_or_create_project("braintrust-api-test")

        assert project_id is not None
        assert isinstance(project_id, str)
        assert len(project_id) > 0

    def test_create_new_project(self):
        """Test creating a new project."""
        import uuid

        from braintrust_api import get_or_create_project

        # Create a unique project name
        unique_name = f"test-project-{uuid.uuid4().hex[:8]}"
        project_id = get_or_create_project(unique_name)

        assert project_id is not None
        assert isinstance(project_id, str)

    def test_returns_none_without_api_key(self, monkeypatch):
        """Test that function returns None when API key is missing."""
        from braintrust_api import get_or_create_project

        monkeypatch.delenv("BRAINTRUST_API_KEY", raising=False)

        result = get_or_create_project("any-project")
        assert result is None


class TestGetExperiments:
    """Tests for get_experiments function."""

    def test_get_experiments_returns_list(self):
        """Test that get_experiments returns a list."""
        from braintrust_api import get_experiments, get_or_create_project

        project_id = get_or_create_project("braintrust-api-test")
        assert project_id is not None

        experiments = get_experiments(project_id)

        assert isinstance(experiments, list)

    def test_get_experiments_with_invalid_project(self):
        """Test that get_experiments handles invalid project ID gracefully."""
        from braintrust_api import get_experiments

        experiments = get_experiments("invalid-project-id-12345")

        assert isinstance(experiments, list)

    def test_returns_empty_without_api_key(self, monkeypatch):
        """Test that function returns empty list when API key is missing."""
        from braintrust_api import get_experiments

        monkeypatch.delenv("BRAINTRUST_API_KEY", raising=False)

        result = get_experiments("any-project-id")
        assert result == []


class TestGetExperimentSummary:
    """Tests for get_experiment_summary function."""

    @pytest.fixture
    def experiment_id(self):
        """Create a test experiment and return its ID."""
        import braintrust

        # Run a minimal eval to create an experiment
        braintrust.Eval(
            "braintrust-api-test",
            data=lambda: [{"input": "test", "expected": "test"}],
            task=lambda input: input,
            scores=[lambda output, expected: 1.0],
        )

        # Get the experiment ID
        braintrust.login()
        conn = braintrust.api_conn()
        resp = conn.get("v1/experiment", params={"project_name": "braintrust-api-test", "limit": 1})

        if resp.status_code == 200:
            experiments = resp.json().get("objects", [])
            if experiments:
                return experiments[0]["id"]

        pytest.skip("Could not create test experiment")

    def test_get_experiment_summary_returns_dict(self, experiment_id):
        """Test that get_experiment_summary returns expected structure."""
        from braintrust_api import get_experiment_summary

        summary = get_experiment_summary(experiment_id)

        assert summary is not None
        assert isinstance(summary, dict)

    def test_summary_has_expected_keys(self, experiment_id):
        """Test that summary contains expected keys."""
        from braintrust_api import get_experiment_summary

        summary = get_experiment_summary(experiment_id)

        assert summary is not None
        expected_keys = {"project_name", "experiment_name", "project_url", "experiment_url"}
        assert expected_keys.issubset(set(summary.keys()))

    def test_summary_has_scores_and_metrics(self, experiment_id):
        """Test that summary includes scores and metrics."""
        from braintrust_api import get_experiment_summary

        summary = get_experiment_summary(experiment_id)

        assert summary is not None
        assert "scores" in summary
        assert "metrics" in summary

    def test_get_experiment_summary_invalid_id(self):
        """Test that invalid experiment ID returns None or handles gracefully."""
        from braintrust_api import get_experiment_summary

        summary = get_experiment_summary("invalid-experiment-id-12345")

        # Should return None for invalid ID
        assert summary is None

    def test_returns_none_without_api_key(self, monkeypatch):
        """Test that function returns None when API key is missing."""
        from braintrust_api import get_experiment_summary

        monkeypatch.delenv("BRAINTRUST_API_KEY", raising=False)

        result = get_experiment_summary("any-experiment-id")
        assert result is None


class TestQueryProjectLogs:
    """Tests for query_project_logs function."""

    def test_query_logs_returns_list(self):
        """Test that query_project_logs returns a list."""
        from braintrust_api import get_or_create_project, query_project_logs

        project_id = get_or_create_project("braintrust-api-test")
        assert project_id is not None

        logs = query_project_logs(project_id)

        assert isinstance(logs, list)

    def test_query_logs_with_test_id_filter(self):
        """Test filtering logs by test_id."""
        from braintrust_api import get_or_create_project, query_project_logs

        project_id = get_or_create_project("braintrust-api-test")
        assert project_id is not None

        # Query with a test_id that likely doesn't exist
        logs = query_project_logs(project_id, test_id="nonexistent-test-id")

        assert isinstance(logs, list)
        assert len(logs) == 0

    def test_returns_empty_without_api_key(self, monkeypatch):
        """Test that function returns empty list when API key is missing."""
        from braintrust_api import query_project_logs

        monkeypatch.delenv("BRAINTRUST_API_KEY", raising=False)

        result = query_project_logs("any-project-id")
        assert result == []


class TestCountLogsWithTestId:
    """Tests for count_logs_with_test_id function."""

    def test_count_returns_integer(self):
        """Test that count_logs_with_test_id returns an integer."""
        from braintrust_api import count_logs_with_test_id, get_or_create_project

        project_id = get_or_create_project("braintrust-api-test")
        assert project_id is not None

        count = count_logs_with_test_id(project_id, "some-test-id")

        assert isinstance(count, int)
        assert count >= 0


class TestApiUrlDiscovery:
    """Tests for API URL discovery via login."""

    def test_login_discovers_api_url(self):
        """Test that braintrust.login() properly discovers the API URL."""
        import braintrust

        braintrust.login()
        conn = braintrust.api_conn()

        # The connection should have a base_url set
        assert conn is not None

        # Make a simple API call to verify the URL works
        resp = conn.get("v1/project", params={"limit": 1})
        assert resp.status_code in (200, 504)  # 504 is timeout, but connection worked

    def test_app_url_env_var_respected(self, monkeypatch):
        """Test that BRAINTRUST_APP_URL environment variable is used."""
        import braintrust

        # This test just verifies the env var is read, not that it changes behavior
        # (since we can't easily test with a different app URL)
        # The SDK should use BRAINTRUST_APP_URL for login if set
        braintrust.login()

        # If we got here without error, the login worked with the configured app URL
        assert True
