.PHONY: test test-unit test-integration bench-single bench-network gen-hot-api clean

DEV_FLAGS := -vet -strict-style -microarch:native
RELEASE_FLAGS := -o:aggressive -no-bounds-check -disable-assert -microarch:native
TEST_FLAGS := -define:ODIN_TEST_SHORT_LOGS=true -define:ODIN_TEST_LOG_LEVEL=warning

test: test-unit test-integration

test-unit:
	@$(MAKE) --no-print-directory -j $(patsubst ./%,test-unit/%,$(sort $(shell find . -name '*_test.odin' -not -path './pkgs/*' -not -path './src/integration_test/*' | xargs -L1 dirname)))

test-unit/%:
	@mkdir -p bin/$*
	@odin test ./$* -out:bin/$*/$(notdir $*) $(DEV_FLAGS) $(TEST_FLAGS)

test-integration:
	@mkdir -p bin
	@echo "building integration tests"
	@odin test ./src/integration_test -out:bin/integration_test $(DEV_FLAGS) $(TEST_FLAGS)

bench-single:
	@mkdir -p bin
	@odin build ./benchmarks/single_proccess/ -out:bin/benchmark $(RELEASE_FLAGS)
	bin/benchmark

bench-network:
	@mkdir -p bin
	@odin build ./benchmarks/network -out:bin/network_benchmark $(RELEASE_FLAGS)
	bin/network_benchmark

gen-hot-api:
	@mkdir -p bin
	@odin run ./src/pkgs/hot_reload/generator $(DEV_FLAGS)

clean:
	@rm -rf bin/
	@echo "cleaned"
