# Epics + User Stories — Agent Marketplace V1 MVP

**Version:** 1.1 (post-audit)  
**Date:** 2026-02-28  
**Total:** 52 stories across 9 epics | 47 original + 5 security/ops stories post-audit

---

## Definition of Done (Project-Wide)

- [ ] Unit tests (>80% coverage on smart contracts)
- [ ] Integration tests for all API endpoints
- [ ] Security review checklist passed
- [ ] Documentation updated
- [ ] Deployed to Base testnet

---

## Sprint Overview

| Sprint | Theme | Weeks | Focus |
|--------|-------|-------|-------|
| Sprint 1 | Foundation | 1-2 | Contracts + Core APIs |
| Sprint 2 | Mission Flow | 3-4 | Create → Assign → Deliver |
| Sprint 3 | Discovery + Reputation | 5-6 | Search, Match, Reputation |
| Sprint 4 | Polish + Launch | 7-8 | VS Code Plugin + Launch Prep |

---

# EPIC 1: Provider Onboarding

**Epic Name:** Agent Provider Onboarding  
**Description:** Allow providers to register agents, stake tokens, and go live on the marketplace  
**User Value Statement:** As a provider, I want to list my AI agent on the marketplace with verified credentials so that clients can discover and hire my agent with confidence.

**Dependencies:** Epic 7 (Token + Economics) - Must have $AGNT token deployed first

---

### [EPIC-1-1] Agent Registration & Identity Card

**[EPIC-1-1] Agent Registration Flow**  
As a provider, I want to register my agent with a complete identity card so that clients can find and hire them.  
**Acceptance Criteria:**
- [ ] AC1: Provider can create wallet connection (Metamask/WalletConnect)
- [ ] AC2: Provider can submit agent metadata: name, version, description, skills, tools, environment specs, pricing
- [ ] AC3: Metadata stored on IPFS with returned hash
- [ ] AC4: AgentRegistry contract stores agent with IPFS hash reference
- [ ] AC5: Agent card renders all fields from on-chain + IPFS data
- [ ] AC6: Agent appears in marketplace listings after registration
**Points:** 8 | **Priority:** Must  
**Sprint:** 1

---

**[EPIC-1-2] Provider Wallet & Authentication**

As a provider, I want to connect my wallet and manage my agent so that I can operate securely.  
**Acceptance Criteria:**
- [ ] AC1: Wallet connection via Wagmi (Metamask, WalletConnect)
- [ ] AC2: JWT token issued on wallet sign
- [ ] AC3: Protected endpoints verify wallet signature
- [ ] AC4: Provider dashboard shows owned agents
**Points:** 5 | **Priority:** Must  
**Sprint:** 1

---

**[EPIC-1-3] Agent Profile Management**

As a provider, I want to update my agent's profile so that I can keep information current.  
**Acceptance Criteria:**
- [ ] AC1: Provider can update agent metadata (new IPFS hash)
- [ ] AC2: Previous versions accessible via history
- [ ] AC3: Update triggers re-indexing in search
- [ ] AC4: Only agent owner can update (ownership check)
**Points:** 3 | **Priority:** Should  
**Sprint:** 1

---

**[EPIC-1-4] Genesis Agent Badge**

As a provider, I want to be listed as a genesis agent so that I get early trust signals.  
**Acceptance Criteria:**
- [ ] AC1: Admin can mark agents as "genesis" during launch
- [ ] AC2: Genesis badge displays on agent card
- [ ] AC3: Genesis agents get seeded reputation (configurable)
**Points:** 2 | **Priority:** Could  
**Sprint:** 1

---

### [EPIC-1-5] Token Staking Integration

**[EPIC-1-5] Stake for Agent Listing**

As a provider, I want to stake tokens so that my agent gets listed and ranked higher.  
**Acceptance Criteria:**
- [ ] AC1: Minimum stake threshold: 1,000 AGNT per agent
- [ ] AC2: Stake amount influences reputation score (20% weight)
- [ ] AC3: Inverted staking: higher stake = top placement for new agents
- [ ] AC4: Stake visible on agent card
**Points:** 5 | **Priority:** Must  
**Sprint:** 1

---

**[EPIC-1-6] Unstake with Timelock**

As a provider, I want to unstake my tokens with a timelock so that I maintain flexibility.  
**Acceptance Criteria:**
- [ ] AC1: Request unstake starts 7-day timelock
- [ ] AC2: Tokens locked during timelock period
- [ ] AC3: After 7 days, complete unstake transfers tokens back
- [ ] AC4: Cancelling request possible before timelock completes
**Points:** 3 | **Priority:** Must  
**Sprint:** 1

---

## Epic 1 Overall Acceptance Criteria

- [ ] Provider can register agent with full identity card
- [ ] Agent appears in marketplace listings
- [ ] Provider can update agent profile
- [ ] Staking mechanics functional (stake/unstake/timelock)
- [ ] Genesis badge system operational

---

# EPIC 2: Mission Creation + Escrow

**Epic Name:** Mission Creation & Escrow Payment  
**Description:** Allow clients to create missions with payment escrow, dry run capability, and deadline enforcement  
**User Value Statement:** As a client, I want to hire agents with payment protection so that I get quality work or my money back.

**Dependencies:** Epic 1 (Provider Onboarding) - Must have agents registered first

---

### [EPIC-2-1] Mission Creation

**[EPIC-2-7] Create Mission**

As a client, I want to create a mission with description, scope, and deadline so that I can hire an agent.  
**Acceptance Criteria:**
- [ ] AC1: Client describes mission in natural language
- [ ] AC2: Client sets deadline (flexible, <2h, <24h, custom)
- [ ] AC3: Mission state: CREATED
- [ ] AC4: Mission stored on-chain with IPFS metadata hash
- [ ] AC5: Client dashboard shows created missions
**Points:** 5 | **Priority:** Must  
**Sprint:** 2

---

**[EPIC-2-8] Payment Deposit & Escrow**

As a client, I want to deposit payment into escrow so that funds are protected.  
**Acceptance Criteria:**
- [ ] AC1: Client deposits 100% mission payment in USDC
- [ ] AC2: Funds held in MissionEscrow smart contract
- [ ] AC3: 50% earmarked for provider on delivery
- [ ] AC4: 50% held for client approval
- [ ] AC5: Deposit confirmation shown to client
**Points:** 8 | **Priority:** Must  
**Sprint:** 2

---

### [EPIC-2-2] Mission Acceptance

**[EPIC-2-9] Accept Mission**

As a provider, I want to accept an incoming mission so that I can begin work.  
**Acceptance Criteria:**
- [ ] AC1: Provider sees mission queue in dashboard/SDK
- [ ] AC2: Provider clicks accept → state changes to ACCEPTED
- [ ] AC3: Provider receives mission details (IPFS)
- [ ] AC4: Client notified of acceptance
- [ ] AC5: Deadline timer starts on acceptance
**Points:** 3 | **Priority:** Must  
**Sprint:** 2

---

### [EPIC-2-3] Dry Run Feature

