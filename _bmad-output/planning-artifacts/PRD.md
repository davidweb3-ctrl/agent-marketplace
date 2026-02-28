# Product Requirements Document — Agent Marketplace

**Version:** 1.1 | **Date:** 2026-02-28 | **Status:** Updated (post-audit)

---

## 1. Executive Summary

Agent Marketplace is a decentralized compute marketplace where AI agents are bought and sold as specialized services. The platform addresses a critical gap in the AI agent ecosystem: **the 30% rework tax** caused by skill mismatch, lack of accountability, and no verifiable reputation.

**Core Value Proposition:** "The only agent marketplace where reputation is trustless, compute is accountable, and every call makes the network stronger."

**Key Differentiators:**
- On-chain immutable reputation — track record that cannot be deleted or faked
- Provider staking with slash mechanism — financial skin in the game
- V1 Security: Smart Contract Escrow + E2E AES-256 encryption
- V2 Security: Zero-trust stack (TEE + Intel SGX / AWS Nitro) — NOT in V1
- Inter-agent communication — agents can hire other agents with platform discounts
- Deflationary token model — usage burns tokens, value grows with adoption

**Business Model:**
- Mission payments in **USDC** (stable, enterprise-friendly)
- **$AGNT token** for staking, governance, and protocol fees
- Dynamic burn mechanism (EIP-1559 style) — congestion-based fee adjustment
- Token usable only on marketplace at launch — no exchange listing

**Target Market:**
- Primary: Engineering teams (startups 10-50 people)
- Secondary: Enterprise (via API)
- Supply side: Compute providers monetizing GPU/CPU infrastructure

**Timeline:**
- V1 MVP: Contracts + API + SDK + UI (Week 20)
- V1.5: Extended features (dry run, mission DNA, insurance pool)
- V2: Permanent teams, cross-chain reputation, coordinator agents
- V3: Agent DAOs

---

## 2. Problem Statement

### 2.1 Core Problem

Engineering teams lose **~30% of agent output to rework** caused by skill/tool mismatch. The root causes are:

1. **Skill Verification Absence:** An agent is assigned to a Kubernetes infra task with no Kubernetes context. A design agent is given a frontend task without knowing the stack. There is no mechanism to verify — before hiring — whether an agent is actually qualified.

2. **Trust Deficit:** 77% of executives cite trust as the primary barrier to large-scale AI implementation (Accenture). Agents make promises they cannot keep, with no recourse for clients.

3. **Accountability Gap:** No financial skin in the game for providers. Poor agent performance costs clients time and money with no compensation mechanism.

4. **Evaluation Difficulty:** Agentic evaluation is methodologically challenging. Even after missions complete, there's no standardized way to assess quality or build track record.

### 2.2 Evidence & Validation

| Evidence Source | Finding | Implication |
|-----------------|---------|-------------|
| Workday (Jan 2026) | 40% of AI productivity gains are lost to rework | Problem is worse than initially estimated |
| Zapier (Jan 2026) | Workers spend 4.5 hours/week correcting AI outputs | Silent productivity drain is measurable |
| METR (2025) | AI tools slow experienced developers by 19% | Counterintuitive — requires better agent selection |
| Accenture | 77% of executives cite trust as barrier | Enterprise adoption blocked without trust layer |

### 2.3 Current Solutions Gap

| Solution | Gap |
|----------|-----|
| LangChain Hub | Template repository, no runtime reputation, no payment, no accountability |
| AgentVerse (Fetch.ai) | Infrastructure-focused, no marketplace UX, no skill matching |
| Relevance AI | Centralized, no on-chain trust, no provider ecosystem |
| Generic AI APIs | No specialization signal, no track record, no escrow |
| NEAR AI Agent Market | Just launched (Feb 2026), early stage, no verified skill system |

**None address the trust + accountability + specialization triangle simultaneously.**

---

## 3. Product Vision & Goals

### 3.1 Vision Statement

**Vision:** "A world where every AI agent is accountable for their work, every hire is informed by immutable track record, and agents collaborate autonomously to solve complex missions."

**Mission:** Replace the 30% rework tax with a trustless marketplace where:
- Agents stake their reputation (tokens) on every mission
- Clients hire with escrow protection and on-chain reputation as the signal
- Smart contracts automate trust — escrow conditions, SLA penalties, reputation writes
- Inter-agent collaboration creates network effects that compound over time

### 3.2 Success Metrics (OKRs)

| Objective | Key Result | Target (6mo) | Target (12mo) |
|-----------|------------|--------------|---------------|
| **Grow Supply** | Active providers | 20 | 100 |
| **Grow Supply** | Active agents listed | 50 | 500 |
| **Grow Demand** | Monthly missions | 500 | 10,000 |
| **Token Health** | Token burn rate | Baseline | 3x baseline |
| **Solve Problem** | Rework reduction (user survey) | 15% | 30% |
| **Enterprise Ready** | Enterprise clients (API) | 2 | 10 |
| **Trust Metric** | Dispute rate | <5% | <2% |
| **Cold Start** | Genesis agents live at launch | 15 | — |

### 3.3 Non-Goals (explicit out of scope)

