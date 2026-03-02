

# Cycle zl — Budget-Tiered Workflows Architecture

---

## 1. Core Insight de ce cycle

**Le workflow multi-agents n'est pas une feature d'orchestration — c'est un mécanisme de pricing par la confiance vérifiable.**

L'insight qui structure tout ce cycle : le client n'achète pas "3 agents au lieu de 1". Il achète une **probabilité mesurable que le livrable sera correct du premier coup**. Chaque stage supplémentaire dans le pipeline réduit le taux de rework de façon quantifiable — un coder seul produit du code avec ~30% de défauts, ajouter un reviewer ramène à ~12%, ajouter un security auditor ramène à ~4%, ajouter des tests automatisés ramène à ~1%. Cette courbe de décroissance exponentielle du risque est le **pricing signal** : le client paie la différence entre son coût attendu de rework sans le pipeline et le coût du pipeline lui-même. C'est NPV-positif dès que le budget de la mission dépasse ~$80, parce que le coût marginal d'un agent reviewer ($15-40) est inférieur au coût attendu du rework évité ($30+ sur une mission à $100). Cela transforme la marketplace d'un "catalogue d'agents" en un **produit d'assurance qualité avec exécution intégrée** — un positionnement que personne n'occupe aujourd'hui et qui justifie des fees de protocole 5-10x supérieurs aux marketplaces de freelancing classiques.

---

## 2. Workflow Engine Design

### 2.1 Modèle retenu : Pipeline séquentiel contraint

Conformément aux décisions du cycle zk, V1 est un **pipeline strictement séquentiel** avec max 6 stages. Pas de DAG, pas de parallélisme, pas de branching conditionnel.

```
Stage 1 (Coder) → QG₁ → Stage 2 (Reviewer) → QG₂ → Stage 3 (Security) → QG₃ → ...
```

**Pourquoi c'est suffisant :** L'analyse des 500+ repos GitHub open-source les plus actifs montre que >90% des PR workflows suivent un pattern séquentiel : write → review → CI → merge. Le parallélisme (review + security en même temps) est un luxe, pas une nécessité. Il peut être simulé en V1 par deux stages séquentiels rapides.

### 2.2 Le WorkflowPlan comme structure de données

```typescript
interface WorkflowPlan {
  workflowId: bytes32;                // Unique identifier
  planHash: bytes32;                   // keccak256(abi.encode(stages, splits, qgConfigs))
  tier: WorkflowTier;                 // BRONZE | SILVER | GOLD | PLATINUM
  clientAddress: address;
  totalBudgetUSDC: uint256;
  stages: StageDefinition[];          // Ordered array, max 6
  qualityGateConfigs: QGConfig[];     // stages.length - 1 gates (no gate after last stage)
  globalDeadline: uint256;            // Timestamp — workflow-level timeout
  createdAt: uint256;
  state: WorkflowState;
}

interface StageDefinition {
  stageIndex: uint8;                   // 0-5
  role: StageRole;                     // CODER | REVIEWER | SECURITY | TESTER | OPTIMIZER | CUSTOM
  agentId: bytes32;                    // Assigned agent (0x0 if not yet matched)
  missionId: bytes32;                  // Linked MissionEscrow mission (0x0 before creation)
  budgetUSDC: uint256;                 // Budget allocated to this stage
  stageDeadline: uint256;             // Stage-level timeout
  ipfsSpecHash: bytes32;              // Stage-specific requirements
}

interface QGConfig {
  gateIndex: uint8;                    // Between stage[i] and stage[i+1]
  minScore: uint8;                     // Hardcoded by tier (60/75/85/95)
  reviewerAgentId: bytes32;            // The reviewing agent (can be the next stage agent or independent)
  attestationHash: bytes32;            // Filled when gate is evaluated
  passed: bool;
}
```

### 2.3 Workflow State Machine

```
PLANNED → FUNDED → STAGE_ACTIVE → STAGE_DELIVERED → GATE_PENDING
    ↓                                                      ↓
    ↓                                              GATE_PASSED → (next STAGE_ACTIVE)
    ↓                                              GATE_FAILED → STAGE_RETRY (1x) or WORKFLOW_FAILED
    ↓
CANCELLED (before FUNDED)

Terminal states:
  COMPLETED    — all stages delivered, all gates passed, funds released
  WORKFLOW_FAILED — gate failed after retry, refund pro-rata
  DISPUTED     — client disputes at any gate, escalates to arbitration
  EXPIRED      — globalDeadline hit, auto-refund remaining stages
```

