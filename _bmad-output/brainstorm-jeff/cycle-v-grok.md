# Walking Skeleton — Agent Marketplace Demo

**Goal:** Prove the core value proposition in under 5 minutes: "an agent received a GitHub issue, did work, got paid."

## The Walking Skeleton

We need the thinnest possible slice that demonstrates the full loop. Here's what can be mocked vs. must be real.

### What Can Be Mocked (for demo only)

- **GitHub Issue Bot** — instead of a real GitHub App, use a simple script that polls a test repo and posts webhooks to localhost
- **Agent Registry** — in-memory Solidity mapping or a stub contract with `registerAgent()` and one hardcoded agent address
- **Agent Identity** — use aEOA (Externally Owned Account) for the demo agent; no decentralized identity verification
- **Escrow Funding** — Jeff funds the escrow contract manually via `cast send` before demo
- **EAL Verification** — skip cryptographic verification; just check that EAL file exists in a known location

### What MUST Be Real (on-chain)

1. **Escrow Contract** — holds USDC, releases funds on submission trigger. This is the critical piece.
2. **USDC Token** — real testnet USDC (Sepolia) to prove actual value transfer.
3. **Task Assignment** — on-chain event emission when issue is detected.

### Step-by-Step Sequence

1. Jeff deploys Escrow contract to Sepolia (1 min)
2. Jeff funds Escrow with 10 USDC via bridge
3. Demo agent (EOA) registers itself (simulated via script calling contract)
4. Jeff opens GitHub issue with TDL YAML in `demo-repo`
5. Bot script detects issue, emits `TaskCreated(bytes32 taskId, address agent)`
6. Agent script picks up task, writes output file `task-{id}.json`
7. Agent calls `submitEAL(taskId, evidenceHash)` on Escrow
8. Escrow releases USDC to agent EOA — transfer verified on Etherscan

---

## Minimum Viable Contracts

Of the 7 contracts in the spec, we need exactly **2** for the demo:

| Contract | Required? | Reason |
|---|---|---|
| Escrow | **YES** | Core payment logic |
| AgentRegistry | **YES** | Bind agent address to task |
| TaskNFT | NO | Skip for demo; track via taskId bytes32 |
| Reputation | NO | Hardcode agent reputation score |
| PaymentChannel | NO | Single payment, no channel |
| SlashDAO | NO | No disputes in demo |
| Treasury | NO | Manual distribution |

**Stub contracts:** Replace AgentRegistry with a simple mapping in Escrow:
```solidity
mapping(address => bool) public registeredAgents;
function register() external { registeredAgents[msg.sender] = true; }
```

**Estimated LOC:** ~150 lines (Escrow: 100, Registry stub: 30, Deploy script: 20)

---

## Minimum Viable Agent

The agent can be a **50-line Python script** using `subprocess`:

```python
#!/usr/bin/env python3
import subprocess, json, sys, os

TASK_FILE = "task.json"
AGENT_KEY = os.getenv("AGENT_PRIVATE_KEY")
ESCROW_ADDR = "0x..."

def main():
    with open(TASK_FILE) as f:
        task = json.load(f)
    
    # Agent "does work": runs a linter on the repo
    result = subprocess.run(
        ["bash", "-c", f"cd {task['repo']} && npm run lint || true"],
        capture_output=True, text=True
    )
    
    # Write evidence
    with open(f"evidence-{task['id']}.json", "w") as f:
        json.dump({"output": result.stdout[:500], "exit": result.returncode}, f)
    
    # Submit EAL (stub: call contract with cast)
    os.system(f"cast send {ESCROW_ADDR} \"submitEAL(bytes32,bytes32)\" "
              f"{task['id']} $EVIDENCE_HASH --private-key {AGENT_KEY}")
```

**What it does:** Clones a repo, runs `npm run lint`, writes output as "evidence", calls `submitEAL()`. The work is trivial (linter run) but proves the loop.

**Framework:** No LangChain needed. Just subprocess + `cast` CLI.

---

## Demo Script (5-minute pitch)

### Prereqs (done before demo starts)
```bash
# Jeff: Deploy contracts
cd contracts && forge script Deploy --rpc-url sepolia --broadcast
# Output: Escrow at 0xABC... note this

# Jeff: Fund escrow
cast send $USDC_ADDR "transfer(address,uint256)" $ESCROW_ADDR 10000000 --rpc-url sepolia
```

### Live Demo Sequence

**Step 1 — Jeff opens GitHub issue (30 sec)**
```bash
# In demo-repo, create issue.yaml:
cat > .github/workflows/demo.yml <<EOF
# TDL: add README section
tasks:
  - id: demo-001
    description: Add "Demo" section to README
    reward: 1 USDC
    proof: lint-pass
EOF
gh issue create --title "Demo: Add README section" --body-file issue.yaml
```
Expected: Issue appears in repo.

**Step 2 — Bot detects and assigns (30 sec)**
```bash
# Bot script (runs locally):
python bot.py --repo demo-repo --escrow 0xABC
# Output: "Task demo-001 assigned to 0xDEF (agent)"
# Emits: TaskCreated(bytes32 keccak("demo-001"), address 0xDEF)
```

**Step 3 — Agent does work (1 min)**
```bash
# On agent machine:
python agent.py
# Output:
# - Fetching task demo-001
# - Cloning demo-repo
# - Running npm run lint
# - Writing evidence-001.json
# - Calling submitEAL(0x..., 0xhash)
# - "EAL submitted, awaiting release"
```

**Step 4 — USDC released (30 sec)**
```bash
# Jeff verifies:
cast call $ESCROW_ADDR "balanceOf(address)" $AGENT_ADDR
# Before: 0
# After: 1000000 (1 USDC)
```
Expected: Etherscan shows Transfer event from Escrow → Agent.

**Total demo time: ~3 minutes**

---

## Risk: What Could Go Wrong

### Top 3 Failure Points

1. **USDC faucet dried up** — Mitigation: Keep $50+ USDC in faucet wallet; use native USDC on mainnet if needed
2. **Agent key exposure in demo** — Mitigation: Use a fresh EOA with only test funds; revoke after demo
3. **Block confirmations too slow on Sepolia** — Mitigation: Use `--gas-price` with priority fee; have block explorer open

### Secondary Risks

- **Bot misses issue** — Run bot in foreground with verbose logging
- **Agent fails to submit** — Show `cast` command output in real-time; have manual fallback
- **EAL verification fails** — Skip verification; trust agent's `submitEAL` call

---

**Result:** A 150-line contract + 50-line agent script + 1 USDC transfer = proof of concept.
