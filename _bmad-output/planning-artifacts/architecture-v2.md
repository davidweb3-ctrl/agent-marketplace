---
stepsCompleted: [1]
inputDocuments:
  - _bmad-output/planning-artifacts/PRD.md
  - _bmad-output/MASTER-v2.md
  - _bmad-output/DECISIONS.md
  - _bmad-output/project-context.md
  - _bmad-output/planning-artifacts/market-research-report.md
  - _bmad-output/planning-artifacts/architecture.md
date: 2026-02-28
version: 2.0
---

# Agent Marketplace — Architecture v2.0 (Post-Audit)

> **Status:** Canonical — supersedes architecture.md for decisions updated post-audit
> **Date:** 2026-02-28
> **Input:** PRD v1.3 + MASTER-v2.md + Market Research (Feb 2026)
> **See also:** `architecture.md` for original detailed diagrams (still valid)

---

## What Changed vs architecture.md v1.0

| Section | Change | Reason |
|---------|--------|--------|
| Blockchain Indexer | Added full spec | Was missing in v1.0 |
| Fiat-First Layer | Added payment abstraction | Post-audit fix (§9b) |
| V1 vs V1.5 scope | Clarified per sprint plan | MoSCoW correction |
| Agent Identity Standard (inspired by EIP-6551/ERC-8004 draft) compliance | Added to AgentRegistry | Market research finding |
| Security | TEE strictly V2 | Post-audit correction |

---



## Project Context Analysis

### Requirements Overview

**Scale:** Enterprise-grade (26 features, 4 smart contracts, 3 user personas, fintech compliance)
**Complexity:** HIGH — blockchain + marketplace + fintech + real-time events
**Primary domain:** Full-stack Web3 (smart contracts + REST API + frontend + indexer)

**Functional Requirements (FRs):**
- 12 Must-Have (V1/V1.5): identity cards, on-chain reputation, escrow, staking, marketplace UI, SDK, token, inter-agent
- Smart contracts are the source of truth — API is a read/write layer on top
- Stateful mission lifecycle (9-state machine) drives the entire backend

**Non-Functional Requirements (NFRs):**
- Gas < $0.01 per transaction (Base L2 satisfies this)
- Finality < 3 seconds (Base L2: ~2s)
- API: 100 req/min authenticated, 10 unauthenticated
- Mobile responsive (320px+)
- 90% smart contract test coverage

**Compliance Requirements (NEW — from PRD v1.3 §12b):**
- GDPR: data deletion endpoint, on-chain immutability disclosure
- KYC/AML: provider verification, $10K threshold enhanced KYC
- OFAC: wallet screening (TRM Labs / Chainalysis) at every transaction
- Token legal opinion required before mainnet

### Technical Constraints

- **Base L2 (Ethereum)** — ERC-20, UUPS proxy, OpenZeppelin
- **⚠️ Finality réelle:** ~2s = soft confirmation uniquement. Finality L1 (anti-reorg) = 10-15 minutes (optimistic rollup epoch). Créditer reputation ou release escrow uniquement après `waitForTransactionReceipt` + 2 block confirmations minimum
- **Agent Identity Standard (inspired by EIP-6551/ERC-8004 draft)** — New Ethereum standard for on-chain agent identity (Feb 2026); AgentRegistry should implement. > **Note:** Interface complete defined in `solidity-interfaces-spec.md`.
- **Node.js 22 / TypeScript strict** — API and indexer
- **Fastify** (not Express) — REST API framework
- **PostgreSQL 16 + pgvector** — off-chain state + semantic search
- **k3s homelab** — deployment target (existing ArgoCD GitOps)
- **Pinata** — IPFS pinning for agent metadata

### Cross-Cutting Concerns

1. **Blockchain-DB sync** — every on-chain event must reflect in PostgreSQL (indexer critical path)
2. **Payment flow duality** — fiat (Stripe→USDC) and crypto-native (wallet) must use same escrow contract
3. **Auth duality** — JWT (clients) + SIWE wallet signature (providers) on same API
4. **State machine enforcement** — mission states in DB must ALWAYS match on-chain states
5. **OFAC screening** — must run before EVERY transaction creation (compliance blocker)
6. **V1 vs V1.5 scope** — pgvector, SDK, dry run, inter-agent are V1.5; DO NOT implement in V1 sprint



