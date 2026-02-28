# Cross-Validation v2 — Grok 4

> 2026-02-28 | Docs: guide + epics + OpenAPI + DB

---

- State machine enums inconsistent: AGENT-CODING-GUIDE defines MissionState as {CREATED, FUNDED, ACCEPTED, IN_PROGRESS, DELIVERED, COMPLETED, DISPUTED, REFUNDED, CANCELLED}, while DB SCHEMA uses ('created', 'assigned', 'in_progress', 'completed', 'disputed', 'resolved', 'cancelled', 'paid', 'refunded') – missing alignments like FUNDED/ACCEPTED/DELIVERED vs added assigned/resolved/paid.
- Staking minimum amount contradiction: AGENT-CODING-GUIDE specifies min 1,000 AGNT, but EPICS-STORIES (EPIC-1-5) sets minimum stake threshold at 100 $AGNT per agent.
- Payment currency mismatch: EPICS-STORIES (EPIC-2-8) requires deposits in USDC, but AGENT-CODING-GUIDE's IMissionEscrow fundMission is payable (implying ETH/native token on Base L2).
- Escrow split logic absent: EPICS-STORIES (EPIC-2-8) describes 50% earmarked for provider on delivery and 50% held for client approval, but AGENT-CODING-GUIDE's IMissionEscrow interface lacks any such split mechanism.
- Platform fees not reflected: AGENT-CODING-GUIDE defines 10% fees (3% burn, 5% insurance, 2% treasury), but EPICS-STORIES (EPIC-2-8) describes 100% deposit without deducting or mentioning fees.
- Missing OpenAPI routes for core features: EPICS-STORIES includes mission creation (EPIC-2-7), funding (EPIC-2-8), and acceptance (EPIC-2-9), but provided OPENAPI lacks corresponding /missions paths or endpoints.
- Missing OpenAPI routes for staking: EPICS-STORIES (EPIC-1-5, EPIC-1-6) detail staking/unstaking flows, but provided OPENAPI has no /staking or /token endpoints.
- Missing OpenAPI routes for agent updates: EPICS-STORIES (EPIC-1-3) requires agent profile updates, but provided OPENAPI lacks PUT /agents/{id} or similar.
- DB lacks table for insurance: AGENT-CODING-GUIDE includes IInsurancePool interface with deposit/claim functions, but DB SCHEMA has no corresponding insurance_pool table.
- DB has extraneous fields not in guide: DB SCHEMA's missions table includes fiat_holdback_expires_at, but AGENT-CODING-GUIDE's IMissionEscrow lacks any fiat-related fields or logic.
- Naming case inconsistency in states: AGENT-CODING-GUIDE uses CamelCase (e.g., IN_PROGRESS), but DB SCHEMA uses snake_case (e.g., 'in_progress') for the same concepts, risking mapping errors.
- Agent staking per-agent vs global: EPICS-STORIES (EPIC-1-5) specifies "per agent" staking, but AGENT-CODING-GUIDE's IAGNTToken stake function is global (no per-agent parameter).
- Unstake timelock mismatch: EPICS-STORIES (EPIC-1-6) specifies 7-day timelock, but AGENT-CODING-GUIDE's IAGNTToken unstake has no timelock parameter or mention.
- Missing DB table for tokens/staking: AGENT-CODING-GUIDE defines IAGNTToken with staking functions, but DB SCHEMA lacks any tokens or staking_balance table for off-chain tracking.
- Genesis badge not in OpenAPI: EPICS-STORIES (EPIC-1-4) requires genesis badge system, but provided OPENAPI /agents response schema lacks a genesis field.
- Reputation influence mismatch: EPICS-STORIES (EPIC-1-5) states stake influences reputation (20% weight), but AGENT-CODING-GUIDE lacks reputation in interfaces, and DB SCHEMA has reputation_score without stake weighting logic.