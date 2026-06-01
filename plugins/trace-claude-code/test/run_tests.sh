#!/bin/bash
###
# Test runner for the trace-claude-code plugin.
#
# Discovers all test_*.sh files in this directory and runs each one in a
# fresh subshell. Aggregates pass/fail counts and prints a summary.
#
# Usage:
#   ./run_tests.sh                    # run all tests
#   ./run_tests.sh test_common.sh     # run a specific file
#   ./run_tests.sh test_common test_insert_span
###

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Color setup
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BOLD=""
    C_DIM=""
    C_RESET=""
fi

# Shared counter files (passed to children via env in helpers/assert.sh)
TESTS_RUN_FILE=$(mktemp)
TESTS_FAIL_FILE=$(mktemp)
export TESTS_RUN_FILE TESTS_FAIL_FILE
: > "$TESTS_RUN_FILE"
: > "$TESTS_FAIL_FILE"

cleanup() {
    rm -f "$TESTS_RUN_FILE" "$TESTS_FAIL_FILE"
}
trap cleanup EXIT

# Resolve which test files to run.
declare -a TEST_FILES=()
if [ $# -gt 0 ]; then
    for arg in "$@"; do
        # Allow specifying with or without .sh, with or without test_ prefix
        local_name="$arg"
        case "$local_name" in
            *.sh) ;;
            *) local_name="${local_name}.sh" ;;
        esac
        case "$local_name" in
            test_*) ;;
            *) local_name="test_${local_name}" ;;
        esac
        if [ -f "$SCRIPT_DIR/$local_name" ]; then
            TEST_FILES+=("$local_name")
        else
            echo "${C_RED}Test file not found: $local_name${C_RESET}" >&2
            exit 2
        fi
    done
else
    while IFS= read -r f; do
        TEST_FILES+=("$f")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'test_*.sh' -type f | sort | xargs -n1 basename)
fi

if [ ${#TEST_FILES[@]} -eq 0 ]; then
    echo "${C_YELLOW}No test files found.${C_RESET}"
    exit 0
fi

printf '%sRunning tests in %s%s\n' "$C_BOLD" "$SCRIPT_DIR" "$C_RESET"
printf '%s%d test file(s)%s\n' "$C_DIM" "${#TEST_FILES[@]}" "$C_RESET"

START_TIME=$(date +%s)
FILES_WITH_FAILURES=0

for file in "${TEST_FILES[@]}"; do
    printf '\n%s──── %s ────%s\n' "$C_BOLD" "$file" "$C_RESET"
    # Run each test file in a fresh subshell so its globals don't leak.
    if ! bash "$SCRIPT_DIR/$file"; then
        FILES_WITH_FAILURES=$((FILES_WITH_FAILURES + 1))
    fi
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

TOTAL=$(wc -l < "$TESTS_RUN_FILE" | tr -d ' ')
FAILED=$(wc -l < "$TESTS_FAIL_FILE" | tr -d ' ')
PASSED=$((TOTAL - FAILED))

printf '\n%s──── Summary ────%s\n' "$C_BOLD" "$C_RESET"
printf '  %sPassed:%s %d\n' "$C_GREEN" "$C_RESET" "$PASSED"
if [ "$FAILED" -gt 0 ]; then
    printf '  %sFailed:%s %d\n' "$C_RED" "$C_RESET" "$FAILED"
else
    printf '  Failed: 0\n'
fi
printf '  Total:  %d\n' "$TOTAL"
printf '  Time:   %ds\n' "$ELAPSED"

if [ "$FAILED" -gt 0 ]; then
    printf '\n%s✗ Tests failed%s\n' "$C_RED" "$C_RESET"
    exit 1
fi

printf '\n%s✓ All tests passed%s\n' "$C_GREEN" "$C_RESET"
exit 0