## Starter Template Evaluation

### Selected Stack — No Starter Template (Custom Bootstrap)

This is a Web3/blockchain project. Standard starters (Vite, T3, Next.js) don't include Hardhat, contract ABIs, blockchain indexers, or SIWE auth. We bootstrap each service separately.

**Rationale:** The architecture has 4 distinct services, each with its own best-practice bootstrap:

| Service | Bootstrap Command | Notes |
|---------|------------------|-------|
| Smart Contracts | `npx hardhat init` | Solidity + Hardhat + OZ |
| API (Fastify) | `npm init fastify` | TypeScript strict, Fastify 5 |
| Frontend | `npm create vite@latest -- --template react-ts` | React 19 + Vite 6 |
| Indexer | Custom Node.js service | viem + PostgreSQL listeners |

**Pre-committed Technical Decisions (from PRD + MASTER-v2.md):**

- **Language:** TypeScript strict everywhere (Node.js 22)
- **Contracts:** Solidity 0.8.28, Hardhat, OpenZeppelin v5, UUPS proxy
- **API:** Fastify 5 (not Express), Zod validation, JWT + SIWE auth
- **Frontend:** React 19, Vite 6, TailwindCSS, wagmi v2 + viem
- **DB:** PostgreSQL 16 + pgvector (V1.5)
- **ORM:** Prisma 6 (schema-first, migrations)
- **IPFS:** Pinata SDK
- **Testing contracts:** Hardhat Chai Matchers (90% coverage required)
- **Testing API:** Vitest + supertest
- **Deployment:** Docker → k3s ArgoCD GitOps (homelab)
- **CI:** GitHub Actions (lint, test, build, push)



## Core Architectural Decisions

### Critical Decisions — Block Implementation

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Smart contract proxy pattern | UUPS (ERC-1967) | Upgradeability without transparent proxy gas overhead |
| Contract ownership | Ownable2Step (OpenZeppelin) | 2-step ownership transfer prevents accidents |
| Token standard | ERC-20 + custom AccessControl | $AGNT needs role-based minting control |
| Mission state machine | On-chain enum + off-chain mirror | Contracts are source of truth; DB is read-optimized cache |
| OFAC screening | TRM Labs API gateway middleware | Called BEFORE every transaction creation (compliance blocker) |
JY|| Blockchain indexer | `watchContractEvent` (primary) + `getLogs` backfill from cursor (`last_indexed_block` from DB table `indexer_state`) to `current_block`, chunk 100 blocks per call + reorg detection + dedup sur txHash | Robustesse prod — watchContractEvent seul = mortel sur volume >1k tx/jour |
MX|| Fee split | 3% → AGNT buy-and-burn: USDC sent to treasury, treasury buys AGNT on DEX (Uniswap Base) and sends to 0x000...dead. Executed weekly via keeper job. | Deflationary tokenomics |
YX|

### Data Architecture

**Primary store:** PostgreSQL 16 (Prisma 6 ORM)
- `agents`, `missions`, `reviews`, `transactions`, `providers` tables
- `walletAddress` indexed on providers (lowercase, checksum normalized)
- `missionEvents` table (append-only log synced from blockchain)
- pgvector column on `agents.embedding` (V1.5 only — do not create in V1)

**IPFS:** Agent metadata JSON pinned via Pinata. CID stored in contract + DB.

**Caching:** Redis for session tokens + rate limiting counters. No business data cached (blockchain is source of truth).

**Migration strategy:** Prisma migrations committed to repo, run on deployment via ArgoCD Job.

### Authentication & Security

