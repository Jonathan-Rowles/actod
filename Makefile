.PHONY: test test-ci test-unit test-integration test-facade vopr vopr-deep bench-single bench-network bench-footprint gen-hot-api clean

VOPR_COUNT ?= 200
VOPR_DEEP_COUNT ?= 100000

DEV_FLAGS := -vet -strict-style -microarch:native
RELEASE_FLAGS := -o:aggressive -no-bounds-check -disable-assert -microarch:native
TEST_FLAGS := -define:ODIN_TEST_SHORT_LOGS=true -define:ODIN_TEST_LOG_LEVEL=warning
JOBS :=

CI_DEV_FLAGS := -vet -strict-style
CI_TEST_FLAGS := -define:ODIN_TEST_SHORT_LOGS=true -define:ODIN_TEST_LOG_LEVEL=warning -define:ODIN_TEST_THREADS=1

test: test-unit test-facade test-integration

test-ci:
	@$(MAKE) --no-print-directory test DEV_FLAGS="$(CI_DEV_FLAGS)" TEST_FLAGS="$(CI_TEST_FLAGS)" JOBS=2

test-facade:
	@odin check ./src/facade_check -vet -strict-style
	@echo "facade OK"

test-unit:
	@$(MAKE) --no-print-directory -j$(JOBS) $(patsubst ./%,test-unit/%,$(sort $(shell find . -name '*_test.odin' -not -path './pkgs/*' -not -path './src/integration_test/*' | xargs -L1 dirname)))

test-unit/%:
	@mkdir -p bin/$*
	@odin test ./$* -out:bin/$*/$(notdir $*) $(DEV_FLAGS) $(TEST_FLAGS)

test-integration:
	@mkdir -p bin
	@echo "building integration tests"
	@odin test ./src/integration_test -out:bin/integration_test $(DEV_FLAGS) $(TEST_FLAGS)

vopr:
	@mkdir -p bin
	@odin build ./src/integration_test -out:bin/integration_test -build-mode:test $(DEV_FLAGS) $(TEST_FLAGS)
	@echo "VOPR sweep: $(VOPR_COUNT) seeds (replay failures with ACTOD_TEST_RUN=test_sim_vopr ACTOD_VOPR_SEED=<seed> bin/integration_test)"
	@ACTOD_TEST_RUN=test_sim_vopr ACTOD_VOPR_BASE=$$(date +%s) ACTOD_VOPR_COUNT=$(VOPR_COUNT) bin/integration_test

vopr-deep:
	@mkdir -p bin
	@odin build ./src/integration_test -out:bin/integration_test -build-mode:test $(DEV_FLAGS) $(TEST_FLAGS)
	@bash scripts/vopr_deep.sh $(VOPR_DEEP_COUNT)

bench-single:
	@mkdir -p bin
	@odin build ./benchmarks/single_proccess/ -out:bin/benchmark $(RELEASE_FLAGS)
	bin/benchmark

bench-network:
	@mkdir -p bin
	@odin build ./benchmarks/network -out:bin/network_benchmark $(RELEASE_FLAGS)
	bin/network_benchmark

bench-footprint:
	@mkdir -p bin
	@odin build ./benchmarks/footprint -out:bin/footprint_benchmark $(RELEASE_FLAGS)
	bin/footprint_benchmark

gen-hot-api:
	@mkdir -p bin
	@odin run ./src/pkgs/hot_reload/generator $(DEV_FLAGS)

clean:
	@rm -rf bin/
	@echo "cleaned"