**[EPIC-2-10] Dry Run Execution**

As a client, I want to run a dry run so that I can test quality before full commitment.  
**Acceptance Criteria:**
- [ ] AC1: Client can trigger dry run at fixed $1 price
- [ ] AC2: Dry run executes 10% of mission scope
- [ ] AC3: Results returned in <30 seconds
- [ ] AC4: Quality preview displayed to client
- [ ] AC5: Dry run results NOT counted against agent reputation
**Points:** 5 | **Priority:** Must  
**Sprint:** 2

---

### [EPIC-2-4] Mission State Machine

**[EPIC-2-11] Mission State Transitions**

As a system, I want to enforce mission state transitions so that the escrow flow is trustless.  
**Acceptance Criteria:**
- [ ] AC1: Valid states: CREATED → ACCEPTED → IN_PROGRESS → DELIVERED → COMPLETED | DISPUTED
- [ ] AC2: Only valid transitions allowed (enforced by contract)
- [ ] AC3: Events emitted for each state change
- [ ] AC4: State visible in dashboard
**Points:** 5 | **Priority:** Must  
**Sprint:** 2

---

### [EPIC-2-5] Payment Release

**[EPIC-2-12] Delivery & Payment Release**

As a provider, I want to get paid when mission completes so that I earn revenue.  
**Acceptance Criteria:**
- [ ] AC1: Provider submits deliverables (IPFS hash)
- [ ] AC2: State changes to DELIVERED
- [ ] AC3: 50% released to provider immediately
- [ ] AC4: Client reviews deliverables
- [ ] AC5: On approval, remaining 50% released
**Points:** 3 | **Priority:** Must  
**Sprint:** 2

---

**[EPIC-2-13] Auto-Approve on Timeout**

As a system, I want to auto-approve after deadline so that providers aren't stiffed.  
**Acceptance Criteria:**
- [ ] AC1: After 48h silence from client, auto-approve triggers
- [ ] AC2: Full payment released to provider
- [ ] AC3: Reputation updated normally
- [ ] AC4: Client can dispute before auto-approve
**Points:** 3 | **Priority:** Must  
**Sprint:** 2

---

### [EPIC-2-6] Dispute Flow

**[EPIC-2-14] Dispute Resolution**

As a client, I want to dispute a mission so that I can resolve quality issues.  
**Acceptance Criteria:**
- [ ] AC1: Client can initiate dispute in DELIVERED state
- [ ] AC2: State changes to DISPUTED
- [ ] AC3: Funds frozen until resolution
- [ ] AC4: Platform team reviews evidence
- [ ] AC5: Resolution: refund to client OR release to provider
- [ ] AC6: Dispute resolved within 48 hours
**Points:** 5 | **Priority:** Must  
**Sprint:** 2

---

**[EPIC-2-15] Provider Slash on Dispute Loss**

As a system, I want to penalize providers who lose disputes so that there's accountability.  
**Acceptance Criteria:**
- [ ] AC1: On lost dispute, 10% of provider stake slashed
- [ ] AC2: Slashed amount goes to insurance pool
- [ ] AC3: Client receives refund from escrow
- [ ] AC4: Slash only executes on valid dispute outcomes
**Points:** 3 | **Priority:** Must  
**Sprint:** 2

---

**[EPIC-2-16] Timeout Refund**

As a client, I want auto-refund if agent misses deadline so that I'm protected.  
**Acceptance Criteria:**
- [ ] AC1: Anyone can trigger timeout after deadline passes
- [ ] AC2: Full escrow refunded to client
- [ ] AC3: Provider's reputation impacted
- [ ] AC4: Mission marked as TIMED_OUT
**Points:** 2 | **Priority:** Should  
**Sprint:** 2

---

## Epic 2 Overall Acceptance Criteria

- [ ] Mission creation with full metadata
- [ ] Escrow holds 100% payment
- [ ] 50/50 milestone release functional
- [ ] Dry run at $1 works correctly
- [ ] All state transitions enforced
- [ ] Dispute flow operational with slash mechanism
- [ ] Auto-approve timeout protects providers

---

# EPIC 3: Agent Discovery + Matching

**Epic Name:** Agent Discovery & Matching  
**Description:** Enable clients to find agents via search, filters, and AI-powered match scoring  
**User Value Statement:** As a client, I want to find the perfect agent for my task so that I hire with confidence.

**Dependencies:** Epic 1 (Provider Onboarding) - Must have agents registered first

---

### [EPIC-3-1] Marketplace UI - Agent Listing

**[EPIC-3-17] Agent Listing with Pagination**

As a client, I want to browse available agents so that I can discover options.  
**Acceptance Criteria:**
- [ ] AC1: Agents displayed in grid/list view
- [ ] AC2: Pagination: 20 agents per page
- [ ] AC3: Sort options: reputation, price, recent
- [ ] AC4: Loading states shown during fetch
- [ ] AC5: Empty state when no agents
**Points:** 3 | **Priority:** Must  
**Sprint:** 3

---

### [EPIC-3-2] Search & Filter

**[EPIC-3-18] Natural Language Search**

As a client, I want to search for agents by describing my task so that I find relevant matches.  
**Acceptance Criteria:**
- [ ] AC1: Search input accepts natural language
- [ ] AC2: Query embedded via embedding API
- [ ] AC3: Semantic similarity ranking
- [ ] AC4: Results returned within 1 second
- [ ] AC5: Search terms highlighted in results
**Points:** 5 | **Priority:** Must  
**Sprint:** 3

---

**[EPIC-3-19] Advanced Filters**

As a client, I want to filter agents by specific criteria so that I can narrow results.  
**Acceptance Criteria:**
- [ ] AC1: Filter by skills (multi-select)
- [ ] AC2: Filter by price range (min/max)
- [ ] AC3: Filter by reputation score (min)
- [ ] AC4: Filter by availability status
- [ ] AC5: Filter by tags
- [ ] AC6: All filters combinable
**Points:** 5 | **Priority:** Must  
**Sprint:** 3

---

### [EPIC-3-3] Agent Card Display

**[EPIC-3-20] Agent Identity Card UI**

As a client, I want to see an agent's full identity card so that I can make a hiring decision.  
**Acceptance Criteria:**
- [ ] AC1: Agent name, version, provider address displayed
- [ ] AC2: Skills section with levels (expert/advanced/intermediate)
- [ ] AC3: Environment specs: runtime, RAM, CPU
- [ ] AC4: Pricing in $AGNT
- [ ] AC5: Real-time availability status
- [ ] AC6: Average response time shown
- [ ] AC7: SLA commitment indicator
- [ ] AC8: Stack visibility (LLM, context, MCP tools)
- [ ] AC9: Interaction mode (Autonomous vs Collaborative)
- [ ] AC10: Card renders in <500ms
**Points:** 8 | **Priority:** Must  
**Sprint:** 3

---

### [EPIC-3-4] Match Score Algorithm

**[EPIC-3-21] Auto Match Score**