| Concern | Solution |
|---------|---------|
| Client auth | JWT (RS256, 1h expiry) + refresh token (7d, Redis) |
| Provider auth | SIWE (Sign-In with Ethereum) → JWT after verification |
| API authorization | Fastify decorators + role checks (client/provider/admin) |
| Admin auth | OAuth2 (GitHub) for internal dashboard |
| Contract auth | OpenZeppelin AccessControl with MINTER_ROLE, PAUSER_ROLE |
| OFAC | TRM Labs wallet screening middleware (sync, pre-transaction) |
| Rate limiting | Fastify rate-limit (Redis backend, per-IP + per-JWT) |
| Data encryption | AES-256-GCM for sensitive fields (API keys stored in providers table) |
KJ|| TEE | **NOT V1/V1.5** — V2 only |
TT|| Commit-Reveal | Agent matching uses commit-reveal to prevent front-running. Client commits `keccak256(nonce | agentId)` → reveal within 50 blocks. Reveal window: [commit_block + 1, commit_block + 50]. After 50 blocks: commitment expires, CANCELLED. Nonce: 32 bytes random, client-side. |
TT|
ZH|### API Design

### API Design

- **Fastify 5** (TypeScript strict, schema validation with JSON Schema + Zod coercion)
- **REST only** — no GraphQL in V1 (complexity not warranted)
- **OpenAPI 3.1** spec auto-generated from Fastify route schemas
- **Versioning:** `/api/v1/` prefix
- **Error format:** `{ error: string, code: string, details?: object }` (consistent)
- **Webhooks:** POST to client-registered URLs on mission state transitions
- **Rate limits:** 100 req/min authenticated, 10 req/min anonymous

### Frontend Architecture

- **React 19** + Vite 6 (SPA, not SSR — no SEO requirements in V1)
- **wagmi v2 + viem** — wallet connection and contract interaction
- **TailwindCSS** — no component library (custom design system for brand differentiation)
- **State:** Zustand (lightweight, no Redux complexity)
- **Data fetching:** TanStack Query v5 (cache + refetch on block events)
- **Routing:** React Router v7
- **Mobile responsive:** 320px+ (Tailwind breakpoints)

### Infrastructure & Deployment

- **k3s** homelab via ArgoCD GitOps (mintrtx 192.168.3.139)
- **Docker images** pushed to `registry.ju`
- **Namespaces:** `agent-marketplace-prod`, `agent-marketplace-staging`
- **TLS:** Let's Encrypt wildcard `*.opstech.dev` (existing cert, valid May 2026)
- **Domain:** `marketplace.opstech.dev`
- **CI:** GitHub Actions (lint → test → build → push → ArgoCD sync)
- **Secrets:** Vault (existing, connected to k3s)
- **Monitoring:** Grafana/Prometheus (existing dashboards)

### Deferred Decisions (Post V1.5)

- Multi-chain expansion (Polygon, Arbitrum)
- zkSNARK proof-of-execution (TEE alternative)
- Agent guild smart contracts
- Secondary market for reputation tokens



## Implementation Patterns & Consistency Rules

> These rules are **MANDATORY** for all agents. No agent may deviate without explicit approval.

### Naming Patterns

**Database (snake_case everywhere):**
- Tables: plural, snake_case → `agents`, `missions`, `mission_events`, `provider_profiles`
- Columns: snake_case → `wallet_address`, `created_at`, `mission_id`
- FKs: `{table_singular}_id` → `agent_id`, `provider_id`
- Indexes: `idx_{table}_{column}` → `idx_agents_wallet_address`

**API (camelCase in JSON, kebab-case in paths):**
- Endpoints: plural nouns → `GET /api/v1/agents`, `POST /api/v1/missions`
- Path params: `:agentId`, `:missionId` (camelCase)
- JSON fields: camelCase → `{ "agentId": "...", "createdAt": "..." }`
- Dates in JSON: ISO 8601 strings → `"2026-02-28T12:00:00.000Z"`

**TypeScript (strict PascalCase for types, camelCase for everything else):**
- Types/Interfaces: `AgentCard`, `MissionState`, `PaymentFlow`
- Functions: `createMission`, `getAgentById`
- Files: `agent.service.ts`, `mission.repository.ts` (kebab-case)
- Constants: UPPER_SNAKE → `MAX_STAKING_AMOUNT`, `MISSION_STATES`

**Solidity:**
- Contracts: PascalCase → `AgentRegistry`, `MissionEscrow`
- Events: PascalCase past tense → `AgentRegistered`, `MissionCompleted`
- Errors: PascalCase → `InsufficientStake`, `MissionNotFound`
- Functions: camelCase → `registerAgent`, `createMission`

### Structure Patterns

