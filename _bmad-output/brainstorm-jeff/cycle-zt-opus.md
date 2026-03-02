

# Cycle zt — Budget-Tiered Workflows Architecture (Opus)

---

## 1. Core Insight de ce cycle

**Le budget n'achète pas plus de compute — il achète une topologie de vérification plus dense.**

L'insight fondamental qui émerge en assemblant les décisions des cycles za et zs est que le vrai produit vendu n'est pas "des agents qui exécutent du code" (ça, tout le monde le fait et le prix converge vers zéro), mais une **chaîne de preuve vérifiable que le livrable est correct**. Un client qui paie $50 obtient un agent qui code. Un client qui paie $500 obtient le même code *plus la preuve cryptographiquement attestée que ce code a été relu par un regard indépendant, audité pour les vulnérabilités, et validé par une suite de tests générée séparément*. La différence de prix ne reflète pas un coût marginal de compute — elle reflète le **nombre de regards indépendants** qui attestent de la qualité. C'est exactement le modèle des cabinets d'audit financier : la signature du rapport vaut plus que le travail d'analyse. Et c'est exactement ce que les enterprises achètent : pas de la vélocité, mais de la **défense juridique** ("nous avons suivi un processus de vérification en N étapes"). Ce cycle spécifie comment transformer cette insight en architecture concrète — du smart contract au matching engine.

---

## 2. Workflow Engine Design

### 2.1 Modèle retenu : Sequential Spine with Parallel Wings (SSPW)

On ne build pas un DAG engine générique. On build un **array ordonné de stages avec groupes parallèles**. C'est la décision zs §1.2, qu'on concrétise ici.

```
Bronze:     [CODER] → [AUTO_GATE] → DONE
                ↑ 1 stage, 1 gate

Silver:     [CODER] → [GATE_1] → [REVIEWER] → [GATE_2] → DONE
                ↑ 2 stages séquentiels, 2 gates

Gold:       [CODER] → [GATE_1] → ┌[REVIEWER_A]┐ → [MERGE_GATE] → DONE
                                  └[REVIEWER_B]┘
                ↑ 1 coder + 2 reviewers parallèles, 3 gates

Platinum:   [CODER] → [GATE_1] → ┌[REVIEWER]    ┐ → [GATE_3] → [OPTIMIZER] → [FINAL_GATE] → DONE
            (V2)                  └[SECURITY_AUDIT]┘
                ↑ 4-6 stages, 4-5 gates
```

### 2.2 Structures de données

```solidity
struct Stage {
    bytes32 agentId;           // Agent assigné (0x0 = pas encore matché)
    uint8 stageIndex;          // Position dans le workflow (0-indexed)
    uint8 parallelGroup;       // 0 = séquentiel, >0 = groupe parallèle
    StageRole role;            // CODER | REVIEWER | SECURITY_AUDITOR | OPTIMIZER | TESTER
    uint256 budget;            // USDC alloué à ce stage (6 decimals)
    bytes32 missionId;         // Réf vers MissionEscrow (créée au moment de l'activation)
    StageState state;          // PENDING | ACTIVE | DELIVERED | PASSED | FAILED | SKIPPED
    bytes32 artifactHash;      // IPFS CID du livrable de ce stage
}

struct QualityGate {
    uint8 gateIndex;
    uint8 afterStageIndex;     // Gate exécutée après ce stage (ou après le groupe parallèle)
    GateType gateType;         // AUTO_LINT | AGENT_ATTESTATION | MULTI_ATTESTATION | MERGE
    uint8 requiredScore;       // Threshold 0-100 pour passer
    uint8 requiredAttestations;// Nombre de signatures requises (1 pour Silver, 2 pour Gold)
    bool passed;
    bytes32 attestationHash;   // Hash du rapport consolidé
}

struct Workflow {
    bytes32 workflowId;
    address client;
    WorkflowTier tier;         // BRONZE | SILVER | GOLD
    uint256 totalBudget;       // Budget total USDC
    uint256 lockedAt;          // Timestamp du lock
    uint8 currentStageIndex;   // Progression
    uint8 totalStages;
    WorkflowState state;       // CREATED | IN_PROGRESS | COMPLETED | FAILED | DISPUTED
    Stage[] stages;
    QualityGate[] gates;
}

enum WorkflowTier { BRONZE, SILVER, GOLD }
enum StageRole { CODER, REVIEWER, SECURITY_AUDITOR, OPTIMIZER, TESTER }
enum StageState { PENDING, ACTIVE, DELIVERED, PASSED, FAILED, SKIPPED }
enum WorkflowState { CREATED, IN_PROGRESS, COMPLETED, FAILED, DISPUTED }
enum GateType { AUTO_LINT, AGENT_ATTESTATION, MULTI_ATTESTATION, MERGE }
```

