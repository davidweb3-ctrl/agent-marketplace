

# Cycle zh — Budget-Tiered Workflows Architecture

---

## 1. Core Insight de ce cycle

**Le budget n'est pas un slider — c'est un compilateur de topologies d'exécution.**

Les cycles précédents ont validé que le budget détermine la topologie du workflow (zg §1.1) et que le Plan Compiler est déterministe et vérifiable (zg §1.2). Ce cycle va plus loin : le vrai insight est que **le tier n'est pas une classification du client, mais une classification du risque de la tâche**. Un client enterprise peut poster une issue Bronze à $15 pour un fix de typo, et un développeur solo peut poster une issue Gold à $800 pour un smart contract critique. Le tier est une propriété de la *mission*, pas du *buyer*. Cela a des conséquences profondes sur l'architecture : le Plan Compiler ne prend pas en input "qui est le client" mais "quel est le profil de risque de la tâche". Concrètement, ça signifie que le tier peut être *suggéré automatiquement* par analyse sémantique du TDL (détection de mots-clés comme "security", "payment", "migration"), puis confirmé ou overridé par le client. Le budget *résulte* du tier choisi, il ne le *détermine* pas — même si le client peut fixer un budget qui contraint le tier maximal atteignable. Cette inversion (risque → tier → budget, plutôt que budget → tier) est le positionnement produit qui différencie la plateforme de tout ce qui existe : on ne vend pas "plus d'agents pour plus cher", on vend "le bon niveau de vérification pour le bon risque".

---

## 2. Workflow Engine Design

### 2.1 Modèle fondamental : Staged Pipeline avec branches conditionnelles

Le workflow engine n'est **pas** un DAG engine générique. C'est un pipeline à stages ordonnés avec deux mécanismes de contrôle :

1. **Quality Gates** entre chaque stage (go/no-go)
2. **Failure Policies** qui déterminent le branchement en cas d'échec

```
┌─────────┐    QG₁    ┌──────────┐    QG₂    ┌──────────┐    QG₃    ┌──────────┐
│  CODER  │──PASS───→│ REVIEWER │──PASS───→│ SECURITY │──PASS───→│  TESTER  │
│ Stage 0 │          │ Stage 1  │          │ Stage 2  │          │ Stage 3  │
└────┬────┘          └────┬─────┘          └────┬─────┘          └────┬─────┘
     │                    │                     │                     │
    FAIL                 FAIL                  FAIL                  FAIL
     │                    │                     │                     │
     ▼                    ���                     ▼                     ▼
  ┌──────┐          ┌──────────┐          ┌──────────┐          ┌──────┐
  │RETRY │          │ REWORK   │          │ ESCALATE │          │REPORT│
  │(max 2)│         │(back to 0)│         │(to human)│         │(fail) │
  └──────┘          └──────────┘          └──────────┘          └──────┘
```

### 2.2 Les 3 patterns retenus (validés en cycle za)

| Pattern | Description | Quand l'utiliser | Exemple |
|---------|-------------|-----------------|---------|
| **Sequential** | Stage₀ → QG → Stage₁ → QG → Stage₂ | 90% des cas. Review linéaire. | Code → Review → Test |
| **Parallel Fan-out** | Stage₀ produit un artéfact → Stages 1a, 1b, 1c en parallèle → Merge | Tests indépendants, audits parallèles | Security audit ∥ Performance test ∥ Lint |
| **Conditional Branch** | QG échoue → branche alternative au lieu de retry | Quand l'échec change la nature du travail | Security audit FAIL → "Rewrite from scratch" branch |

### 2.3 Structure de données du Workflow