**Monorepo layout (pnpm workspaces):**
```
agent-marketplace/
  packages/
    contracts/     # Hardhat project
    api/           # Fastify API
    frontend/      # React/Vite app
    indexer/       # Blockchain event indexer
    shared/        # Shared types (TypeScript)
```

**API structure (within packages/api):**
```
src/
  routes/          # Route handlers (thin — delegate to services)
  services/        # Business logic
  repositories/    # DB access (Prisma)
  middleware/      # Auth, rate limit, OFAC check
  lib/             # Utilities (blockchain client, ipfs, etc.)
  types/           # Domain types (re-exported from shared)
```

**Tests co-located with source:**
```
src/services/agent.service.ts
src/services/agent.service.test.ts   ← same folder, .test.ts suffix
```

### Format Patterns

**API Response — always wrapped:**
```typescript
// Success:
{ "data": { ... }, "meta": { "total": 42 } }  // list
{ "data": { ... } }                             // single item

// Error:
{ "error": "MISSION_NOT_FOUND", "message": "Mission 0x... not found", "details": {} }
```

**HTTP status codes:**
- 200: successful GET/PUT
- 201: successful POST (resource created)
- 204: successful DELETE (no body)
- 400: validation error
- 401: not authenticated
- 403: not authorized
- 404: resource not found
- 409: conflict (duplicate)
- 422: business logic violation
- 500: unexpected server error

**Blockchain addresses:** always lowercase in DB (`wallet_address.toLowerCase()`), checksum-validated at API boundary.

### Process Patterns

**Mission State Machine — enforcement:**
- ALL state transitions MUST go through `MissionService.transitionState()`
- This service validates the transition, calls the contract, then updates DB
- NEVER update `missions.state` in DB directly from anywhere else
YZ|- State enum must match Solidity `MissionState` enum exactly
YM|
YM|**MissionEscrow State Diagram:**
YM|```mermaid
YM|stateDiagram-v2
YM|    [*] --> CREATED : createMission() [client]
YM|    CREATED --> FUNDED : fundMission() [client, USDC transfer]
YM|    CREATED --> CANCELLED : cancel() [client, before funding]
YM|    FUNDED --> ACCEPTED : acceptMission() [agent, stake verified ≥1000 AGNT]
YM|    FUNDED --> REFUNDED : timeout 24h [auto via keeper]
YM|    ACCEPTED --> IN_PROGRESS : startWork() [agent]
YM|    ACCEPTED --> REFUNDED : timeout 48h [auto]
YM|    IN_PROGRESS --> DELIVERED : submitEAL(ealHash) [agent]
YM|    IN_PROGRESS --> REFUNDED : timeout(deadline) [auto]
YM|    DELIVERED --> COMPLETED : approve() [client, within 48h]
YM|    DELIVERED --> DISPUTED : dispute() [client, within 48h]
YM|    DELIVERED --> COMPLETED : auto-release [after 48h no action]
YM|    DISPUTED --> COMPLETED : resolveFor(agent) [reviewers 2/3]
YM|    DISPUTED --> REFUNDED : resolveFor(client) [reviewers 2/3]
YM|    COMPLETED --> [*]
YM|    REFUNDED --> [*]
YM|    CANCELLED --> [*]
YM|```

**OFAC Screening — mandatory:**
```typescript
// In middleware/ofac.middleware.ts:
// Called BEFORE: createMission, registerAgent, requestPayout
async function ofacCheck(walletAddress: string): Promise<void> {
  const result = await trmLabs.screen(walletAddress)
  if (result.risk === 'HIGH') throw new ForbiddenError('OFAC_BLOCKED')
}
JB|```
PS|
PS|> **Note:** Screening is SYNCHRONOUS and BLOCKING on `createMission` and `fundMission` API calls. Cache 1h for clean wallets only. Never async before financial transactions.
PS|
WK|**Indexer sync — never trust DB, always verify:**

**Indexer sync — never trust DB, always verify:**
- Indexer populates `mission_events` (append-only)
- API reads from `missions` table (materialized view of events)
- On startup, indexer replays missed events from last processed block
- Block number stored in `indexer_state` table

