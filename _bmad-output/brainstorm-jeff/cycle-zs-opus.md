

# Cycle zs — Budget-Tiered Workflows Architecture

---

## 1. Core Insight de ce cycle

**Le budget n'achète ni du compute, ni du temps, ni même une "probabilité de qualité" — il achète une topologie de vérification.** C'est l'insight qui différencie fondamentalement Agent Marketplace de tous les concurrents (Replit Agent, Devin, GitHub Copilot Workspace). Quand un client poste $50, il obtient un coder seul. Quand il poste $500, il n'obtient pas un "meilleur coder" — il obtient un **pipeline structurel** où chaque agent ne voit que l'artifact du précédent et produit une attestation indépendante. La qualité n'émerge pas d'un agent plus intelligent, elle émerge de l'**indépendance des regards**. C'est exactement le modèle de l'audit financier (Big 4), de la peer review scientifique, et du code review en ingénierie logicielle — sauf qu'ici, c'est automatisé, tarifé, et vérifiable on-chain. Le corollaire business est limpide : on ne se bat pas sur le prix de l'agent unitaire (race to the bottom), on se bat sur la **confiance du pipeline** (race to the top). Ça crée un moat : chaque pipeline complété avec succès enrichit le corpus de données qui permet d'affiner les tiers, les quality gates, et à terme de proposer des SLA probabilistes contractualisables. Le flywheel est : plus de missions → plus de données de qualité par tier → meilleur pricing → plus de clients enterprise → plus de missions.

---

## 2. Workflow Engine Design

### 2.1 Modèle fondamental : Sequential Spine with Parallel Wings (SSPW)

Validé par le cycle zr, mais on spécifie ici le modèle formel complet.

**Entités du moteur :**

```
Workflow
├── workflowId: bytes32
├── clientAddress: address
├── tier: enum {BRONZE, SILVER, GOLD, PLATINUM}
├── issueHash: bytes32           // hash de l'issue GitHub source
├── totalBudget: uint256         // USDC total
├── stages: Stage[]              // ordered
├── gates: QualityGate[]         // between stages
├── state: WorkflowState
└── createdAt: uint256

Stage
├── stageIndex: uint8
├── role: enum {CODER, REVIEWER, SECURITY_AUDITOR, TESTER, OPTIMIZER}
├── missionId: bytes32           // référence vers MissionEscrow
├── agentId: bytes32
├── budgetAllocation: uint256    // part du budget total
├── parallelGroup: uint8         // 0 = séquentiel, N>0 = parallèle avec même group
├── slaDeadline: uint64
├── status: StageStatus
└── artifactHash: bytes32        // IPFS CID de l'output

QualityGate
├── gateIndex: uint8
├── gateType: enum {AUTO_LINT, PEER_ATTESTATION, MERGE_GATE, CLIENT_APPROVAL}
├── requiredScore: uint8         // 0-100, threshold pour passer
├── attestationHash: bytes32     // commitment on-chain
├── passed: bool
└── timestamp: uint256
```

### 2.2 Topologies supportées V1

On ne supporte que **3 patterns** (décision cycle za confirmée) :

**Pattern 1 — Linear (Bronze/Silver)**
```
[CODER] → [Gate: lint] → [REVIEWER] → [Gate: attestation] → DONE
```

**Pattern 2 — Fan-out Review (Gold)**
```
[CODER] → [Gate: lint+build] → ┌─[REVIEWER]──────┐ → [Merge Gate] → [TESTER] → DONE
                                └─[SECURITY_AUDIT]─┘
```

**Pattern 3 — Full Pipeline with Conditional (Platinum)**
```
[CODER] → [Gate] → ┌─[REVIEWER]──────┐ → [Merge] → [TESTER] → [Gate] → [OPTIMIZER]? → DONE
                    ├─[SECURITY_AUDIT]─┤                              ↑
                    └─[COMPLIANCE]?────┘                    conditional: si score < 80
```

### 2.3 Règles formelles du moteur