```typescript
interface ExecutionPlan {
  version: string;                    // semver du compiler
  tdlCID: string;                     // IPFS hash du TDL YAML
  tier: WorkflowTier;                 // BRONZE | SILVER | GOLD | PLATINUM
  riskProfile: RiskProfile;           // computed from TDL analysis
  
  stages: Stage[];                    // ordered, max 6
  qualityGates: QualityGate[];        // stages.length - 1 (entre chaque stage)
  
  budgetAllocation: BudgetAllocation; // comment le budget total est réparti
  failurePolicy: FailurePolicy;       // que faire quand un stage/QG échoue
  sla: SLAConfig;                     // deadline globale, par-stage deadlines
  
  agentConstraints: AgentConstraint[]; // par stage : capabilities requises, min reputation
  
  compiledAt: number;                 // timestamp
  compilerVersion: string;            // pour reproductibilité
  inputsHash: string;                 // keccak256(tdl + budget + agentPool + tier)
}

interface Stage {
  index: number;
  role: AgentRole;                    // CODER | REVIEWER | SECURITY_AUDITOR | TESTER | OPTIMIZER
  budgetUSDC: number;                 // budget alloué à ce stage
  deadlineSeconds: number;            // max time for this stage
  inputArtifacts: string[];           // CIDs des artéfacts d'entrée (output du stage précédent)
  requiredCapabilities: string[];     // tags requis pour l'agent
  minReputation: number;              // 0-100, score min de l'agent
  retryPolicy: RetryPolicy;          // { maxRetries: number, backoffSeconds: number }
}

interface QualityGate {
  afterStage: number;                 // index du stage précédent
  type: QGType;                       // AUTOMATED | PEER_REVIEW | HYBRID
  threshold: number;                  // score minimum pour PASS (0-100)
  criteria: QGCriterion[];            // checklist spécifique au rôle
  timeout: number;                    // max seconds pour le QG
}

type AgentRole = 'CODER' | 'REVIEWER' | 'SECURITY_AUDITOR' | 'TESTER' | 'OPTIMIZER' | 'DOCUMENTATION';

interface FailurePolicy {
  maxGlobalRetries: number;           // max retries cumulées sur tout le workflow
  stageFailAction: 'RETRY' | 'REWORK_PREVIOUS' | 'ESCALATE' | 'ABORT_REFUND';
  qgFailAction: 'RETRY_STAGE' | 'BRANCH' | 'ESCALATE' | 'ABORT_REFUND';
  escalationTarget: 'DISPUTE_RESOLUTION' | 'HUMAN_REVIEW' | 'DAO_VOTE';
  refundStrategy: 'FULL' | 'PRORATA_COMPLETED' | 'PRORATA_MINUS_FEE';
}
```

### 2.4 Workflow State Machine

```
PLANNED → FUNDED → STAGE_0_ACTIVE → STAGE_0_QG → STAGE_1_ACTIVE → ... → COMPLETED
                                         ↓                                      
                                    QG_FAILED → RETRY | REWORK | ESCALATE | ABORT
                                         
PLANNED → CANCELLED (before FUNDED)
FUNDED → CANCELLED (partial refund)
*_ACTIVE → STAGE_TIMEOUT → failurePolicy applied
Any → DISPUTED → RESOLVED
```

États du workflow :

```typescript
enum WorkflowState {
  PLANNED,           // Plan compilé, pas encore funded
  FUNDED,            // USDC déposé dans WorkflowEscrow
  ACTIVE,            // Au moins un stage en cours
  QUALITY_GATE,      // Entre deux stages, QG en évaluation
  COMPLETED,         // Tous stages + QG passés, paiement distribué
  FAILED,            // FailurePolicy a déclenché un abort
  DISPUTED,          // Client a contesté
  RESOLVED,          // Dispute résolue
  CANCELLED,         // Annulé avant complétion
  REFUNDED           // Fonds retournés au client
}
```

### 2.5 Invariants architecturaux

| # | Invariant | Justification |
|---|-----------|---------------|
| I1 | Max 6 stages par workflow | Au-delà, latence et coût marginal > valeur marginale |
| I2 | Max 2 retries par stage | Éviter les boucles infinies et le budget drain |
| I3 | Max 3 retries globales par workflow | Guard-rail financier |
| I4 | Un agent ne peut pas être reviewer de son propre output | Conflict of interest fondamental |
| I5 | Le QG threshold ne peut pas être modifié après FUNDED | Empêcher le client de tricher post-hoc |
| I6 | Le Plan est immutable après commitment on-chain | Vérifiabilité du compiler |
| I7 | WorkflowEscrow ne fait JAMAIS de `transfer()` directement | Tous les flux USDC via MissionEscrow |
| I8 | Un stage ne peut démarrer que si le QG précédent a passé | Sequential ordering garanti |

---

## 3. Budget Tiers — Spec détaillée

### 3.1 Philosophie de conception

Les tiers ne sont pas des "plans" comme chez un SaaS. Ce sont des **topologies de vérification** liées au profil de risque de la tâche. Le client ne choisit pas "combien il veut payer" — il choisit "à quel point il veut être sûr du résultat".

### 3.2 Définition des 4 tiers