**Error handling:**
```typescript
// Always use typed errors:
throw new NotFoundError('AGENT_NOT_FOUND', `Agent ${id} not found`)
throw new ValidationError('INVALID_STAKE', `Stake must be >= ${MIN_STAKE} AGNT`)

// Never throw raw Error in business logic
// Never expose internal errors to API responses
```

### All Agents MUST:
1. Run `pnpm test` before marking any task complete
2. Never commit `.env` files (use `.env.example` templates)
3. Never hardcode contract addresses (use config from env vars)
4. Never mix fiat amounts with crypto amounts without explicit unit labels
5. Add OpenAPI annotations to every new route
6. Add Prisma migration for every schema change (never edit DB directly)



## Project Structure & Boundaries

### Complete Monorepo Directory Structure

```
agent-marketplace/
├── README.md
├── package.json                     # pnpm workspaces root
├── pnpm-workspace.yaml
├── turbo.json                       # Turborepo build pipeline
├── .env.example
├── .gitignore
├── docker-compose.yml               # Local dev (postgres, redis)
├── .github/
│   └── workflows/
│       ├── ci.yml                   # lint + test + build on PR
│       └── deploy.yml               # build + push + ArgoCD sync on main
│
├── packages/
│   ├── shared/                      # @agent-marketplace/shared
│   │   ├── src/
│   │   │   ├── types/               # Shared TypeScript types
│   │   │   │   ├── agent.ts         # AgentCard, AgentMetadata
│   │   │   │   ├── mission.ts       # MissionState enum, MissionEvent
│   │   │   │   ├── payment.ts       # PaymentFlow, PaymentMethod
│   │   │   │   └── index.ts
│   │   │   └── constants/
│   │   │       ├── mission-states.ts   # Mirrors Solidity MissionState enum
│   │   │       └── contract-abis.ts    # Generated ABIs (from contracts build)
│   │   └── package.json
│   │
│   ├── contracts/                   # @agent-marketplace/contracts
│   │   ├── contracts/
│   │   │   │   ├── AgentRegistry.sol    # Agent Identity Standard (EIP-6551/ERC-8004 inspired) compliant agent identity
│   │   │   ├── MissionEscrow.sol    # Mission lifecycle + payments
│   │   │   ├── AGNTToken.sol        # ERC-20 governance token
│   │   │   └── ReputationOracle.sol # On-chain reputation aggregator
│   │   ├── scripts/
│   │   │   ├── deploy.ts
│   │   │   └── verify.ts
│   │   ├── test/
│   │   │   ├── AgentRegistry.test.ts
│   │   │   ├── MissionEscrow.test.ts
│   │   │   ├── AGNTToken.test.ts
│   │   │   └── ReputationOracle.test.ts
│   │   ├── hardhat.config.ts
│   │   ├── typechain-types/         # Auto-generated (gitignored)
│   │   └── package.json
│   │
│   ├── api/                         # @agent-marketplace/api (Fastify)
│   │   ├── src/
│   │   │   ├── main.ts              # Server entry point
│   │   │   ├── app.ts               # Fastify app factory
│   │   │   ├── routes/
│   │   │   │   ├── agents.ts        # GET /agents, POST /agents
│   │   │   │   ├── missions.ts      # CRUD + state transitions
│   │   │   │   ├── payments.ts      # Fiat + crypto payment initiation
│   │   │   │   ├── reviews.ts       # Mission reviews
│   │   │   │   ├── auth.ts          # JWT + SIWE auth flows
│   │   │   │   └── health.ts        # Health check
│   │   │   ├── services/
│   │   │   │   ├── agent.service.ts
│   │   │   │   ├── agent.service.test.ts
│   │   │   │   ├── mission.service.ts     # ← State machine enforcement
│   │   │   │   ├── mission.service.test.ts
│   │   │   │   ├── payment.service.ts     # Fiat + crypto unified
│   │   │   │   ├── payment.service.test.ts
│   │   │   │   ├── reputation.service.ts
│   │   │   │   └── ofac.service.ts       # TRM Labs integration
│   │   │   ├── repositories/
│   │   │   │   ├── agent.repository.ts
│   │   │   │   ├── mission.repository.ts
│   │   │   │   └── review.repository.ts
│   │   │   ├── middleware/
│   │   │   │   ├── auth.middleware.ts    # JWT + SIWE verification
│   │   │   │   ├── ofac.middleware.ts    # OFAC check (pre-transaction)
│   │   │   │   └── rate-limit.middleware.ts
│   │   │   └── lib/
│   │   │       ├── blockchain.ts         # viem public + wallet clients
│   │   │       ├── ipfs.ts               # Pinata SDK wrapper
│   │   │       ├── stripe.ts             # Stripe SDK (fiat→USDC)
│   │   │       └── prisma.ts             # Prisma client singleton
│   │   ├── prisma/
│   │   │   ├── schema.prisma
│   │   │   └── migrations/
│   │   └── package.json
│   │
│   ├── indexer/                     # @agent-marketplace/indexer
│   │   ├── src/
│   │   │   ├── main.ts              # Indexer entry point
│   │   │   ├── listeners/
│   │   │   │   ├── agent-registry.listener.ts   # AgentRegistered, AgentDeactivated
│   │   │   │   ├── mission-escrow.listener.ts   # MissionCreated → MissionCompleted
│   │   │   │   └── reputation.listener.ts       # ReviewSubmitted events
│   │   │   ├── processors/
│   │   │   │   ├── mission-event.processor.ts   # Sync event → DB
│   │   │   │   └── reputation.processor.ts
│   │   │   └── lib/
│   │   │       ├── blockchain.ts    # viem watchContractEvent
│   │   │       └── prisma.ts
│   │   └── package.json
│   │
│   └── frontend/                    # @agent-marketplace/frontend
│       ├── src/
│       │   ├── main.tsx
│       │   ├── App.tsx
│       │   ├── routes/              # React Router v7
│       │   │   ├── index.tsx        # Marketplace listing
│       │   │   ├── agent/[id].tsx   # Agent profile
│       │   │   ├── mission/[id].tsx # Mission tracking
│       │   │   ├── dashboard/       # Provider dashboard
│       │   │   └── onboarding/      # Provider registration
│       │   ├── components/
│       │   │   ├── ui/              # Design system primitives
│       │   │   ├── agent/           # AgentCard, AgentList, AgentModal
│       │   │   ├── mission/         # MissionForm, MissionTracker
│       │   │   └── payment/         # PaymentModal (fiat + crypto)
│       │   ├── stores/              # Zustand stores
│       │   │   ├── auth.store.ts
│       │   │   └── mission.store.ts
│       │   ├── hooks/               # TanStack Query hooks
│       │   │   ├── useAgents.ts
│       │   │   └── useMissions.ts
│       │   └── lib/
│       │       ├── wagmi.ts         # wagmi config (Base mainnet + Sepolia)
│       │       └── api-client.ts    # API client (fetch wrapper)
│       ├── index.html
│       ├── vite.config.ts
│       └── package.json
│
└── k8s/                             # ArgoCD manifests (gitops)
    ├── api/
    ├── indexer/
    ├── frontend/
    └── postgres/
```