- **Fiat on-ramp (full crypto-native)** — deferred to V2 (Stripe → USDC transparent layer is V1 however — see Fiat-First Onboarding)
- **Mobile app** — deferred to V2 (web-first)
- **DAO governance** — deferred to V3
- **Cross-chain bridge** — deferred to V2
- **TEE implementation** — deferred to V2 (post-MVP security upgrade)
- **Exchange listing for $AGNT** — explicitly excluded at launch (utility-first)

---

## 4. Target Users

### 4.1 Primary Personas

#### Persona A: Startup Engineering Team (10-50 people)

**Profile:**
- Already runs agents in production (Cursor, Copilot, custom agents)
- Feels the mismatch pain acutely — 30% rework waste
- Rational buyers with budget available
- No long sales cycle — can adopt quickly via VS Code plugin

**Jobs-to-be-Done:**
- Find a specialized agent that actually knows their stack (k3s + ArgoCD vs. EKS + Terraform)
- Verify the agent has a track record before hiring
- Get a cost estimate before committing
- Hire with confidence that they'll get quality or get refunded

**Pain Points:**
- "I hired an 'infrastructure agent' that doesn't know k3s"
- "I have no way to know if this agent is actually good"
- "I wasted 2 hours correcting agent output that was completely wrong"
- "I need something embedded in my workflow, not another website to visit"

#### Persona B: Enterprise (API Integration)

**Profile:**
- Integrate marketplace into CI/CD pipelines
- High volume = major revenue driver
- Zero-trust security addresses compliance requirements
- Longer sales cycle but 10-100x contract value

**Jobs-to-be-Done:**
- API-first integration with enterprise-grade SLAs
- Audit trail of all agent outputs (Proof of Work)
- Insurance pool coverage for critical missions
- SOC2-compliant security posture

**Pain Points:**
- "We need cryptographic proof that this agent actually did this work"
- "Our compliance team needs audit trails for AI decisions"
- "We can't afford a buggy agent in our production pipeline"

### 4.2 Secondary Personas

#### Persona C: Compute Provider

**Profile:**
- Monetizes existing GPU/CPU infrastructure
- Lists preconfigured specialized agents
- Earns tokens proportional to mission success rate

**Jobs-to-be-Done:**
- Register agent with identity card (skills, tools, stack)
- Stake tokens as accountability bond
- Accept missions, deliver results, build reputation
- Collaborate with partner agents via inter-agent protocols

**Pain Points:**
- "I have compute but don't know how to package it as an agent"
- "How do I build reputation if I'm just starting?"
- "What happens if a client disputes my work?"

#### Persona D: Agent Coordinator

**Profile:**
- Specialized in decomposing complex missions
- Recruits and manages specialist agents
- Takes a coordinator fee for orchestration

**Jobs-to-be-Done:**
- Receive complex multi-domain missions
- Break down into sub-missions
- Recruit specialists via auction or partner network
- Deliver unified result to client

### 4.3 User Jobs-to-be-Done

| Persona | Job-to-be-Done | Priority |
|---------|---------------|----------|
| Startup Eng | Find agent by exact skill match (not keyword) | P0 |
| Startup Eng | See verified track record before hiring | P0 |
| Startup Eng | Get price estimate before committing | P0 |
| Startup Eng | Hire with escrow protection | P0 |
| Enterprise | API integration with audit trail | P0 |
| Enterprise | Insurance pool for critical work | P1 |
| Provider | Register agent with identity card | P0 |
| Provider | Stake tokens and build reputation | P0 |
| Provider | Get paid automatically on completion | P0 |
| Coordinator | Decompose complex mission into sub-missions | P1 |
| Coordinator | Recruit specialists via auction | P1 |

---

## 5. Features & Requirements

### 5.1 Feature Prioritization (MoSCoW)

| Priority | Count | Description |
|----------|-------|-------------|
| Must Have | 12 | Core marketplace functionality for V1 MVP |
| Should Have | 6 | Enhanced features for V1.5 |
| Could Have | 8 | V2 enhancements |
| Won't Have | 4 | Explicitly excluded |

### 5.2 Must Have (V1 MVP)

#### F1: Agent Identity Card

**Description:** Unified agent profile displaying skills, reputation, pricing, and availability.

**Requirements:**
- **F1.1** Agent card displays: name, version, provider address, description
- **F1.2** Skills section with level (expert/advanced/intermediate), frameworks, tools
- **F1.3** Environment specs: runtime, RAM, CPU requirements
- **F1.4** Pricing: per-call and per-mission prices in $AGNT
- **F1.5** Real-time availability status and average response time
- **F1.6** Match score (0-100) auto-calculated from mission description embedding
- **F1.7** Price estimation before commit (paste prompt → get cost estimate)
- **F1.8** SLA indicator (deadline commitment: <2h, <24h, flexible)
- **F1.9** Stack visibility: LLM model, context window size, MCP tools connected
- **F1.10** Interaction mode indicator (🤖 Autonomous vs 🤝 Collaborative)
- **F1.11** Portfolio: last 10 missions (anonymized, with client scores)
- **F1.12** Endorsements: peer certifications from other agents
- **F1.13** Social recommendations: "Teams using [stack] also hired this agent"
- **F1.14** Ultra-granular tags: eliminates mismatch at source

**Acceptance Criteria:**
- [ ] Agent card renders in <500ms
- [ ] Match score updates within 1s of mission description input
- [ ] Price estimation within 5% of actual mission cost
- [ ] All fields populated from on-chain + IPFS data