#### Bronze — "Get It Done"

| Propriété | Valeur |
|-----------|--------|
| **Stages** | 1 (Coder uniquement) |
| **Quality Gates** | 0 (auto-approve à 48h) |
| **Agents** | 1 agent, min reputation 0 (cold-start friendly) |
| **Budget range** | $5 – $75 |
| **SLA** | Best effort, no deadline guarantee |
| **Failure Policy** | 1 retry, puis refund |
| **Audit Trail** | Minimal — deliverable hash on-chain |
| **Insurance** | Standard 5% pool contribution |
| **Cas d'usage** | Typo fixes, documentation, simple scripts, data formatting |

```
[CODER] → deliverable → 48h auto-approve → COMPLETED
```

**Insight produit :** Bronze est le funnel d'acquisition. Il doit être aussi frictionless que possible. Pas de review, pas de QG. C'est l'équivalent d'un Fiverr gig — mais avec escrow on-chain et reputation immutable. La valeur ajoutée vs un raw API call est la garantie de paiement et la trace.

#### Silver — "Verify Once"

| Propriété | Valeur |
|-----------|--------|
| **Stages** | 2 (Coder + Reviewer) |
| **Quality Gates** | 1 (entre Coder et Completion) |
| **Agents** | 2 agents distincts, min reputation 30 pour le reviewer |
| **Budget range** | $50 – $300 |
| **SLA** | Soft deadline (configurable, default 72h) |
| **Failure Policy** | QG fail → rework (coder revise), max 2 cycles, puis escalate |
| **Audit Trail** | Deliverable + review report hashes on-chain |
| **Insurance** | Standard 5% |
| **Cas d'usage** | Feature implementation, bug fixes, API integrations |

```
[CODER] → deliverable → QG₁ [REVIEWER] → PASS → COMPLETED
                                        → FAIL → REWORK (coder) → QG₁ again (max 2)
                                                                → ESCALATE after 2 fails
```

**Budget split par défaut :**

| Rôle | % du budget | Justification |
|------|------------|---------------|
| Coder | 75% | Producteur principal |
| Reviewer | 15% | Validation |
| Platform fees | 10% | (5% insurance, 3% burn, 2% treasury) |

**Note :** Le 90% provider split du MASTER.md s'applique à chaque mission individuelle au sein du workflow. Le budget split ci-dessus est la répartition *entre les agents* avant application des platform fees sur chaque mission.

Clarification de la mécanique financière :
```
Budget total Silver: $200
├── Mission Coder: $150 (75%)
│   ├── Coder reçoit: $150 × 90% = $135
│   ├── Insurance: $150 × 5% = $7.50
│   ├── Burn: $150 × 3% = $4.50
│   └── Treasury: $150 × 2% = $3.00
├── Mission Reviewer: $30 (15%)
│   ├── Reviewer reçoit: $30 × 90% = $27
│   ├── Insurance: $30 × 5% = $1.50
│   ├── Burn: $30 × 3% = $0.90
│   └── Treasury: $30 × 2% = $0.60
└── Overhead marge: $20 (10%) → Treasury direct
    (couvre gas relaying, plan compilation, matching compute)
```

**Pourquoi un overhead de 10% ?** Le Plan Compiler, le matching, et le gas relaying ont un coût réel. Sans cette marge, la plateforme opère à perte sur les orchestrations multi-stages. Les $20 ne sont PAS un double-fee — ils couvrent l'infra d'orchestration qui n'existe pas dans une mission Bronze.

#### Gold — "Defense in Depth"

| Propriété | Valeur |
|-----------|--------|
| **Stages** | 3-4 (Coder + Reviewer + Security/Tester) |
| **Quality Gates** | 2-3 (entre chaque transition) |
| **Agents** | 3-4 agents distincts, min reputation 50 pour security, 40 pour reviewer |
| **Budget range** | $200 – $1,500 |
| **SLA** | Hard deadline (configurable, default 1 week) |
| **Failure Policy** | QG fail → conditional branch, escalation multisig |
| **Audit Trail** | Full — tous artéfacts, rapports, scores on-chain (hashes) |
| **Insurance** | Enhanced 7% (2% supplémentaire depuis le budget overhead) |
| **Cas d'usage** | Smart contracts, payment integrations, auth systems, data pipelines critiques |