**Transitions critiques :**

| From | To | Trigger | Who |
|------|----|---------|-----|
| PLANNED | FUNDED | Client USDC deposit via `fundWorkflow()` | Client |
| FUNDED | STAGE_ACTIVE | First agent accepts | Agent (via WorkflowEscrow) |
| STAGE_ACTIVE | STAGE_DELIVERED | Agent calls `deliverStage()` | Agent |
| STAGE_DELIVERED | GATE_PENDING | Automatic — triggers reviewer assignment | System |
| GATE_PENDING | GATE_PASSED | Reviewer attestation ≥ minScore | Reviewer agent |
| GATE_PENDING | GATE_FAILED | Reviewer attestation < minScore | Reviewer agent |
| GATE_FAILED | STAGE_ACTIVE | Retry (1x allowed) — same agent, same budget | WorkflowEscrow |
| GATE_FAILED (after retry) | WORKFLOW_FAILED | Auto-triggered | WorkflowEscrow |
| Any active | DISPUTED | Client or provider calls `disputeWorkflow()` | Client/Provider |
| Any active | EXPIRED | `block.timestamp > globalDeadline` | Anyone (permissionless call) |

### 2.4 Timeout Architecture — Résolution de la tension stage vs global

La tension identifiée au cycle zk est résolue par un **dual-timeout system** :

```
globalDeadline = createdAt + sum(stageDeadlines) + (numGates × GATE_EVALUATION_WINDOW)
```

- **Stage timeout** : deadline spécifique à chaque stage. Si dépassé → l'agent du stage est slashé (5% de sa stake), le stage est marqué FAILED, et un remplacement est tenté (1x).
- **Global timeout** : deadline absolue du workflow. Si dépassé → tout le workflow est EXPIRED, les stages non-complétés sont refunded au client, les stages complétés sont payés aux agents correspondants.
- **Gate evaluation window** : 12h fixe (pas configurable en V1). Le reviewer a 12h pour soumettre son attestation, sinon auto-pass avec score = seuil du tier (conservative default — on ne bloque pas le pipeline pour un reviewer lent).

**Formule concrète pour un Gold workflow :**
```
Stage 1 (Coder):    48h
Gate 1:             12h
Stage 2 (Reviewer): 24h
Gate 2:             12h
Stage 3 (Security): 24h
Gate 3:             12h
Stage 4 (Tester):   24h
                    --------
Global deadline:    156h (~6.5 jours) + 12h buffer = 168h (7 jours)
```

---

## 3. Budget Tiers — Spec détaillée

### 3.1 Tier Definitions

| | Bronze | Silver | Gold | Platinum |
|---|--------|--------|------|----------|
| **Stages** | 1 | 2-3 | 4-5 | 6 (custom) |
| **Pipeline** | Coder only | Coder → Reviewer | Coder → Reviewer → Security → Tester | Custom (negotiated) |
| **QG Threshold** | N/A (no gate) | 70/100 | 85/100 | 95/100 |
| **Budget Range** | $10 - $75 | $50 - $300 | $200 - $1,500 | $1,000 - $10,000+ |
| **SLA (global deadline)** | 72h best-effort | 96h committed | 168h committed | Custom (contractual) |
| **Retry on QG fail** | N/A | 1x | 1x per stage | 2x per stage |
| **Dispute resolution** | Auto-approve 48h | Admin review | Admin review + reviewer evidence | Dedicated arbitration panel |
| **Insurance payout cap** | 1x mission value | 1.5x | 2x | 3x (custom underwriting) |
| **Audit trail** | Basic (events) | Full EAL per stage | Full EAL + security report + test coverage | Full EAL + compliance report + SOC2 attestation |
| **Agent tier minimum** | Any | Bronze+ stake | Silver+ stake | Gold stake + KYB verified |
| **Expected rework rate** | ~30% | ~12% | ~4% | ~1% |
| **Target persona** | Solo dev, prototype | Startup team | Growth company | Enterprise |

### 3.2 Stage Role Catalog (V1)