### 2.3 Invariants du moteur

| Invariant | Enforcement | Justification |
|-----------|-------------|---------------|
| Max 6 stages par workflow | `require(stages.length <= 6)` | Au-delà = quality theater, latence > valeur |
| Max 3 stages parallèles dans un groupe | `require(groupSize <= 3)` | Gas + complexité dispute |
| Tout stage séquentiel attend la gate précédente | `require(gates[prev].passed)` | Pas de skip, la chaîne de confiance est le produit |
| Un stage parallèle ne bloque que sa gate de groupe | Logique `advanceStage` | Fail d'un reviewer parallèle ≠ fail du workflow |
| Budget total = Σ budgets stages + frais protocole | Vérifié au `createWorkflow` | Pas de budget dynamique (rejeté en zs §2.3) |
| Chaque stage crée exactement 1 mission MissionEscrow | `createMission()` au moment de l'activation | Composition, pas remplacement |

### 2.4 Pourquoi pas un DAG arbitraire

Un DAG arbitraire en V1 est un piège pour trois raisons concrètes :

1. **Gas non-borné** : Traverser un DAG arbitraire on-chain coûte O(V+E) en gas. Avec 6 stages max et des groupes parallèles plats, c'est O(n) avec n ≤ 6. Prévisible, borné, auditable.

2. **Surface d'attaque combinatoire** : Un DAG arbitraire permet des topologies adversariales (cycles déguisés, dépendances circulaires via proxy). Le DFS off-chain + `checkDepsResolved()` on-chain specé en cycle T est fragile en production sans une batterie massive de tests.

3. **UX client** : Le client qui poste une issue GitHub ne veut pas dessiner un DAG. Il veut choisir Bronze/Silver/Gold. Le template fait le travail.

---

## 3. Budget Tiers — Spec détaillée

### 3.1 Définition des tiers

#### BRONZE — Quick Fix ($5–$50)

```yaml
name: "Quick Fix"
target_persona: "Startup dev, side project, non-critical"
stages:
  - role: CODER
    parallelGroup: 0
gates:
  - type: AUTO_LINT
    afterStage: 0
    requiredScore: 60
    requiredAttestations: 0
sla:
  max_time: 2h
  guarantee: "best_effort"
agent_selection:
  min_reputation: 0        # Ouvert aux nouveaux agents
  min_stake_tier: NONE     # Pas de stake requis
  model_constraint: none
budget_split:
  coder: 100%
dispute_resolution: "client_override"  # Le client a toujours raison en Bronze
```

**Quality Gate AUTO_LINT** : Le bot vérifie automatiquement :
- Le code compile
- Les tests pré-existants passent toujours
- Pas de vulnérabilités critiques (Semgrep basic ruleset)
- Score = (compilation_ok × 30) + (tests_pass × 40) + (no_critical_vuln × 30)
- Threshold : 60/100 (permet tests cassés si la compilation passe et pas de vuln)

**Ce que le client obtient** : Un patch rapide, vérifié mécaniquement. Aucune garantie humaine/agent de review. C'est le "vibe coding" tier.

---

#### SILVER — Reviewed ($50–$200)

```yaml
name: "Reviewed"
target_persona: "Startup team, production code"
stages:
  - role: CODER
    parallelGroup: 0
  - role: REVIEWER
    parallelGroup: 0
gates:
  - type: AUTO_LINT
    afterStage: 0
    requiredScore: 70
    requiredAttestations: 0
  - type: AGENT_ATTESTATION
    afterStage: 1
    requiredScore: 70
    requiredAttestations: 1
sla:
  max_time: 24h
  guarantee: "deadline_or_refund"
agent_selection:
  coder_min_reputation: 30
  reviewer_min_reputation: 50   # Reviewer plus senior que coder
  min_stake_tier: BRONZE
  model_constraint: none        # V1 : pas de contrainte modèle
  independence: "reviewer != coder.provider"  # Pas le même provider
budget_split:
  coder: 70%
  reviewer: 30%
dispute_resolution: "client_override_with_cooldown"  # 24h pour contester
```

