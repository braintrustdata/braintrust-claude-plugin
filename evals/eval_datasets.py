"""
Braintrust skill eval: dataset management

Tests the agent's ability to create, read, update, and manage datasets.
Includes operations like adding records, querying datasets, and
creating datasets from logs.

Run with: braintrust eval evals/eval_datasets.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from braintrust import Eval
from scorers import criteria_scorer, get_anthropic_client

client = get_anthropic_client()


def baseline_task(input_str):
    """Baseline task without skill - test what Claude knows about datasets."""
    response = client.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=1500,
        system="""You are a helpful assistant for Braintrust, an LLM evaluation platform.

When asked about datasets, provide specific code examples using the Braintrust SDK.
Be precise about field names and API patterns.""",
        messages=[{"role": "user", "content": input_str}],
    )
    return response.content[0].text


# Dataset management test cases with natural language criteria
DATASET_DATA = [
    # Creating datasets
    {
        "input": "Write Python code to create a new dataset called 'qa-golden' in project 'my-app' with 3 question-answer pairs.",
        "expected": [
            "Uses init_dataset() with project and name parameters",
            "Calls insert() to add records",
            "Each record has an input field (the question)",
            "Each record has an expected field (the answer)",
        ],
        "metadata": {"category": "create_dataset", "difficulty": "easy"},
    },
    {
        "input": "How do I add metadata like 'difficulty' and 'category' to dataset records?",
        "expected": [
            "Shows metadata parameter in insert() call",
            "Metadata is a dictionary with arbitrary fields",
            "Example includes difficulty or category keys",
        ],
        "metadata": {"category": "create_dataset", "difficulty": "easy"},
    },
    {
        "input": "Write code to create a dataset for testing a code review assistant, with code snippets as input and review comments as expected output.",
        "expected": [
            "Uses init_dataset() to create/open the dataset",
            "Input field contains code snippets",
            "Expected field contains review comments",
            "Uses insert() to add records",
        ],
        "metadata": {"category": "create_dataset", "difficulty": "medium"},
    },
    # Reading datasets
    {
        "input": "How do I iterate through all records in a Braintrust dataset?",
        "expected": [
            "Uses init_dataset() to open the dataset",
            "Iterates with a for loop over the dataset",
            "Can access record fields like input, expected, metadata",
        ],
        "metadata": {"category": "read_dataset", "difficulty": "easy"},
    },
    {
        "input": "How can I filter dataset records to only get those where metadata.difficulty equals 'hard'?",
        "expected": [
            "Shows filtering by metadata field",
            "Can use Python filtering or BTQL query",
            "Checks metadata.difficulty value",
        ],
        "metadata": {"category": "read_dataset", "difficulty": "medium"},
    },
    {
        "input": "How do I use BTQL to query records from a dataset?",
        "expected": [
            "References querying a dataset data source",
            "Uses select clause for fields",
            "Can use filter clause for conditions",
        ],
        "metadata": {"category": "read_dataset", "difficulty": "medium"},
    },
    # Creating datasets from logs
    {
        "input": "How do I copy the 10 best-scoring logs from my project into a new 'golden-examples' dataset?",
        "expected": [
            "Query logs sorted by score in descending order",
            "Limit to 10 results",
            "Insert the results into a new dataset with init_dataset()",
        ],
        "metadata": {"category": "logs_to_dataset", "difficulty": "hard"},
    },
    {
        "input": "Write code to take logs with thumbs-up feedback and add them to a training dataset.",
        "expected": [
            "Filter logs by feedback/metadata indicating thumbs-up",
            "Use init_dataset() to create/open target dataset",
            "Insert filtered logs into the dataset",
        ],
        "metadata": {"category": "logs_to_dataset", "difficulty": "medium"},
    },
    # Advanced operations
    {
        "input": "How do I update an existing record in a dataset?",
        "expected": [
            "Use insert() with the same id to update",
            "Specify the record id to identify which record to update",
            "New fields overwrite existing values",
        ],
        "metadata": {"category": "update_dataset", "difficulty": "medium"},
    },
    {
        "input": "What's the best way to version my datasets in Braintrust?",
        "expected": [
            "Datasets are automatically versioned on each change",
            "Can reference specific dataset versions",
            "Version history is preserved",
        ],
        "metadata": {"category": "versioning", "difficulty": "easy"},
    },
]


# Run the eval
Eval(
    "Braintrust Skill - Datasets",
    data=lambda: DATASET_DATA,
    task=baseline_task,
    scores=[criteria_scorer],
    metadata={
        "description": "Tests agent's ability to create and manage Braintrust datasets",
        "category": "datasets",
    },
)