As a client, I want to see a match score so that I know how suitable an agent is.  
**Acceptance Criteria:**
- [ ] AC1: Client pastes mission description
- [ ] AC2: Match score 0-100 calculated within 1 second
- [ ] AC3: Score based on skill match + reputation + price
- [ ] AC4: Top 5 matches displayed
- [ ] AC5: Score updates in real-time as description changes
**Points:** 5 | **Priority:** Must  
**Sprint:** 3

---

### [EPIC-3-5] Price Estimation

**[EPIC-3-22] Price Estimate Before Commit**

As a client, I want to get a price estimate before committing so that I don't overspend.  
**Acceptance Criteria:**
- [ ] AC1: Client inputs mission description
- [ ] AC2: System estimates cost in USDC
- [ ] AC3: Estimate within 5% of actual cost
- [ ] AC4: Estimate displayed before hire confirmation
- [ ] AC5: Factors: agent price + mission complexity
**Points:** 3 | **Priority:** Must  
**Sprint:** 3

---

### [EPIC-3-6] Portfolio & Social Proof

**[EPIC-3-23] Agent Portfolio Display**

As a client, I want to see an agent's past work so that I can verify quality.  
**Acceptance Criteria:**
- [ ] AC1: Last 10 missions displayed (anonymized)
- [ ] AC2: Each entry shows: outcome, client score, date
- [ ] AC3: Portfolio link expandable on card
- [ ] AC4: Full history accessible via API
**Points:** 3 | **Priority:** Should  
**Sprint:** 3

---

**[EPIC-3-24] Social Recommendations**

As a client, I want to see what other teams hired so that I get peer validation.  
**Acceptance Criteria:**
- [ ] AC1: "Teams using [stack] also hired this agent" shown
- [ ] AC2: Similar agents recommended
- [ ] AC3: Based on hire patterns in same stack
**Points:** 2 | **Priority:** Could  
**Sprint:** 3

---

## Epic 3 Overall Acceptance Criteria

- [ ] Agent listing with pagination functional
- [ ] Natural language search returns relevant results <1s
- [ ] All filters combinable and working
- [ ] Full agent identity card renders correctly
- [ ] Match score calculates and displays accurately
- [ ] Price estimation within 5% accuracy

---

# EPIC 4: Mission Execution + Delivery

**Epic Name:** Mission Execution & Delivery  
**Description:** Handle mission execution lifecycle, output delivery, and proof of work  
**User Value Statement:** As a provider, I want to receive missions and deliver results so that I can complete work and get paid.

**Dependencies:** Epic 2 (Mission Creation + Escrow) - Must have missions created first

---

### [EPIC-4-1] Mission Event Delivery

**[EPIC-3-25] Mission WebSocket Events**

As a provider, I want to receive mission events so that I can react in real-time.  
**Acceptance Criteria:**
- [ ] AC1: WebSocket connection for real-time events
- [ ] AC2: Events: new mission, mission accepted, delivery requested, dispute
- [ ] AC3: SDK includes event listener
- [ ] AC4: Reconnection on disconnect
**Points:** 5 | **Priority:** Must  
**Sprint:** 2

---

### [EPIC-4-2] Mission Execution

**[EPIC-4-26] Start Mission Work**

As a provider, I want to start working on an accepted mission so that I can deliver results.  
**Acceptance Criteria:**
- [ ] AC1: Provider initiates work → state IN_PROGRESS
- [ ] AC2: Provider receives full mission details from IPFS
- [ ] AC3: Deadline timer visible
- [ ] AC4: Progress tracking optional
**Points:** 2 | **Priority:** Must  
**Sprint:** 2

---

### [EPIC-4-3] Deliverables Submission

**[EPIC-4-27] Submit Deliverables**

As a provider, I want to submit my work so that the client can review.  
**Acceptance Criteria:**
- [ ] AC1: Provider uploads deliverables to IPFS
- [ ] AC2: IPFS hash submitted to escrow contract
- [ ] AC3: State changes to DELIVERED
- [ ] AC4: Client notified of delivery
- [ ] AC5: Delivery includes summary description
**Points:** 3 | **Priority:** Must  
**Sprint:** 2

---

### [EPIC-4-4] Proof of Work

**[EPIC-4-28] Cryptographic Output Signing**

As an enterprise client, I want cryptographically signed outputs so that I have audit trails.  
**Acceptance Criteria:**
- [ ] AC1: Every output signed by provider's key
- [ ] AC2: Output hash recorded on-chain
- [ ] AC3: Client can verify signature
- [ ] AC4: Audit trail accessible via API
**Points:** 5 | **Priority:** Must  
**Sprint:** 3

---

**[EPIC-4-29] Output Verification**

As a client, I want to verify that output wasn't tampered with so that I trust the work.  
**Acceptance Criteria:**
- [ ] AC1: Output hash matches on-chain record
- [ ] AC2: Signature verification UI
- [ ] AC3: Verification status shown in dashboard
**Points:** 3 | **Priority:** Should  
**Sprint:** 3

---

### [EPIC-4-5] Mission DNA (Historical Matching)

**[EPIC-4-30] Mission DNA Matching**

As a client, I want to see how well an agent matches historical success patterns so that I hire with data.  
**Acceptance Criteria:**
- [ ] AC1: Mission embedded and matched against historical data
- [ ] AC2: Confidence score displayed
- [ ] AC3: Similar successful missions shown
- [ ] AC4: Response time <2 seconds
- [ ] AC5: Improves hire success rate target: 20%+
**Points:** 5 | **Priority:** Should  
**Sprint:** 3

---

## Epic 4 Overall Acceptance Criteria

- [ ] Real-time mission events via WebSocket
- [ ] Full mission execution lifecycle functional
- [ ] Deliverables submission to IPFS works
- [ ] Cryptographic signing and verification functional
- [ ] Mission DNA matching operational

---

# EPIC 5: Reputation System

**Epic Name:** On-Chain Reputation System  
**Description:** Immutable track record of mission outcomes with calculated reputation scores  
**User Value Statement:** As a client, I want to see verified reputation so that I hire trusted agents.

**Dependencies:** Epic 2 (Mission Creation + Escrow) - Must have completed missions first

---

### [EPIC-5-1] Reputation Algorithm

**[EPIC-5-31] Reputation Score Calculation**

As a system, I want to calculate reputation scores so that clients can make informed decisions.  
**Acceptance Criteria:**
- [ ] AC1: Algorithm weights: Success rate 40%, Client score 30%, Stake 20%, Recency 10%
- [ ] AC2: Score displayed as 0-100
- [ ] AC3: Stored as 0-10000 (2 decimals) on-chain
- [ ] AC4: Algorithm produces consistent results
- [ ] AC5: Updates within 1 block of mission completion
**Points:** 5 | **Priority:** Must  
**Sprint:** 3

---

### [EPIC-5-2] Mission Outcome Recording

**[EPIC-5-32] Record Mission Outcomes**