**Quality Gate AGENT_ATTESTATION** : L'agent reviewer :
1. Reçoit le diff produit par le coder + le contexte de l'issue originale
2. Produit un rapport structuré (off-chain, stocké IPFS) :
   ```json
   {
     "review_id": "...",
     "diff_hash": "...",
     "scores": {
       "correctness": 80,
       "readability": 70,
       "test_coverage": 60,
       "security": 90
     },
     "overall_score": 75,
     "issues_found": [...],
     "recommendation": "APPROVE" | "REQUEST_CHANGES" | "REJECT"
   }
   ```
3. Signe `hash(reportCID, overall_score)` avec sa clé agent
4. Soumet l'attestation on-chain → `submitGateAttestation()`

**Indépendance des regards** (insight zs §1.1) : En V1, on impose que le reviewer reçoit **uniquement le diff et l'issue, pas le prompt/reasoning du coder**. C'est l'orthogonalité des inputs (option b retenue en zs §1.1). Le reviewer évalue le livrable, pas le processus.

---

#### GOLD — Verified ($200–$1,000)

```yaml
name: "Verified"
target_persona: "Enterprise, production-critical, compliance"
stages:
  - role: CODER
    parallelGroup: 0
  - role: REVIEWER_A
    parallelGroup: 1     # Parallèle
  - role: REVIEWER_B
    parallelGroup: 1     # Parallèle
gates:
  - type: AUTO_LINT
    afterStage: 0
    requiredScore: 80
    requiredAttestations: 0
  - type: MULTI_ATTESTATION
    afterParallelGroup: 1
    requiredScore: 75
    requiredAttestations: 2    # Les DEUX reviewers doivent attester
  - type: MERGE
    afterGate: 1
    requiredScore: 70
    requiredAttestations: 0    # Auto-merge si scores concordent
sla:
  max_time: 48h
  guarantee: "deadline_or_refund_with_insurance"
  insurance_eligible: true
agent_selection:
  coder_min_reputation: 50
  reviewer_min_reputation: 70
  min_stake_tier: SILVER
  independence:
    - "reviewer_a.provider != reviewer_b.provider"   # Providers différents
    - "reviewer_a.provider != coder.provider"
    - "reviewer_b.provider != coder.provider"
  model_constraint: none  # V1, mais recommandation de diversité
budget_split:
  coder: 55%
  reviewer_a: 20%
  reviewer_b: 20%
  merge_overhead: 5%     # Gas + protocol ops
dispute_resolution: "multi_reviewer_consensus"  # 2/3 reviewers + client
```

**Quality Gate MULTI_ATTESTATION** : Les deux reviewers travaillent en parallèle et indépendamment :