### Architectural Boundaries

**API ↔ Blockchain:** `packages/api/src/lib/blockchain.ts` — only write through this module
**API ↔ DB:** `packages/api/src/repositories/` — only data access layer touches Prisma
**Indexer ↔ DB:** Indexer writes ONLY to `mission_events` table and `indexer_state`
**Frontend ↔ API:** `packages/frontend/src/lib/api-client.ts` — typed fetch wrapper
**Frontend ↔ Contracts:** Only via wagmi hooks, never raw `viem` calls from components

### Feature → Directory Mapping

| Feature | Code Location |
|---------|--------------|
| F1 Agent Identity Cards | `contracts/AgentRegistry.sol`, `api/routes/agents.ts`, `frontend/components/agent/` |
| F2 On-chain Reputation | `contracts/ReputationOracle.sol`, `api/services/reputation.service.ts` |
| F3 Escrow + Payment | `contracts/MissionEscrow.sol`, `api/services/payment.service.ts`, `api/middleware/ofac.middleware.ts` |
| F4 Staking + Slash | Part of `MissionEscrow.sol` |
| F5 Marketplace UI | `frontend/routes/index.tsx`, `frontend/components/agent/AgentList.tsx` |
| F7 Token ($AGNT) | `contracts/AGNTToken.sol` |
| F8 Mission DNA | `api/services/agent.service.ts` (tag matching), `frontend/components/mission/MissionForm.tsx` |
| Indexer | `packages/indexer/` entire package |
| Fiat layer | `api/lib/stripe.ts`, `api/services/payment.service.ts` |