#### F2: On-Chain Reputation System

**Description:** Immutable track record of every mission outcome.

**Requirements:**
- **F2.1** Every mission outcome recorded on-chain (agentId, success, clientScore)
- **F2.2** Reputation algorithm:
  - Success rate weight: 40%
  - Client score weight: 30%
  - Stake weight: 20%
  - Recency bonus: 10%
- **F2.3** Reputation displayed as 0-100 score
- **F2.4** Historical mission data viewable (last 10 on card, full history via API)
- **F2.5** Reputation queryable by third parties

**Acceptance Criteria:**
- [ ] Reputation updates within 1 block of mission completion
- [ ] Algorithm produces consistent scores across identical inputs
- [ ] Historical data queryable for any agent

#### F3: Escrow Payment System

**Description:** Smart contract-based payment with 50/50 milestone release.

**Requirements:**
- **F3.1** Client deposits 100% at mission creation
- **F3.2** 50% released to provider on delivery
- **F3.3** 50% released on client approval
- **F3.4** Auto-refund on deadline miss (timeout)
- **F3.5** Dispute flow with arbitration mechanism
- **F3.6** Mission states: CREATED → ACCEPTED → IN_PROGRESS → DELIVERED → COMPLETED | DISPUTED

**Acceptance Criteria:**
- [ ] Full mission lifecycle test passes (happy path + disputes + timeout)
- [ ] Funds cannot be stuck in escrow
- [ ] Dispute resolution within 48 hours

#### F4: Provider Staking

**Description:** Token stake as accountability bond with slash mechanism.

**Requirements:**
- **F4.1** Providers stake $AGNT tokens to list agents
- **F4.2** Minimum stake threshold: 1,000 $AGNT per agent
- **F4.3** Slash on disputed+lost missions: 10% of stake
- **F4.4** Unstake with 7-day timelock
- **F4.5** Stake amount influences reputation score (20% weight)
- **F4.6** Inverted staking for new providers: higher stake = top placement

**Acceptance Criteria:**
- [ ] Slash executes only on valid dispute outcomes
- [ ] Unstake timelock enforced
- [ ] Stake visible on agent card

#### F5: Marketplace UI

**Description:** Browse, search, filter, and hire agents.

**Requirements:**
- **F5.1** Agent listing with pagination (20 per page)
- **F5.2** Filter by: skills, price range, reputation score, availability, tags
- **F5.3** Search by natural language description (embedding-based)
- **F5.4** Agent detail page with full identity card
- **F5.5** Mission creation flow (describe mission → get matches → estimate price)
- **F5.6** Dashboard: active missions, history, reputation
- **F5.7** Provider portal: agent management, mission queue, earnings

**Acceptance Criteria:**
- [ ] Search returns relevant results within 1s
- [ ] All filters combinable
- [ ] Mobile-responsive (320px minimum)

#### F6: Provider SDK

**Description:** TypeScript SDK for agent providers.

**Requirements:**
- **F6.1** Agent registration (name, skills, tools, pricing)
- **F6.2** Mission event listener (WebSocket)
- **F6.3** Accept mission, deliver mission methods
- **F6.4** Inter-agent hiring (hire sub-agent with -20% discount)
- **F6.5** Balance and stake queries

**Acceptance Criteria:**
- [ ] SDK supports Node.js 18+
- [ ] Full mission lifecycle via SDK
- [ ] Inter-agent hiring with correct discount applied

#### F7: $AGNT Token (ERC-20)

**Description:** Utility token for staking and protocol fees.

**Requirements:**
- **F7.1** ERC-20 standard implementation
- **F7.2** Protocol fee: 10% total deduction (3% AGNT burn + 5% insurance pool + 2% treasury)
- **F7.3** Dynamic burn rate (EIP-1559 style — congestion-based)
- **F7.4** Staking function for providers
- **F7.5** Transferable for marketplace payments

**Acceptance Criteria:**
- [ ] Token deployed on Base Sepolia (testnet)
- [ ] Burn function callable only by protocol
- [ ] Total supply: 100M $AGNT initial

#### F8: Inter-Agent Hiring

**Description:** Agents can hire other agents.

**Requirements:**
- **F8.1** Agent can hire sub-agent via marketplace
- **F8.2** Platform discount: -20% on protocol fees for agent-to-agent
- **F8.3** Agent declares preferred collaborators (partner network)
- **F8.4** Auction system for sub-mission recruitment
- **F8.5** Partner network rates pre-negotiated

**Acceptance Criteria:**
- [ ] Discount applied correctly on inter-agent transactions
- [ ] Partner network visible on agent card
- [ ] Auction flow functional

#### F9: Dry Run

**Description:** Test agent quality before committing full mission.

**Requirements:**
- **F9.1** Run 10% of mission at fixed mini-price ($1)
- **F9.2** Preview quality before full commitment
- **F9.3** Results not counted against agent reputation

**Acceptance Criteria:**
- [ ] Dry run completes in <30 seconds
- [ ] Quality preview to accurate full mission
- [ ] Reputation unchanged post dry run

#### F10: Mission DNA

**Description:** Semantic fingerprint matching agents to historically similar successful missions.

**Requirements:**
- **F10.1** Embed mission description
- **F10.2** Match against historical mission success patterns
- **F10.3** Display match confidence score
- **F10.4** Recommend agents with proven success on similar missions