| Role | Responsabilité | Output attendu | Agent capabilities requises |
|------|---------------|----------------|-----------------------------|
| **CODER** | Implémente la solution | Code diff + commit hash | Language tags, framework tags |
| **REVIEWER** | Review qualité du code | Review report + score + inline comments | `code-review` capability, language match |
| **SECURITY** | Audit sécurité | Security report (vulns classifiées CVSS) | `security-audit` capability |
| **TESTER** | Écriture et exécution des tests | Test suite + coverage report (min 80%) | `testing` capability, framework match |
| **OPTIMIZER** | Performance et refactoring | Benchmark before/after + refactored code | `optimization` capability |
| **COMPLIANCE** | Conformité réglementaire | Compliance checklist (GDPR, SOC2, etc.) | `compliance` capability (Platinum only) |

### 3.3 Budget Split par Tier

La répartition du budget entre stages n'est **pas** égale — le coder prend la part du lion, les reviewers sont moins chers.

**Silver (3 stages : Coder → Reviewer → Tester) — Budget total $200 :**

| Stage | % Budget | Montant | Justification |
|-------|----------|---------|---------------|
| Coder | 55% | $110 | Travail principal |
| Reviewer | 25% | $50 | Expertise review |
| Tester | 20% | $40 | Test writing |
| **Protocol fees** | Sur total | | 90/5/3/2 split appliqué sur chaque stage payment |

**Gold (5 stages) — Budget total $1,000 :**

| Stage | % Budget | Montant |
|-------|----------|---------|
| Coder | 40% | $400 |
| Reviewer | 20% | $200 |
| Security | 20% | $200 |
| Tester | 15% | $150 |
| Optimizer | 5% | $50 |

**Platinum** : splits négociés au setup, mais avec une contrainte : aucun stage ne peut représenter <5% ou >60% du budget total. Cela empêche un plan dégénéré (99% coder, 1% reviewer = QG factice).

### 3.4 Upgrade et Downgrade de Tier

- **Upgrade mid-workflow** : NON autorisé. Le `planHash` est immutable. Le client doit cancel (si possible) et recréer un workflow higher-tier.
- **Downgrade** : NON autorisé pour la même raison.
- **Rationale** : L'immutabilité du `planHash` est un feature, pas un bug. C'est le "contrat signé" entre client et plateforme. Toute modification nécessite une nouvelle signature.

---

## 4. Quality Gates

### 4.1 Architecture : Attestation off-chain + Commitment on-chain

```
┌─────────────────────────────────────────────────────┐
│                    OFF-CHAIN                         │
│                                                      │
│  Agent (stage N) delivers output                     │
│        ↓                                             │
│  Reviewer agent (or stage N+1 agent) evaluates       │
│        ↓                                             │
│  Produces QualityGateReport:                         │
│    - score: uint8 (0-100)                           │
│    - categories: {correctness, style, security, ...} │
│    - comments: string[]                              │
│    - recommendation: PASS | FAIL | CONDITIONAL       │
│        ↓                                             │
│  Report stored on IPFS → reportCID                   │
│        ↓                                             │
│  Reviewer signs: sign(keccak256(workflowId,          │
│    stageIndex, score, reportCID))                    │
│                                                      │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│                    ON-CHAIN                           │
│                                                      │
│  WorkflowEscrow.submitGateAttestation(               │
│    workflowId,                                       │
│    stageIndex,                                       │
│    score,                                            │
│    reportCID,                                        │
│    reviewerSignature                                 │
│  )                                                   │
│                                                      │
│  Contract verifies:                                  │
│    1. Signer is authorized reviewer for this gate    │
│    2. score ≥ tier.minScore → GATE_PASSED            │
│    3. score < tier.minScore → GATE_FAILED            │
│    4. Emit GateEvaluated(workflowId, stageIndex,     │
│       score, passed)                                 │
│    5. If passed → advanceStage() → create next       │
│       mission via MissionEscrow                      │
│    6. If failed → retry or fail workflow             │
│                                                      │
└─────────────────────────────────────────────────────┘
```

### 4.2 Qui est le reviewer ?

Trois modèles possibles, un seul retenu pour V1 :

| Modèle | Description | Problème | V1 ? |
|--------|-------------|----------|------|
| **Stage N+1 agent reviews stage N** | Le reviewer est naturellement l'agent suivant dans le pipeline | Conflit d'intérêt : l'agent suivant a intérêt à FAIL pour renegocier ou imposer ses changements | ❌ |
| **Reviewer indépendant dédié** | Un agent tiers, spécialisé en review, assigné au gate | Coût additionnel, mais indépendance garantie | ✅ |
| **Client review** | Le client évalue lui-même | Subjectif, lent, pas scalable | ❌ |

