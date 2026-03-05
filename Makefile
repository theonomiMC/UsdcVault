-include .env

.PHONY: all build test clean coverage deploy help

# --- Default internal variables (Base is Anvil) ---
NETWORK_RPC := $(LOCAL_RPC_URL)
NETWORK_KEY := $(ANVIL_PRIVATE_KEY)
VERIFY_FLAG := 

# --- If network=sepolia is passed, override with Sepolia settings ---
ifeq ($(network),sepolia)
    NETWORK_RPC := $(SEPOLIA_RPC_URL)
    NETWORK_KEY := $(PRIVATE_KEY)
    VERIFY_FLAG := --verify --etherscan-api-key $(ETHERSCAN_API_KEY)
endif

build:
	forge build

clean:
	forge clean

test:
	forge test -vvv

test-invariant:
	forge test --match-contract UsdcVaultInvariants \
		--invariant-runs 500 \
		--invariant-depth 100 \
		-vvv

coverage:
	forge coverage --report lcov
	lcov --remove lcov.info "test/*" "script/*" "test/mocks/*" -o lcov.info.refined
	genhtml lcov.info.refined -o coverage_report
	@echo "Report: coverage_report/index.html"

deploy:
	@forge script script/DeployUsdcVault.s.sol:DeployUsdcVault \
		--rpc-url $(NETWORK_RPC) \
		--private-key $(NETWORK_KEY) \
		--broadcast \
		$(VERIFY_FLAG) \
		-vvvv
deploy-upgradeable:
	@forge script script/DeployUpgradeable.s.sol:DeployUpgradeable \
		--rpc-url $(NETWORK_RPC) \
		--private-key $(NETWORK_KEY) \
		--broadcast \
		$(VERIFY_FLAG) \
		-vvvv
help:
	@echo ""
	@echo "Usage: make [target] [network=sepolia]"
	@echo ""
	@echo "  build              Compile contracts"
	@echo "  clean              Remove build artifacts"
	@echo "  test               Run all tests"
	@echo "  test-invariant     Run invariant suite"
	@echo "  coverage           Generate HTML coverage report"
	@echo "  deploy             Deploy to Anvil (local by default)"
	@echo "  deploy network=sepolia  Deploy to Sepolia + verify"
	@echo ""