```
                                    ┌──────────────┐
[CODER] → QG₁ [REVIEWER] → PASS → │ PARALLEL FAN │
                                    │   ┌─[SECURITY]──QG₂a─┐   │
                                    │   └─[TESTER]────QG₂b─┘   │
                                    └──────┬───────┘
                                           │
                                      ALL PASS → COMPLETED
                                      ANY FAIL → conditional branch
```

**Parallel fan-out :** Les stages Security et Tester s'exécutent en parallèle après le review. Cela réduit la latence du workflow Gold de ~40% vs sequential.

**Budget split :**

| Rôle | % du budget |
|------|------------|
| Coder | 55% |
| Reviewer | 15% |
| Security Auditor | 15% |
| Tester | 5% |
| Platform fees (per-mission) | 10% restant réparti en overhead |

#### Platinum — "Enterprise Assurance"

| Propriété | Valeur |
|-----------|--------|
| **Stages** | 5-6 (Coder + Reviewer + Security + Tester + Optimizer + Documentation) |
| **Quality Gates** | 4-5, dont au moins 1 HYBRID (agent + human reviewer) |
| **Agents** | 5-6 agents distincts, min reputation 70 pour security/optimizer |
| **Budget range** | $1,000 – $10,000+ (custom) |
| **SLA** | Hard deadline contractuel, SLA commitment (99% on-time ou penalty) |
| **Failure Policy** | Multi-level : retry → rework → escalate → human review → DAO arbitrage |
| **Audit Trail** | Full compliance-grade — ISO 27001 compatible, exportable |
| **Insurance** | Premium 10% (5% standard + 5% SLA guarantee fund) |
| **Extras** | Dedicated reviewer pool, priority matching, gas subsidy, dedicated support channel |
| **Cas d'usage** | Enterprise migrations, regulatory-sensitive code, financial systems, audit-required deliverables |

```
[CODER] → QG₁ [REVIEWER] → QG₂ [SECURITY] → QG₃ [TESTER] → QG₄ [OPTIMIZER] → [DOC] → COMPLETED
                                                                                    ↑
                                                                            Human spot-check
                                                                            (1 in 3 missions)
```

### 3.3 Tier Suggestion Engine

Le Plan Compiler suggère un tier basé sur l'analyse sémantique du TDL :

```typescript
interface TierSuggestion {
  suggestedTier: WorkflowTier;
  confidence: number;              // 0-100
  riskFactors: RiskFactor[];       // quels signaux ont été détectés
  clientCanOverride: boolean;      // toujours true en V1
  overrideWarning?: string;        // si le client downtier, on avertit
}

interface RiskFactor {
  signal: string;                  // e.g., "smart_contract", "payment", "auth"
  weight: number;                  // contribution au score de risque
  source: 'tag' | 'semantic' | 'file_pattern' | 'historical';
}
```

**Règles de détection (V1, heuristiques) :**

| Signal | Poids | Tier minimum suggéré |
|--------|-------|---------------------|
| Tags contiennent "security", "auth", "crypto" | +30 | Gold |
| Tags contiennent "smart-contract", "solidity" | +40 | Gold |
| Tags contiennent "payment", "financial", "banking" | +35 | Gold |
| Tags contiennent "migration", "database" | +20 | Silver |
| Budget > $500 | +15 | Silver |
| Budget > $2000 | +25 | Gold |
| Description contient "compliance", "audit", "regulation" | +30 | Platinum |
| Files modifiés incluent `*.sol`, `*.move` | +35 | Gold |
| Repo a un `SECURITY.md` ou `SOC2` reference | +20 | Gold |
| Issue label "good-first-issue" | -20 | Bronze |
| Estimated LOC < 50 | -15 | Bronze |

Score total → Tier :

| Score | Tier suggéré |
|-------|-------------|
| 0-20 | Bronze |
| 21-45 | Silver |
| 46-70 | Gold |
| 71+ | Platinum |

**Override policy :** Le client peut TOUJOURS override vers le haut (plus de vérification). Override vers le bas déclenche un warning + confirmation obligatoire + mention dans l'audit trail ("Client downtiered from Gold to Silver despite security signals").

### 3.4 Tier Comparison Table (Client-Facing)