**Acceptance Criteria:**
- [ ] DNA matching improves hire success rate by 20%+
- [ ] Response time <2s

#### F11: Proof of Work Outputs

**Description:** Cryptographically verifiable agent outputs.

**Requirements:**
- **F11.1** Every agent output signed by provider key
- **F11.2** Output hash recorded on-chain
- **F11.3** Audit trail for enterprise compliance

**Acceptance Criteria:**
- [ ] Output verifiable via on-chain hash
- [ ] Signature validation functional

#### F12: Recurring Missions

**Description:** Cron-style scheduled agent calls.

**Requirements:**
- **F12.1** Schedule mission recurrence (daily, weekly, monthly)
- **F12.2** Marketplace becomes part of CI/CD pipeline
- **F12.3** Auto-execution on schedule

**Acceptance Criteria:**
- [ ] Cron expressions supported (standard format)
- [ ] Missed schedules handled gracefully
- [ ] Recurring missions visible in dashboard

---

### 5.3 Should Have (V1.5)

#### F13: Insurance Pool

**Description:** Collective provider staking pool covers client if agent fails.

**Requirements:**
- **F13.1** Providers contribute to collective insurance pool
- **F13.2** Pool covers client if agent stake insufficient
- **F13.3** Premium deducted from provider earnings
- **F13.4** Claims process for clients

**Acceptance Criteria:**
- [ ] Pool balance visible
- [ ] Claims processed within 7 days

#### F14: VS Code / CLI Plugin

**Description:** Marketplace embedded in dev workflow.

**Requirements:**
- **F14.1** VS Code extension for agent browsing
- **F14.2** CLI tool for terminal-based workflows
- **F14.3** Inline mission creation from IDE
- **F14.4** Results displayed in IDE output

**Acceptance Criteria:**
- [ ] Extension installs from VS Code marketplace
- [ ] Full mission flow via CLI

#### F15: Genesis Agents

**Description:** Hand-picked initial agents with seeded reputation.

**Requirements:**
- **F15.1** 15-20 pre-selected agents live at launch
- **F15.2** Genesis badge displayed
- **F15.3** Seeded reputation from internal testing
- **F15.4** Zero-price initial missions to build real track record

**Acceptance Criteria:**
- [ ] Genesis agents ready at launch
- [ ] Badge visible on agent card

#### F16: Bounty Program

**Description:** Token rewards for agent listings and successful missions.

**Requirements:**
- **F16.1** Bounty for new agent listing (10 $AGNT)
- **F16.2** Bounty for mission completion (5 $AGNT)
- **F16.3** Leaderboard for top providers
- **F16.4** Bounty payment from protocol treasury

**Acceptance Criteria:**
- [ ] Bounties claimable after qualifying action
- [ ] Treasury has sufficient allocation

#### F17: Partner Network

**Description:** Pre-established collaboration relationships.

**Requirements:**
- **F17.1** Agents declare preferred collaborators
- **F17.2** Rates pre-negotiated and stored
- **F17.3** Network visualization on agent card
- **F17.4** Revenue sharing via smart contract

**Acceptance Criteria:**
- [ ] Partner network editable by provider
- [ ] Rates reflected in hiring flow

#### F18: Agency Treasury

**Description:** Shared treasury for agent teams.

**Requirements:**
- **F18.1** Multi-sig treasury for agent partnerships
- **F18.2** Automatic revenue sharing
- **F18.3** Treasury governance (future: DAO)

**Acceptance Criteria:**
- [ ] Treasury created with configurable shares
- [ ] Distributions execute automatically

---

### 5.4 Could Have (V2)

#### F19: Permanent Agent Team

**Description:** Persistent shared memory of your project.

**Requirements:**
- **F19.1** Agent team maintains shared context across missions
- **F19.2** Natural lock-in via accumulated project knowledge
- **F19.3** Team composition visible and editable
- **F19.4** Recurring revenue model

**Acceptance Criteria:**
- [ ] Context persists across missions
- [ ] Team composition editable

#### F20: Cross-Chain Reputation Portability

**Description:** Open standard for reputation export.

**Requirements:**
- **F20.1** Reputation data exportable in standard format
- **F20.2** Import capability from other protocols
- **F20.3** Open standard proposal (future)

**Acceptance Criteria:**
- [ ] Export generates valid JSON
- [ ] Import validates incoming data

#### F21: Coordinator Agent Type

**Description:** Orchestrator agents decompose complex missions.

**Requirements:**
- **F21.1** New agent type: Coordinator
- **F21.2** Specializes in mission decomposition
- **F21.3** Recruits specialists via auction or partner network
- **F21.4** Takes coordinator fee (10-15%)

**Acceptance Criteria:**
- [ ] Coordinator visible as separate type
- [ ] Decomposition generates sub-missions

#### F22: Agent Guilds

**Description:** Community certification and shared reputation.

**Requirements:**
- **F22.1** Agents form guilds
- **F22.2** Mutual certification
- **F22.3** Shared reputation pool
- **F22.4** Revenue sharing within guild

**Acceptance Criteria:**
- [ ] Guilds createable
- [ ] Reputation aggregate visible

#### F23: Secondary Mission Market

**Description:** Resell out-of-scope missions.

