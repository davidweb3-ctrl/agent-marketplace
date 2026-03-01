# MVP Critical Gaps — Cycle T Specification

**Author:** Jeff (Sisyphus orchestrator)  
**Date:** 2026-03-01  
**Status:** Specification for Implementation  

---

## Executive Summary

This document specifies solutions for four critical gaps blocking the Agent Marketplace MVP:
1. Issue Dependency DAG (mission ordering)
2. EAL (Execution Attribution Log) Forgery Prevention
3. Agent SDK Complete Specification
4. Docker Trust & Compute Model

Each gap includes concrete technical specifications, rationales for architectural choices, and implementation guidance.

---

## Gap 1 — Issue Dependency DAG

### 1.1 TDL YAML Extension

The Task Definition Language (TDL) needs explicit dependency declaration. We extend YAML mission definitions:

```yaml
mission:
  id: "issue-42"
  title: "Add user authentication"
  depends_on: ["issue-38", "issue-40"]
```

**Justification:** Flat issue lists break when agent B needs agent A's output. Explicit DAG ordering ensures downstream missions cannot be dispatched until dependencies complete.

### 1.2 MissionEscrow Contract Changes

We add dependency tracking to the smart contract:

```solidity
// In MissionEscrow.sol
mapping(bytes32 => bytes32[]) public missionDeps;
mapping(bytes32 => mapping(bytes32 => bool)) public depResolved;

function checkDepsResolved(bytes32 missionId) public view returns (bool) {
    bytes32[] memory deps = missionDeps[missionId];
    for (uint i = 0; i < deps.length; i++) {
        if (!depResolved[missionId][deps[i]]) return false;
    }
    return true;
}
```

**State Machine Update:** Missions with unresolved dependencies remain `CREATED` — they cannot transition to `ASSIGNED` until `checkDepsResolved()` returns true.

### 1.3 Cycle Detection Strategy

**Decision:** Off-chain validation with on-chain checkpoint.

The matching bot validates the DAG before dispatch. Cycle detection runs client-side (or in the API layer) using standard DFS with visited/recursion-stack markers. If a cycle is detected, the mission creation fails with `ERR_CYCLIC_DEPS`.

On-chain storage is append-only — we trust the off-chain validation. Putting cycle detection on-chain would require iterating the full DAG per mission, which is O(V+E) gas per dispatch. That's unacceptable at scale.

### 1.4 Matching Bot Filter

The `POST /match` endpoint filters out missions where dependencies are unresolved:

```typescript
// In matching service
const eligibleMissions = missions.filter(m => 
  m.depends_on.every(depId => getMissionState(depId) === 'COMPLETED')
);
```

---

## Gap 2 — EAL Forgery Prevention

### 2.1 EAL Structure

The Execution Attribution Log links a mission to the exact code that executed it:

```json
{
  "missionId": "0x1234...abcd",
  "agentDID": "did:agent:0x5678...efgh",
  "gitCommitHash": "a1b2c3d4e5f6789012345678901234567890abcd",
  "timestamp": 1709234567,
  "nonce": "0xdeadbeefcafebabe",
  "signature": "0xsig1234..."
}
```

### 2.2 Nonce Lifecycle

Nonces prevent replay attacks and tie EALs to specific mission assignments:

1. **`assignMission(missionId, agentId)`** — generates a fresh `nonce` and stores it: `missionNonce[missionId] = keccak256(abi.encode(block.timestamp, agentId))`
2. Agent receives nonce via webhook/polling
3. Agent submits EAL with that exact nonce
4. **`submitEAL()`** burns the nonce — it cannot be reused

**Justification:** Nonces prevent an agent from recycling a valid-looking EAL from an old mission. Each assignment gets a one-time-use token.

### 2.3 QA Agent Verification

The QA agent (or client) must verify:

1. `gitCommitHash` exists in the repository
2. The commit is linked to the mission (via PR title convention: `[mission-0x1234]`)
3. The commit timestamp is within the mission's execution window

```typescript
// Verification pseudocode
const commit = await github.getCommit(eal.gitCommitHash);
const pr = await github.getPRs({ head: eal.missionId });
const isValid = commit.sha === eal.gitCommitHash &&
                pr.length > 0 &&
                commit.committer_date >= mission.startedAt;
```

### 2.4 Anti-Replay Guarantees

- **Nonce + timestamp + missionId** — three-way binding prevents replay across missions
- **Contract-side nonce burning** — on-chain verification ensures each nonce is consumed exactly once
- **Signature includes all fields** — the agent's DID signs the complete EAL, not just the hash

---

## Gap 3 — Agent SDK Complete Spec

### 3.1 Required REST Endpoints

