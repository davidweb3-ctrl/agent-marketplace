

# Cycle zd — Budget-Tiered Workflows Architecture

---

## 1. Core Insight de ce cycle

Le vrai produit qu'on construit n'est pas un marketplace d'agents — c'est un **compilateur de confiance**. Le client écrit une spécification (le TDL YAML), alloue un budget, et le système compile ce budget en un pipeline de vérifications dont la rigueur est proportionnelle au montant investi. C'est l'insight architectural central de ce cycle : le `WorkflowEscrow` n'est pas un simple orchestrateur séquentiel, c'est un **compilateur qui transforme un tuple `(task_spec, budget, risk_profile)` en un DAG d'exécution concret avec des agents assignés, des quality gates paramétrés, et des SLA calculés**. La conséquence directe est que le workflow engine ne doit PAS être un système de templates rigides (Bronze = toujours 1 agent, Gold = toujours 5 agents). Il doit être un **plan compiler** qui, étant donné les contraintes d'entrée, génère le plan d'exécution optimal. Les tiers Bronze/Silver/Gold/Platinum sont des presets marketing qui appellent ce compiler avec des paramètres prédéfinis, mais un client enterprise peut fournir ses propres contraintes (`min_review_passes: 3`, `require_security_audit: true`, `max_latency: 4h`) et le compiler génère un plan custom. C'est ce qui différencie fondamentalement le produit d'un simple "multi-step agent pipeline" — et c'est ce qui justifie le token economics, parce que plus le plan est complexe, plus il brûle d'AGNT.

---

## 2. Workflow Engine Design

### 2.1 Modèle : Pipeline Séquentiel Contraint avec Conditional Exit

Confirmé par le cycle zc : V1 = séquentiel strict. Mais l'architecture doit anticiper V2 sans tout casser. Voici le modèle formel.

#### Entité centrale : `WorkflowPlan`

```typescript
interface WorkflowPlan {
  workflowId: bytes32;
  clientAddress: address;
  tier: TierPreset | "CUSTOM";
  totalBudgetUSDC: uint256;
  stages: Stage[];            // ordered, max 6
  qualityGates: QualityGate[]; // stages.length - 1 gates (between each stage)
  globalDeadline: uint256;     // timestamp
  failurePolicy: FailurePolicy;
}

interface Stage {
  index: uint8;               // 0-5
  role: StageRole;            // CODER | REVIEWER | SECURITY | TESTER | OPTIMIZER | CUSTOM
  agentId: bytes32 | null;    // null = auto-match
  budgetUSDC: uint256;        // portion of total budget for this stage
  timeoutSeconds: uint256;    // max time for this stage
  requiredCapabilities: bytes32[]; // tag filter for matching
  minReputationScore: uint8;  // 0-100
}

interface QualityGate {
  gateIndex: uint8;
  qualityThreshold: uint8;    // 0-100, score minimum to pass
  failureAction: "HALT" | "RETRY_ONCE" | "SKIP_IF_BRONZE";
  maxRetries: uint8;          // 0 or 1 in V1
}
```

#### Flux d'exécution V1

```
┌──────────────────────────────────────────────────────────────────────┐
│                        WORKFLOW LIFECYCLE                             │
│                                                                      │
│  PLAN_CREATED ──→ STAGE[0] ──→ GATE[0] ──→ STAGE[1] ──→ GATE[1]   │
│       │              │            │             │            │        │
│       │          EXECUTING    PASS/FAIL     EXECUTING    PASS/FAIL   │
│       │              │            │             │            │        │
│       │              ▼            │             ▼            │        │
│       │         DELIVERED ───────┘         DELIVERED ───────┘        │
│       │                                                              │
│       │  ... ──→ STAGE[N] ──→ FINAL_QA ──→ WORKFLOW_COMPLETED      │
│       │                           │                                  │
│       │                       PASS/FAIL                              │
│       │                           │                                  │
│       ├──── CANCELLED (before any stage ACCEPTED)                    │
│       ├──── FAILED (quality gate hard fail, no retries left)         │
│       └──── DISPUTED (client challenges any gate attestation)        │
└──────────────────────────────────────────────────────────────────────┘
```

#### Pourquoi pas un DAG en V1 — le cas définitif

J'ai analysé les 3 patterns proposés en cycle za (Sequential, Parallel Fan-out, Conditional Branch). Pour des GitHub Issues unitaires :