| Règle | Spec | Justification |
|---|---|---|
| **R1** | Max 6 stages par workflow | Au-delà, latence > valeur ajoutée |
| **R2** | Max 3 stages en parallèle | Merge gate ingérable au-delà |
| **R3** | Stages producteurs (CODER, OPTIMIZER) toujours séquentiels | Ils mutent l'artifact |
| **R4** | Stages consommateurs (REVIEWER, SECURITY, TESTER) parallélisables | Read-only sur artifact |
| **R5** | Un merge gate exige ALL_PASS | Un seul fail bloque le pipeline |
| **R6** | Si un stage parallèle fail, les autres du même group sont CANCELLED | Pas de travail gaspillé |
| **R7** | Chaque stage crée une Mission dans MissionEscrow | Composabilité avec l'existant |
| **R8** | Un stage TIMEOUT trigger re-assignment, pas workflow fail | Résilience |
| **R9** | Le client peut cancel le workflow avant FIRST_STAGE_ACTIVE | Refund total |
| **R10** | Après FIRST_STAGE_ACTIVE, cancel → refund prorata des stages non-commencés | Fair pour tous |

### 2.4 Machine à états du Workflow

```
CREATED → FUNDED → STAGE_ACTIVE → STAGE_GATING → ... → ALL_STAGES_COMPLETE → COMPLETED
                                                                            ↗
CREATED → CANCELLED (avant funding)                     STAGE_GATING → GATE_FAILED → REMEDIATION → STAGE_ACTIVE
FUNDED → CANCELLED (avant first stage)                                            ↘ WORKFLOW_FAILED (max retries)
STAGE_ACTIVE → DISPUTED → RESOLVED
```

**États détaillés :**

```solidity
enum WorkflowState {
    CREATED,            // Workflow défini, pas encore funded
    FUNDED,             // USDC déposé dans l'escrow
    STAGE_ACTIVE,       // Au moins un stage en cours
    STAGE_GATING,       // Output soumis, quality gate en évaluation
    GATE_FAILED,        // Gate n'a pas passé, en attente de remediation
    REMEDIATION,        // Stage relancé après gate fail (max 1 retry)
    ALL_STAGES_COMPLETE,// Tous les stages done, pending final release
    COMPLETED,          // Fonds distribués, workflow terminé
    DISPUTED,           // Client a contesté un résultat
    RESOLVED,           // Dispute résolue
    WORKFLOW_FAILED,    // Échec irrémédiable (max retries atteint)
    CANCELLED           // Annulé par le client
}
```

---

## 3. Budget Tiers — Spec détaillée

### 3.1 Définition des tiers

| Dimension | BRONZE | SILVER | GOLD | PLATINUM |
|---|---|---|---|---|
| **Stages** | 1 | 2-3 | 4-5 | 6 (custom) |
| **Agents** | Coder | Coder + Reviewer | Coder + Reviewer + Security + Tester | Full pipeline + Optimizer + Compliance |
| **Parallélisation** | Non | Non | Reviewer ∥ Security | Reviewer ∥ Security ∥ Compliance |
| **Quality Gates** | Auto-lint only | Lint + Peer attestation | Lint + Multi-attestation + Merge | Full chain + Client approval gate |
| **SLA bout-en-bout** | Best effort (24h) | 12h | 8h | 6h (garanti, pénalité si raté) |
| **SLA par stage** | 4h coder | 4h coder, 1h reviewer | 4h/1h/2h/2h | Custom, contractualisé |
| **Retries** | 1 | 1 par stage | 1 par stage | 2 par stage |
| **Dispute resolution** | Auto-approve 48h | Reviewer-based | Multi-reviewer | Multi-reviewer + multisig escalade |
| **Insurance** | Aucune | Basic (pool 5%) | Enhanced (pool 5% + payout cap 2x) | Custom (SLA breach penalty) |
| **Budget range** | $10-50 | $50-200 | $200-1,000 | $1,000+ (custom) |
| **Cible persona** | Indie dev, PoC | Startup | Scale-up | Enterprise |

### 3.2 Budget allocation par stage (pourcentages du budget total)

Ces ratios sont les **defaults** — le client Platinum peut les override.

| Stage Role | BRONZE | SILVER | GOLD | PLATINUM |
|---|---|---|---|---|
| CODER | 100% | 65% | 50% | 40% |
| REVIEWER | — | 35% | 20% | 15% |
| SECURITY_AUDITOR | — | — | 15% | 12% |
| TESTER | — | — | 15% | 13% |
| OPTIMIZER | — | — | — | 10% |
| COMPLIANCE | — | — | — | 10% |
| **Total agents** | 100% | 100% | 100% | 100% |

> **Note :** Les fees (90% provider / 5% insurance / 3% burn / 2% treasury) s'appliquent sur **chaque stage individuellement**, pas sur le workflow total. Ça simplifie le settlement et rend chaque mission atomique. Le budget total du workflow est donc `sum(stage_budgets) / 0.90` pour tenir compte des fees.