As a system, I want to record mission outcomes on-chain so that reputation is immutable.  
**Acceptance Criteria:**
- [ ] AC1: On mission COMPLETED, record: agentId, success, clientScore
- [ ] AC2: On DISPUTED, record: agentId, disputed, outcome
- [ ] AC3: Events emitted for indexing
- [ ] AC4: Historical data queryable for any agent
**Points:** 3 | **Priority:** Must  
**Sprint:** 3

---

### [EPIC-5-3] Client Scoring

**[EPIC-5-33] Client Rating System**

As a client, I want to rate completed missions so that I contribute to reputation.  
**Acceptance Criteria:**
- [ ] AC1: Client can submit score 1-10 on approval
- [ ] AC2: Score affects reputation algorithm
- [ ] AC3: Score required for full payment release
- [ ] AC4: Scores anonymized in portfolio
**Points:** 2 | **Priority:** Must  
**Sprint:** 2

---

### [EPIC-5-4] Inter-Agent Endorsements

**[EPIC-5-34] Agent Endorsements**

As a provider, I want to endorse other agents so that peer trust is established.  
**Acceptance Criteria:**
- [ ] AC1: Agent can endorse another agent
- [ ] AC2: Endorsements displayed on agent card
- [ ] AC3: Endorsements stored on-chain
- [ ] AC4: "Certified by [agent]" shown
**Points:** 3 | **Priority:** Could  
**Sprint:** 3

---

### [EPIC-5-5] Reputation API

**[EPIC-5-35] Public Reputation Query**

As a third party, I want to query agent reputation so that I can build integrations.  
**Acceptance Criteria:**
- [ ] AC1: Public read endpoint for reputation
- [ ] AC2: Full mission history accessible
- [ ] AC3: Filter by date range
- [ ] AC4: Rate limiting applied
**Points:** 2 | **Priority:** Should  
**Sprint:** 3

---

## Epic 5 Overall Acceptance Criteria

- [ ] Reputation algorithm implemented with correct weights
- [ ] Mission outcomes recorded on-chain
- [ ] Client scoring functional
- [ ] Reputation queryable by third parties
- [ ] Historical data accessible

---

# EPIC 6: Inter-Agent Protocol *(→ V1.5 — NOT in 8-week sprint)*

> ⚠️ **Scope lock (Grok audit):** Auction system too complex for MVP. All EPIC-6 stories deferred to V1.5 (weeks 9-16). Remove from Sprint 4.

**Epic Name:** Inter-Agent Communication & Collaboration  
**Description:** Enable agents to hire sub-agents, form partner networks, and collaborate  
**User Value Statement:** As a provider, I want to collaborate with other agents so that I can handle complex missions.

**Dependencies:** Epic 2 (Mission Creation + Escrow), Epic 4 (Mission Execution) - Must have mission flow working

---

### [EPIC-6-1] Sub-Agent Hiring

**[EPIC-6-36] Hire Sub-Agent**

As a provider, I want to hire a sub-agent so that I can handle complex missions.  
**Acceptance Criteria:**
- [ ] AC1: Provider can browse marketplace as agent
- [ ] AC2: Provider creates sub-mission for specialist
- [ ] AC3: -20% protocol fee discount applied
- [ ] AC4: Payment split: provider pays from mission budget
- [ ] AC5: Sub-agent delivers to primary provider
**Points:** 5 | **Priority:** Must  
**Sprint:** 4

---

### [EPIC-6-2] Partner Network

**[EPIC-6-37] Declare Preferred Collaborators**

As a provider, I want to declare preferred collaborators so that I have ready partners.  
**Acceptance Criteria:**
- [ ] AC1: Provider declares partner agents
- [ ] AC2: Partner rates pre-negotiated and stored
- [ ] AC3: Partner network visible on agent card
- [ ] AC4: Direct hire without auction for partners
- [ ] AC5: Revenue split via smart contract
**Points:** 5 | **Priority:** Should  
**Sprint:** 4

---

### [EPIC-6-3] Sub-Mission Auctions

**[EPIC-6-38] Auction for Specialists**

As a coordinator, I want to post sub-missions to auction so that I can recruit specialists.  
**Acceptance Criteria:**
- [ ] AC1: Coordinator posts sub-mission requirements
- [ ] AC2: Specialists submit bids (price, timeline)
- [ ] AC3: Lowest qualifying bid wins
- [ ] AC4: Smart contract assigns winner
- [ ] AC5: Auction closes and assignment executes
**Points:** 5 | **Priority:** Should  
**Sprint:** 4

---

### [EPIC-6-4] Agency Treasury

**[EPIC-6-39] Create Agency Treasury**

As a group of providers, I want to share revenue so that we can operate as a team.  
**Acceptance Criteria:**
- [ ] AC1: Multi-sig treasury creation
- [ ] AC2: Configurable revenue shares
- [ ] AC3: Auto-distribution on mission completion
- [ ] AC4: Treasury visible to members
**Points:** 5 | **Priority:** Could  
**Sprint:** 4

---

## Epic 6 Overall Acceptance Criteria

- [ ] Agent-to-agent hiring functional with -20% discount
- [ ] Partner network stored and displayed
- [ ] Auction system for sub-mission recruitment
- [ ] Treasury creation and revenue sharing operational

---

# EPIC 7: Token + Economics

**Epic Name:** Token Economics & Protocol Fees  
**Description:** $AGNT token, staking, burn mechanism, and insurance pool  
**User Value Statement:** As a protocol, I want sustainable token economics so that the marketplace grows.

---

### [EPIC-7-1] AGNT Token Contract

**[EPIC-7-40] Deploy AGNT Token**

As a system, I want the AGNT token deployed so that it can be used for staking and fees.  
**Acceptance Criteria:**
- [ ] AC1: ERC-20 standard implementation
- [ ] AC2: Total supply: 100M $AGNT
- [ ] AC3: Deployed on Base Sepolia
- [ ] AC4: Token transferred to treasury, team, investors per allocation
**Points:** 5 | **Priority:** Must  
**Sprint:** 1

---

### [EPIC-7-2] Burn Mechanism

**[EPIC-7-41] Protocol Fee Burn**

As a system, I want to burn tokens on every transaction so that value compounds.  
**Acceptance Criteria:**
- [ ] AC1: Protocol fee: 1% of agent call cost
- [ ] AC2: Dynamic burn: EIP-1559 style (congestion-based)
- [ ] AC3: Floor: 0.5%, Ceiling: 3%
- [ ] AC4: Burn function callable only by protocol
- [ ] AC5: Burn events logged
**Points:** 5 | **Priority:** Must  
**Sprint:** 1

---

### [EPIC-7-3] Insurance Pool

**[EPIC-7-42] Insurance Pool Fund**

As a client, I want coverage if an agent fails so that I'm protected.  
**Acceptance Criteria:**
- [ ] AC1: Providers contribute to insurance pool (2% of earnings)
- [ ] AC2: Pool covers client if agent stake insufficient
- [ ] AC3: Claims process for clients
- [ ] AC4: Pool balance visible in UI
- [ ] AC5: Claims processed within 7 days
**Points:** 5 | **Priority:** Should  
**Sprint:** 4

