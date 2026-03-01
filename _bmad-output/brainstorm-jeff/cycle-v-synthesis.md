# Cycle V — Synthesis: Implementation Plan + Walking Skeleton

> Synthesized from cycle-v-opus.md + cycle-v-grok.md | 2026-03-01 | Clawd

---

## Walking Skeleton (Demo First)

**Demo = 150-line contract + 50-line Python agent + 1 USDC transfer**

### What's real vs mocked

| Component | Demo | Production |
|---|---|---|
| Escrow contract | ✅ Real (Sepolia) | ✅ Real |
| USDC transfer | ✅ Real | ✅ Real |
| AgentRegistry | Stub (mapping in Escrow) | ✅ Full contract |
| EAL verification | Mocked | ✅ Merkle + nonce |
| GitHub bot | Simple polling script | ✅ GitHub App |
| Agent "work" | npm lint | ✅ Any task |

### Demo sequence (3 min)
1. `forge script Deploy --rpc-url sepolia --broadcast` → Escrow at 0x...
2. Jeff funds 10 USDC to Escrow via `cast send`
3. Jeff opens GitHub issue with TDL YAML
4. Bot detects → emits `TaskCreated(taskId, agentAddr)`
5. Agent script runs lint, writes evidence, calls `submitEAL()`
6. Escrow releases 1 USDC → verify on Etherscan

---

## Sprint Plan (6 weeks)

### Sprint 0 — Foundations (Week 1)
- Monorepo: `/contracts` (Foundry), `/sdk`, `/bot`, `/infra`
- CI: `forge test` + `pytest` on every PR
- Local stack: `docker-compose up` → anvil + IPFS + registry mock

### Sprint 1 — Core Contracts (Weeks 2-3)
Order: **AgentRegistry → MissionEscrow → AGNTToken**
- MissionEscrow is the minimum for walking skeleton (deploy first)
- Done when: `forge test` 100%, fork test on Sepolia passes, no function >500k gas

### Sprint 2 — Agent SDK + Bot (Weeks 4-5)
- `spec/openapi.yaml` → generate Python + TypeScript SDKs
- FastAPI webhook bot: TDL parser, mission dispatcher, heartbeat monitor
- E2E test: fake agent completes a mission end-to-end

### Sprint 3 — Security + Hardening (Week 6)
- cosign keyless signing in CI
- gVisor runtime config
- Slither + Mythril clean
- Internal 2-person audit → sign-off

### Testnet Launch Criteria
- [ ] All sprint done criteria met
- [ ] E2E test passes on Sepolia fork
- [ ] Slither/Mythril: 0 critical findings
- [ ] Contract verified on Basescan
- [ ] External audit scheduled (Trail of Bits / OpenZeppelin)

---

## Key Files to Create First
1. `infra/docker-compose.yml` — local dev stack
2. `.github/workflows/ci.yml` — forge test + pytest
3. `contracts/src/MissionEscrow.sol` — the walking skeleton contract
4. `spec/openapi.yaml` — agent SDK contract
5. `bot/agent_demo.py` — 50-line demo agent

