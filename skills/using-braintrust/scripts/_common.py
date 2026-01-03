"""
Common utilities for Braintrust scripts.

This module provides shared functionality for loading environment variables,
checking API keys, and initializing the Braintrust SDK.
"""

import os
import sys
from pathlib import Path

from dotenv import load_dotenv


def load_env():
    """Load environment from .env file in current directory or parents."""
    for path in [Path.cwd(), *Path.cwd().parents]:
        env_file = path / ".env"
        if env_file.exists():
            load_dotenv(env_file)
            return True
    return False


def require_api_key():
    """Ensure BRAINTRUST_API_KEY is set, exit with error if not."""
    if not os.environ.get("BRAINTRUST_API_KEY"):
        print("Error: BRAINTRUST_API_KEY not found.", file=sys.stderr)
        print("Set it via environment variable or create a .env file with:", file=sys.stderr)
        print('  BRAINTRUST_API_KEY="your-api-key"', file=sys.stderr)
        sys.exit(1)


def init_braintrust():
    """
    Initialize Braintrust SDK: load env, check API key, and login.

    This handles API URL discovery automatically via the login endpoint.
    Supports BRAINTRUST_APP_URL env var for alternate deployments.
    """
    import braintrust

    load_env()
    require_api_key()
    braintrust.login()


def get_api_conn():
    """Get the Braintrust API connection."""
    import braintrust

    braintrust.login()  # No-op if already logged in
    return braintrust.api_conn()
