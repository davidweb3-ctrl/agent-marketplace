# Agent Marketplace MVP — Critical Gap Specifications

This document specifies alternative/complementary approaches for 4 critical MVP gaps.

---

## Gap 1: DAG Dependencies Between Issues

**Problem**: Managing mission dependencies on-chain without expensive graph storage.

**Alternative**: Off-chain topological sort + on-chain dependency markers.

### Implementation

```solidity
// MissionEscrow.sol
contract MissionEscrow {
    mapping(bytes32 => bytes32[]) public blockedBy;
    mapping(bytes32 => bool) public unlocked;
    
    function unlock(bytes32 missionId) external {
        bytes32[] storage deps = blockedBy[missionId];
        for (uint i = 0; i < deps.length; i++) {
            require(unlocked[deps[i]], "Dependency not satisfied");
        }
        unlocked[missionId] = true;
    }
    
    function submitTDL(bytes32 missionId, bytes32 tdlRoot) external {
        require(unlocked[missionId], "Mission blocked by dependencies");
        // ... existing TDL submission logic
    }
}
```

**Backend cycle detection**:

```python
# backend/validator.py
def validate_tdl_no_cycles(tdl: dict) -> bool:
    graph = {m['id']: m.get('blockedBy', []) for m in tdl['missions']}
    visited, recursion_stack = set(), set()
    
    def has_cycle(node):
        visited.add(node)
        recursion_stack.add(node)
        for dep in graph.get(node, []):
            if dep not in visited:
                if has_cycle(dep): return True
            elif dep in recursion_stack:
                return True
        recursion_stack.remove(node)
        return False
    
    return not any(has_cycle(n) for n in graph if n not in visited)
```

**UX**: GitHub bot comments "⏳ Waiting for #42 to complete before this mission is unlocked" via webhook from backend.

---

## Gap 2: EAL Anti-Forgery

**Problem**: Ensuring EAL (Evidence Assertion Log) integrity without central authority.

**Alternative**: Merkle tree of file hashes + git SHA verification + QA spot-checks.

### Implementation

```solidity
// MissionEscrow.sol
function submitEAL(
    bytes32 missionId,
    bytes32 ealRoot,
    bytes calldata signature
) external {
    require(isAgent[msg.sender], "Only agent");
    require(verifySignature(missionId, ealRoot, signature), "Invalid sig");
    ealRoots[missionId] = ealRoot;
    emit EALSubmitted(missionId, ealRoot);
}
```

**Merkle tree structure** (pushed to IPFS, root stored on-chain):

```json
{
  "root": "0xabc123...",
  "leaves": [
    "0xhash(src/auth.ts: sha256(content))",
    "0xhash(src/utils.ts: sha256(content))"
  ]
}
```

**QA spot-check protocol**:
1. Randomly select 3 files from EAL manifest
2. Fetch actual file content from PR diff
3. Compute `sha256(content)` and verify against Merkle leaf
4. Verify PR base branch is ancestor of commit via GitHub API: `GET /repos/{owner}/{repo}/compare/{base}...{head}`

---

## Gap 3: Minimal Agent SDK

**Problem**: Agents need clear integration contract without framework lock-in.

**Alternative**: OpenAPI 3.0 spec → auto-generated SDKs in Python/TypeScript/Go.

### OpenAPI Specification

```yaml
# marketplace.yaml
openapi: 3.1.0
info:
  title: Agent Marketplace API
  version: 1.0.0
webhooks:
  mission_assigned:
    post:
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/MissionAssigned'
  dispute_opened:
    post:
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/DisputeOpened'
  mission_cancelled:
    post:
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/MissionCancelled'
components:
  schemas:
    MissionAssigned:
      type: object
      properties:
        missionId:
          type: string
          format: bytes32
        tdlRoot:
          type: string
          format: bytes32
        deadline:
          type: integer
          format: uint256
paths:
  /missions/{id}/details:
    get:
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        '200':
          description: Mission details
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Mission'
```

**SDK generation**:

```bash
npx @openapitools/openapi-generator-cli generate \
  -i marketplace.yaml \
  -g python \
  -o ./agent_sdk/python
```

**Error handling**: 4xx = agent fault (billable), 5xx = platform fault (not billable).

---

## Gap 4: Secure Docker Execution

**Problem**: Isolating agent code execution from platform infrastructure.

**Alternative**: Kata Containers + IPFS + cosign keyless + cgroups v2.

### Container Configuration

```yaml
# kata-config.yaml
runtime:
  name: kata-containers
  ioPriority: low
  defaultMemory: 512M
  defaultVCPUs: 1
  defaultMaxMemory: 2G
sandboxing: kata

# Resource enforcement via cgroups v2
cgroup:
  memory:
    max: "536870912"  # 512MB
  cpu:
    quota: 50000      # 50% CPU
```

**Image delivery via IPFS**:

```python
# Verify IPFS image
import subprocess

def pull_and_verify(cid: str, nodes: list[str]) -> bool:
    for node in nodes:
        result = subprocess.run(
            ["ipfs", "dag", "stat", cid],
            capture_output=True, cwd=node
        )
        if result.returncode != 0:
            return False
    return True
```

**Cosign keyless signing** (no long-lived keys):

```bash
cosign sign --fulcio-url https://fulcio.sigstore.dev \
  --oidc-provider github \
  agent-marketplace/images/agent-python:v1.2.3
```

**Tamper evidence**: Record image digest (`sha256:abc...`) and runtime measurements (memory, CPU, duration) in EAL for post-hoc verification.