| Pattern | Use Case Réel V1 | Fréquence estimée |
|---|---|---|
| Sequential | Code → Review → Fix → Test | 90%+ |
| Parallel Fan-out | Security scan ∥ Performance test | <5% |
| Conditional Branch | IF security_fail THEN hotfix ELSE proceed | <5% |

Le parallélisme n'a de sens que quand les stages sont **indépendants en input**. Pour une single issue, chaque stage dépend de l'output du précédent (le reviewer a besoin du code, le tester a besoin du code fixé). Le seul cas de parallélisme réel serait security + perf testing sur le même code, et ça peut attendre V2.

**Décision ferme : V1 = `Stage[]` ordonné, itéré séquentiellement. Le `WorkflowPlan` est un array, pas un graph.**

### 2.2 Le Plan Compiler

Le compiler est un service off-chain (pas on-chain — trop de logique métier, trop cher en gas).

```
┌─────────────────────────────────────────────────────┐
│              PLAN COMPILER (off-chain)               │
│                                                      │
│  INPUT:                                              │
│    - TDL YAML (task description)                     │
│    - Budget USDC                                     │
│    - Tier preset OR custom constraints               │
│    - Available agent pool (from AgentRegistry)       │
│                                                      │
│  PROCESS:                                            │
│    1. Parse TDL → extract task complexity signals     │
│       (LOC estimate, language, deps, security flag)  │
│    2. Map tier → stage template                      │
│    3. Allocate budget across stages (see §8)         │
│    4. Match agents per stage (see §6)                │
│    5. Set quality thresholds per gate                │
│    6. Calculate global deadline                      │
│                                                      │
│  OUTPUT:                                             │
│    - WorkflowPlan (serialized)                       │
│    - Plan hash (keccak256)                           │
│    - Client signs plan → submitted on-chain          │
│                                                      │
│  ON-CHAIN:                                           │
│    WorkflowEscrow.createWorkflow(planHash, stages,   │
│      budgetSplits, gateConfigs)                      │
│    → Locks total USDC in escrow                      │
│    → Emits WorkflowCreated event                     │
└─────────────────────────────────────────────────────┘
```

**Pourquoi off-chain :** Le plan compiler a besoin de pgvector embeddings, d'accès au pool d'agents avec leur disponibilité temps réel (heartbeat), et de logique de pricing dynamique. Rien de ça ne va on-chain. Le contrat reçoit le plan finalisé et l'exécute — séparation claire entre **planning** (off-chain, flexible, évolutif) et **settlement** (on-chain, déterministe, vérifiable).

**Guard-rail anti-manipulation :** Le client voit et signe le plan avant qu'il soit soumis on-chain. Le plan hash lie le client au contenu exact. Si le plan compiler proposait un plan gonflé, le client refuse. Transparence par design.

---

## 3. Budget Tiers — Spec détaillée

### 3.1 Définitions formelles

| Tier | Stages | Rôles | Budget Range | Quality Threshold | SLA Deadline | Retry Policy |
|---|---|---|---|---|---|---|
| **Bronze** | 1 | `CODER` | $10–80 | N/A (pas de gate) | 24h | Aucun |
| **Silver** | 3 | `CODER → REVIEWER → CODER_FIX` | $50–250 | 70/100 | 48h | 1 retry sur fix |
| **Gold** | 5 | `CODER → REVIEWER → CODER_FIX → SECURITY → FINAL_QA` | $200–800 | 80/100 | 72h | 1 retry par stage |
| **Platinum** | 6 | `CODER → REVIEWER → CODER_FIX → SECURITY → OPTIMIZER → FINAL_QA` | $500–2000 | 90/100 | 96h | 1 retry + escalation to human |

### 3.2 Détail par tier

#### Bronze — "Ship Fast"

```yaml
tier: BRONZE
stages:
  - role: CODER
    budget_share: 100%
    min_reputation: 30
    timeout: 24h
quality_gates: []  # none
client_review: MANUAL  # client approves or disputes
auto_approve: 48h
insurance: false  # no insurance pool contribution on Bronze
```

**Produit :** Un agent prend l'issue, code, livre. Le client review manuellement. C'est le Fiverr de l'agent AI : rapide, pas cher, aucune garantie au-delà de l'escrow. Best effort.

**Pourquoi ça existe :** Onboarding. Le client teste la plateforme à bas coût. Funnel d'acquisition. Aussi utile pour les tâches genuinement simples (fix typo, add config, update dependency).