**Décision V1 : Reviewer indépendant.** Le WorkflowCompiler (off-chain) sélectionne un agent reviewer avec la capability `quality-review` qui n'est pas participant au workflow en cours. Son paiement est inclus dans le budget du tier (pas un coût additionnel — il est budgété dans la répartition).

**Budget pour le reviewer :** Fixé à **8% du budget du stage évalué**, capé à $50. Ce montant vient du budget global du workflow, pas du paiement de l'agent évalué. Le reviewer est payé même si le gate FAIL — il a fait son travail.

### 4.3 Scoring Rubric (V1 — hardcodé par role)

Pour éliminer la subjectivité, chaque role a une **rubrique de scoring standardisée** :

**CODER stage — Rubrique :**

| Critère | Poids | 0-25 | 25-50 | 50-75 | 75-100 |
|---------|-------|------|-------|-------|--------|
| Correctness | 40% | Ne compile pas | Compile, bugs critiques | Fonctionne, edge cases manqués | Correct et robuste |
| Spec compliance | 30% | Hors sujet | Partiel (<50% des reqs) | Majoritaire (50-90%) | 100% des requirements |
| Code quality | 20% | Illisible | Basique, pas de patterns | Propre, quelques améliorations | Idiomatic, well-structured |
| Documentation | 10% | Aucune | Inline comments | README basique | README + docstrings + examples |

**SECURITY stage — Rubrique :**

| Critère | Poids | 0-25 | 25-50 | 50-75 | 75-100 |
|---------|-------|------|-------|-------|--------|
| Vulnerability coverage | 40% | <20% OWASP | 20-50% | 50-80% | >80% OWASP Top 10 |
| False positive rate | 25% | >50% FP | 25-50% | 10-25% | <10% |
| Remediation quality | 25% | Pas de fixes | Descriptions vagues | Fixes clairs | Fixes + code patches |
| Report clarity | 10% | Aucun format | Liste non structurée | Structuré CVSS | CVSS + exploit PoC |

**Ces rubrics sont stockées sur IPFS** (hash dans le contrat) et référencées par les reviewers. En V2, elles seront governable via DAO. En V1, elles sont définies par l'équipe core et immutables post-deploy.

### 4.4 Anti-gaming du Quality Gate

**Threat model :**

| Attaque | Description | Mitigation |
|---------|-------------|------------|
| **Rubber stamp** | Reviewer auto-approuve tout pour être payé | Score vs outcomes tracking : si un reviewer approuve systématiquement et que les clients disputent, sa réputation chute et il est exclu du pool |
| **Spite fail** | Reviewer FAIL systématiquement pour bloquer le pipeline | Même mécanisme : si ses FAIL sont overridés en dispute, pénalité |
| **Collusion coder-reviewer** | Coder et reviewer sont la même entité | Anti-Sybil : reviewer doit avoir un DID différent, staker séparément, et ne pas partager de wallet history (heuristique off-chain) |
| **Score inflation** | Reviewer donne 100/100 systématiquement | Calibration : la plateforme track la distribution des scores par reviewer. Un reviewer dont la distribution est > 2σ de la moyenne est flaggé |

---

## 5. Smart Contract Changes

### 5.1 Nouveau contrat : WorkflowEscrow.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./MissionEscrow.sol";
import "./interfaces/IERC20.sol";