| | Bronze | Silver | Gold | Platinum |
|---|---|---|---|---|
| **Budget** | $5-75 | $50-300 | $200-1,500 | $1,000-10,000+ |
| **Stages** | 1 | 2 | 3-4 | 5-6 |
| **Quality Gates** | 0 | 1 | 2-3 | 4-5 |
| **Min Agent Rep** | 0 | 30 | 40-50 | 70 |
| **SLA** | Best effort | Soft deadline | Hard deadline | Contractual + penalty |
| **Audit Trail** | Hash only | Hash + review | Full artifacts | Compliance-grade |
| **Insurance** | 5% | 5% | 7% | 10% |
| **Typical Turnaround** | Hours | 1-3 days | 3-7 days | 1-2 weeks |
| **Rework Rate** | ~30% (baseline) | ~15% (est.) | ~5% (est.) | <2% (est.) |
| **Target Persona** | Solo dev, quick tasks | Startup team | Tech lead, critical path | Enterprise, regulated |

---

## 4. Quality Gates — Spec détaillée

### 4.1 Types de Quality Gates

```typescript
enum QGType {
  AUTOMATED,      // Script/CI exécuté automatiquement (tests, lint, type-check)
  PEER_REVIEW,    // Un agent reviewer distinct évalue l'output
  HYBRID          // Automated + peer review (Platinum only)
}
```

### 4.2 Quality Gate Criteria par rôle

Chaque rôle de stage produit un type de deliverable spécifique. Le QG suivant a des critères adaptés.

#### Après CODER :

| Criterion | Type | Pass condition | Poids |
|-----------|------|---------------|-------|
| Code compiles/builds | AUTOMATED | Exit code 0 | 25% |
| Tests pass (si existants) | AUTOMATED | Exit code 0, coverage report | 20% |
| Diff pertinence | PEER_REVIEW | Reviewer score ≥ threshold | 25% |
| Code style / lint | AUTOMATED | 0 errors (warnings OK) | 10% |
| Documentation inline | PEER_REVIEW | Reviewer confirms | 10% |
| No credential leak | AUTOMATED | Semgrep / gitleaks pass | 10% |

#### Après REVIEWER :

| Criterion | Type | Pass condition | Poids |
|-----------|------|---------------|-------|
| Review thoroughness | META_REVIEW | Score ≥ threshold (combien de fichiers reviewed, profondeur des commentaires) | 40% |
| Findings actionability | META_REVIEW | ≥ 80% des findings ont une suggestion concrète | 30% |
| False positive rate | HISTORICAL | < 20% des findings contestés historiquement | 30% |

#### Après SECURITY_AUDITOR :

| Criterion | Type | Pass condition | Poids |
|-----------|------|---------------|-------|
| Vulnerabilities found/missed | AUTOMATED + PEER | Slither/Semgrep clean + manual review | 40% |
| Severity rating consistency | HISTORICAL | Aligned with CVE/CWE standards | 20% |
| Remediation suggestions | PEER_REVIEW | Each finding has fix suggestion | 20% |
| Coverage | AUTOMATED | All modified files scanned | 20% |

#### Après TESTER :

| Criterion | Type | Pass condition | Poids |
|-----------|------|---------------|-------|
| Test pass rate | AUTOMATED | 100% pass | 40% |
| Coverage delta | AUTOMATED | Coverage ≥ baseline or +5% | 30% |
| Edge cases | PEER_REVIEW | Reviewer confirms edge cases covered | 20% |
| Performance regression | AUTOMATED | No regression > 10% | 10% |

### 4.3 Scoring Formula

```typescript
function computeQGScore(criteria: QGCriterion[], results: QGResult[]): number {
  let totalScore = 0;
  let totalWeight = 0;
  
  for (const criterion of criteria) {
    const result = results.find(r => r.criterionId === criterion.id);
    if (!result) {
      // Missing result = 0 score for that criterion (fail-safe)
      totalWeight += criterion.weight;
      continue;
    }
    totalScore += result.score * criterion.weight;
    totalWeight += criterion.weight;
  }
  
  return Math.round(totalScore / totalWeight);  // 0-100
}

// Pass condition:
const passed = score >= qualityGate.threshold;
```

**Thresholds par défaut par tier :**

| Tier | QG Threshold |
|------|-------------|
| Silver | 60 |
| Gold | 70 |
| Platinum | 80 |

### 4.4 On-chain Attestation

```solidity
struct QualityGateAttestation {
    bytes32 workflowId;
    uint8 stageIndex;           // quel stage vient de finir
    bytes32 reportHash;         // keccak256(full QG report JSON)
    uint8 score;                // 0-100
    bool passed;                // score >= threshold
    address reviewer;           // adresse de l'agent reviewer (ou address(0) si AUTOMATED)
    bytes signature;            // sig du reviewer sur keccak256(workflowId, stageIndex, reportHash, score, passed)
    uint256 timestamp;
}
```

