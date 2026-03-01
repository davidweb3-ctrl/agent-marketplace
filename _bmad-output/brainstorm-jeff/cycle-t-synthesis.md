# Cycle T — Synthesis: 4 Critical MVP Gaps

> Synthesized from cycle-t-opus.md + cycle-t-grok.md | 2026-03-01 | Clawd

---

## Gap 1 — Issue Dependency DAG

**Consensus:** Off-chain cycle detection + minimal on-chain storage. Both agents agree.

**TDL YAML:**
```yaml
mission:
  id: "issue-42"
  depends_on: ["issue-38", "issue-40"]
```

**MissionEscrow:**
- `missionDeps` mapping + `checkDepsResolved(missionId)` function
- Missions with unresolved deps stay CREATED — cannot be ASSIGNED
- Cycle detection: backend DFS before on-chain submission (gas cost O(V+E) is unacceptable on-chain)
- UX: GitHub bot comments "⏳ Waiting for #38, #40 to complete before this mission unlocks."

---

## Gap 2 — EAL Forgery Prevention

**Decision:** Nonce lifecycle (opus) + Merkle tree of diffs (grok) — complementary, use both.

**EAL structure:** `{missionId, agentDID, gitCommitHash, ealMerkleRoot, timestamp, nonce, signature}`

**Nonce lifecycle:** `assignMission()` generates → stored on-chain → burned in `submitEAL()` → anti-replay guaranteed.

**EAL Merkle tree:** Leaves = `hash(filePath + sha256(content))` for each changed file. Root stored on-chain, full tree on IPFS.

**QA:** Random spot-check 3 files, verify against PR diff. `gitCommitHash` must be child of mission base branch.

---

## Gap 3 — Agent SDK

**Decision:** OpenAPI 3.0 spec → auto-generated SDKs.

**5 REST endpoints (agent exposes):** `/health`, `/capabilities`, `/accept_mission`, `/progress`, `/submit_eal`

**3 webhooks (platform pushes):** `mission_assigned`, `dispute_opened`, `mission_cancelled`

**Standard env vars:** `MISSION_ID, AGENT_DID, ESCROW_CONTRACT, RPC_URL, GITHUB_TOKEN`

**Heartbeat:** POST every 60s → timeout 120s = TIMEOUT + auto-refund

**Error contract:** 4xx = agent fault (billable), 5xx = platform fault (not billable)

---

## Gap 4 — Docker Trust & Compute Model

**Decision:** gVisor over Kata Containers (simpler ops). cosign keyless via Sigstore (no key management).

**Flow:** Push to `registry.agent-marketplace.io` → cosign sign → verify before start → abort if invalid

**Isolation:** gVisor, egress deny-all except GitHub API + RPC, cgroups v2 (2 CPU, 4GB RAM, 10GB disk)

**Audit:** Logs 90d retention, image digest + resource usage in EAL, SBOM via syft → IPFS → AgentRegistry

---

## Implementation Priority

| Gap | Priority |
|---|---|
| Agent SDK (OpenAPI spec) | **P0** — unblocks everything |
| EAL Forgery (nonce + Merkle) | **P0** |
| Docker Trust | P1 |
| Dependency DAG | P1 |

**Score estimate post-Cycle T: ~82/100** — tous les gaps résolus, open questions non-bloquantes.

## Open Questions → Cycle U
1. Heartbeat timeout configurable pour missions longues ?
2. SBOM enforced ou optionnel (enterprise tier) ?
3. Benchmark gVisor vs Kata pour vraies workloads agent ?
