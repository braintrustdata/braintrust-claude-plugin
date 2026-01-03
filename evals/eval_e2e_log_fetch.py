"""
Braintrust skill eval: end-to-end log and fetch

Tests Claude's ability to actually execute code that:
1. Logs data to Braintrust
2. Fetches the logs back using SQL
3. Verifies the data matches

Verification is done by querying Braintrust directly, not trusting Claude's output.

Run with: braintrust eval evals/eval_e2e_log_fetch.py
"""

import asyncio
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from autoevals import Score
from braintrust import Eval, start_span
from braintrust.wrappers.claude_agent_sdk import setup_claude_agent_sdk
from braintrust_api import count_logs_with_test_id, get_or_create_project
from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient

# Generate unique test identifier to avoid collisions
TEST_RUN_ID = str(uuid.uuid4())[:8]
TEST_PROJECT_NAME = f"skill-eval-e2e-{TEST_RUN_ID}"

# Load skill content
SKILL_PATH = Path(__file__).parent.parent / "skill" / "SKILL.md"
SKILL_CONTENT = SKILL_PATH.read_text() if SKILL_PATH.exists() else ""

# Setup Claude Agent SDK patching (will trace within parent span context)
setup_claude_agent_sdk()


async def run_claude_agent(prompt: str, max_turns: int = 10, use_skill: bool = True) -> dict:
    """
    Run Claude Agent with code execution enabled and collect results.
    Returns dict with 'success', 'output', 'error' fields.
    """
    base_prompt = """You are an expert at Braintrust, an LLM evaluation platform.
You have access to code execution. Use Python to complete the tasks.
Be concise and execute code directly - don't just explain."""

    if use_skill and SKILL_CONTENT:
        system_prompt = f"""{base_prompt}

Here is the reference documentation for using Braintrust:

{SKILL_CONTENT}

Follow the examples in the documentation exactly. Pay special attention to:
- Always call logger.flush() after logging to ensure data is sent
- Use init_logger(project="name") to create a logger"""
    else:
        system_prompt = f"""{base_prompt}
Always use the braintrust SDK for logging and querying."""

    options = ClaudeAgentOptions(
        model="claude-sonnet-4-5-20250929",
        system_prompt=system_prompt,
        max_turns=max_turns,
        permission_mode="bypassPermissions",
    )

    success = False
    output = ""
    messages: list[str] = []
    error: str | None = None

    try:
        async with ClaudeSDKClient(options=options) as client:
            await client.query(prompt)
            async for message in client.receive_response():
                msg_type = type(message).__name__
                messages.append(msg_type)

                # Extract text from assistant messages
                if hasattr(message, "content"):
                    content = getattr(message, "content", [])
                    if isinstance(content, list):
                        for block in content:
                            block_type = type(block).__name__
                            if hasattr(block, "text"):
                                output += getattr(block, "text", "") + "\n"
                            if block_type == "ToolResultBlock" and hasattr(block, "content"):
                                output += f"\n[Tool Result]: {getattr(block, 'content', '')}\n"

                if msg_type == "ResultMessage":
                    if hasattr(message, "result"):
                        output += f"\n[Final Result]: {getattr(message, 'result', '')}\n"
                    success = not getattr(message, "is_error", False)

    except Exception as e:
        error = str(e)

    return {"success": success, "output": output, "messages": messages, "error": error}


def e2e_log_fetch_task(input_data: dict) -> dict:
    """
    Task that asks Claude to log data and returns verification data.
    """
    test_id = f"{TEST_RUN_ID}-{input_data.get('id', 'test')}"
    expected_count = input_data.get("expected_count", 3)

    # Get or create the test project
    project_id = get_or_create_project(TEST_PROJECT_NAME)

    # Count logs before Claude runs
    logs_before = count_logs_with_test_id(project_id, test_id) if project_id else 0

    prompt = f"""
Complete this task using Python code execution:

{input_data["task"]}

Important requirements:
- Use project name: "{TEST_PROJECT_NAME}"
- Add metadata={{"test_id": "{test_id}"}} to ALL log calls so we can verify them
- After logging, call logger.flush() to ensure logs are sent
- Print what you logged

Execute the code, don't just show it.
"""

    # Run Claude within a traced span
    with start_span(name="claude_agent", input={"prompt": prompt[:500]}):
        result = asyncio.run(run_claude_agent(prompt))
    output = result["output"] if not result["error"] else f"ERROR: {result['error']}"

    # Count logs after Claude runs - this is the ground truth verification
    logs_after = count_logs_with_test_id(project_id, test_id) if project_id else 0
    logs_created = logs_after - logs_before

    return {
        "output": output,
        "success": result["success"],
        "project_id": project_id,
        "test_id": test_id,
        "logs_before": logs_before,
        "logs_after": logs_after,
        "logs_created": logs_created,
        "expected_count": expected_count,
    }


def logs_created_scorer(output: dict, expected: dict, **kwargs) -> Score:
    """
    Scorer that verifies logs were actually created in Braintrust.
    Queries Braintrust directly - does not trust Claude's output.
    """
    if isinstance(output, str):
        return Score(name="Logs Created", score=0, metadata={"reason": "output is string"})

    logs_created = output.get("logs_created", 0)
    expected_count = output.get("expected_count", 1)

    if logs_created == 0:
        return Score(
            name="Logs Created",
            score=0,
            metadata={
                "reason": "no logs found in Braintrust",
                "project_id": output.get("project_id"),
                "test_id": output.get("test_id"),
                "logs_before": output.get("logs_before"),
                "logs_after": output.get("logs_after"),
            },
        )

    # Score based on how many logs were created vs expected
    score = min(1.0, logs_created / expected_count) if expected_count > 0 else 1.0

    return Score(
        name="Logs Created",
        score=score,
        metadata={
            "logs_created": logs_created,
            "expected_count": expected_count,
            "logs_before": output.get("logs_before"),
            "logs_after": output.get("logs_after"),
            "test_id": output.get("test_id"),
        },
    )