---

### [EPIC-7-4] Bounty Program

**[EPIC-7-43] Bounty Distribution**

As a system, I want to reward actions so that the marketplace grows.  
**Acceptance Criteria:**
- [ ] AC1: Bounty for new agent listing: 10 $AGNT
- [ ] AC2: Bounty for mission completion: 5 $AGNT
- [ ] AC3: Leaderboard for top providers
- [ ] AC4: Bounty paid from protocol treasury
**Points:** 3 | **Priority:** Could  
**Sprint:** 4

---

## Epic 7 Overall Acceptance Criteria

- [ ] AGNT token deployed on Base Sepolia
- [ ] Burn mechanism functional (dynamic rate)
- [ ] Insurance pool operational
- [ ] Bounty system active

---

# EPIC 8: VS Code Plugin

**Epic Name:** IDE Integration (VS Code Plugin)  
**Description:** Marketplace embedded in developer workflow  
**User Value Statement:** As a developer, I want to hire agents from VS Code so that I don't leave my workflow.

**Dependencies:** Epic 1, Epic 2, Epic 3 - Must have core marketplace functional

---

### [EPIC-8-1] VS Code Extension

**[EPIC-8-44] VS Code Extension Install**

As a developer, I want to install the marketplace extension so that I can access it from VS Code.  
**Acceptance Criteria:**
- [ ] AC1: Extension published to VS Code Marketplace
- [ ] AC2: Install from extension panel
- [ ] AC3: Extension activates on IDE open
- [ ] AC4: Status bar shows connection
**Points:** 3 | **Priority:** Must  
**Sprint:** 4

---

### [EPIC-8-45] Agent Browse in IDE**

As a developer, I want to browse agents from VS Code so that I can find hires quickly.  
**Acceptance Criteria:**
- [ ] AC1: Side panel shows agent listings
- [ ] AC2: Search and filter available
- [ ] AC3: Agent card details in panel
- [ ] AC4: Real-time availability status
**Points:** 5 | **Priority:** Must  
**Sprint:** 4

---

### [EPIC-8-46] Mission Creation from IDE**

As a developer, I want to create a mission from VS Code so that I stay in flow.  
**Acceptance Criteria:**
- [ ] AC1: Create mission from side panel
- [ ] AC2: Paste mission description
- [ ] AC3: See match scores inline
- [ ] AC4: Approve and pay from IDE
- [ ] AC5: Results displayed in output panel
**Points:** 5 | **Priority:** Must  
**Sprint:** 4

---

### [EPIC-8-47] CLI Tool**

As a developer, I want a CLI tool so that I can integrate with scripts.  
**Acceptance Criteria:**
- [ ] AC1: CLI installed via npm
- [ ] AC2: Commands: search, create-mission, status, deliver
- [ ] AC3: Full mission flow via CLI
- [ ] AC4: Output formatted for scripting
**Points:** 3 | **Priority:** Could  
**Sprint:** 4

---

## Epic 8 Overall Acceptance Criteria

- [ ] VS Code extension installs and activates
- [ ] Agent browsing from IDE works
- [ ] Mission creation from IDE functional
- [ ] Results display in IDE output
- [ ] CLI tool operational

---


---

### [EPIC-9-48] Commit-Reveal Mission Creation (MEV Protection)

As a developer, I want mission creation to use commit-reveal so that front-running bots cannot steal missions.
**Acceptance Criteria:**
- [ ] AC1: `commitMission(bytes32 commitment)` stores hash on-chain
- [ ] AC2: `revealMission(params, salt)` verifies commitment before creating mission
- [ ] AC3: Commitment expires after 10 blocks if not revealed
- [ ] AC4: Tests cover front-running scenario
**Points:** 5 | **Priority:** Must | **Sprint:** 1
**Ref:** GAP-01 (Grok audit — MEV protection)

---

### [EPIC-9-49] OFAC Screening Async + Cache

As an operator, I want OFAC screening to be async with Redis cache so that it doesn't block every request.
**Acceptance Criteria:**
- [ ] AC1: Known clean wallets cached 1h in Redis (key: `ofac:{wallet}`)
- [ ] AC2: First check is sync/blocking; subsequent checks hit cache
- [ ] AC3: TRM Labs down → fail-open with Grafana alert (not 500 error)
- [ ] AC4: OFAC-positive wallets cached as BLOCKED permanently
- [ ] AC5: Cache invalidation endpoint for ops team
**Points:** 3 | **Priority:** Must | **Sprint:** 1
**Ref:** GAP-04 (Grok/Clawd audit — OFAC bottleneck)

---

### [EPIC-9-50] Indexer Backfill + Reorg Detection

As an operator, I want the indexer to survive RPC restarts and handle reorgs so that the DB never diverges from on-chain state.
**Acceptance Criteria:**
- [ ] AC1: `getLogs` backfill runs every 10min for last 100 blocks
- [ ] AC2: `UNIQUE(tx_hash, log_index)` on `mission_events` — duplicate inserts are no-ops
- [ ] AC3: Indexer stores `last_block_hash` in `indexer_state`; detects reorg if hash changes
- [ ] AC4: On reorg: rollback affected events, re-process from forked block
- [ ] AC5: Fallback RPC cascade: Alchemy → Infura → Base public node
**Points:** 8 | **Priority:** Must | **Sprint:** 1
**Ref:** Grok audit — indexer robustesse

---

### [EPIC-9-51] Agent Benchmark Score (Anti-Race-to-Bottom)

As a marketplace operator, I want agents to have a verifiable benchmark score so that low-quality GPT wrappers cannot flood the marketplace.
**Acceptance Criteria:**
- [ ] AC1: Provider submits benchmark results (URL or score) at registration
- [ ] AC2: Agents without benchmark score shown with "Unverified" badge
- [ ] AC3: Auto-delisting if dispute rate >15% over 30-day window
- [ ] AC4: Benchmark score displayed on agent card
**Points:** 3 | **Priority:** Should | **Sprint:** 3
**Ref:** GAP-09 (Opus audit — race to bottom)

---

### [EPIC-9-52] Incident Response Alerting

As an operator, I want Grafana alerts to fire on Telegram for critical incidents so that I can respond at 3am.
**Acceptance Criteria:**
- [ ] AC1: Alert: indexer lag >5min → Telegram critical
- [ ] AC2: Alert: insurance pool balance <10% of total staked → Telegram critical
- [ ] AC3: Alert: dispute rate >10% in 1h window → Telegram warning
- [ ] AC4: Alert: OFAC screening error rate >5% → Telegram warning
- [ ] AC5: Runbook link included in each alert message
**Points:** 3 | **Priority:** Must | **Sprint:** 1
**Ref:** GAP-10 (Opus audit — incident response)


---

# Sprint Planning

## Sprint 1: Foundation (Weeks 1-2)

**Focus:** Smart contracts + Core APIs + Token deployment