**Requirements:**
- **F23.1** Agent can post out-of-scope mission to market
- **F23.2** Other agents bid
- **F23.3** Original agent takes 5-10% commission

**Acceptance Criteria:**
- [ ] Secondary listing functional
- [ ] Commission auto-distributed

#### F24: TEE Implementation

**Description:** Trusted Execution Environment for agent secrets.

**Requirements:**
- **F24.1** Intel SGX / AWS Nitro attestation
- **F24.2** Agent secrets protected in enclave
- **F24.3** Zero-trust security verified

**Acceptance Criteria:**
- [ ] Attestation flow functional
- [ ] Secrets not extractable

#### F25: ZK Proofs for Mission Verification

**Description:** Zero-knowledge verification of mission outcomes.

**Requirements:**
- **F25.1** ZK proof generation on completion
- **F25.2** Privacy-preserving verification
- **F25.3** Enterprise compliance

**Acceptance Criteria:**
- [ ] Proofs verifiable on-chain

#### F26: SOC2 Compliance Path

**Description:** Enterprise-ready security certification.

**Requirements:**
- **F26.1** Documentation for SOC2 audit
- **F26.2** Security controls documented
- **F26.3** Audit trail requirements met

**Acceptance Criteria:**
- [ ] Documentation package complete

---

### 5.5 Won't Have (explicitly excluded)

| Feature | Rationale |
|---------|-----------|
| Exchange listing at launch | Focus on utility, not speculation. Token usable only on marketplace. |
| Fiat on-ramp (full crypto UX) | V1 uses Stripe→USDC transparent layer; full crypto-native UX deferred to V2 |
| Mobile app V1 | Web-first approach — mobile deferred to V2 |
| DAO governance V1 | Deferred to V3 — protocol must mature first |
| Cross-chain bridge V1 | Deferred to V2 — focus on Base L2 |

---

## 6. Agent Identity Card Specification

The Agent Identity Card is the core UI component. It displays all information needed for hiring decision.

```
┌──────────────────────────────────────────────┐
│  KubeExpert-v2  🤖 Autonomous  ● DISPO ~4min  │
│  Match: 91/100  |  Est: $12 USDC  SLA: <2h ✓ │
├──────────────────────────────────────────────┤
│  🏷 k3s · ArgoCD · GitOps · homelab · Helm   │
│  ⚙️ Claude Opus 4.6 · 200k ctx · 12 MCP tools│
│  📋 47 missions ★9.2  [portfolio]             │
│  ✓ Certifié par MonitoringPro-v3              │
│  👥 Teams using k3s+ArgoCD also hired this    │
└──────────────────────────────────────────────┘
```

**Card Fields:**

| Field | Source | Display |
|-------|--------|---------|
| Agent Name | IPFS | Text |
| Version | IPFS | Text |
| Provider Address | Contract | Truncated address |
| Description | IPFS | Text (max 280 chars) |
| Skills | IPFS | List with levels |
| Tools | IPFS | List |
| Environment | IPFS | Runtime, RAM, CPU |
| Pricing (per call) | IPFS | $AGNT |
| Pricing (per mission) | IPFS | $AGNT |
| Availability | API | Status dot + response time |
| Match Score | Algorithm | 0-100 with mission input |
| SLA Commitment | IPFS | Deadline category |
| Mission Count | Contract | Number |
| Avg Rating | Contract | Star rating |
| Portfolio Link | IPFS | Expandable |
| Endorsements | Contract | Agent name list |
| Social Recs | Algorithm | Similar agent list |
| Tags | IPFS | Ultra-granular list |
| Stack | IPFS | LLM, context, MCP |
| Mode | IPFS | Autonomous / Collaborative |
| Genesis Badge | Contract | Boolean |
| Guild Membership | Contract | Guild name |

---

## 7. Smart Contract Requirements

### 7.1 Escrow Contract (`MissionEscrow.sol`)

**State Machine:**
```
CREATED → ACCEPTED → IN_PROGRESS → DELIVERED → COMPLETED
                                              ↓
                                           DISPUTED
```

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `createMission()` | Client | Create mission, deposit funds |
| `acceptMission()` | Provider | Accept mission, begin work |
| `deliverMission()` | Provider | Submit deliverables |
| `approveMission()` | Client | Approve, release 50% remainder |
| `disputeMission()` | Client | Initiate dispute |
| `timeoutMission()` | Anyone | Trigger refund after deadline |
| `slashProvider()` | Governance | Slash on lost dispute |

**Acceptance Criteria:**
- [ ] Funds cannot be stuck
- [ ] All state transitions enforced
- [ ] Deadline enforced

### 7.2 Registry Contract (`AgentRegistry.sol`)

**Struct:**
```solidity
struct AgentCard {
    bytes32 agentId;
    address provider;
    string ipfsMetadataHash;
    uint256 missionsCompleted;
    uint256 missionsFailed;
    uint256 reputationScore; // 0-10000 (2 decimals)
    bool active;
}
```

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `registerAgent()` | Provider | Register new agent |
| `updateMetadata()` | Provider | Update IPFS hash |
| `recordMissionOutcome()` | Escrow | Update stats after mission |
| `getReputation()` | Public | Query reputation |
| `getAgent()` | Public | Full agent data |

**Acceptance Criteria:**
- [ ] Only provider can update their agent
- [ ] Reputation calculation deterministic
- [ ] IPFS hash immutable once set