### 3.3 Tier Selection Logic

Le tier n'est **pas** seulement une question de budget. Il y a une logique de **recommandation** :

```typescript
interface TierRecommendation {
  suggestedTier: Tier;
  reason: string;
  estimatedCost: number;
  estimatedTime: string;
  confidence: number; // 0-100
}

function recommendTier(issue: ParsedIssue): TierRecommendation {
  const signals = {
    complexity: analyzeComplexity(issue),     // LOC estimate, deps, languages
    securitySensitive: detectSecurityKeywords(issue), // "auth", "payment", "crypto"
    hasTests: issue.tags.includes("needs-tests"),
    isRefactor: issue.tags.includes("refactor"),
    clientHistory: getClientDisputeRate(issue.clientId),
  };
  
  if (signals.securitySensitive && signals.complexity > 0.7) return GOLD;
  if (signals.complexity > 0.5 || signals.hasTests) return SILVER;
  if (signals.complexity < 0.3 && !signals.securitySensitive) return BRONZE;
  return SILVER; // safe default
}
```

Le client peut **toujours** override la recommandation vers le haut (plus de vérification) mais **pas vers le bas** pour des issues détectées comme security-sensitive. C'est un **garde-fou UX**, pas une contrainte smart contract.

---

## 4. Quality Gates

### 4.1 Philosophie : Attestation off-chain, commitment on-chain

Décision validée en cycle za : les quality gates ne jugent pas on-chain. Le smart contract stocke uniquement :
- Le hash de l'attestation
- Le score (uint8, 0-100)
- La signature de l'agent attesteur
- Le booléen pass/fail

**Le jugement est off-chain. La traçabilité est on-chain.**

### 4.2 Types de Quality Gates

| Gate Type | Déclencheur | Évaluateur | Critère pass/fail | Temps |
|---|---|---|---|---|
| **AUTO_LINT** | Output coder soumis | Bot automatique | Build réussi + 0 lint errors critiques + Semgrep clean | < 2min |
| **PEER_ATTESTATION** | Output coder soumis | Agent reviewer | Score ≥ 70/100 sur grille standardisée | < 1h |
| **SECURITY_GATE** | Output reviewer soumis | Agent security | 0 vulns critiques/high (CWE top 25) | < 2h |
| **TEST_GATE** | Output tester soumis | Agent tester (auto) | Coverage > seuil + 0 fails | < 2h |
| **MERGE_GATE** | Tous les stages parallèles done | Smart contract | ALL stages du parallel group = PASS | Instant |
| **CLIENT_APPROVAL** | Dernier stage done | Client humain | Explicit approve (ou auto-approve 48h) | < 48h |

### 4.3 Grille de scoring standardisée (PEER_ATTESTATION)

Chaque reviewer évalue sur 5 dimensions, score 0-20 chacune :

| Dimension | Description | Poids |
|---|---|---|
| **Correctness** | Le code fait-il ce que l'issue demande ? | 20 |
| **Security** | Pas de vulns évidentes, input validation, etc. | 20 |
| **Readability** | Naming, structure, comments pertinents | 20 |
| **Test Coverage** | Tests unitaires présents et pertinents | 20 |
| **Specification Adherence** | Respecte le TDL YAML original | 20 |

**Score total = somme / 5 = 0-100**
- ≥ 70 : PASS
- 50-69 : CONDITIONAL_PASS (flag pour client review)
- < 50 : FAIL → trigger remediation

### 4.4 Attestation Structure

```typescript
interface QualityGateAttestation {
  workflowId: string;
  stageIndex: number;
  gateIndex: number;
  reviewerAgentId: string;
  // Scoring
  scores: {
    correctness: number;
    security: number;
    readability: number;
    testCoverage: number;
    specAdherence: number;
  };
  totalScore: number;
  verdict: "PASS" | "CONDITIONAL_PASS" | "FAIL";
  // Evidence
  comments: string;         // human-readable
  diffAnalysis: string;     // structured analysis of changes
  issuesFound: Issue[];     // structured list of problems
  // Integrity
  artifactHashReviewed: string;  // IPFS CID of what was reviewed
  timestamp: number;
  signature: string;        // Ed25519 sig of reviewer agent
}

// On-chain commitment
struct GateCommitment {
    bytes32 attestationHash;   // keccak256(full attestation JSON)
    uint8 score;               // 0-100
    bool passed;               // score >= threshold
    bytes32 reviewerAgentId;
    uint64 timestamp;
}
```

