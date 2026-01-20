"""
Braintrust skill eval: experiment workflows

Tests the agent's ability to create, run, analyze, and compare experiments.
This covers the full evaluation lifecycle in Braintrust.

Run with: braintrust eval evals/eval_experiments.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from braintrust import Eval
from scorers import criteria_scorer, get_anthropic_client

client = get_anthropic_client()


def baseline_task(input_str):
    """Baseline task without skill - test what Claude knows about experiments."""
    response = client.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=1500,
        system="""You are a helpful assistant for Braintrust, an LLM evaluation platform.

When asked about experiments, provide specific code examples and actionable guidance.
Be precise about Braintrust-specific APIs and patterns.""",
        messages=[{"role": "user", "content": input_str}],
    )
    return response.content[0].text


# Experiment workflow test cases with natural language criteria
EXPERIMENT_DATA = [
    # Creating experiments
    {
        "input": "Write Python code to create a simple Braintrust eval that tests if an LLM can answer 'What is 2+2?' correctly. Use the Factuality scorer.",
        "expected": [
            "Imports Eval from braintrust",
            "Imports Factuality from autoevals",
            "Defines a data parameter with test cases including input/expected",
            "Defines a task function that calls an LLM",
            "Passes Factuality as a scorer",
        ],
        "metadata": {"category": "create_experiment", "difficulty": "easy"},
    },
    {
        "input": "Write a Braintrust eval that tests a summarization task with 3 test cases. Include both Factuality and a custom length-based scorer.",
        "expected": [
            "Uses Eval() with data containing 3 test cases",
            "Includes Factuality scorer from autoevals",
            "Defines a custom scorer function that checks length",
            "Custom scorer returns a Score object with value 0-1",
        ],
        "metadata": {"category": "create_experiment", "difficulty": "medium"},
    },
    {
        "input": "How do I pass metadata to an experiment in Braintrust, like the model name and temperature I used?",
        "expected": [
            "Shows the metadata parameter in Eval()",
            "Metadata is a dictionary with arbitrary key-value pairs",
            "Example includes model name or configuration values",
        ],
        "metadata": {"category": "create_experiment", "difficulty": "easy"},
    },
    # Running experiments
    {
        "input": "How do I run a Braintrust eval from the command line?",
        "expected": [
            "Shows braintrust eval command",
            "Specifies path to eval file (.py or .ts)",
            "Mentions npx braintrust for TypeScript or braintrust eval for Python",
        ],
        "metadata": {"category": "run_experiment", "difficulty": "easy"},
    },
    {
        "input": "How can I run an eval locally without sending results to Braintrust?",
        "expected": [
            "Shows --no-send-logs flag",
            "Used with braintrust eval command",
            "Results are computed but not uploaded",
        ],
        "metadata": {"category": "run_experiment", "difficulty": "easy"},
    },
    # Analyzing experiments
    {
        "input": "I have an experiment with 60% Factuality score. How can I see which specific test cases failed?",
        "expected": [
            "Filter by score to find failing cases (e.g., scores.Factuality < 0.5)",
            "Can use BTQL or the UI to filter results",
            "Examine input/output pairs for failing cases",
        ],
        "metadata": {"category": "analyze_experiment", "difficulty": "medium"},
    },
    {
        "input": "How do I compare two experiments in Braintrust to see what improved or regressed?",
        "expected": [
            "Use summarize_experiment with comparison_experiment_id parameter",
            "Shows score differences between experiments",
            "Identifies improvements and regressions",
        ],
        "metadata": {"category": "analyze_experiment", "difficulty": "medium"},
    },
    {
        "input": "My experiment shows some test cases with low scores. How should I analyze the patterns to improve my prompt?",
        "expected": [
            "Look at common patterns in failing inputs",
            "Examine the outputs to understand why scores are low",
            "Iterate on the prompt based on failure patterns",
        ],
        "metadata": {"category": "analyze_experiment", "difficulty": "hard"},
    },
    # Advanced patterns
    {
        "input": "How do I create a scorer that returns multiple scores from a single function?",
        "expected": [
            "Return a list of Score objects from the scorer function",
            "Each Score has its own name and value",
            "Example showing multiple Score() returns",
        ],
        "metadata": {"category": "advanced", "difficulty": "hard"},
    },
    {
        "input": "How do I use a dataset from Braintrust as the data source for my eval?",
        "expected": [
            "Use init_dataset() to load an existing dataset",
            "Pass the dataset to Eval()'s data parameter",
            "Dataset records become test cases",
        ],
        "metadata": {"category": "advanced", "difficulty": "medium"},
    },
]


# Run the eval
Eval(
    "Braintrust Skill - Experiments",
    data=lambda: EXPERIMENT_DATA,
    task=baseline_task,
    scores=[criteria_scorer],
    metadata={
        "description": "Tests agent's ability to create, run, and analyze Braintrust experiments",
        "category": "experiments",
    },
)