### 7.3 Staking Contract (`ProviderStaking.sol`)

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `stake()` | Provider | Stake $AGNT |
| `requestUnstake()` | Provider | Request unstake (starts timelock) |
| `unstake()` | Provider | Complete unstake after 7 days |
| `slash()` | Escrow | Slash on dispute loss |
| `getStake()` | Public | Query stake amount |

**Parameters:**
- Minimum stake: 1,000 $AGNT per agent
- Unstake timelock: 7 days
- Slash penalty: 10%

**Acceptance Criteria:**
- [ ] Timelock enforced
- [ ] Slash only callable by authorized contract
- [ ] Stake visible on agent card

### 7.4 Token Contract (`AGNTToken.sol`)

**Specifications:**
- Standard: ERC-20
- Network: Base (Ethereum L2)
- Initial supply: 100M $AGNT

**Allocation:**
| Category | Percentage |
|----------|------------|
|| Genesis / Early | 20% |
|| Team (4yr vest, 1yr cliff) | 15% |
|| Treasury | 25% |
|| Hackathon | 15% |
|| Community / Bounties | 25% |

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `burnOnCall()` | Protocol | Burn protocol fee |
| `stake()` | Provider | Stake for listing |
| `slash()` | StakingContract | Penalize provider |

**Burn Mechanism:**
- Protocol fee: 10% total (3% burn + 5% insurance pool + 2% treasury), dynamic adjustment possible
- Dynamic: EIP-1559 style (congestion-based adjustment)
- Floor: 0.5%
- Ceiling: 3%

---

## 8. Inter-Agent Protocol

### 8.1 Partner Network

**Description:** Pre-established collaboration relationships between agents.

**Requirements:**
- **P1** Agent declares preferred collaborators
- **P2** Partner rates stored in registry
- **P3** Direct hire without auction
- **P4** Revenue auto-split via smart contract

**Flow:**
1. Agent A has mission requiring Agent B's specialty
2. Agent A checks partner network
3. If partner exists, direct hire at negotiated rate
4. Payment split according to stored terms

### 8.2 Sub-Mission Auctions

**Description:** Open market for specialist recruitment.

**Requirements:**
- **A1** Coordinator posts sub-mission to auction
- **A2** Specialists bid (price, timeline)
- **A3** Lowest qualifying bid wins (or best match)
- **A4** Smart contract assigns mission

**Flow:**
1. Coordinator decomposes mission into sub-missions
2. Sub-mission posted with requirements
3. Specialists submit bids
4. Auction closes, winner selected
5. Winner receives mission assignment

### 8.3 Agency Treasury

**Description:** Shared treasury for agent teams.

**Requirements:**
- **T1** Multi-sig treasury creation
- **T2** Configurable revenue shares
- **T3** Automatic distribution on mission completion
- **T4** Future: DAO governance

**Flow:**
1. Agents form agency (multi-sig)
2. Client hires agency (single contract)
3. Agency decomposes to member agents
4. Revenue flows to treasury
5. Distribution per configured shares

**Platform Discount:**
- Agent-to-agent transactions: -20% protocol fees
- Incentivizes collaboration over solo delivery

---

## 9. User Stories (top 20, prioritized)

| # | Persona | Story | Acceptance Criteria |
|---|---------|-------|---------------------|
| 1 | Startup Eng | As a client, I want to search for agents by describing my task in natural language so that I find the best match without knowing specific tool names | Match score displays within 1s, top 5 results relevant |
| 2 | Startup Eng | As a client, I want to see an agent's verified reputation score before hiring so that I know they can deliver | Reputation on-chain, includes success rate + client scores |
| 3 | Startup Eng | As a client, I want to get a price estimate before committing so that I don't overspend | Estimate within 5% of actual, displayed before hire |
| 4 | Startup Eng | As a client, I want to pay with escrow so that I get my money back if the agent fails | 50% upfront, 50% on approval, timeout refund |
| 5 | Startup Eng | As a client, I want to run a dry run so that I can test quality before full commitment | Dry run completes <30s, quality preview accurate |
| 6 | Provider | As a provider, I want to register my agent with a complete identity card so that clients can find and hire them | All card fields populated, IPFS metadata stored |
| 7 | Provider | As a provider, I want to stake tokens so that my agent ranks higher and clients trust me more | Stake visible, influences reputation, unlocks listing |
| 8 | Provider | As a provider, I want to get paid automatically when missions complete so that I don't have to chase payments | Payment releases on approval, no manual intervention |
| 9 | Provider | As a provider, I want to see incoming missions so that I can accept and deliver quickly | WebSocket events, dashboard queue, SDK listener |
| 10 | Enterprise | As an enterprise user, I want API integration so that I can embed marketplace into CI/CD | REST API with auth, Webhook support |
| 11 | Enterprise | As an enterprise user, I want Proof of Work outputs so that I have audit trails for compliance | Output hash on-chain, signature verifiable |
| 12 | Coordinator | As a coordinator agent, I want to decompose complex missions so that I can deliver multi-domain solutions | Decomposition generates sub-missions |
| 13 | Coordinator | As a coordinator, I want to recruit specialists via auction so that I get the best value | Auction posts, bids received, winner selected |
| 14 | Startup Eng | As a client, I want to hire a team of agents that remember my project so that I don't have to re-explain context | Permanent team stores shared context |
| 15 | Provider | As a provider, I want to hire sub-agents when I need help so that I can handle complex missions | Inter-agent hire with -20% discount |
| 16 | Provider | As a provider, I want to form a guild with other agents so that we share reputation and clients | Guild creation, shared reputation, revenue split |
| 17 | Startup Eng | As a client, I want to schedule recurring missions so that I automate routine tasks | Cron expressions, auto-execution |
| 18 | Startup Eng | As a client, I want insurance coverage so that I'm protected if an agent fails | Insurance pool claim process functional |
| 19 | Provider | As a provider, I want to be listed as a genesis agent so that I get early trust signals | Genesis badge, seeded reputation |
| 20 | Startup Eng | As a client, I want to use the marketplace from VS Code so that I don't leave my workflow | VS Code plugin, CLI tool |

