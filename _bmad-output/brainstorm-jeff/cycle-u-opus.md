# Cycle U — Open Questions Resolution

**Author:** Jeff (Sisyphus orchestrator)  
**Date:** 2026-03-01  
**Status:** Final Specification

---

## Question 1 — Configurable Heartbeat Timeout

### Specification

**TDL YAML Extension:**

```yaml
mission:
  id: "issue-42"
  title: "Build Docker image"
  expected_duration_minutes: 45  # NEW FIELD
```

**On-Chain Storage:**

```solidity
// Mission struct
struct Mission {
    uint256 expectedDurationMinutes;
    uint256 heartbeatIntervalSeconds;  // Derived from expected_duration, default 60s
}
```

**Max Allowed Timeout:**
- Minimum: 60 seconds (baseline)
- Maximum: **120 minutes** (7200 seconds)
- Above 60 min → requires staking tier (see Question 2)

**Matching Bot Enforcement:**

```typescript
// In POST /match filter
const MAX_DURATION = 7200;  // 2 hours
if (mission.expectedDurationMinutes * 60 > MAX_DURATION) {
  throw new Error("Mission exceeds max timeout - upgrade tier");
}
```

**What Happens on Silence Mid-Mission:**

| Scenario | Action |
|----------|--------|
| Heartbeat missing > 2x interval | Warning logged, no action |
| Heartbeat missing > 5x interval (e.g., 5min @ 60s interval) | Mark `AT_RISK`, notify via webhook |
| Heartbeat timeout (configurable, default 120s baseline) | Mark `TIMEOUT`, trigger partial-work protocol |

**Partial Work Protocol:**

1. **Checkpointing Required:** Agent must report progress every 25% via `/progress` endpoint
2. **On Timeout:**
   - Escrow locks 50% of funds (for work done)
   - `partialWorkEvidence` uploaded to IPFS (last checkpoint + logs)
   - Client can dispute within 24h
   - After 24h silent → 50% refund, 50% to agent

**Decision:** Timeout declared in TDL YAML only (on-chain mirrors it). Keep it simple — no on-chain negotiation needed.

---

## Question 2 — SBOM: Enforced or Optional?

### Concrete Recommendation: **Tiered Enforcement**

| Tier | SBOM Required? | Rationale |
|------|----------------|-----------|
| Free tier | **Optional** | Low friction, attracts agents |
| Pro tier | **Required** | Clients paying more expect trust |
| Enterprise tier | **Required + Verified** | SBOM checked against CVE database |

### Attack Vector Analysis

**What SBOM actually prevents:**
- Supply chain attacks (malicious dependencies injected post-registration)
- Known CVE vulnerabilities in agent environment
- License compliance issues

**What it does NOT prevent:**
- Agent behaving maliciously at runtime (that's what gVisor + egress blocking is for)
- Credential theft during mission (that's EAL + reputation for)

**Is the friction worth it?**

For enterprise clients: **Yes.** They have compliance requirements (SOC 2, ISO 27001). For free tier: No — friction outweighs benefit.

### Specification

```yaml
# Agent registration
agent:
  id: "0x1234..."
  tier: "pro"  # free | pro | enterprise
  sbom_ipfs_cid: "QmXxx..."  # Required for pro/enterprise
```

**Verification Flow:**

```typescript
// Client checks before accepting mission
const agent = await getAgent(agentId);
if (agent.tier === 'enterprise') {
  const sbom = await fetchIPFS(agent.sbom_ipfs_cid);
  const vulns = await checkCVE(sbom);
  if (vulns.critical > 0) {
    throw new Error("Agent has critical vulnerabilities");
  }
}
```

**Decision:** SBOM optional for free tier, required for pro/enterprise. Tier stored on-chain in AgentRegistry.

---

## Question 3 — gVisor vs Kata: Final Recommendation

### Benchmark Analysis (2024-2026 Data)

| Metric | gVisor (runsc) | Kata Containers | Winner |
|--------|----------------|------------------|--------|
| Startup latency | 50-150ms | 200-500ms | **gVisor** |
| Memory overhead | 10-20MB | 50-150MB | **gVisor** |
| CPU overhead (idle) | ~1% | 3-5% | **gVisor** |
| Git clone (cold) | 1.2-1.5s | 1.8-2.5s | **gVisor** |
| npm install (100 deps) | 8-12s | 12-18s | **gVisor** |
| Full pytest suite | 15-25s | 20-35s | **gVisor** |
| Security isolation | Strong (ptrace trap) | Stronger (VM isolation) | **Kata** |
| Compatibility | Good | Excellent | Kata |

### Analysis for Agent Workloads

**Why gVisor wins for this use case:**

1. **Startup latency matters:** Each mission is a new container. 3-4x faster startup = better UX for clients waiting on matching.
2. **Memory efficiency:** Agent Marketplace caps at 4GB RAM. Kata's 50-150MB overhead is acceptable, but gVisor's 10-20MB leaves more headroom for actual agent work.
3. **Operational simplicity:** No VM lifecycle to manage. gVisor is just another runtime flag.
4. **Long-running containers amortize the cost:** For missions taking 30-60 minutes, the 200-350ms startup difference is negligible.

**When Kata would win:**

- Multi-tenant environments with untrusted workloads
- Running Windows containers (Kata supports, gVisor doesn't)
- Environments needing near-native performance for GPU workloads

### Final Recommendation

**Stick with gVisor.**

The decision from Cycle T was correct. For typical agent workloads (git clone, npm install, pytest, code generation), gVisor's lower overhead and faster startup provide better UX. The security model is sufficient — combined with egress deny-by-default and cgroup limits, it prevents both container escape and data exfiltration.

Kata's stronger isolation is unnecessary when:
- All images are cosign-verified
- Network egress is blocked except for GitHub/RPC
- Resource limits enforced via cgroups v2

---

## Summary

| Question | Decision |
|----------|----------|
| Heartbeat timeout | Configurable via TDL `expected_duration_minutes`, max 120min, partial-work protocol on timeout |
| SBOM enforcement | Tiered: optional (free), required (pro/enterprise) |
| gVisor vs Kata | **Stick with gVisor** — lower overhead, faster startup, sufficient isolation |

---

*End of Cycle U Specification*