| Story ID | Epic | Story Title | Points |
|----------|------|-------------|--------|
| EPIC-1-1 | 1 | Agent Registration Flow | 8 |
| EPIC-1-2 | 1 | Provider Wallet & Authentication | 5 |
| EPIC-1-5 | 1 | Stake for Agent Listing | 5 |
| EPIC-1-6 | 1 | Unstake with Timelock | 3 |
| EPIC-7-40 | 7 | Deploy AGNT Token | 5 |
| EPIC-7-41 | 7 | Protocol Fee Burn | 5 |

| EPIC-9-48 | 9 | Commit-Reveal MEV Protection | 5 |
| EPIC-9-49 | 9 | OFAC Async + Cache | 3 |
| EPIC-9-50 | 9 | Indexer Backfill + Reorg | 8 |
| EPIC-9-52 | 9 | Incident Response Alerting | 3 |

**Sprint 1 Total:** 50 points (+19 security/ops stories)

---

## Sprint 2: Mission Flow (Weeks 3-4)

**Focus:** Create → Assign → Deliver lifecycle

| Story ID | Epic | Story Title | Points |
|----------|------|-------------|--------|
| EPIC-2-7 | 2 | Create Mission | 5 |
| EPIC-2-8 | 2 | Payment Deposit & Escrow | 8 |
| EPIC-2-9 | 2 | Accept Mission | 3 |
| ~~EPIC-2-10~~ | ~~2~~ | ~~Dry Run Execution~~ | ~~5~~ | **→ V1.5** |
| EPIC-2-11 | 2 | Mission State Transitions | 5 |
| EPIC-2-12 | 2 | Delivery & Payment Release | 3 |
| EPIC-2-13 | 2 | Auto-Approve on Timeout | 3 |
| EPIC-2-14 | 2 | Dispute Resolution | 5 |
| EPIC-2-15 | 2 | Provider Slash on Dispute Loss | 3 |
| EPIC-2-16 | 2 | Timeout Refund | 2 |
| EPIC-4-25 | 4 | Mission WebSocket Events | 5 |
| EPIC-4-26 | 4 | Start Mission Work | 2 |
| EPIC-4-27 | 4 | Submit Deliverables | 3 |
| EPIC-5-33 | 5 | Client Rating System | 2 |

**Sprint 2 Total:** 54 points

---

## Sprint 3: Discovery + Reputation (Weeks 5-6)

**Focus:** Search, Match, Reputation system

| Story ID | Epic | Story Title | Points |
|----------|------|-------------|--------|
| EPIC-3-17 | 3 | Agent Listing with Pagination | 3 |
| EPIC-3-18 | 3 | Natural Language Search | 5 |
| EPIC-3-19 | 3 | Advanced Filters | 5 |
| EPIC-3-20 | 3 | Agent Identity Card UI | 8 |
| EPIC-3-21 | 3 | Auto Match Score | 5 |
| EPIC-3-22 | 3 | Price Estimate Before Commit | 3 |
| EPIC-3-23 | 3 | Agent Portfolio Display | 3 |
| EPIC-3-24 | 3 | Social Recommendations | 2 |
| EPIC-4-28 | 4 | Cryptographic Output Signing | 5 |
| EPIC-4-29 | 4 | Output Verification | 3 |
| EPIC-4-30 | 4 | Mission DNA Matching | 5 |
| EPIC-5-31 | 5 | Reputation Score Calculation | 5 |
| EPIC-5-32 | 5 | Record Mission Outcomes | 3 |
| EPIC-5-34 | 5 | Agent Endorsements | 3 |
| EPIC-5-35 | 5 | Public Reputation Query | 2 |

**Sprint 3 Total:** 60 points

---

## Sprint 4: Polish + Launch (Weeks 7-8)

**Focus:** VS Code Plugin, Inter-Agent Protocol, Insurance Pool, Launch Prep

| Story ID | Epic | Story Title | Points |
|----------|------|-------------|--------|
| ~~EPIC-6-36~~ | ~~6~~ | ~~Hire Sub-Agent~~ | ~~5~~ | **→ V1.5** |
| ~~EPIC-6-37~~ | ~~6~~ | ~~Declare Preferred Collaborators~~ | ~~5~~ | **→ V1.5** |
| ~~EPIC-6-38~~ | ~~6~~ | ~~Auction for Specialists~~ | ~~5~~ | **→ V1.5** |
| ~~EPIC-6-39~~ | ~~6~~ | ~~Create Agency Treasury~~ | ~~5~~ | **→ V1.5** |
| EPIC-7-42 | 7 | Insurance Pool Fund | 5 |
| EPIC-7-43 | 7 | Bounty Distribution | 3 |
| EPIC-8-44 | 8 | VS Code Extension Install | 3 |
| EPIC-8-45 | 8 | Agent Browse in IDE | 5 |
| EPIC-8-46 | 8 | Mission Creation from IDE | 5 |
| EPIC-8-47 | 8 | CLI Tool | 3 |
| EPIC-1-3 | 1 | Agent Profile Management | 3 |
| EPIC-1-4 | 1 | Genesis Agent Badge | 2 |

**Sprint 4 Total:** 49 points

---

# Summary

| Metric | Value |
|--------|-------|
| **Total Epics** | 8 |
| **Total Stories** | 52 (47 original + 5 post-audit) |
| **Total Points** | 194 |
| **Sprints** | 4 (8 weeks) |
| **Avg Points/Sprint** | 48.5 |

---

# Point Distribution by Priority

| Priority | Stories | Points |
|----------|---------|--------|
| Must | 28 | 134 |
| Should | 12 | 42 |
| Could | 7 | 18 |

---

# Dependencies Map

```
EPIC 7 (Token) ─────┐
                    ├──► EPIC 1 (Onboarding)
EPIC 1 (Onboarding) ┤
                    ├──► EPIC 2 (Mission + Escrow)
EPIC 2 (Mission) ───┼──► EPIC 4 (Execution)
                    │
EPIC 1+2 ───────────┼──► EPIC 3 (Discovery)
                    │
EPIC 2+4 ───────────┼──► EPIC 5 (Reputation)
                    │
EPIC 2+4 ───────────┼──► EPIC 6 (Inter-Agent)
                    │
EPIC 1+2+3 ─────────┼──► EPIC 8 (VS Code)
```

---

# Definition of Done Checklist (Per Epic)

- [ ] Unit tests (>80% coverage on smart contracts)
- [ ] Integration tests for all API endpoints
- [ ] Security review checklist passed
- [ ] Documentation updated
- [ ] Deployed to Base testnet
- [ ] Smoke tests pass on testnet

---

*Document generated: 2026-02-27*  
*Status: Ready for Sprint Planning*



<!-- BMad workflow create-epics-and-stories: v1.1 patch applied 2026-02-28 -->
<!-- Changes: Epic 6 → V1.5, Dry Run → V1.5, +5 security stories (MEV, OFAC, indexer, benchmark, alerting) -->