## Corrections Post-Audit Grok 4 (2026-02-28)

> Audit Grok 4 avec 40 sources — findings critiques appliqués.

### 1. Indexer — Robustesse Obligatoire

`watchContractEvent` seul n'est **pas suffisant en prod**. Implémentation requise:

```typescript
// indexer/src/lib/blockchain.ts

// PRIMARY: websocket watchContractEvent
const unwatch = publicClient.watchContractEvent({ ... })

JT|// BACKFILL: getLogs from cursor stored in DB table `indexer_state`
YV|// Chunk size: 100 blocks per getLogs call to avoid RPC timeout
HR|// On restart: resume from cursor. On reorg: rollback to fork point.
WY|const latest = await publicClient.getBlockNumber()
HJ|from = lastIndexedBlock  // from DB table `indexer_state`
WR|while (from < latest) {
WR|  const to = Math.min(from + 100, latest)
WR|  const logs = await publicClient.getLogs({ fromBlock: from, toBlock: to, ... })
WR|  await processLogsIdempotent(logs)  // ← dedup sur txHash + logIndex
WR|  await db.indexerState.update({ lastIndexedBlock: to })  // persist cursor
WR|  from = to + 1
WR|}
setInterval(async () => {
  const latest = await publicClient.getBlockNumber()
  const from = lastProcessedBlock
  const logs = await publicClient.getLogs({ fromBlock: from, toBlock: latest, ... })
  await processLogsIdempotent(logs)  // ← dedup sur txHash + logIndex
}, 10 * 60 * 1000)

// REORG DETECTION: comparer block hash
// Si block hash change sur un block déjà processé → rollback events de ce block
```

**Règles:**
- Dedup OBLIGATOIRE: `UNIQUE(tx_hash, log_index)` sur `mission_events`
- Fallback RPC multi-provider: Alchemy → Infura → Base public node (en cascade)
- `indexer_state` stocke le dernier block hash processé (pas juste le numéro)
- `waitForTransactionReceipt` + 2 confirmations avant tout crédit reputation / release escrow

### 2. Finality — Correction Critique

| Confirmation | Durée | Usage |
|-------------|-------|-------|
| Soft (tx incluse dans block L2) | ~2s | UI feedback seulement |
| Safe (2 block confirmations L2) | ~4s | Indexer processing |
| **L1 Finality (anti-reorg)** | **10-15 min** | **Release escrow, crédit reputation** |

→ Ne JAMAIS release escrow ou créditer reputation avant finality L1 (ou minimum `safeBlockNumber`).

### 3. UUPS Governance — Sécurité Obligatoire

| Contrat | Upgrade Authority | Timelock |
|---------|------------------|---------|
| AgentRegistry | Multisig 3/5 | 48h |
| MissionEscrow | Multisig 3/5 | 72h |
| AGNTToken | Multisig 3/5 | 48h |
| **ReputationOracle** | **Immutable (pas de UUPS)** | — |

**Règles Solidity obligatoires:**
```solidity
// Sur TOUTES les implémentations:
constructor() { _disableInitializers(); }

// Sur _authorizeUpgrade:
function _authorizeUpgrade(address) internal override onlyTimelock {}
```

- `DEFAULT_ADMIN_ROLE` = Gnosis Safe multisig 3/5 — JAMAIS EOA
- ReputationOracle → **immutable** (upgradable = peut réécrire historique → confiance nulle)
- Storage gaps vérifiés avec Slither avant chaque upgrade

### 4. Slash Governance — Qui Décide ?

**Problème identifié:** ReputationOracle seul pour décider "mission failed" = oracle attack / sybil / griefing.

**Solution V1:**
```
Dispute flow:
  Client claim "failed" → 48h dispute window
  → Provider peut contester
  → Si pas de résolution → Admin arbitration (multisig)
  → Admin décide → slash ou release
  → Décision on-chain (event loggé, immutable)
```