#### Silver — "Standard Quality"

```yaml
tier: SILVER
stages:
  - role: CODER
    budget_share: 55%
    min_reputation: 50
    timeout: 24h
  - role: REVIEWER
    budget_share: 25%
    min_reputation: 60
    timeout: 12h
  - role: CODER_FIX
    budget_share: 20%
    min_reputation: 50  # same agent as stage 0
    timeout: 12h
quality_gates:
  - after_stage: 0
    threshold: 70
    failure_action: HALT
  - after_stage: 1  # review produces fix list
    threshold: 70
    failure_action: RETRY_ONCE
auto_approve: 48h
insurance: true
```

**Produit :** Le standard. Un agent code, un autre review, le premier fixe les issues trouvées. C'est l'équivalent d'une PR avec code review. Le client obtient un livrable qui a été validé par un deuxième pair de yeux AI.

**Subtilité architecturale — le CODER_FIX est-il le même agent que le CODER ?**

Oui par défaut. C'est le même `agentId` réutilisé pour le stage 2. Raisons :
- L'agent a le contexte du code qu'il a écrit
- Pas de coût de context switching
- L'agent est payé pour la fix, ce qui l'incentivise à fixer proprement

Mais si le REVIEWER score < 40 (qualité catastrophique), le plan compiler peut assigner un agent CODER différent pour le fix. C'est un conditional dans le compiler, pas dans le contrat.

#### Gold — "Enterprise Standard"

```yaml
tier: GOLD
stages:
  - role: CODER
    budget_share: 40%
    min_reputation: 65
    timeout: 24h
  - role: REVIEWER
    budget_share: 15%
    min_reputation: 70
    timeout: 12h
  - role: CODER_FIX
    budget_share: 15%
    min_reputation: 65
    timeout: 12h
  - role: SECURITY_AUDITOR
    budget_share: 20%
    min_reputation: 75
    timeout: 12h
  - role: FINAL_QA
    budget_share: 10%
    min_reputation: 70
    timeout: 6h
quality_gates:
  - after_stage: 0  # post-code
    threshold: 75
    failure_action: HALT
  - after_stage: 1  # post-review
    threshold: 75
    failure_action: RETRY_ONCE
  - after_stage: 2  # post-fix
    threshold: 80
    failure_action: HALT
  - after_stage: 3  # post-security
    threshold: 85
    failure_action: HALT  # security fail = hard stop
auto_approve: 48h
insurance: true
sla_guarantee: "structural"
audit_trail: COMPLETE  # all EALs, attestations, IPFS CIDs archived
```

**Produit :** Le premier tier qui inclut un audit de sécurité. Pour du code qui touche à l'auth, au paiement, aux données sensibles. L'enterprise buyer qui a un compliance checklist achète ce tier.

**Le FINAL_QA n'est pas un rubber stamp.** C'est un agent spécialisé qui :
- Vérifie que tous les tests passent
- Vérifie que le code fixé intègre bien les commentaires du reviewer ET les findings du security auditor
- Produit un rapport de conformité récapitulatif

Si le FINAL_QA fail, c'est un signal fort que le pipeline a un problème systémique. Pas de retry automatique — le workflow passe en DISPUTED pour review humain.

#### Platinum — "Mission Critical"

```yaml
tier: PLATINUM
stages:
  - role: CODER
    budget_share: 30%
    min_reputation: 80
    timeout: 24h
  - role: REVIEWER
    budget_share: 12%
    min_reputation: 80
    timeout: 12h
  - role: CODER_FIX
    budget_share: 13%
    min_reputation: 80
    timeout: 12h
  - role: SECURITY_AUDITOR
    budget_share: 20%
    min_reputation: 85
    timeout: 12h
  - role: OPTIMIZER
    budget_share: 15%
    min_reputation: 80
    timeout: 12h
  - role: FINAL_QA
    budget_share: 10%
    min_reputation: 85
    timeout: 6h
quality_gates:
  - after_stage: 0
    threshold: 80
    failure_action: HALT
  - after_stage: 1
    threshold: 80
    failure_action: RETRY_ONCE
  - after_stage: 2
    threshold: 85
    failure_action: HALT
  - after_stage: 3
    threshold: 90
    failure_action: HALT
  - after_stage: 4
    threshold: 85
    failure_action: HALT
auto_approve: 72h  # more time for manual review
insurance: true
sla_guarantee: "structural_plus"
audit_trail: COMPLETE
escalation: HUMAN_MULTISIG  # automatic escalation if any gate fails twice
```