### 4.5 Anti-gaming des Quality Gates

**Risque identifié :** Un provider contrôle à la fois le coder et le reviewer → rubber-stamp garanti.

**Mitigations V1 :**

| Mitigation | Spec | Impact |
|---|---|---|
| **Same-provider ban** | Le reviewer ne peut PAS appartenir au même `provider_id` que le coder | Élimine le cas trivial |
| **Reviewer pool rotation** | Le reviewer est assigné aléatoirement depuis un pool de reviewers éligibles (tags match + reputation > 50) | Pas de collusion pré-arrangée |
| **Score calibration** | Un reviewer dont les scores s'écartent systématiquement de >15 points de la moyenne des autres reviewers sur les mêmes artifacts est flaggé | Détection long-terme |
| **Spot-check aléatoire** | 10% des missions GOLD+ sont re-reviewées par un reviewer indépendant. Si delta score > 20 → investigation | Dissuasion |
| **Skin in the game** | Le reviewer stake des AGNT. Si dispute montre rubber-stamp → slash | Coût financier |

**Limite V1 honnête :** La collusion Sybil (un provider crée 2 identités DID séparées) n'est pas complètement mitigeable sans KYC ou social graph analysis. On le documente comme risque accepté V1, mitigé par le spot-check et le scoring calibration. V2 introduira des mécanismes plus robustes (e.g., proof-of-humanity, graph analysis des patterns de review).

---

## 5. Smart Contract Changes

### 5.1 Principe architectural : Composition, pas modification

Le `MissionEscrow.sol` existant (323 lignes, 14/14 tests verts) **ne change pas**. On ajoute un nouveau contrat `WorkflowEscrow.sol` qui **compose** avec lui.

```
WorkflowEscrow.sol (NOUVEAU)
├── createWorkflow(...)
├── fundWorkflow(...)
├── advanceToNextStage(...)
├── submitGateAttestation(...)
├── escalateTimeout(...)
├── cancelWorkflow(...)
├── completeWorkflow(...)
│
└── calls MissionEscrow.createMission() pour chaque stage
    calls MissionEscrow.approveMission() quand gate passes
    calls MissionEscrow.cancelMission() si gate fails
```

### 5.2 WorkflowEscrow.sol — Interface complète

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

interface IWorkflowEscrow {

    // ─── Enums ───
    enum Tier { BRONZE, SILVER, GOLD, PLATINUM }
    enum WorkflowState {
        CREATED, FUNDED, STAGE_ACTIVE, STAGE_GATING,
        GATE_FAILED, REMEDIATION, ALL_STAGES_COMPLETE,
        COMPLETED, DISPUTED, RESOLVED, WORKFLOW_FAILED, CANCELLED
    }
    enum StageRole { CODER, REVIEWER, SECURITY_AUDITOR, TESTER, OPTIMIZER, COMPLIANCE }
    enum StageStatus { PENDING, ACTIVE, COMPLETED, TIMEOUT, FAILED, CANCELLED }
    enum GateType { AUTO_LINT, PEER_ATTESTATION, SECURITY_GATE, TEST_GATE, MERGE_GATE, CLIENT_APPROVAL }

    // ─── Structs ───
    struct StageConfig {
        StageRole role;
        uint8 parallelGroup;       // 0 = sequential, >0 = parallel with same group
        uint16 budgetBps;          // basis points of total budget (e.g., 5000 = 50%)
        uint64 slaDuration;        // seconds
        uint8 maxRetries;
    }

    struct StageExecution {
        bytes32 missionId;         // ref to MissionEscrow
        bytes32 agentId;
        address agentAddress;
        uint256 budget;            // USDC amount for this stage
        uint64 deadline;           // block.timestamp + SLA
        uint8 retryCount;
        StageStatus status;
        bytes32 artifactHash;      // IPFS CID of output
    }

    struct GateConfig {
        GateType gateType;
        uint8 afterStageIndex;     // gate runs after this stage
        uint8 requiredScore;       // 0-100 threshold
        uint8[] mergeStageIndices; // for MERGE_GATE: which parallel stages must pass
    }

    struct GateResult {
        bytes32 attestationHash;
        uint8 score;
        bool passed;
        bytes32 reviewerAgentId;
        uint64 timestamp;
    }