- **Reviewer A** reçoit : le diff + l'issue + les tests existants
- **Reviewer B** reçoit : le diff + l'issue + l'interface publique uniquement (pas l'implémentation interne, uniquement les signatures et types exposés)

Cette asymétrie d'inputs est **intentionnelle** — elle crée deux regards structurellement différents :
- A vérifie la **correctness interne** (est-ce que l'implémentation est juste ?)
- B vérifie la **contract compliance** (est-ce que les interfaces exposées font ce que l'issue demande ?)

**MERGE Gate** : Si les deux scores sont ≥ threshold ET la différence entre les scores est < 20 points, merge automatique. Si divergence > 20 points, le workflow passe en état `REVIEW_CONFLICT` → un troisième reviewer (tiebreaker) est recruté automatiquement, payé par le `merge_overhead`.

```
Score_A = 85, Score_B = 80 → |85-80| = 5 < 20 → Auto-merge ✅
Score_A = 90, Score_B = 55 → |90-55| = 35 > 20 → Tiebreaker 🔄
Score_A = 60, Score_B = 40 → B < 75 threshold  → Gate Failed ❌
```

---

#### PLATINUM — Enterprise Audit ($1,000+, V2)

Déscope V1. Mentionné ici pour l'architecture forward-compatible. Ajoute security auditor + optimizer + compliance report. Nécessite arbitrage multi-stage sophistiqué (Kleros/UMA). Le `WorkflowEscrow` est designé pour supporter ce tier sans modification structurelle — il suffit d'ajouter des stages et des gates.

### 3.2 Tableau comparatif

| Dimension | BRONZE | SILVER | GOLD |
|-----------|--------|--------|------|
| **Stages** | 1 | 2 | 3-4 |
| **Gates** | 1 (auto) | 2 (auto + attestation) | 3 (auto + dual attestation + merge) |
| **SLA** | Best effort, 2h | Deadline-or-refund, 24h | Deadline + insurance, 48h |
| **Min reputation coder** | 0 | 30 | 50 |
| **Min reputation reviewer** | — | 50 | 70 |
| **Min stake tier** | NONE | BRONZE | SILVER |
| **Insurance eligible** | ❌ | ❌ | ✅ |
| **Independence guarantee** | ��� | Different provider | Different provider × 3 |
| **Input orthogonality** | — | Diff-only review | Asymmetric review |
| **Dispute resolution** | Client override | Client override + 24h | Multi-reviewer consensus |
| **Budget range** | $5–$50 | $50–$200 | $200–$1,000 |
| **Target rework reduction** | ~20% | ~50% | ~80% |
| **Audit trail** | Lint report | Lint + 1 attestation | Lint + 2 attestations + merge proof |

---

## 4. Quality Gates — Spec complète

### 4.1 Taxonomie des gates

| Gate Type | Trigger | Évaluateur | On-chain | Off-chain |
|-----------|---------|-----------|----------|-----------|
| `AUTO_LINT` | Stage complété | Bot automatique | pass/fail + score hash | Rapport Semgrep + compilation |
| `AGENT_ATTESTATION` | Stage complété | Agent reviewer (1) | score + sig + report hash | Rapport structuré JSON |
| `MULTI_ATTESTATION` | Groupe parallèle complété | N agents reviewers | N scores + N sigs + hashes | N rapports indépendants |
| `MERGE` | Multi-attestation passée | Logique déterministe | convergence check | Reconciliation report |

### 4.2 Scoring standardisé

Tous les agents reviewer utilisent un **schéma de scoring uniforme** (pas de scores libres, sinon incomparable).

```typescript
interface QualityReport {
  // Identifiers
  workflowId: string;
  stageIndex: number;
  gateIndex: number;
  reviewerAgentId: string;
  
  // What was reviewed
  artifactHash: string;       // IPFS CID du livrable
  issueContextHash: string;   // IPFS CID de l'issue originale
  
  // Scoring (0-100 each)
  scores: {
    correctness: number;      // Le code fait-il ce que l'issue demande ?
    completeness: number;     // Tous les acceptance criteria sont-ils couverts ?
    security: number;         // Pas de vulnérabilités introduites ?
    testability: number;      // Le code est-il testable / les tests passent-ils ?
    maintainability: number;  // Lisibilité, patterns, documentation
  };
  
  // Aggregation
  overallScore: number;       // Moyenne pondérée (configurable par tier)
  recommendation: 'APPROVE' | 'REQUEST_CHANGES' | 'REJECT';
  
  // Details
  issuesFound: Issue[];
  suggestedFixes: Fix[];
  
  // Attestation
  timestamp: number;
  signature: string;          // Ed25519 sig over hash(artifactHash, overallScore, timestamp)
}
```

**Pondération par défaut** (modifiable par governance V2) :

| Critère | Poids Bronze | Poids Silver | Poids Gold |
|---------|-------------|-------------|-----------|
| Correctness | 50% | 35% | 30% |
| Completeness | 30% | 25% | 20% |
| Security | 10% | 15% | 25% |
| Testability | 5% | 15% | 15% |
| Maintainability | 5% | 10% | 10% |

**Justification** : En Bronze, on veut juste que ça marche. En Gold, la sécurité et la testabilité prennent du poids parce que c'est du code production-critical.

### 4.3 Gate failure flows

```
Gate PASSED (score ≥ threshold):
  → advanceStage() → next stage activated
  → Event: GatePassed(workflowId, gateIndex, score)

Gate FAILED (score < threshold):
  → Stage revient à PENDING
  → Même agent a 1 retry (sans coût additionnel)
  → Si retry échoue → agent slashé (5% du stage budget)
  → Nouveau coder matché automatiquement
  → Si 3 agents échouent → workflow FAILED → refund client (moins gas)
  → Event: GateFailed(workflowId, gateIndex, score, retryCount)

Gate CONFLICT (scores divergent > 20 pts, Gold only):
  → Tiebreaker reviewer recruté
  → Payé par le merge_overhead (5% du budget)
  → Score tiebreaker fait majorité
  → Event: GateConflict(workflowId, gateIndex, scoreA, scoreB)
```

### 4.4 Anti-gaming measures

**Problème** : Un agent reviewer pourrait rubber-stamp (toujours 100/100) pour toucher sa part sans effort. Ou un reviewer malveillant pourrait systématiquement rejeter pour forcer un rematching vers un agent complice.

**Mitigations** :

| Attaque | Mitigation | Détection |
|---------|-----------|-----------|
| Rubber-stamping | Score distribution monitoring — si un reviewer donne > 90/100 sur plus de 80% de ses reviews, flag | Off-chain analytics → reputation penalty |
| Systematic rejection | Si un reviewer rejette > 60% et que les re-matchs passent ensuite, flag | Pattern matching sur outcome post-review |
| Collusion coder-reviewer | Independence constraints (different providers) | On-chain vérifiable |
| Score manipulation | Signature obligatoire, score committé avant reveal de l'autre reviewer (Gold) | Commit-reveal pattern |

**Commit-reveal pour Gold MULTI_ATTESTATION** :
1. Reviewer A soumet `commit(hash(score_A, salt_A))`
2. Reviewer B soumet `commit(hash(score_B, salt_B))`
3. Après les deux commits : `reveal(score_A, salt_A)` et `reveal(score_B, salt_B)`
4. Les scores sont comparés → merge ou conflict

Cela empêche le second reviewer de copier le score du premier.

---

## 5. Smart Contract Changes

### 5.1 Nouveau contrat : WorkflowEscrow.sol

**Principes architecturaux** :
- **Compose** `MissionEscrow.sol`, ne le modifie pas
- **Singleton** avec mapping interne (pas un contrat par workflow)
- **UUPS upgradeable** (cohérent avec le reste du stack)
- **Le budget total est locké au createWorkflow**, puis débloqué stage par stage

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MissionEscrow.sol";

contract WorkflowEscrow is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // ═══════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════
    
    bytes32 public constant ORCHESTRATOR_ROLE = keccak256("ORCHESTRATOR_ROLE");
    uint8 public constant MAX_STAGES = 6;
    uint8 public constant MAX_PARALLEL_GROUP_SIZE = 3;
    uint8 public constant MAX_RETRIES_PER_STAGE = 3;
    uint8 public constant SCORE_DIVERGENCE_THRESHOLD = 20;
    
    // ═══════════════════════════════════════════════════
    //  ENUMS
    // ═══════════════════════════════════════════════════
    
    enum WorkflowTier { BRONZE, SILVER, GOLD }
    enum StageRole { CODER, REVIEWER, SECURITY_AUDITOR, OPTIMIZER, TESTER }
    enum StageState { PENDING, ACTIVE, DELIVERED, PASSED, FAILED, SKIPPED }
    enum WorkflowState { CREATED, IN_PROGRESS, COMPLETED, FAILED, DISPUTED, CANCELLED }
    enum GateType { AUTO_LINT, AGENT_ATTESTATION, MULTI_ATTESTATION, MERGE }
    
    // ═══════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════
    
    struct Stage {
        bytes32 agentId;
        uint8 stageIndex;
        uint8 parallelGroup;
        StageRole role;
        uint256 budget;
        bytes32 missionId;           // Ref to MissionEscrow
        StageState state;
        bytes32 artifactHash;
        uint8 retryCount;
    }
    
    struct QualityGate {
        uint8 gateIndex;
        uint8 afterStageIndex;       // Or afterParallelGroup
        GateType gateType;
        uint8 requiredScore;
        uint8 requiredAttestations;
        bool passed;
        bytes32 attestationHash;
        // Commit-reveal for multi-attestation (Gold)
        mapping(address => bytes32) commits;
        mapping(address => uint8) revealedScores;
        uint8 attestationCount;
    }
    
    struct Workflow {
        bytes32 workflowId;
        address client;
        WorkflowTier tier;
        uint256 totalBudget;
        uint256 lockedAt;
        uint8 currentStageIndex;
        uint8 totalStages;
        WorkflowState state;
        uint256 deadline;
    }
    
    // ═══════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════
    
    IERC20 public usdc;
    MissionEscrow public missionEscrow;
    
    mapping(bytes32 => Workflow) public workflows;
    mapping(bytes32 => Stage[]) public workflowStages;
    mapping(bytes32 => QualityGate[]) public workflowGates;
    
    // Independence tracking: workflow → provider → bool
    mapping(bytes32 => mapping(address => bool)) public providerUsedInWorkflow;
    
    uint256 public workflowCount;
    
    // ═════════════════════════════════════���═════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════
    
    event WorkflowCreated(
        bytes32 indexed workflowId, 
        address indexed client, 
        WorkflowTier tier, 
        uint256 totalBudget
    );
    event StageActivated(
        bytes32 indexed workflowId, 
        uint8 stageIndex, 
        bytes32 agentId, 
        bytes32 missionId
    );
    event StageDelivered(
        bytes32 indexed workflowId, 
        uint8 stageIndex, 
        bytes32 artifactHash
    );
    event GatePassed(
        bytes32 indexed workflowId, 
        uint8 gateIndex, 
        uint8 score
    );
    event GateFailed(
        bytes32 indexed workflowId, 
        uint8 gateIndex, 
        uint8 score, 
        uint8 retryCount
    );
    event GateConflict(
        bytes32 indexed workflowId, 
        uint8 gateIndex, 
        uint8 scoreA, 
        uint8 scoreB
    );
    event WorkflowCompleted(
        bytes32 indexed workflowId, 
        uint256 totalPaid
    );
    event WorkflowFailed(
        bytes32 indexed workflowId, 
        uint8 failedAtStage
    );
    
    // ═══════════════════════════════════════════════════
    //  CORE FUNCTIONS
    // ═══════════════════════════════════════════════════
    
    function createWorkflow(
        WorkflowTier tier,
        bytes32[] calldata agentIds,       // Pre-matched agents (0x0 = to be matched)
        uint256[] calldata budgetSplits,   // Per-stage budget in USDC
        string calldata ipfsIssueHash      // Issue context
    ) external nonReentrant returns (bytes32 workflowId) {
        uint256 totalBudget = _sumBudgets(budgetSplits);
        
        // Validate tier constraints
        _validateTierConstraints(tier, agentIds.length, totalBudget);
        
        // Transfer total budget to this contract
        usdc.transferFrom(msg.sender, address(this), totalBudget);
        
        // Generate workflow ID
        workflowId = keccak256(
            abi.encodePacked(msg.sender, block.timestamp, workflowCount++)
        );
        
        // Create workflow
        workflows[workflowId] = Workflow({
            workflowId: workflowId,
            client: msg.sender,
            tier: tier,
            totalBudget: totalBudget,
            lockedAt: block.timestamp,
            currentStageIndex: 0,
            totalStages: uint8(agentIds.length),
            state: WorkflowState.CREATED,
            deadline: block.timestamp + _tierDeadline(tier)
        });
        
        // Create stages from tier template
        _createStagesFromTemplate(workflowId, tier, agentIds, budgetSplits);
        
        // Create quality gates from tier template
        _createGatesFromTemplate(workflowId, tier);
        
        // Activate first stage
        _activateStage(workflowId, 0, ipfsIssueHash);
        
        emit WorkflowCreated(workflowId, msg.sender, tier, totalBudget);
    }
    
    function submitGateAttestation(
        bytes32 workflowId,
        uint8 gateIndex,
        bytes32 reportHash,
        uint8 score,
        bytes calldata sig
    ) external nonReentrant {
        Workflow storage wf = workflows[workflowId];
        require(wf.state == WorkflowState.IN_PROGRESS, "Workflow not active");
        
        QualityGate storage gate = workflowGates[workflowId][gateIndex];
        require(!gate.passed, "Gate already passed");
        
        if (gate.gateType == GateType.AGENT_ATTESTATION) {
            // Silver: single attestation
            _verifySingleAttestation(workflowId, gateIndex, reportHash, score, sig);
            _processGateResult(workflowId, gateIndex, score);
            
        } else if (gate.gateType == GateType.MULTI_ATTESTATION) {
            // Gold: commit-reveal multi-attestation
            // This is the reveal phase — commit must have happened first
            _processMultiAttestation(workflowId, gateIndex, reportHash, score, sig);
        }
    }
    
    function commitGateScore(
        bytes32 workflowId,
        uint8 