**Produit :** Le OPTIMIZER est le stage différenciant. Ce n'est pas un "make it faster" générique. C'est un agent spécialisé qui :
- Analyse la complexité algorithmique
- Identifie les N+1 queries, les allocations inutiles, les hot paths
- Propose des refactors avec benchmarks avant/après
- S'assure que les optimizations ne cassent pas les fixes du CODER_FIX ni les recommendations du SECURITY_AUDITOR

**Le Platinum est le seul tier où l'escalation humaine est automatique.** Si un quality gate fail deux fois, un multisig de 3 reviewers humains est déclenché. C'est le safety net ultime. Coût additionnel facturé au client (prévu dans le budget split).

### 3.3 Contraintes inter-agents

**Règle anti-collusion :** Aucun agent dans un workflow ne peut partager le même `provider_id` qu'un autre agent du même workflow. Si Provider X fournit le CODER, un autre provider fournit le REVIEWER. Sans cette règle, un provider pourrait auto-review ses propres agents et rubber-stamp.

Exception : Le CODER et le CODER_FIX peuvent être le même agent (même provider). C'est logique — l'auteur du code est le mieux placé pour le fixer. Mais le REVIEWER et le SECURITY_AUDITOR doivent être d'un provider différent du CODER.

```
provider(CODER) = provider(CODER_FIX)  ✅ allowed
provider(CODER) ≠ provider(REVIEWER)    ✅ enforced
provider(CODER) ≠ provider(SECURITY)    ✅ enforced
provider(REVIEWER) ≠ provider(SECURITY) ⚠️ recommended, not enforced V1
```

**Enforcé où ?** Dans le Plan Compiler (off-chain) ET vérifié on-chain dans `WorkflowEscrow.createWorkflow()` via lookup sur `AgentRegistry.getAgent(agentId).provider`. Dual enforcement.

---

## 4. Quality Gates

### 4.1 Architecture des Quality Gates

Le cycle zc a validé le pattern "attestation off-chain + commitment on-chain". Ce cycle formalise l'implémentation.

#### Structure de données on-chain

```solidity
struct QualityGateConfig {
    uint8 stageIndex;          // which stage this gate follows
    uint8 qualityThreshold;    // 0-100, minimum score to pass
    uint8 maxRetries;          // 0 or 1 in V1
    FailureAction failureAction; // HALT, RETRY_ONCE, ESCALATE
}

struct QualityGateAttestation {
    bytes32 workflowId;
    uint8 stageIndex;
    bytes32 ipfsCid;           // full report on IPFS
    uint8 score;               // 0-100
    uint256 timestamp;
    address attestorAgent;     // the agent who performed the review
    bytes signature;           // EIP-712 typed signature
}

enum GateResult { PENDING, PASSED, FAILED, RETRYING, ESCALATED }
```

#### Flux d'un Quality Gate

```
Stage N completes (DELIVERED state in MissionEscrow)
       │
       ▼
WorkflowEscrow emits StageDelivered(workflowId, stageIndex)
       │
       ▼
Off-chain: Next-stage agent (or dedicated reviewer) picks up output
       │
       ▼
Agent reviews output, produces:
  - Structured report (JSON)
  - Score 0-100
  - List of issues found (if any)
  - Stores on IPFS → CID
       │
       ▼
Agent calls WorkflowEscrow.submitGateAttestation(
    workflowId, stageIndex, ipfsCid, score, timestamp, signature
)
       │
       ▼
On-chain verification:
  1. Verify signature matches registered agent for next stage
  2. Verify agent is registered and active in AgentRegistry
  3. Verify agent.provider ≠ previous stage agent.provider (anti-collusion)
  4. Verify timestamp within acceptable window
       │
       ├── score >= threshold → GateResult.PASSED → advance to Stage N+1
       │
       ├── score < threshold AND retries remaining → GateResult.RETRYING
       │   → Stage N agent gets retry mission (same budget allocation)
       │   → New submission required within timeout
       │
       └─�� score < threshold AND no retries → GateResult.FAILED
           → failureAction executed:
              HALT → workflow FAILED, unused budget refunded
              ESCALATE → workflow DISPUTED, multisig invoked
```

### 4.2 Scoring Rubric

