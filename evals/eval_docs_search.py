"""
Braintrust skill eval: documentation search

Tests the agent's ability to accurately answer questions about Braintrust
concepts, APIs, and workflows.

Run with: braintrust eval evals/eval_docs_search.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from braintrust import Eval
from scorers import criteria_scorer, get_anthropic_client

client = get_anthropic_client()


def baseline_task(input: str) -> str:
    """
    Baseline task - asks Claude to answer Braintrust questions WITHOUT any skill.
    This establishes what Claude knows from training data alone.
    """
    response = client.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=1024,
        system="You are a helpful assistant. Answer questions about Braintrust, an LLM evaluation and observability platform. Be concise and specific.",
        messages=[{"role": "user", "content": input}],
    )
    return response.content[0].text


# Documentation search test cases with natural language criteria
DOCS_SEARCH_DATA = [
    # Scorers
    {
        "input": "How do I create a custom scorer that uses an LLM to judge response quality in Braintrust?",
        "expected": [
            "Explains that you can create scorers via the UI or code",
            "Mentions that the scorer function receives output (and optionally input/expected)",
            "Shows how to return a score between 0 and 1",
        ],
        "metadata": {"category": "scorers", "difficulty": "medium"},
    },
    {
        "input": "What built-in scorers does Braintrust provide through autoevals?",
        "expected": [
            "Mentions Factuality as a built-in scorer",
            "Mentions at least one other scorer (e.g., Levenshtein, ClosedQA, Summary)",
            "Indicates these come from the autoevals library",
        ],
        "metadata": {"category": "scorers", "difficulty": "easy"},
    },
    # Experiments vs logs
    {
        "input": "What's the difference between experiments and project logs in Braintrust?",
        "expected": [
            "Explains that experiments are for offline evaluation/testing",
            "Explains that project logs are for production/runtime logging",
            "Notes they are separate concepts (not the same data)",
        ],
        "metadata": {"category": "concepts", "difficulty": "medium"},
    },
    {
        "input": "How do I run an evaluation using the Eval() function?",
        "expected": [
            "Shows importing Eval from braintrust",
            "Explains the data parameter (test cases)",
            "Explains the task parameter (function to evaluate)",
            "Explains the scores parameter (scoring functions)",
        ],
        "metadata": {"category": "experiments", "difficulty": "easy"},
    },
    # BTQL
    {
        "input": "How do I use BTQL to find logs where the Factuality score is below 0.5?",
        "expected": [
            "Uses filter clause with scores.Factuality",
            "Uses a comparison operator like < 0.5",
            "Shows valid BTQL syntax (not generic SQL)",
        ],
        "metadata": {"category": "btql", "difficulty": "medium"},
    },
    {
        "input": "What is BTQL and what can I use it for?",
        "expected": [
            "Explains BTQL is Braintrust Query Language",
            "Mentions it's used for querying logs/experiments",
            "Notes it has SQL-like syntax",
        ],
        "metadata": {"category": "btql", "difficulty": "easy"},
    },
    {
        "input": "How do I aggregate token usage by day using BTQL?",
        "expected": [
            "Uses dimensions clause for time grouping (e.g., day(created))",
            "Uses measures clause for aggregation",
            "References metrics.total_tokens or similar token field",
        ],
        "metadata": {"category": "btql", "difficulty": "hard"},
    },
    # Datasets
    {
        "input": "How do I create a dataset in Braintrust using the Python SDK?",
        "expected": [
            "Uses init_dataset() function",
            "Shows how to insert records with input field",
            "Mentions expected field for ground truth",
        ],
        "metadata": {"category": "datasets", "difficulty": "easy"},
    },
    {
        "input": "What fields does a dataset record have in Braintrust?",
        "expected": [
            "Mentions input as a required/main field",
            "Mentions expected as an optional field",
            "Mentions metadata as an optional field",
        ],
        "metadata": {"category": "datasets", "difficulty": "easy"},
    },
    # Tracing/logging
    {
        "input": "How do I automatically trace OpenAI API calls in Braintrust?",
        "expected": [
            "Uses wrap_openai() to wrap the OpenAI client",
            "Shows initializing a logger with init_logger()",
            "Indicates traces are automatic after wrapping",
        ],
        "metadata": {"category": "tracing", "difficulty": "medium"},
    },
    {
        "input": "How do I add custom metadata to my Braintrust logs?",
        "expected": [
            "Shows passing metadata parameter to log/span",
            "Metadata is a dictionary/object of key-value pairs",
        ],
        "metadata": {"category": "tracing", "difficulty": "medium"},
    },
    # Prompts
    {
        "input": "How does prompt versioning work in Braintrust?",
        "expected": [
            "Explains that each prompt change creates a new version",
            "Mentions you can reference specific versions",
            "Mentions ability to compare or roll back versions",
        ],
        "metadata": {"category": "prompts", "difficulty": "medium"},
    },
]


# Run the eval
Eval(
    "Braintrust Skill - Docs Search",
    data=lambda: DOCS_SEARCH_DATA,
    task=baseline_task,
    scores=[criteria_scorer],
    metadata={
        "description": "Tests agent's ability to answer Braintrust documentation questions",
        "category": "docs_search",
    },
)