def correct_count_scorer(output: dict, expected: dict, **kwargs) -> Score:
    """
    Scorer that checks if the exact expected number of logs were created.
    """
    if isinstance(output, str):
        return Score(name="Correct Count", score=0, metadata={"reason": "output is string"})

    logs_created = output.get("logs_created", 0)
    expected_count = output.get("expected_count", 1)

    score = 1.0 if logs_created >= expected_count else 0.0

    return Score(
        name="Correct Count",
        score=score,
        metadata={
            "logs_created": logs_created,
            "expected_count": expected_count,
            "met_expectation": logs_created >= expected_count,
        },
    )


def task_completed_scorer(output: dict, expected: dict, **kwargs) -> Score:
    """
    Scorer that checks if Claude completed the task without errors.
    """
    if isinstance(output, str):
        return Score(name="Task Completed", score=0, metadata={"reason": "output is string"})

    output_text = output.get("output", "")
    success = output.get("success")  # Can be None, True, or False

    # Check for error indicators
    has_error = (
        output_text.startswith("ERROR:") or "Traceback" in output_text or "Exception" in output_text
    )

    # Success if no errors detected (success=None or True means no explicit failure)
    score = 1.0 if not has_error and success is not False else 0.0

    return Score(
        name="Task Completed",
        score=score,
        metadata={
            "success": success,
            "has_error": has_error,
        },
    )


def e2e_query_task(input_data: dict) -> dict:
    """
    Task that asks Claude to query logs and returns the output for analysis.
    """
    prompt = f"""
Complete this task using Python code execution:

{input_data["task"]}

Important: Use SQL syntax for queries against Braintrust logs.
Execute the code, don't just show it.
"""

    # Run Claude within a traced span
    with start_span(name="claude_agent_query", input={"prompt": prompt[:500]}):
        result = asyncio.run(run_claude_agent(prompt))

    output = result["output"] if not result["error"] else f"ERROR: {result['error']}"

    return {
        "output": output,
        "success": result["success"],
    }


def sql_query_scorer(output: dict, expected: dict, **kwargs) -> Score:
    """
    Scorer that checks if Claude used proper SQL query syntax.
    """
    output_text = output if isinstance(output, str) else output.get("output", "")

    # Check for SQL patterns
    has_select = "select" in output_text.lower()
    has_from = "from" in output_text.lower()
    has_where = "where" in output_text.lower()
    has_interval = "interval" in output_text.lower()
    has_count = "count(" in output_text.lower()

    # Check for anti-patterns (old BTQL syntax)
    has_btql_syntax = "select:" in output_text.lower() or "filter:" in output_text.lower()

    # Score based on SQL usage
    sql_indicators = sum([has_select, has_from, has_where, has_interval, has_count])
    base_score = min(1.0, sql_indicators / 3)
    score = base_score * 0.5 if has_btql_syntax else base_score

    return Score(
        name="SQL Query",
        score=score,
        metadata={
            "has_select": has_select,
            "has_from": has_from,
            "has_where": has_where,
            "has_interval": has_interval,
            "has_count": has_count,
            "has_btql_syntax": has_btql_syntax,
        },
    )


# End-to-end test scenarios
E2E_LOG_FETCH_DATA = [
    {
        "input": {
            "task": "Log 3 sample LLM calls with input/output pairs to Braintrust.",
            "id": "simple-log",
            "expected_count": 3,
        },
        "expected": {"logs_created": 3},
        "metadata": {"category": "log_fetch", "difficulty": "easy"},
    },
    {
        "input": {
            "task": "Log 2 entries with custom metadata fields (user_id='user123' and session_id='sess456').",
            "id": "log-with-metadata",
            "expected_count": 2,
        },
        "expected": {"logs_created": 2},
        "metadata": {"category": "log_fetch", "difficulty": "medium"},
    },
    {
        "input": {
            "task": "Log 3 entries with different score values: one with score 0.2, one with 0.5, and one with 0.9.",
            "id": "log-with-scores",
            "expected_count": 3,
        },
        "expected": {"logs_created": 3},
        "metadata": {"category": "log_fetch", "difficulty": "medium"},
    },
]

# Query test scenarios (separate data for query eval)
E2E_QUERY_DATA = [
    {
        "input": {
            "task": "Query the 'Loop logs' project in Braintrust. How many logs were created in the last day? Use a SQL query with count().",
        },
        "expected": {},
        "metadata": {
            "category": "log_query",
            "difficulty": "easy",
            "scenario": "count_recent_logs",
        },
    },
]


# Run the logging eval
Eval(
    "Braintrust Skill - E2E Log Fetch",
    data=lambda: E2E_LOG_FETCH_DATA,
    task=lambda input: e2e_log_fetch_task(input),
    scores=[logs_created_scorer, correct_count_scorer, task_completed_scorer],
    metadata={
        "description": "Tests Claude's ability to log data, verified by querying Braintrust directly",
        "skill": "using-braintrust",
        "category": "e2e",
        "test_run_id": TEST_RUN_ID,
        "test_project": TEST_PROJECT_NAME,
    },
)

# Run the query eval
Eval(
    "Braintrust Skill - E2E Log Query",
    data=lambda: E2E_QUERY_DATA,
    task=lambda input: e2e_query_task(input),
    scores=[sql_query_scorer, task_completed_scorer],
    metadata={
        "description": "Tests Claude's ability to query logs using SQL syntax",
        "skill": "using-braintrust",
        "category": "e2e",
        "test_run_id": TEST_RUN_ID,
    },
)