Le score 0-100 n'est pas arbitraire. Il est calculé par l'agent reviewer sur la base d'un rubric standardisé par `StageRole`. Chaque rôle a des critères pondérés.

#### Rubric pour REVIEWER (post-CODER)

| Critère | Poids | 0 | 50 | 100 |
|---|---|---|---|---|
| **Functional correctness** | 35% | Code doesn't run | Runs with bugs | Passes all spec requirements |
| **Code quality** | 20% | Spaghetti, no structure | Acceptable, minor issues | Clean, idiomatic, well-structured |
| **Test coverage** | 20% | No tests | Partial coverage | >80% coverage, edge cases |
| **Spec adherence** | 15% | Ignores TDL | Partial implementation | Fully addresses TDL |
| **Documentation** | 10% | None | Inline comments | README + inline + API docs |

Score final = Σ(critère × poids)

#### Rubric pour SECURITY_AUDITOR

| Critère | Poids | 0 | 50 | 100 |
|---|---|---|---|---|
| **Vulnerability count** | 40% | Critical vulns found | Minor vulns only | No vulns found |
| **OWASP compliance** | 25% | Multiple violations | Partial compliance | Full compliance |
| **Dependency safety** | 15% | Known CVEs in deps | Outdated but no CVEs | All deps current, no CVEs |
| **Input validation** | 10% | No validation | Partial | Complete sanitization |
| **Auth/AuthZ** | 10% | Broken auth | Functional but gaps | Robust, follows best practices |

#### Rubric pour FINAL_QA

| Critère | Poids | 0 | 50 | 100 |
|---|---|---|---|---|
| **All previous issues resolved** | 40% | Issues ignored | Partially resolved | All reviewer + security issues fixed |
| **Integration tests pass** | 25% | Failures | Flaky | All green |
| **Performance baseline** | 15% | Regression | No change | Improvement |
| **Deployment readiness** | 10% | Can't deploy | Manual steps needed | CI/CD ready |
| **Spec completeness** | 10% | Missing features | Minor gaps | 100% spec coverage |

### 4.3 Le problème du reviewer incompétent

**Challenge identifié :** Un agent reviewer peut être techniquement compétent mais systématiquement laxiste (score toujours 90+) ou systématiquement sévère (score toujours 30). Les deux cas polluent le signal.

**Mitigation V1 — Calibration par spot-check :**

Le système maintient un score de calibration par agent reviewer, basé sur des spot-checks aléatoires :
- 10% des attestations de review sont auditées par un deuxième reviewer (choisi aléatoirement parmi les Gold+ agents)
- Si le delta entre les deux scores > 25 points, l'attestation originale est flaggée
- 3 flags sur les 20 dernières attestations → le reviewer perd le rôle REVIEWER temporairement

Coût : Le spot-check reviewer est payé par le treasury (pas par le client). C'est un coût opérationnel de maintien de la qualité du réseau.

**Mitigation V2 — Statistical reputation :**

Avec suffisamment de données (>100 reviews par agent), on calcule :
- Score moyen donné vs score moyen du réseau
- Variance des scores (un bon reviewer a de la variance — pas tout à 90)
- Corrélation entre score donné et outcome final de la mission (completed vs disputed)

Un reviewer dont les scores ne corrèlent pas avec les outcomes est déranké.

---

## 5. Smart Contract Changes

### 5.1 Nouveau contrat : `WorkflowEscrow.sol`

Ce contrat **compose** avec `MissionEscrow.sol` existant. Il ne le modifie pas. `MissionEscrow` garde ses 14 tests verts.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./MissionEscrow.sol";
import "./AgentRegistry.sol";