- Dispute window: 48h après deadline mission
- Admin arbitration: multisig 2/3 suffit pour dispute (pas timelock — rapidité nécessaire)
- V1.5: DAO vote sur disputes >$1000

### 5. Fiat Holdback — Protection Chargeback Stripe

**Problème:** Chargeback Stripe possible 30-90j vs finality blockchain immédiate.

**Solution:**
- Fiat missions: holdback 7 jours avant que le provider puisse withdraw USDC
- Holdback stocké en DB: `missions.fiat_holdback_expires_at`
- Stripe webhook `charge.dispute.created` → gèle le withdraw automatiquement
- Escrow contract: `releaseAfterHoldback(missionId)` vérifie timestamp on-chain

### 6. Anti-Spam Économique — Rate-Limit Mission

**Problème:** Pas de coût à spammer des créations de missions → DoS escrow + fees.

**Solution V1:**
- `POST /api/v1/missions` → rate-limit: **5 missions/heure/wallet**
- Mission creation requiert deposit minimum: **10 USDC** (remboursé si annulé dans 30min)
- On-chain: `MissionEscrow.createMission()` requiert `msg.value >= MIN_DEPOSIT`
- Rate-limit économique > rate-limit HTTP pour ce cas

## Architecture Validation

### Coherence Check ✅

| Check | Result |
|-------|--------|
| viem + wagmi v2 + Hardhat compatible | ✅ All target Base L2 (EVM compatible) |
| Fastify 5 + Prisma 6 + Zod | ✅ No conflicts |
| React 19 + TanStack Query v5 + Zustand | ✅ All React 19 compatible |
| TypeScript strict mode across all packages | ✅ Turborepo shared tsconfig |
| pnpm workspaces + Turbo | ✅ Standard monorepo pattern |
| Docker → k3s ArgoCD | ✅ Existing homelab supports this |

### Requirements Coverage ✅

**V1 Must-Have (weeks 1-8):**
- F1 Agent Identity Cards → AgentRegistry.sol + `/agents` route ✅
- F2 On-chain Reputation → ReputationOracle.sol + reputation.service.ts ✅
- F3 Escrow + Payment → MissionEscrow.sol + payment.service.ts + OFAC middleware ✅
- F4 Staking + Slash → MissionEscrow.sol (same contract) ✅
- F5 Marketplace UI → frontend routes + agent components ✅
- F7 $AGNT Token → AGNTToken.sol ✅
- F8 Mission DNA (V1: tag match) → agent.service.ts ✅

**V1.5 Should-Have (weeks 9-16):**
- F6 SDK → new package `packages/sdk/` (not in V1 structure — correct)
- F9 Dry Run → frontend modal + new mission type (not in V1 contracts)
- F10 pgvector search → add column to agents table in migration (schema ready)
- F11 Proof of Work → new route `GET /missions/:id/proof`

**NFRs:**
- Gas < $0.01 → Base L2 (✅ confirmed, avg ~$0.001)
- API rate limits → rate-limit middleware ✅
- 90% contract coverage → Hardhat Chai Matchers in test/ ✅
- OFAC compliance → pre-transaction middleware ✅
- GDPR → data deletion endpoint (POST /users/delete) — **ADD TO ROUTES** ⚠️

### Gap Found — GDPR Deletion Endpoint

Missing from route definitions: `POST /api/v1/users/me/delete`
- Soft-delete wallet from `provider_profiles`
- On-chain data stays (immutable — disclose in ToS)
- Redis cache flush for that JWT
- Add to `routes/auth.ts` in V1

### Architecture Readiness: READY FOR IMPLEMENTATION

**Confidence: HIGH**

**Strengths:**
- Clear service boundaries, no circular dependencies
- Proven tech stack (no experimental libs in critical path)
- Existing homelab infrastructure reused
- Compliance handled at middleware layer (swappable)
- Indexer decoupled — can restart without losing data

**V1 Sprint Start: Smart Contracts**
```bash
cd packages/contracts && npx hardhat init --typescript
# Start with: AgentRegistry.sol → MissionEscrow.sol → AGNTToken.sol
```



---
stepsCompleted: [1, 2, 3, 4, 5, 6, 7, 8]
workflowType: architecture
lastStep: 8
status: complete
completedAt: 2026-02-28
---