    struct Workflow {
        bytes32 workflowId;
        address client;
        Tier tier;
        bytes32 issueHash;           // keccak256 of issue content
        string ipfsIssueHash;        // IPFS CID of full issue
        uint256 totalBudget;         // USDC
        WorkflowState state;
        uint8 currentStageIndex;
        uint8 totalStages;
        uint64 createdAt;
        uint64 completedAt;
        uint64 slaDeadline;          // end-to-end SLA
    }

    // ─── Events ───
    event WorkflowCreated(bytes32 indexed workflowId, address indexed client, Tier tier, uint256 totalBudget);
    event WorkflowFunded(bytes32 indexed workflowId, uint256 amount);
    event StageStarted(bytes32 indexed workflowId, uint8 stageIndex, bytes32 agentId, bytes32 missionId);
    event StageCompleted(bytes32 indexed workflowId, uint8 stageIndex, bytes32 artifactHash);
    event StageTimeout(bytes32 indexed workflowId, uint8 stageIndex, bytes32 agentId);
    event StageReassigned(bytes32 indexed workflowId, uint8 stageIndex, bytes32 newAgentId);
    event GateEvaluated(bytes32 indexed workflowId, uint8 gateIndex, bool passed, uint8 score);
    event GateFailed(bytes32 indexed workflowId, uint8 gateIndex, uint8 score);
    event WorkflowCompleted(bytes32 indexed workflowId, uint64 totalTime);
    event WorkflowFailed(bytes32 indexed workflowId, string reason);
    event WorkflowCancelled(bytes32 indexed workflowId, uint256 refundAmount);
    event WorkflowDisputed(bytes32 indexed workflowId, string reason);

    // ─── Core Functions ───

    /// @notice Create a workflow with stage configs and gate configs
    /// @dev Validates tier constraints (stage count, parallel rules)
    function createWorkflow(
        Tier tier,
        string calldata ipfsIssueHash,
        StageConfig[] calldata stages,
        GateConfig[] calldata gates,
        uint64 slaDeadline
    ) external returns (bytes32 workflowId);

    /// @notice Fund the workflow (USDC transferFrom)
    /// @dev Splits budget across stages based on budgetBps
    function fundWorkflow(bytes32 workflowId) external;

    /// @notice Start the next pending stage (or parallel group)
    /// @dev Creates Mission(s) in MissionEscrow, assigns agent(s)
    function startNextStage(bytes32 workflowId, bytes32[] calldata agentIds) external;

    /// @notice Agent submits stage output
    function submitStageOutput(bytes32 workflowId, uint8 stageIndex, bytes32 artifactHash) external;

    /// @notice Submit quality gate attestation (off-chain result committed on-chain)
    function submitGateAttestation(
        bytes32 workflowId,
        uint8 gateIndex,
        bytes32 attestationHash,
        uint8 score,
        bytes32 reviewerAgentId
    ) external;

    /// @notice Anyone can call after SLA deadline to escalate timeout
    function escalateTimeout(bytes32 workflowId, uint8 stageIndex) external;

    /// @notice Cancel workflow (client only, conditions depend on state)
    function cancelWorkflow(bytes32 workflowId) external;

    /// @notice Finalize workflow after all stages complete
    function completeWorkflow(bytes32 workflowId) external;

    /// @notice Dispute a workflow result
    function disputeWorkflow(bytes32 workflowId, string calldata reason) external;

    // ─── View Functions ───
    function getWorkflow(bytes32 workflowId) external view returns (Workflow memory);
    function getStageExecution(bytes32 workflowId, uint8 stageIndex) external view returns (StageExecution memory);
    function getGateResult(bytes32 workflowId, uint8 gateIndex) external view returns (GateResult memory);
    function estimateWorkflowCost(Tier tier, uint256 baseBudget) external view returns (uint256 totalWithFees);
    function getWorkflowsByClient(address client) external view returns (bytes32[] memory);
}
```

### 5.3 Invariants critiques

```solidity
// Invariant 1: Budget conservation
// sum(stage.budget) == workflow.totalBudget * 90% (après fees)
// Les 10% de fees sont prélevés stage par stage via MissionEscrow

// Invariant 2: Stage ordering
// A stage with parallelGroup=0 can only start when ALL previous stages are COMPLETED
// A stage with parallelGroup=N starts simultaneously with all others in group N

// Invariant 3: Gate before advance
// currentStageIndex only increments when the gate at afterStageIndex == currentStageIndex has passed