contract WorkflowEscrow is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // ============ ENUMS ============
    
    enum WorkflowState { 
        CREATED,        // plan submitted, budget locked
        ACTIVE,         // at least one stage running
        COMPLETED,      // all stages passed, budget distributed
        FAILED,         // quality gate hard fail
        DISPUTED,       // client or system challenged
        CANCELLED,      // client cancelled before any stage ACCEPTED
        REFUNDED        // failed/cancelled, budget returned
    }
    
    enum StageRole { CODER, REVIEWER, CODER_FIX, SECURITY, OPTIMIZER, FINAL_QA }
    enum FailureAction { HALT, RETRY_ONCE, ESCALATE }
    enum GateResult { PENDING, PASSED, FAILED, RETRYING, ESCALATED }

    // ============ STRUCTS ============
    
    struct WorkflowConfig {
        bytes32 workflowId;
        address client;
        uint8 tier;                    // 0=Bronze, 1=Silver, 2=Gold, 3=Platinum
        uint256 totalBudgetUSDC;
        uint256 createdAt;
        uint256 globalDeadline;
        uint8 stageCount;
        WorkflowState state;
        uint8 currentStageIndex;
        bytes32 planHash;              // keccak256 of full plan for verification
    }
    
    struct StageConfig {
        StageRole role;
        bytes32 agentId;
        uint256 budgetUSDC;
        uint256 timeoutSeconds;
        uint8 minReputation;
        bytes32 missionId;             // created in MissionEscrow, populated on advance
    }
    
    struct QualityGateConfig {
        uint8 qualityThreshold;        // 0-100
        uint8 maxRetries;
        FailureAction failureAction;
    }
    
    struct GateAttestation {
        bytes32 ipfsCid;
        uint8 score;
        uint256 timestamp;
        address attestor;
        GateResult result;
        uint8 retryCount;
    }

    // ============ STATE ============
    
    MissionEscrow public missionEscrow;
    AgentRegistry public agentRegistry;
    IERC20 public usdc;
    
    mapping(bytes32 => WorkflowConfig) public workflows;
    mapping(bytes32 => StageConfig[]) public workflowStages;       // workflowId => stages
    mapping(bytes32 => QualityGateConfig[]) public workflowGates;  // workflowId => gates
    mapping(bytes32 => mapping(uint8 => GateAttestation)) public gateAttestations; // workflowId => stageIndex => attestation
    mapping(bytes32 => bytes32) public missionToWorkflow;          // missionId => workflowId (reverse lookup)
    
    uint8 public constant MAX_STAGES = 6;
    uint256 public constant ANTI_COLLUSION_CHECK = 1; // flag
    
    // ============ EVENTS ============
    
    event WorkflowCreated(bytes32 indexed workflowId, address indexed client, uint8 tier, uint256 totalBudget, uint8 stageCount);
    event StageStarted(bytes32 indexed workflowId, uint8 stageIndex, bytes32 missionId, bytes32 agentId);
    event StageDelivered(bytes32 indexed workflowId, uint8 stageIndex, bytes32 missionId);
    event GateAttestationSubmitted(bytes32 indexed workflowId, uint8 stageIndex, uint8 score, GateResult result);
    event WorkflowAdvanced(bytes32 indexed workflowId, uint8 fromStage, uint8 toStage);
    event WorkflowCompleted(bytes32 indexed workflowId, uint256 totalPaid);
    event WorkflowFailed(bytes32 indexed workflowId, uint8 failedStage, string reason);
    event WorkflowDisputed(bytes32 indexed workflowId, uint8 disputedStage);
    
    // ============ CORE FUNCTIONS ============
    
    /// @notice Creates a new workflow, locks total budget in USDC
    /// @dev Client must have approved this contract for totalBudget USDC
    function createWorkflow(
        bytes32 planHash,
        StageConfig[] calldata stages,
        QualityGateConfig[] calldata gates,
        uint256 globalDeadline
    ) external nonReentrant returns (bytes32 workflowId) {
        require(stages.length >= 1 && stages.length <= MAX_STAGES, "Invalid stage count");
        require(stages.length > 1 ? gates.length == stages.length - 1 : gates.length == 0, "Gate count mismatch");
        require(globalDeadline > block.timestamp + 1 hours, "Deadline too soon");
        
        // Verify total budget matches sum of stage budgets
        uint256 totalBudget;
        for (uint8 i = 0; i < stages.length; i++) {
            totalBudget += stages[i].budgetUSDC;
        }
        
        // Anti-collusion: verify no provider overlap between CODER and REVIEWER/SECURITY roles
        _enforceAntiCollusion(stages);
        
        // Lock USDC
        usdc.transferFrom(msg.sender, address(this), totalBudget);
        
        workflowId = keccak256(abi.encodePacked(msg.sender, planHash, block.timestamp, block.number));
        
        workflows[workflowId] = WorkflowConfig({
            workflowId: workflowId,
            client: msg.sender,
            tier: _deriveTier(stages.length),
            totalBudgetUSDC: totalBudget,
            createdAt: block.timestamp,
            globalDeadline: globalDeadline,
            stageCount: uint8(stages.length),
            state: WorkflowState.CREATED,
            currentStageIndex: 0,
            planHash: plan