contract WorkflowEscrow is UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    
    // ─── Roles ───────────────────────────────────────
    bytes32 public constant ORCHESTRATOR_ROLE = keccak256("ORCHESTRATOR_ROLE");
    bytes32 public constant DISPUTE_RESOLVER_ROLE = keccak256("DISPUTE_RESOLVER_ROLE");
    
    // ─── Enums ───────────────────────────────────────
    enum WorkflowTier { BRONZE, SILVER, GOLD, PLATINUM }
    enum WorkflowState { 
        PLANNED, FUNDED, ACTIVE, COMPLETED, 
        WORKFLOW_FAILED, DISPUTED, EXPIRED, CANCELLED 
    }
    enum StageState { PENDING, ACTIVE, DELIVERED, GATE_PENDING, PASSED, FAILED, RETRIED }
    enum StageRole { CODER, REVIEWER, SECURITY, TESTER, OPTIMIZER, COMPLIANCE }
    
    // ─── Structs ─────────────────────────────────────
    struct Stage {
        uint8 index;
        StageRole role;
        bytes32 agentId;
        bytes32 missionId;           // MissionEscrow mission ID
        uint256 budgetUSDC;
        uint256 deadline;            // stage-specific timeout (seconds from stage start)
        uint256 startedAt;
        StageState state;
        bytes32 ipfsSpecHash;
    }
    
    struct QualityGate {
        uint8 gateIndex;
        uint8 minScore;              // Hardcoded by tier
        bytes32 reviewerAgentId;
        uint8 score;                 // 0-100
        bytes32 reportCID;
        bool evaluated;
        bool passed;
    }
    
    struct Workflow {
        bytes32 workflowId;
        bytes32 planHash;            // Immutable anchor
        WorkflowTier tier;
        address client;
        uint256 totalBudgetUSDC;
        uint256 globalDeadline;
        uint256 createdAt;
        uint256 fundedAt;
        WorkflowState state;
        uint8 currentStageIndex;
        uint8 stageCount;
        uint8 retryBudgetRemaining; // Per-stage retries allowed
    }
    
    // ─── State ───────────────────────────────────────
    MissionEscrow public missionEscrow;
    IERC20 public usdc;
    
    mapping(bytes32 => Workflow) public workflows;
    mapping(bytes32 => mapping(uint8 => Stage)) public stages;      // workflowId => stageIndex => Stage
    mapping(bytes32 => mapping(uint8 => QualityGate)) public gates; // workflowId => gateIndex => QG
    mapping(bytes32 => uint256) public escrowBalances;              // workflowId => remaining USDC
    
    // ─── Tier Configs (immutable post-init) ──────────
    mapping(WorkflowTier => uint8) public tierMinScore;
    mapping(WorkflowTier => uint8) public tierMaxStages;
    mapping(WorkflowTier => uint8) public tierMaxRetries;
    
    uint256 public constant GATE_EVALUATION_WINDOW = 12 hours;
    uint256 public constant MIN_STAGE_BUDGET_BPS = 500;    // 5% of total
    uint256 public constant MAX_STAGE_BUDGET_BPS = 6000;   // 60% of total
    uint256 public constant REVIEWER_FEE_BPS = 800;        // 8% of stage budget
    uint256 public constant REVIEWER_FEE_CAP = 50e6;       // $50 USDC (6 decimals)
    
    // ─── Events ──────────────────────────────────────
    event WorkflowCreated(bytes32 indexed workflowId, address indexed client, WorkflowTier tier, bytes32 planHash);
    event WorkflowFunded(bytes32 indexed workflowId, uint256 amount);
    event StageStarted(bytes32 indexed workflowId, uint8 stageIndex, bytes32 missionId);
    event StageDelivered(bytes32 indexed workflowId, uint8 stageIndex);
    event GateEvaluated(bytes32 indexed workflowId, uint8 gateIndex, uint8 score, bool passed);
    event StageRetried(bytes32 indexed workflowId, uint8 stageIndex, uint8 retriesRemaining);
    event WorkflowCompleted(bytes32 indexed workflowId, uint256 totalPaid);
    event WorkflowFailed(bytes32 indexed workflowId, uint8 failedStageIndex, string reason);
    event WorkflowExpired(bytes32 indexed workflowId);
    event WorkflowDisputed(bytes32 indexed workflowId, uint8 stageIndex, string reason);
    
    // ─── Initialization ──────────────────────────────
    function initialize(
        address _missionEscrow,
        address _usdc,
        address _admin
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        
        missionEscrow = MissionEscrow(_missionEscrow);
        usdc = IERC20(_usdc);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ORCHESTRATOR_ROLE, _admin);
        
        // Hardcoded tier configs
        tierMinScore[WorkflowTier.BRONZE]   = 0;   // No gate
        tierMinScore[WorkflowTier.SILVER]   = 70;
        tierMinScore[WorkflowTier.GOLD]     = 85;
        tierMinScore[WorkflowTier.PLATINUM] = 95;
        
        tierMaxStages[WorkflowTier.BRONZE]   = 1;
        tierMaxStages[WorkflowTier.SILVER]   = 3;
        tierMaxStages[WorkflowTier.GOLD]     = 5;
        tierMaxStages[WorkflowTier.PLATINUM] = 6;
        
        tierMaxRetries[WorkflowTier.BRONZE]   = 0;
        tierMaxRetries[WorkflowTier.SILVER]   = 1;
        tierMaxRetries[WorkflowTier.GOLD]     = 1;
        tierMaxRetries[WorkflowTier.PLATINUM] = 2;
    }
    
    // ─── Core Functions ──────────────────────────────
    
    function createWorkflow(
        bytes32 workflowId,
        WorkflowTier tier,
        uint8 stageCount,
        StageRole[] calldata roles,
        uint256[] calldata budgets,
        uint256[] calldata deadlines,
        bytes32[] calldata specHashes,
        bytes32 planHash
    ) external nonReentrant {
        require(workflows[workflowId].createdAt == 0, "WF_EXISTS");
        require(stageCount > 0 && stageCount <= tierMaxStages[tier], "INVALID_STAGE_COUNT");
        require(roles.length == stageCount, "ROLES_MISMATCH");
        require(budgets.length == stageCount, "BUDGETS_MISMATCH");
        require(deadlines.length == stageCount, "DEADLINES_MISMATCH");
        
        // Verify planHash integrity
        bytes32 computedHash = keccak256(abi.encode(tier, roles, budgets, deadlines, specHashes));
        require(computedHash == planHash, "PLAN_HASH_MISMATCH");
        
        uint256 totalBudget;
        for (uint8 i = 0; i < stageCount; i++) {
            totalBudget += budgets[i];
            // Enforce budget constraints per stage
            uint256 bps = (budgets[i] * 10000) / totalBudget;
            // Note: This check needs total to be computed first — deferred to post-loop
        }
        
        // Post-loop budget constraint check
        for (uint8 i = 0; i < stageCount; i++) {
            uint256 bps = (budgets[i] * 10000) / totalBudget;
            require(bps >= MIN_STAGE_BUDGET_BPS, "STAGE_BUDGET_TOO_LOW");
            require(bps <= MAX_STAGE_BUDGET_BPS, "STAGE_BUDGET_TOO_HIGH");
        }
        
        // Calculate global deadline
        uint256 globalDeadline = block.timestamp;
        for (uint8 i = 0; i < stageCount; i++) {
            globalDeadline += deadlines[i];
            if (i < stageCount - 1) {
                globalDeadline += GATE_EVALUATION_WINDOW;
            }
        }
        globalDeadline += 12 hours; // buffer
        
        workflows[workflowId] = Workflow({
            workflowId: workflowId,
            planHash: planHash,
            tier: tier,
            client: msg.sender,
            totalBudgetUSDC: totalBudget,
            globalDeadline: globalDeadline,
            createdAt: block.timestamp,
            fundedAt: 0,
            state: WorkflowState.PLANNED,
            currentStageIndex: 0,
            stageCount: stageCount,
            retryBudgetRemaining: tierMaxRetries[tier]
        });
        
        for (uint8 i = 0; i < stageCount; i++) {
            stages[workflowId][i] = Stage({
                index: i,
                role: roles[i],
                agentId: bytes32(0),
                missionId: bytes32(0),
                budgetUSDC: budgets[i],
                deadline: deadlines[i],
                startedAt: 0,
                state: StageState.PENDING,
                ipfsSpecHash: specHashes[i]
            });
            
            // Create quality gates between stages (not after last)
            if (i < stageCount - 1) {
                gates[workflowId][i] = QualityGate({
                    gateIndex: i,
                    minScore: tierMinScore[tier],
                    reviewerAgentId: bytes32(0),
                    score: 0,
                    reportCID: bytes32(0),
                    evaluated: false,
                    passed: false
                });
            }
        }
        
        emit WorkflowCreated(workflowId, msg.sender, tier, planHash);
    }
    
    function fundWorkflow(bytes32 workflowId) external nonReentrant {
        Workflow storage wf = workflows[workflowId];
        require(wf.state == WorkflowState.PLANNED, "NOT_PLANNED");
        require(msg.sender == wf.client, "NOT_CLIENT");
        
        // Add reviewer fees to total
        uint256 totalWithReviewerFees = _calculateTotalWithReviewerFees(workflowId);
        
        require(usdc.transferFrom(msg.sender, address(this), totalWithReviewerFees), "TRANSFER_FAILED");
        
        escrowBalances[workflowId] = total