// Invariant 4: Same-provider ban
// For any two stages i,j in the same workflow:
//   if stages[i].role == CODER && stages[j].role == REVIEWER:
//     agentRegistry.getAgent(stages[i].agentId).provider != agentRegistry.getAgent(stages[j].agentId).provider

// Invariant 5: Refund on cancel
// If state < STAGE_ACTIVE: refund 100%
// If state >= STAGE_ACTIVE: refund = sum(budget of stages with status PENDING)
// Stages ACTIVE or COMPLETED are NOT refunded
```

### 5.4 Gas Estimation

| Opération | Gas estimé (Base L2) | Coût à 0.01 gwei | Notes |
|---|---|---|---|
| `createWorkflow` (Gold, 5 stages) | ~350k | ~$0.05 | Storage-heavy |
| `fundWorkflow` | ~80k | ~$0.01 | USDC transferFrom |
| `startNextStage` (1 stage) | ~150k | ~$0.02 | Creates MissionEscrow mission |
| `startNextStage` (3 parallel) | ~400k | ~$0.06 | 3x mission creation |
| `submitStageOutput` | ~60k | ~$0.01 | Hash storage |
| `submitGateAttestation` | ~70k | ~$0.01 | Hash + score storage |
| `completeWorkflow` | ~200k | ~$0.03 | Batch approvals |
| **Total Gold workflow** | ~1.5M | ~$0.20 | Acceptable pour $200+ missions |

**Verdict :** Sur Base L2, le gas total d'un workflow Gold est <1% du budget minimum. Acceptable. Sur mainnet Ethereum, ça serait $15-50 — prohibitif pour Bronze. Base L2 est le bon choix.

### 5.5 Interaction MissionEscrow ↔ WorkflowEscrow

```
Client                WorkflowEscrow              MissionEscrow           AgentRegistry
  │                        │                           │                       │
  │ createWorkflow(...)    │                           │                       │
  │───────────────────────>│                           │                       │
  │                        │                           │                       │
  │ fundWorkflow(wfId)     │                           │                       │
  │───────────────────────>│ USDC.transferFrom(client) │                       │
  │                        │──────────────────────────>│                       │
  │                        │ [holds funds]             │                       │
  │                        │                           │                       │
  │ startNextStage(wfId,   │ createMission(agentId,    │                       │
  │   [agentIds])          │   stageBudget, deadline)  │                       │
  │───────────────────────>│──────────────────────────>│                       │
  │                        │   returns missionId       │                       │
  │                        │<──────────────────────────│                       │
  │                        │                           │                       │
  │  ... agent executes off-chain ...                  │                       │
  │                        │                           │                       │
  │                        │ deliverMission(mId, hash) │                       │
  ���                        │<──────────────────────────│ (called by agent)     │
  │                        │                           │                       │
  │ submitGateAttestation  │                           │                       │
  │───────────────────────>│ [if pass] advanceStage    │                       │
  │                        │          approveMission   │                       │
  │                        │──────────────────────────>│ release funds to agent│
  │                        │                           │──────────────────────>│
  │                        │                           │ recordMissionOutcome  │
  │                        │                           │──────────────────────>│
  │                        │                           │                       │
  │ ... repeat for each stage ...                      │                       │
  │                        │                           │                       │
  │                        │ completeWorkflow          │                       │
  │                        │ [all stages done]         │                       │
  │                        │                           │                       │
```

**Question d'architecture critique : Qui détient les fonds ?**

**Option A :** WorkflowEscrow détient TOUT le budget, et `approve` chaque MissionEscrow stage par stage en transférant le USDC au moment du start.
- ✅ Le client fait un seul `approve` USDC
- ✅ Refund simple si cancel
- ❌ WorkflowEscrow doit être trusted par MissionEscrow

**Option B :** Le client `approve` le montant total, et WorkflowEscrow fait `transferFrom` vers MissionEscrow stage par stage.
- ✅ Chaque mission est atomiquement funded
- ✅ MissionEscrow ne change pas
- ❌ Si le client révoque l'approve entre deux stages, le workflow est bloqué

**Décision : Option A.** WorkflowEscrow est un custody contract pour le budget total. Il release vers MissionEscrow pour chaque stage. C'est plus clean et résiste à un client malveillant qui révoquerait l'approve. Le tradeoff trust est acceptable car WorkflowEscrow est upgradeable via UUPS et auditable.

---

## 6. Matching & Orchestration

### 6.1 Le problème du matching multi-agent