#XZ|# EPIC 10: Agent-Driven Development (Jeff Use Case)
#NV|
#NP|**Epic Name:** Agent-Driven Development (Jeff Use Case)
#SZ|**Description:** Enable automated agent-driven development workflows with GitHub integration, EAL verification, and compute governance
#BM|**User Value Statement:** As a developer (Jeff), I want agents to automatically pick up GitHub issues and deliver code so that development is fully automated.
#RN|
#NR|**Dependencies:** Epic 1 (Provider Onboarding), Epic 2 (Mission Creation + Escrow)
#QR|
#TH|---
#NM|
#SY|### [EPIC-10-1] TDL Validation Bot
#NP|
#WH|**[EPIC-10-1] TDL Validation Bot**
#NV|
#QK|As a developer, I want a GitHub Action to parse YAML frontmatter and add `agent-ready` label if Zod schema is valid so that only valid tasks enter the marketplace.
#BP|**Acceptance Criteria:**
#SW|- [ ] AC1: GitHub Action triggers on issue creation/update
#TT|- [ ] AC2: Parses YAML frontmatter from issue body
#YZ|- [ ] AC3: Validates against TDL Zod schema (task_id, description, reward, deadline, skills)
#HP|- [ ] AC4: Adds `agent-ready` label if valid, `agent-invalid` if not
#SZ|- [ ] AC5: Comments validation result on issue
#WM|**Points:** 3 | **Priority:** Must | **Sprint:** 1
#RR|
#JB|---
#NR|
#KM|### [EPIC-10-2] GitHub Webhook Bridge
#RX|
#SM|**[EPIC-10-2] GitHub Webhook Bridge**
#VR|
#KM|As a marketplace, I want POST /webhook/github to create missions on-chain so that GitHub issues automatically trigger agent tasks.
#BP|**Acceptance Criteria:**
#XZ|- [ ] AC1: Fastify endpoint handles GitHub webhook POST
#YV|- [ ] AC2: Validates HMAC signature from GitHub
#QT|- [ ] AC3: Converts issue to mission via createMission on-chain
#SY|- [ ] AC4: Idempotent: uses issueHash = keccak256(repoOwner, repoName, issueNumber)
#SY|- [ ] AC5: Returns missionId or existing mission if duplicate
#NP|**Points:** 5 | **Priority:** Must | **Sprint:** 1
#BQ|
#NM|---
#NM|
#SB|### [EPIC-10-3] EAL Submission Endpoint
#XZ|
#KM|**[EPIC-10-3] EAL Submission Endpoint**
#BQ|
#RX|As an agent, I want to submit Execution Attestation Log (EAL) with EIP-712 signature so that execution is verifiable.
#BP|**Acceptance Criteria:**
#QW|- [ ] AC1: POST /missions/:id/eal accepts EAL payload
#TH|- [ ] AC2: Validates EIP-712 signature from agent wallet
#QR|- [ ] AC3: Stores EAL on IPFS, returns hash
#VR|- [ ] AC4: Records IPFS hash on-chain linked to mission
#SW|- [ ] AC5: Returns 400 if signature invalid or expired
#QM|**Points:** 5 | **Priority:** Must | **Sprint:** 1
#RR|
#MM|---
#NM|
#NP|### [EPIC-10-4] QA Agent Spot-Check Flow
#QR|
#XS|**[EPIC-10-4] QA Agent Spot-Check Flow**
#XK|
#QK.As a client, I want automatic QA verification when an agent submits so that quality is ensured without manual review.
#BP|**Acceptance Criteria:**
#SW|- [ ] AC1: POST /missions/:id/qa-review triggers verification
#SY|- [ ] AC2: Structural check: code compiles, tests pass
#JB|- [ ] AC3: Duration check: execution time within expected range
#SY|- [ ] AC4: Test replay: runs provided test suite against delivered code
#SW|- [ ] AC5: Returns QA score (0-100) and pass/fail
#RR|- [ ] AC6: Blocks payment release if QA score < 70
#NP|**Points:** 8 | **Priority:** Must | **Sprint:** 2
#RR|
#RN|---
#NM|
#NB|### [EPIC-10-5] ReviewerRegistry Integration
#BQ|
#RX|**[EPIC-10-5] ReviewerRegistry Integration**
#QM|
#RN|As a dispute resolver, I want ReviewerRegistry.sol to manage disputes so that conflicts are fairly arbitrated.
#BP|**Acceptance Criteria:**
#SY|- [ ] AC1: ReviewerRegistry.sol deployed on Base Sepolia
#RT|- [ ] AC2: Registered reviewers can vote on disputes
#SY|- [ ] AC3: Integration with MissionEscrow for fund locking during dispute
#SY|- [ ] AC4: Resolution triggers payout based on majority vote
#RT|- [ ] AC5: Dispute events indexed for transparency
#NP|**Points:** 8 | **Priority:** Must | **Sprint:** 1
#BQ|
#TH|---
#NM|
#SB|### [EPIC-10-6] Meta-Tx Relayer
#QM|
#SZ|**[EPIC-10-6] Meta-Tx Relayer**
#RX|
#QW|As an agent without ETH, I want to send gasless transactions so that I can interact with the marketplace.
#BP|**Acceptance Criteria:**
#NM|- [ ] AC1: MinimalForwarder.sol deployed (EIP-2771)
#SY|- [ ] AC2: POST /relay accepts forwarded transactions
#SQ|- [ ] AC3: Validates signature and nonce
#TH|- [ ] AC4: Relayer pays gas, deducted from agent balance
#SY|- [ ] AC5: Replay protection via domain separator
#NP|**Points:** 5 | **Priority:** Must | **Sprint:** 1
#QM|
#TH|---
#NM|
#SZ|### [EPIC-10-7] ColdStartVault
#QS|
#RW|**[EPIC-10-7] ColdStartVault**
#QM|
#QT|As an early provider, I want ColdStartVault.sol to bootstrap the first 50 agents so that the marketplace gains initial traction.
#BP|**Acceptance Criteria:**
#NM|- [ ] AC1: ColdStartVault.sol deployed on Base Sepolia
#SY|- [ ] AC2: 50 slots available for genesis agents
#SY|- [ ] AC3: Each genesis agent receives 1000 AGNT auto-staked
#NM|- [ ] AC4: 6-month vesting schedule (cliff 3 months)
#SY|- [ ] AC5: Early withdrawal imposes 20% penalty
#NP|**Points:** 3 | **Priority:** Must | **Sprint:** 1
#QW|
#TH|---
#NM|
#RR|### [EPIC-10-8] Agent SDK Minimal
#RX|
#QS|**[EPIC-10-8] Agent SDK Minimal**
#QM|
#RK|As an agent developer, I want @agent-marketplace/sdk so that I can integrate with the marketplace easily.
#BP|**Acceptance Criteria:**
#SY|- [ ] AC1: npm package @agent-marketplace/sdk published
#NM|- [ ] AC2: receive_task(): receives mission payload
#RW|- [ ] AC3: execute(): runs agent logic with provided context
#SY|- [ ] AC4: submit_eal(): submits EAL with EIP-712 signature
#RS|- [ ] AC5: TypeScript types for all payloads
#QM|- [ ] AC6: Documentation with examples
#NP|**Points:** 8 | **Priority:** Must | **Sprint:** 2
#RS|
#TH|---
#NM|
#SQ|### [EPIC-10-9] Compute Mode Badge
#RW|
#SQ|**[EPIC-10-9] Compute Mode Badge**
#QN|
#QT|As a verified agent, I want a "verified-runtime" badge so that clients trust my execution environment.
#BP|**Acceptance Criteria:**
#SQ|- [ ] AC1: Badge "verified-runtime" for Model B agents (official GitHub Actions)
#SQ|- [ ] AC2: Model B agents get +10% matching score bonus
#SY|- [ ] AC3: Model A agents: reputation cap at 80/100
#SQ|- [ ] AC4: Badge displayed on agent card
#SQ|- [ ] AC5: Verification via GitHub Actions metadata
#NP|**Points:** 3 | **Priority:** Should | **Sprint:** 2
#QW|
#TH|---
#NM|
#NP|### [EPIC-10-10] Jeff Funding Flow
#RW|
#SQ|**[EPIC-10-10] Jeff Funding Flow**
#QN|
#QT|As Jeff, I want fundMissions() with deterministic issueHash so that my GitHub issues map directly to funded missions.
#BP|**Acceptance Criteria:**
#SY|- [ ] AC1: fundMissions() batch funds multiple missions
#SY|- [ ] AC2: issueHash = keccak256(repoOwner, repoName, issueNumber)
#SY|- [ ] AC3: Funding creates mission if not exists
#SY|- [ ] AC4: Escrow deposit on funding
#NP|**Points:** 3 | **Priority:** Must | **Sprint:** 1
#QW|
#TH|---
#NM|
#SQ|## Epic 10 Overall Acceptance Criteria
#QT|
#SY|- [ ] TDL validation GitHub Action operational
#TH|- [ ] GitHub webhook bridge creates missions idempotently
#SY|- [ ] EAL submission with EIP-712 verification functional
#SY|- [ ] QA spot-check flow verifies structural/duration/test compliance
#SY|- [ ] ReviewerRegistry integrated with MissionEscrow
#SY|- [ ] Meta-tx relayer enables gasless agent transactions
#SY|- [ ] ColdStartVault bootstraps 50 genesis agents
#SY|- [ ] Agent SDK published and documented
#SY|- [ ] Compute mode badges for verified agents
#QT|- [ ] Jeff funding flow with deterministic issueHash
#QT|
#YQ|---
#QT|
#SY|# Sprint Planning Update
#YQ|
#QT|## Sprint 1: Foundation (Weeks 1-2) — Updated
#RV|
#SY|**Focus:** Smart contracts + Core APIs + Token deployment + Jeff Integration
#RM|
#SY|| Story ID | Epic | Story Title | Points |
#SZ||----------|------|-------------|--------|
#SZ|| EPIC-1-1 | 1 | Agent Registration Flow | 8 |
#RV|| EPIC-1-2 | 1 | Provider Wallet & Authentication | 5 |
#SZ|| EPIC-1-5 | 1 | Stake for Agent Listing | 5 |
#SZ|| EPIC-1-6 | 1 | Unstake with Timelock | 3 |
#RV|| EPIC-7-40 | 7 | Deploy AGNT Token | 5 |
#SZ|| EPIC-7-41 | 7 | Protocol Fee Burn | 5 |
#SZ|| EPIC-9-48 | 9 | Commit-Reveal MEV Protection | 5 |
#RV|| EPIC-9-49 | 9 | OFAC Async + Cache | 3 |
#SZ|| EPIC-9-50 | 9 | Indexer Backfill + Reorg | 8 |
#SZ|| EPIC-9-52 | 9 | Incident Response Alerting | 3 |
#SQ|| EPIC-10-1 | 10 | TDL Validation Bot | 3 |
#SZ|| EPIC-10-2 | 10 | GitHub Webhook Bridge | 5 |
#SZ|| EPIC-10-3 | 10 | EAL Submission Endpoint | 5 |
#SZ|| EPIC-10-5 | 10 | ReviewerRegistry Integration | 8 |
#SZ|| EPIC-10-6 | 10 | Meta-Tx Relayer | 5 |
#SZ|| EPIC-10-7 | 10 | ColdStartVault | 3 |
#SZ|| EPIC-10-10 | 10 | Jeff Funding Flow | 3 |
#RM|
#SZ|**Sprint 1 Total:** 76 points (+26 Jeff stories)
#SZ|
#RM|---
#RM|
#RR|## Sprint 2: Mission Flow (Weeks 3-4) — Updated
#RT|
#SY|**Focus:** Create → Assign → Deliver lifecycle + QA + SDK
#RX|
#RT|| Story ID | Epic | Story Title | Points |
#RV||----------|------|-------------|--------|
#RS|| EPIC-2-7 | 2 | Create Mission | 5 |
#RV|| EPIC-2-8 | 2 | Payment Deposit & Escrow | 8 |
#RX|| EPIC-2-9 | 2 | Accept Mission | 3 |
#RS|| EPIC-2-11 | 2 | Mission State Transitions | 5 |
#RX|| EPIC-2-12 | 2 | Delivery & Payment Release | 3 |
#RS|| EPIC-2-13 | 2 | Auto-Approve on Timeout | 3 |
#RT|| EPIC-2-14 | 2 | Dispute Resolution | 5 |
#RV|| EPIC-2-15 | 2 | Provider Slash on Dispute Loss | 3 |
#RX|| EPIC-2-16 | 2 | Timeout Refund | 2 |
#RS|| EPIC-4-25 | 4 | Mission WebSocket Events | 5 |
#RS|| EPIC-4-26 | 4 | Start Mission Work | 2 |
#RS|| EPIC-4-27 | 4 | Submit Deliverables | 3 |
#RS|| EPIC-5-33 | 5 | Client Rating System | 2 |
#RS|| EPIC-10-4 | 10 | QA Agent Spot-Check Flow | 8 |
#RS|| EPIC-10-8 | 10 | Agent SDK Minimal | 8 |
#RS|| EPIC-10-9 | 10 | Compute Mode Badge | 3 |
#RT|
#RS|**Sprint 2 Total:** 68 points
#RS|
#RT|---
#RR|
#SY|# Summary — Updated
#RS|
#SY|| Metric | Value |
#RS||--------|-------|
#RR|| **Total Epics** | 10 |
#RS|| **Total Stories** | 62 (52 original + 10 new Jeff stories) |
#SY|| **Total Points** | 252 |
#RS|| **Sprints** | 4 (8 weeks) |
#RS|| **Avg Points/Sprint** | 63 |
#RR|
#RS|---
#RT|
#RT|<!-- BMad workflow create-epics-and-stories: v1.2 patch applied 2026-03-01 -->
#RT|<!-- Changes: Epic 10 — Agent-Driven Development (Jeff use case), +10 new stories -->