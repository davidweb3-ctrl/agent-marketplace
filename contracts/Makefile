.PHONY: install build test test-fork deploy-local deploy-sepolia slither snapshot

install:
	foundryup
	forge install openzeppelin/openzeppelin-contracts --no-commit

build:
	forge build

test:
	forge test -vv

test-fork:
	forge test --fork-url $(BASE_SEPOLIA_RPC) -vv

deploy-local:
	forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

deploy-sepolia:
	forge script script/Deploy.s.sol --rpc-url $(BASE_SEPOLIA_RPC) --broadcast --verify

slither:
	slither src/ --exclude-dependency

snapshot:
	forge snapshot