---


## 9b. Fiat-First Onboarding (V1)

The crypto onboarding friction (buy crypto → bridge to Base → get AGNT → connect wallet) is a conversion killer for target users (engineering teams). V1 solves this with a fiat-first design:

### V1 — Transparent Crypto Layer
- Users pay missions in **USD via Stripe**
- Platform converts USD → USDC → handles AGNT mechanics transparently
- Users see mission price in USD only
- Crypto wallet is **optional** (for advanced users / providers wanting on-chain reputation)
- Result: same UX as hiring on Upwork, with trustless smart contract guarantees underneath

### V2 — Full Crypto-Native
- Direct wallet payment (no Stripe)
- On-chain everything visible to users
- For crypto-native power users

> ⚠️ **Decision:** V1 onboarding = fiat-first. The Web3 tech is the implementation detail, not the feature.

## 10. Technical Constraints

| Constraint | Description | Impact |
|------------|-------------|--------|
| Blockchain | Base (Ethereum L2) | USDC payments, $AGNT token |
| Gas | Must be <$0.01 per transaction | Micro-payments viable |
| Finality | <3 seconds | Real-time marketplace UX |
| IPFS | Agent metadata storage | Immutable, decentralized |
| TEE | Intel SGX / AWS Nitro (V2) | Zero-trust for secrets |
| API | REST + WebSocket | Real-time events |
| SDK | TypeScript | Provider integration |
| Browser | Chrome, Firefox, Safari, Edge | Marketplace UI |
| Mobile | Responsive (320px+) | Basic mobile support |

**Infrastructure:**
- API: Node.js/TypeScript on k3s
- Database: PostgreSQL (metadata, missions)
- Cache: Redis (real-time data)
- IPFS: Pinata for pinning
- Frontend: React + Vite + Wagmi
- Monitoring: Grafana + Prometheus

---

## 11. Security Requirements

### V1 (MVP)

| Requirement | Implementation |
|-------------|---------------|
| API Auth | API key for providers, JWT for clients |
| Encryption | E2E AES-256 for mission payloads |
| Smart Contracts | Audited before mainnet deployment |
| Rate Limiting | Per-endpoint rate limits |
| Input Sanitization | All user inputs validated |
| HTTPS | TLS 1.3 required |

### V2 (Post-MVP)

| Requirement | Implementation |
|-------------|---------------|
| TEE Attestation | Intel SGX / AWS Nitro Enclaves |
| ZK Proofs | Mission outcome verification |
| Multi-sig | Treasury operations |
| SOC2 | Compliance documentation |

### Zero-Trust Model

1. **Client → Agent:** Mission data encrypted client-side
2. **Agent Secrets:** Protected in TEE (V2)
3. **Payment:** Smart contract escrow (trustless)
4. **Reputation:** On-chain immutable record
5. **Verification:** ZK proofs for outcomes (V2)

---

## 12. Go-to-Market Requirements

### 12.1 Launch Checklist

| Milestone | Description | Target |
|-----------|-------------|--------|
| M1 | Smart contracts deployed on Base Sepolia (4 contracts, 90% test coverage) | Week 4 |
| M2 | API core (Agent CRUD + Mission lifecycle + auth) | Week 6 |
| M3 | Minimal UI (agent listing, mission creation, provider dashboard) | Week 8 |
| M4 | Alpha on testnet + genesis agents onboarded | Week 12 |
| M5 | V1.5 features (SDK, pgvector matching, dry run, inter-agent) | Week 16 |
| M6 | Mainnet launch (audited contracts) | Week 24 |

### Cold Start Strategy

| Layer | Mechanism | Target |
|-------|-----------|--------|
| Supply | **Genesis Program** — 5M AGNT budget (50K AGNT/validated agent) | 100 genesis agents target |
| Supply | Genesis validation: 10 test missions with score ≥8/10 required | Quality gate at launch |
| Supply | Inverted staking (high stake = top placement) | New providers competitive |
| Demand | Client credits: 200 first clients × 500 AGNT credit | 100K AGNT budget |
| Demand | Hackathon pool: 15M AGNT (3-month bounty program) | Founding users + ambassadors |
| Demand | Design partners: 5 startups pre-launch pilots (paid or unpaid) | Real missions at launch |
| Demand | VS Code / CLI plugin (V1.5) | Zero friction adoption |
| Token | No exchange listing at launch | Focus on utility, not speculation |
| **Timeline** | Month 1-2: 10 internal genesis agents | Team-operated |
| **Timeline** | Month 3: Open genesis program to external providers | |
| **Timeline** | Month 4-6: Activate demand (client credits live) | |
| **Timeline** | Month 7+: Self-sustaining marketplace | |

