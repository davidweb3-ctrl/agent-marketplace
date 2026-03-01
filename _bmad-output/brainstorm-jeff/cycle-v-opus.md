# Agent Marketplace Implementation Sprint Plan

**Spec Status:** 88% complete (Cycles A–U)  
**Target:** Base Sepolia Testnet

---

## Sprint 0 — Foundations (Week 1)

### Repo Structure
Use a monorepo at `github.com/agent-marketplace/protocol` with this layout:

```
/contracts       # Solidity contracts (Foundry)
/sdk             # Python + TypeScript SDKs
/bot             # GitHub bot + heartbeat monitor
/infra           # Docker Compose, Terraform, GitHub Actions
```

**Command:** `gh repo create agent-marketplace/protocol --public --source=. --push`

### Toolchain Decisions
- **Smart Contracts:** Foundry (forge test, forge build)
- **Backend:** Python FastAPI for webhook server + SQLAlchemy (SQLite for dev, PostgreSQL for prod)
- **SDKs:** OpenAPI generator (Speakeasy or openapi-generator-cli)
- **Infrastructure:** Terraform for AWS/GCP deployment

### CI/CD Skeleton
Create `.github/workflows/ci.yml`:

```yaml
on: [push, pull_request]
jobs:
  contracts:
    runs-on: ubuntu-latest
    steps:
      - uses: foundry-rs/foundry@latest
      - run: forge test
      - run: forge build
  
  bot:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: pip install -r requirements.txt
      - run: pytest tests/
```

### Dev Environment
Create `infra/docker-compose.yml`:

```yaml
services:
  anvil:
    image: ghcr.io/foundry-rs/foundry:latest
    command: anvil --chain-id 31337
    ports: ["8545:8545"]
  
  ipfs:
    image: ipfs/kubo:latest
    ports: ["5001:5001", "8080:8080"]
  
  registry-mock:
    build: ./registry-mock
    ports: ["8081:8081"]
```

Run locally: `docker compose -f infra/docker-compose.yml up -d`

---

## Sprint 1 — Core Smart Contracts (Week 2-3)

### Implementation Order (Priority First)
1. **AgentRegistry** — Register agents, store metadata IPFS CID
2. **MissionNFT** — ERC-721 for mission ownership + state machine
3. **AgentCore** — Agent registration, stake management, reputation scoring

### Minimum Viable Core Loop
Deploy **AgentRegistry + MissionNFT** first. This enables:
1. Agent registers → IPFS metadata published
2. Mission created → NFT minted with `Pending` status
3. Agent submits completion → NFT state → `Completed`

All on local Anvil. Test with `forge test --match-path test/Core.t.sol`.

### Test Suite Strategy
- **Unit tests:** `test/` directory per contract (Foundry native)
- **Fork tests:** `forge test --fork-url $BASE_SEPOLIA_RPC` — use `--fork-block-number` for reproducibility

### Done Criteria
- [ ] `forge build` compiles without warnings
- [ ] `forge test` passes 100%
- [ ] Fork test against Base Sepolia passes
- [ ] Gas report shows no function > 500k gas

---

## Sprint 2 — Agent SDK + Bot (Week 4-5)

### OpenAPI Spec → SDKs
1. Write `spec/openapi.yaml` from contract ABIs (use `forge inspect AgentRegistry abi > abi.json` then convert)
2. Generate SDKs:

```bash
npx @speakeasy-api/openapi-generator-cli generate \
  -i spec/openapi.yaml \
  -o sdk/typescript \
  -l typescript

pip install openapi-python-client
openapi-python-client generate --path spec/openapi.yaml --output sdk/python
```

### GitHub Bot Components
- **Webhook listener:** `bot/webhook.py` — FastAPI endpoint at `/webhook/github`
- **TDL parser:** `bot/tdl/parser.py` — Parse `#agent:NAME` and `#mission:TASK` from issue body
- **Mission dispatcher:** `bot/dispatcher.py` — Queue missions to agent via SDK

### Heartbeat Monitor
- `bot/heartbeat.py` — Poll each registered agent's `/health` endpoint every 60s
- Store last_heartbeat in `missions` table
- If > 5 min no heartbeat → emit `AgentUnresponsive` event

### E2E Integration Test
Create `tests/e2e/test_mission_flow.py`:

```python
def test_fake_agent_completes_mission():
    # 1. Register fake agent
    agent_id = sdk.register_agent(agent_metadata)
    
    # 2. Create mission
    mission_id = sdk.create_mission("fix-bug-#42", requirements)
    
    # 3. Agent submits completion
    sdk.submit_completion(mission_id, result_cid)
    
    # 4. Verify NFT state
    assert sdk.get_mission_state(mission_id) == "Completed"
```

Run: `pytest tests/e2e/ -v`

---

## Sprint 3 — Security + Hardening (Week 6)

### Cosign Pipeline
Install cosign: `brew install sigstore/tap/cosign`

CI job to sign artifacts:

```yaml
- name: Sign contracts
  run: |
    cosign sign-blob --key cosign.key contracts/out/AgentRegistry.sol/AgentRegistry.json > contracts.out.sig
```

### gVisor Runtime
Configure in `infra/task-def.json`:

```json
"linuxParameters": {
  "capabilities": { "add": ["SYS_PTRACE"] },
  "maskedGuestPaths": ["/proc"]
}
```

### EAL Merkle Verification
Deploy `MerkleVerifier` contract and run `scripts/verify_merkle_root.py` — compares on-chain root vs. off-chain computed root daily.

### Audit Checklist Before Testnet
- [ ] Slither static analysis passes (`slither . --exclude-dependency`)
- [ ] Mythril security scan clean
- [ ] All contract NatSpec complete
- [ ] Upgradeable proxies (if used) — proxy pattern verified
- [ ] Emergency pause mechanism tested

---

## Testnet Launch Criteria

### Exact Conditions for Base Sepolia Deploy
1. All Sprint 1–3 done criteria met
2. E2E test passes locally + on Sepolia fork
3. Internal security review sign-off (2 engineers)
4. Slither + Mythril reports show no high/critical findings
5. Contract verified on Basescan (source code uploaded)

### Initial Audit
- **Internal:** First — conduct 2-person code review + informal audit
- **External:** Before mainnet — engage Trail of Bits or OpenZeppelin for professional audit ($15k–$50k)

---

**Total estimated timeline: 6 weeks**  
**Key files to create first:** `infra/docker-compose.yml`, `.github/workflows/ci.yml`, `spec/openapi.yaml`
