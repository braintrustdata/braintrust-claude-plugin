"""
Braintrust skill eval: end-to-end experiment workflow

Tests Claude's ability to:
1. Create a dataset
2. Write an eval with a scorer
3. Run the eval
4. Analyze results and improve the prompt
5. Run again and verify improvement

Verification is done by querying Braintrust directly for experiments.

Run with: braintrust eval evals/eval_e2e_eval_improve.py
"""

import asyncio
import os
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from autoevals import Score
from braintrust import Eval, start_span
from braintrust.wrappers.claude_agent_sdk import setup_claude_agent_sdk
from braintrust_api import get_experiments, get_or_create_project
from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient

# Generate unique test identifier
TEST_RUN_ID = str(uuid.uuid4())[:8]
TEST_PROJECT_NAME = f"skill-eval-experiment-{TEST_RUN_ID}"

# Setup Claude Agent SDK patching
setup_claude_agent_sdk()

# MCP server configuration for Braintrust
MCP_SERVERS = {
    "braintrust": {
        "type": "http",
        "url": "https://api.braintrust.dev/mcp",
        "headers": {"Authorization": f"Bearer {os.environ.get('BRAINTRUST_API_KEY', '')}"},
    }
}


async def run_claude_agent(prompt: str, max_turns: int = 15, use_mcp: bool = True) -> dict:
    """
    Run Claude Agent with code execution enabled.

    Args:
        prompt: The prompt to send to Claude
        max_turns: Maximum number of conversation turns
        use_mcp: If True, connect the Braintrust MCP server for enhanced capabilities
    """
    system_prompt = """You are an expert at Braintrust, an LLM evaluation platform.
You have access to code execution. Use Python to complete the tasks.
Be concise and execute code directly - don't just explain.

When running evals, use braintrust.Eval() with proper task and scorer functions.
Pay special attention to:
- Eval() takes the project name as the FIRST POSITIONAL argument, not a keyword argument
- Always call logger.flush() after logging"""

    options = ClaudeAgentOptions(
        model="claude-sonnet-4-5-20250929",
        system_prompt=system_prompt,
        max_turns=max_turns,
        permission_mode="bypassPermissions",
        mcp_servers=MCP_SERVERS if use_mcp else {},
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


def e2e_experiment_task(input_data: dict) -> dict:
    """
    Task that asks Claude to create and run experiments.
    """
    test_id = f"{TEST_RUN_ID}-{input_data.get('id', 'test')}"

    # Get or create the test project
    project_id = get_or_create_project(TEST_PROJECT_NAME)

    # Count experiments before
    experiments_before = get_experiments(project_id) if project_id else []
    exp_count_before = len(experiments_before)

    prompt = f"""
Complete this task using Python code execution:

{input_data["task"]}

Important requirements:
- Use project name: "{TEST_PROJECT_NAME}"
- Add metadata={{"test_id": "{test_id}"}} to experiments
- After running, print the experiment results/scores

Execute the code, don't just show it.
"""

    # Run Claude
    with start_span(name="claude_agent", input={"prompt": prompt[:500]}):
        result = asyncio.run(run_claude_agent(prompt))
    output = result["output"] if not result["error"] else f"ERROR: {result['error']}"

    # Get experiments after
    experiments_after = get_experiments(project_id) if project_id else []
    exp_count_after = len(experiments_after)
    experiments_created = exp_count_after - exp_count_before

    # Get new experiment IDs
    before_ids = {e["id"] for e in experiments_before}
    new_experiments = [e for e in experiments_after if e["id"] not in before_ids]

    return {
        "output": output,
        "success": result["success"],
        "project_id": project_id,
        "test_id": test_id,
        "experiments_before": exp_count_before,
        "experiments_after": exp_count_after,
        "experiments_created": experiments_created,
        "new_experiment_ids": [e["id"] for e in new_experiments],
        "expected_experiments": input_data.get("expected_experiments", 1),
    }


def experiments_created_scorer(output: dict, expected: dict, **kwargs) -> Score:
    """
    Scorer that verifies experiments were actually created in Braintrust.
    """
    if isinstance(output, str):
        return Score(name="Experiments Created", score=0, metadata={"reason": "output is string"})

    experiments_created = output.get("experiments_created", 0)
    expected_count = output.get("expected_experiments", 1)

    if experiments_created == 0:
        return Score(
            name="Experiments Created",
            score=0,
            metadata={
                "reason": "no experiments found in Braintrust",
                "project_id": output.get("project_id"),
                "test_id": output.get("test_id"),
            },
        )

    score = min(1.0, experiments_created / expected_count) if expected_count > 0 else 1.0

    return Score(
        name="Experiments Created",
        score=score,
        metadata={
            "experiments_created": experiments_created,
            "expected_count": expected_count,
            "experiment_ids": output.get("new_experiment_ids", []),
        },
    )


def task_completed_scorer(output: dict, expected: dict, **kwargs) -> Score:
    """
    Scorer that checks if Claude completed the task successfully.
    Looks for success indicators, not just absence of errors.
    """
    if isinstance(output, str):
        return Score(name="Task Completed", score=0, metadata={"reason": "output is string"})

    output_text = output.get("output", "")

    # Success indicators - task completed even if there were minor errors
    success_indicators = [
        "Task Completed" in output_text,
        "successfully" in output_text.lower(),
        "✅" in output_text,
    ]

    # Fatal error indicators - task fundamentally failed
    fatal_errors = [
        output_text.startswith("ERROR:"),
        "ModuleNotFoundError" in output_text,
        "got an unexpected keyword argument" in output_text,
    ]

    has_success = any(success_indicators)
    has_fatal = any(fatal_errors)

    if has_fatal:
        score = 0.0
    elif has_success:
        score = 1.0
    else:
        score = 0.5

    return Score(
        name="Task Completed",
        score=score,
        metadata={
            "has_success_indicators": has_success,
            "has_fatal_errors": has_fatal,
        },
    )


def eval_ran_scorer(output: dict, expected: dict, **kwargs) -> Score:
    """
    Scorer that checks if an eval actually ran (output mentions scores/results).
    """
    if isinstance(output, str):
        return Score(name="Eval Ran", score=0, metadata={"reason": "output is string"})

    output_text = output.get("output", "").lower()

    indicators = [
        "score" in output_text,
        "result" in output_text,
        "experiment" in output_text,
        "running" in output_text or "ran" in output_text,
        "braintrust.dev" in output_text,  # Link to experiment
    ]

    passed = sum(indicators)
    score = passed / len(indicators)

    return Score(
        name="Eval Ran",
        score=score,
        metadata={"indicators_passed": passed, "total_indicators": len(indicators)},
    )


# End-to-end experiment test scenarios
E2E_EXPERIMENT_DATA = [
    {
        "input": {
            "task": """Create and run a simple eval that tests a greeting function.

1. Create a simple task function that takes an input name and returns a greeting
2. Create 3 test cases with different names
3. Create a scorer that checks if the greeting contains the name
4. Run the eval using braintrust.Eval()

Print the results when done.""",
            "id": "simple-eval",
            "expected_experiments": 1,
        },
        "expected": {"experiments_created": 1},
        "metadata": {"category": "experiment", "difficulty": "easy"},
    },
    {
        "input": {
            "task": """Create and run an eval for a summarization task.

1. Create 3 test cases with short paragraphs to summarize
2. Create a task function that generates a summary (just use a simple heuristic like taking first sentence)
3. Create a scorer that checks if the summary is shorter than the input
4. Run the eval using braintrust.Eval()

Print the experiment link and scores.""",
            "id": "summarization-eval",
            "expected_experiments": 1,
        },
        "expected": {"experiments_created": 1},
        "metadata": {"category": "experiment", "difficulty": "medium"},
    },
    {
        "input": {
            "task": """Create an eval that uses the autoevals library.

1. Create 3 test cases with questions and expected answers
2. Create a task function that generates answers (can be simple/placeholder)
3. Use autoevals.Factuality as a scorer
4. Run the eval using braintrust.Eval()

Print the results including the Factuality scores.""",
            "id": "autoevals-eval",
            "expected_experiments": 1,
        },
        "expected": {"experiments_created": 1},
        "metadata": {"category": "experiment", "difficulty": "medium"},
    },
]


# Run the eval
Eval(
    "Braintrust Skill - E2E Experiment",
    data=lambda: E2E_EXPERIMENT_DATA,
    task=lambda input: e2e_experiment_task(input),
    scores=[experiments_created_scorer, task_completed_scorer, eval_ran_scorer],
    metadata={
        "description": "Tests Claude's ability to create and run experiments, verified via Braintrust API",
        "category": "e2e",
        "test_run_id": TEST_RUN_ID,
        "test_project": TEST_PROJECT_NAME,
    },
)
