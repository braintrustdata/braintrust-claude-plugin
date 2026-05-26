.PHONY: test test-trace-claude-code

# Run all plugin tests
test: test-trace-claude-code

# Run trace-claude-code plugin tests
test-trace-claude-code:
	@bash plugins/trace-claude-code/test/run_tests.sh