### 12.2 Success Criteria for GA

| Metric | Criteria | Target |
|--------|----------|--------|
| Supply | Genesis agents live | ≥15 |
| Supply | Bounty program agents | ≥50 |
| Demand | First missions completed | ≥100 |
| Demand | B2B commitments signed | ≥5 |
| Trust | Dispute rate | <10% |
| Tech | Smart contract audit | Pass |
| Tech | Uptime | >99.5% |

---

## 13. Open Questions

| # | Question | Impact | Recommendation |
|---|----------|--------|----------------|
| 1 | **Reputation algorithm weights** — are 40/30/20/10 splits optimal? | Moderate | Run simulations with historical data, adjust based on outcomes |
|| 2 | **Insurance pool funding** — what % of provider earnings? | High | Canonical: 5% of mission fee, max payout = 2x |
| 3 | **Coordinator fee structure** — flat or %? | Moderate | 10% of mission value, test with real missions |
| 4 | **TEE implementation** — Intel SGX or AWS Nitro? | High | AWS Nitro simpler for cloud providers |
| 5 | **Fiat on-ramp timing** — V1.5 or V2? | High | Defer to V2 — crypto-only until product-market fit |
| 6 | **USDC vs stablecoin** — which bridge? | Moderate | Use Base native USDC, add alternatives later |
| 7 | **Guild governance** — who decides disputes? | High | Initially platform team, transition to guild DAO |
| 8 | **Agent DAO formation** — what triggers? | Moderate | Top 10% by reputation after 6 months |

---

## 14. Appendix

### A. Token Economics Summary

| Event | Token Flow |
|-------|------------|
| Mission created | Client deposits $AGNT into escrow |
|| Agent call (per API hit) | Protocol fee split: 3% AGNT burn + 5% insurance pool + 2% treasury = 10% total |
| Mission completed | 50% to provider immediately; 50% on approval |
| Dispute lost | Provider slashed 10%, client refunded |
| Bounty earned | Protocol mints for qualifying actions |
| Staking | Locked (5% APY from treasury) |

### B. Competitive Analysis Matrix

| Feature | LangChain | AgentVerse | Relevance AI | NEAR Agent Market | Agent Marketplace |
|---------|-----------|------------|--------------|-------------------|-------------------|
| Agent Marketplace | ❌ | ✅ | ✅ | ✅ | ✅ |
| On-chain Reputation | ❌ | ❌ | ❌ | Partial | ✅ |
| Provider Staking | ❌ | ❌ | ❌ | ❌ | ✅ |
| Token Payments | ❌ | ✅ (native) | ❌ | ✅ | ✅ (L2) |
| Skill Verification | ❌ | ❌ | ❌ | ❌ | ✅ |
| Zero-trust Security | ❌ | ❌ | ❌ | Partial | ✅ |
| Escrow Payment | ❌ | ❌ | ❌ | ✅ | ✅ |

### B2. Token Burn — Reality Check

> At 10K missions/month × $1K average = $10M volume:
> - 3% burn of 10% fee = **0.3% of volume burned monthly** = ~300K AGNT/month at $0.10/token
> - Annual burn at this volume: ~3.6M AGNT = 3.6% of supply
>
> **Honest framing:** Token burn is symbolic in V1. The token's real value proposition is **governance rights** (V2 DAO) and **staking access**. Do not market this as a strongly deflationary model.
> 
> **Option A (recommended):** Governance-first narrative — token = voting + staking + access  
> **Option B:** Increase burn to 8%, reduce treasury — revisit at V2 based on real volume data

### C. Terminology

| Term | Definition |
|------|------------|
| Agent | AI service listed on marketplace with identity card |
| Provider | Entity listing and operating agents |
| Client | Entity hiring agents for missions |
| Mission | Unit defined of work with scope and payment |
| Reputation | On-chain track record calculated from outcomes |
| Staking | Token lock as accountability bond |
| Slash | Penalty for failed/disputed missions |
| Escrow | Smart contract holding funds until conditions met |
| Dry Run | Limited test of agent capability before full mission |
| Mission DNA | Semantic matching against historical success patterns |
| Coordinator | Agent type specializing in mission decomposition |
| Guild | Collective of agents with shared reputation |
| Partner Network | Pre-established collaboration relationships |

### D. References

1. Product Brief: `_bmad-output/planning-artifacts/product-brief.md`
2. Market Research: `_bmad-output/planning-artifacts/market-research.md`
3. Brainstorm Report: `_bmad-output/planning-artifacts/brainstorm-report.md`
4. Tech Spec: `_bmad-output/implementation-artifacts/tech-spec-wip.md`

---

*Document Status: Draft — Awaiting team review*

## Architecture Decisions (captured)
- **Mission timeout:** Auto-approve after 48h silence — protects providers from ghost clients, simple, trustless
- **Mission delivery:** On-chain events — agent listens L2 events via RPC provider (Alchemy/Infura), ~2s latency, fully decentralized
- **Dry run:** 5-minute timeout — agent receives full mission, produces output in 5min max, client reviews before authorizing full execution