Every agent must implement these 5 endpoints:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Liveness probe |
| `/capabilities` | GET | Return agent skills, tools, pricing |
| `/accept_mission` | POST | Accept mission assignment (returns nonce) |
| `/progress` | POST | Report progress updates |
| `/submit_eal` | POST | Submit Execution Attribution Log |

### 3.2 JSON Contracts

**`GET /health`**
```json
{ "status": "healthy", "agentId": "0x...", "version": "1.0.0" }
```

**`POST /accept_mission`**
```json
// Request
{ "missionId": "0x...", "nonce": "0x...", "prompt": "..." }
// Response
{ "accepted": true, "executionId": "0x..." }
```

**`POST /progress`**
```json
// Request
{ "missionId": "0x...", "status": "in_progress", "message": "30% complete" }
```

**`POST /submit_eal`**
```json
// Request
{ "missionId": "0x...", "eal": { ... } }
// Response
{ "received": true, "txHash": "0x..." }
```

### 3.3 Standard Docker Environment Variables

```dockerfile
ENV MISSION_ID=""
ENV AGENT_DID=""
ENV ESCROW_CONTRACT="0x..."
ENV RPC_URL="https://base-mainnet.alchemy.com"
ENV GITHUB_TOKEN="ghp_..."
```

### 3.4 Heartbeat Protocol

Agents must POST to the platform every 60 seconds:

```typescript
// Platform endpoint: POST /agents/{id}/heartbeat
{ "missionId": "0x...", "status": "alive", "timestamp": 1709234567 }
```

**Timeout Rule:** If no heartbeat is received within 120 seconds, the mission is marked `TIMEOUT` and escrow auto-refunds.

### 3.5 Python Skeleton (10 Lines)

```python
from flask import Flask, request, jsonify
app = Flask(__name__)

@app.route("/health", methods=["GET"])
def health(): return jsonify({"status": "healthy"})

@app.route("/accept_mission", methods=["POST"])
def accept(): 
    data = request.json
    return jsonify({"accepted": True, "nonce": data.get("nonce")})

@app.route("/submit_eal", methods=["POST"])
def submit(): return jsonify({"received": True})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

---

## Gap 4 — Docker Trust & Compute Model

### 4.1 Trusted Registry

**Registry:** `registry.agent-marketplace.io`

All agent images are pushed here. We enforce **cosign signatures** — every image must be signed by a key registered with the platform. Unsigned images are rejected at pull time.

```bash
cosign verify --key cosign.pub registry.agent-marketplace.io/agent:v1.2.3
```

### 4.2 Verification Flow

1. Matching bot selects agent
2. Platform pulls image manifest from registry
3. Cosign validates signature
4. If invalid → abort mission, notify provider
5. If valid → inject env vars, start container

### 4.3 Runtime Isolation

We use **gVisor** for sandboxing plus network egress deny-by-default:

```yaml
# Pod security policy
securityContext:
  runAsNonRoot: true
  seccompProfile: runtime/default
networkPolicy:
  egress:
    - to:
      - namespaceSelector: {}
      # Allow GitHub API + RPC only
      ports: [{port: 443, protocol: TCP}]
```

**Egress Whitelist:**
- `api.github.com` (port 443)
- Base RPC endpoints (port 443)
- IPFS gateway (port 443)

All other egress is blocked. This prevents exfiltrated computation or lateral movement.

### 4.4 Audit Trail & Resource Limits

**Logs:** All stdout/stderr routed to centralized logging (Datadog/ELK). Retention: 90 days.

**Resource Quotas:**
- CPU: 2 cores max
- RAM: 4GB max
- Disk: 10GB ephemeral

**SBOM Generation:**

We generate Software Bill of Materials using **syft** at image build:

```bash
syft registry.agent-marketplace.io/agent:v1.2.3 -o json > sbom.json
```

SBOMs are stored in IPFS and linked in the agent's on-chain registry. Clients can audit dependencies before accepting a mission.

---

## Implementation Priority

| Gap | Priority | Dependencies |
|-----|----------|--------------|
| Agent SDK Spec | P0 | None — unblocks agent development |
| EAL Forgery Prevention | P0 | SDK spec |
| Docker Trust | P1 | SDK spec |
| Issue Dependency DAG | P1 | None |

The SDK and EAL gaps are P0 because without them, agents cannot meaningfully participate in the marketplace. Docker trust is P1 — agents can run with manual oversight initially. Dependency DAG is P1 — most early missions will be independent.

---

## Open Questions

1. **DAG Storage:** Should we store the full DAG on-chain or just the dependency list per mission? (Latter — reduce storage cost)
2. **Heartbeat Frequency:** 60s works for most agents. Should long-running missions get configurable timeouts?
3. **SBOM Consumption:** Do clients actually check SBOMs, or is this a "nice to have" for enterprise audits?

---

*End of Cycle T Specification*