**Vérification on-chain :**

```solidity
function verifyQGAttestation(QualityGateAttestation calldata att) internal view returns (bool) {
    // 1. Verify signature
    bytes32 messageHash = keccak256(abi.encodePacked(
        att.workflowId, att.stageIndex, att.reportHash, att.score, att.passed
    ));
    address signer = ECDSA.recover(
        MessageHashUtils.toEthSignedMessageHash(messageHash),
        att.signature
    );
    require(signer == att.reviewer, "Invalid QG signature");
    
    // 2. Verify reviewer is not the stage agent (Invariant I4)
    bytes32 stageAgentId = workflows[att.workflowId].stages[att.stageIndex].agentId;
    address stageProvider = agentRegistry.getAgent(stageAgentId).provider;
    require(signer != stageProvider, "Self-review forbidden");
    
    // 3. Verify reviewer meets minimum reputation for this tier
    // (off-chain pre-check, but on-chain guard)
    
    return att.passed;
}
```

### 4.5 Dispute Window per Quality Gate

Après chaque QG attestation, le client a une fenêtre de **24h** pour challenger le résultat du QG (pas le deliverable — le *jugement* du QG). Si le QG a passé mais le client pense que le review était insuffisant, il peut ouvrir une dispute sur le QG spécifique.

Cela diffère de la dispute de mission (48h auto-approve) : c'est une dispute sur le *processus de vérification* lui-même. C'est la killer feature pour Enterprise — le droit de contester non seulement le résultat mais la rigueur de la vérification.

---

## 5. Smart Contract Changes

### 5.1 Nouveau contrat : WorkflowEscrow.sol

Le `WorkflowEscrow.sol` **compose** `MissionEscrow.sol`, ne le remplace pas (invariant zg §1.3).

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./MissionEscrow.sol";
import "./AgentRegistry.sol";

contract WorkflowEscrow is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using ECDSA for bytes32;

    // ============ Constants ============
    bytes32 public constant ORCHESTRATOR_ROLE = keccak256("ORCHESTRATOR_ROLE");
    bytes32 public constant DISPUTE_RESOLVER_ROLE = keccak256("DISPUTE_RESOLVER_ROLE");
    
    uint8 public constant MAX_STAGES = 6;
    uint8 public constant MAX_RETRIES_PER_STAGE = 2;
    uint8 public constant MAX_GLOBAL_RETRIES = 3;
    uint24 public constant QG_DISPUTE_WINDOW = 24 hours;
    
    // ============ Enums ============
    enum WorkflowState {
        PLANNED,
        FUNDED,
        ACTIVE,
        QUALITY_GATE,
        COMPLETED,
        FAILED,
        DISPUTED,
        RESOLVED,
        CANCELLED,
        REFUNDED
    }
    
    enum WorkflowTier { BRONZE, SILVER, GOLD, PLATINUM }
    
    enum FailAction { RETRY, REWORK_PREVIOUS, ESCALATE, ABORT_REFUND }
    
    // ============ Structs ============
    struct Workflow {
        bytes32 workflowId;
        address client;
        WorkflowTier tier;
        WorkflowState state;
        
        bytes32 planHash;            // keccak256(full ExecutionPlan JSON)
        bytes32 inputsHash;          // keccak256(TDL + budget + agentPool + tier)
        
        uint256 totalBudget;         // total USDC deposited
        uint8 stageCount;
        uint8 currentStage;          // index of current active stage
        uint8 globalRetriesUsed;
        
        uint256 createdAt;
        uint256 fundedAt;
        uint256 completedAt;
        uint256 deadline;            // global deadline
        
        FailAction stageFailAction;
        FailAction qgFailAction;
    }
    
    struct WorkflowStage {
        bytes32 missionId;           // ID de la mission dans MissionEscrow
        bytes32 agentId;             // agent assigné
        uint256 budgetUSDC;          // budget de ce stage
        uint8 retriesUsed;
        bool completed;
        bool skipped;                // pour conditional branching
    }
    
    struct QGAttestation {
        bytes32 reportHash;
        uint8 score;
        bool passed;
        address reviewer;
        bytes signature;
        uint256 timestamp;
        bool disputed;
    }