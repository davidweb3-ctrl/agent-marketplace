

# Cycle zq — Budget-Tiered Workflows Architecture (Opus)

---

## 1. Core Insight de ce cycle

**Le budget n'achète pas plus de compute — il achète plus d'adversaires.** C'est la rupture fondamentale avec toutes les plateformes d'agents IA existantes. Quand un client passe de BRONZE à GOLD, il ne paie pas pour un "meilleur modèle" ou "plus de GPU" — il paie pour que davantage d'agents indépendants, structurellement incités à trouver des défauts, examinent le travail produit. C'est un modèle d'assurance qualité adversariale où chaque dollar supplémentaire réduit exponentiellement la probabilité qu'un défaut survive la chaîne. Cette insight transforme le marketplace d'un "freelance marketplace pour IA" en un **pipeline de vérification programmable** — ce qui est fondamentalement plus défendable, plus priceable, et plus aligné avec les besoins enterprise. Le corollaire business est que le rework tax de 30% devient le budget justification : si un workflow GOLD à $500 élimine 80% du rework sur une feature qui aurait coûté $2000 en corrections, c'est NPV-positif dès la première mission. Le corollaire technique est que l'architecture doit traiter les quality gates comme des citoyens de première classe — pas des add-ons — parce qu'ils **sont** le produit.

---

## 2. Workflow Engine Design

### 2.1 Pourquoi un pipeline séquentiel strict (V1)

Un DAG arbitraire en V1 est un piège. Les raisons sont terminales :

| Critère | Pipeline séquentiel | DAG arbitraire |
|---------|---------------------|----------------|
| Gas cost prévisible | O(n) linéaire, n ≤ 6 | O(E + V) imprévisible |
| Surface d'attaque | Linéaire, facile à auditer | Combinatoire, cycles possibles |
| UX client | Menu déroulant "choisir un tier" | Interface de construction de graphe |
| Dispute resolution | Stage N a un seul prédécesseur | Blame attribution multi-branch |
| Time-to-market | 2 sprints | 6+ sprints |

Le pipeline séquentiel **est** un sous-cas du DAG. Migrer de séquentiel à DAG en V2 est un ajout pur, pas un refactor. L'inverse est impossible.

### 2.2 Modèle de données du Workflow

```
Workflow {
  workflowId: bytes32
  clientAddress: address
  tier: enum(BRONZE, SILVER, GOLD, PLATINUM)
  totalBudget: uint256 (USDC, 6 decimals)
  stages: Stage[1..6]
  qualityGates: QualityGate[0..5]  // entre chaque stage
  currentStageIndex: uint8
  state: WorkflowState
  createdAt: uint256
  deadline: uint256
}

Stage {
  stageIndex: uint8
  role: enum(CODER, REVIEWER, SECURITY_AUDITOR, TESTER, OPTIMIZER, ADVERSARIAL_REVIEWER)
  missionId: bytes32  // référence MissionEscrow
  agentId: bytes32
  budgetAllocation: uint256  // USDC pour ce stage
  state: StageState
  outputCID: bytes32  // IPFS hash du livrable
}

QualityGate {
  gateIndex: uint8
  reviewerAgentId: bytes32
  scoreThreshold: uint8  // 0-100
  requiredReviewers: uint8
  attestations: Attestation[]
  passed: bool
}

Attestation {
  reviewerAddress: address
  reportHash: bytes32
  score: uint8
  pass: bool
  signature: bytes
  timestamp: uint256
}
```

### 2.3 State Machine du Workflow

```
                    ┌──────────────────────────────────────────┐
                    │                                          │
CREATED ──► FUNDED ──► STAGE_1_ACTIVE ──► QG_1_PENDING ──────┤
                                                    │         │
                                              pass? │    fail?│
                                                ▼         ▼
                                         STAGE_2_ACTIVE  FAILED
                                              │
                                              ▼
                                        QG_2_PENDING ──► ... ──► COMPLETED
                                              │
                                         fail?│
                                              ▼
                                           FAILED ──► PARTIAL_REFUND
```

États :

```solidity
enum WorkflowState {
    CREATED,        // Client a choisi un tier, pas encore funded
    FUNDED,         // USDC déposé dans WorkflowEscrow
    IN_PROGRESS,    // Au moins un stage actif
    COMPLETED,      // Tous les stages + QG passés
    FAILED,         // Un QG a échoué, refund partiel
    DISPUTED,       // Client conteste un résultat
    CANCELLED       // Client annule avant premier stage
}

enum StageState {
    PENDING,        // En attente (stages futurs)
    ACTIVE,         // Agent assigné, travail en cours
    DELIVERED,      // Agent a soumis son output
    QG_REVIEW,      // Quality gate en cours d'évaluation
    PASSED,         // QG passé, stage terminé
    FAILED,         // QG échoué
    SKIPPED         // Stage non exécuté (workflow failed avant)
}
```

### 2.4 Failure Modes & Branching (V1 simplifié)

En V1, un QG failure = **workflow terminé + refund partiel**. Pas de retry automatique, pas de branch conditionnel.

```
Si QG[n] fail:
  - Stages[0..n] : payés (travail effectué)
  - Stages[n+1..end] : refundés au client
  - QG reviewers : payés (ils ont fait leur travail)
  - Insurance pool : activé si le QG failure est dû à un agent défaillant
```

**Justification :** le retry et le branching conditionnel (e.g., "si security audit fail, revenir au coder") sont des features V2. En V1, on garde la propriété que le workflow se termine toujours en temps fini et que le refund est déterministe.

---

## 3. Budget Tiers — Spec Détaillée

### 3.1 Définition des 4 Tiers

#### BRONZE — Quick Fix
```yaml
tier: BRONZE
budget_range: $10 - $50
stages:
  - role: CODER
    budget_pct: 90%
quality_gates: []  # Aucun QG
sla:
  max_duration: 2h
  auto_approve: 24h
agents_involved: 1
use_cases:
  - Bug fix simple
  - Typo / documentation
  - Small refactor (< 50 LOC)
  - Dependency update
guarantee: "Best effort, no verification"
fee_breakdown:
  provider: 90%
  insurance: 5%
  burn: 3%
  treasury: 2%
```

#### SILVER — Standard Feature
```yaml
tier: SILVER
budget_range: $50 - $200
stages:
  - role: CODER
    budget_pct: 65%
  - role: REVIEWER
    budget_pct: 25%
quality_gates:
  - after_stage: 0  # QG entre CODER et REVIEWER (le reviewer EST le QG)
    score_threshold: 70
    required_reviewers: 1
sla:
  max_duration: 24h
  auto_approve: 48h
agents_involved: 2
use_cases:
  - Feature standard
  - API endpoint
  - Refactor moyen (50-200 LOC)
  - Test suite addition
guarantee: "Code reviewed by independent agent"
```

**Nuance architecturale SILVER :** Le reviewer est à la fois le stage 2 et le quality gate. Il produit un review + un score. Si score ≥ 70 → workflow COMPLETED. Si score < 70 → FAILED. Le reviewer n'a pas d'incentive à approuver facilement parce qu'il stake sa propre réputation sur la qualité de ses reviews (un reviewer qui approve du mauvais code et que le client dispute voit sa rep chuter).

#### GOLD — Complex Feature
```yaml
tier: GOLD
budget_range: $200 - $1000
stages:
  - role: CODER
    budget_pct: 50%
  - role: REVIEWER
    budget_pct: 20%
  - role: SECURITY_AUDITOR
    budget_pct: 20%
quality_gates:
  - after_stage: 0
    score_threshold: 75
    required_reviewers: 1
  - after_stage: 1
    score_threshold: 80
    required_reviewers: 1
    # Le security auditor est plus strict
sla:
  max_duration: 72h
  auto_approve: 48h
agents_involved: 3
use_cases:
  - Feature complexe avec security implications
  - API integration avec auth
  - Database migration
  - Payment flow implementation
guarantee: "Code reviewed + security audited by independent agents"
```

#### PLATINUM — Enterprise / Security-Critical
```yaml
tier: PLATINUM
budget_range: $1000+
stages:
  - role: CODER
    budget_pct: 35%
  - role: REVIEWER
    budget_pct: 15%
  - role: SECURITY_AUDITOR
    budget_pct: 15%
  - role: TESTER
    budget_pct: 15%
  - role: ADVERSARIAL_REVIEWER
    budget_pct: 10%
quality_gates:
  - after_stage: 0
    score_threshold: 75
    required_reviewers: 1
  - after_stage: 1
    score_threshold: 80
    required_reviewers: 1
  - after_stage: 2
    score_threshold: 85
    required_reviewers: 1
  - after_stage: 3
    score_threshold: 85
    required_reviewers: 2  # L'adversarial + un reviewer indépendant
    consensus: "2_OF_3_MAJORITY"
sla:
  max_duration: 1 week
  auto_approve: 72h
agents_involved: 5+
use_cases:
  - Architecture change
  - Smart contract development
  - Security-critical feature
  - Compliance-required changes
guarantee: "Full adversarial pipeline with audit trail"
```

### 3.2 Budget Split par Défaut — Formule

Le budget split est **par défaut mais overridable** par le client. La formule de base :

```
stage_budget[i] = total_budget × stage_weight[i] / sum(stage_weights)
```

Où `stage_weight` est défini par le tier template. Le client peut ajuster les weights tant que :
- Chaque stage reçoit ≥ 10% du total (prevent underpayment → bad quality)
- La somme = 100% (invariant)

### 3.3 Matrice de Comparaison

| | BRONZE | SILVER | GOLD | PLATINUM |
|---|--------|--------|------|----------|
| **Verification depth** | 0 | 1 layer | 2 layers | 3 layers + adversarial |
| **Defect escape rate** (estimé) | ~30% | ~12% | ~4% | <1% |
| **Time-to-complete** | 1-2h | 12-24h | 24-72h | 3-7 days |
| **Cost multiplier** (vs BRONZE) | 1x | 3-5x | 10-25x | 25-100x |
| **Insurance active** | ❌ | ✅ basic | ✅ enhanced | ✅ full + SLA penalty |
| **Audit trail** | Minimal | Standard | Full | Full + compliance export |
| **Dispute resolution** | Auto-approve only | 1 reviewer | 3 reviewers | 3 reviewers + multisig |

---

## 4. Quality Gates

### 4.1 Philosophie

Un Quality Gate n'est **pas** un test automatisé (ça, c'est dans le stage TESTER). Un QG est une **attestation humaine-or-agent** qu'un livrable atteint un seuil de qualité suffisant pour que le stage suivant puisse travailler dessus. C'est un checkpoint de confiance.

### 4.2 Structure d'une Attestation

```solidity
struct QualityGateAttestation {
    bytes32 workflowId;
    uint8 stageIndex;
    address reviewer;          // Must be registered in AgentRegistry
    bytes32 reportHash;        // keccak256(full report stored on IPFS)
    uint8 score;               // 0-100
    bool pass;                 // reviewer's verdict
    uint256 timestamp;
    bytes signature;           // EIP-712 typed signature
}
```

### 4.3 Critères objectifs par rôle de QG

Le score est un agrégat pondéré de sous-critères. Chaque rôle de stage suivant (qui fait office de QG) évalue sur **ses propres** critères :

#### QG après CODER (évalué par REVIEWER)
| Critère | Poids | Mesure |
|---------|-------|--------|
| Functional correctness | 30% | Tests passent, requirements couverts |
| Code quality | 25% | Lint clean, naming, structure |
| Test coverage | 20% | ≥ 80% line coverage (mesuré) |
| Documentation | 10% | Comments, README updated |
| Diff cleanliness | 15% | No unrelated changes, small commits |

#### QG après REVIEWER (évalué par SECURITY_AUDITOR)
| Critère | Poids | Mesure |
|---------|-------|--------|
| No critical vulns | 40% | Aucune CVE critique, pas d'injection |
| Input validation | 20% | Tous les inputs sanitizés |
| Auth/authz correct | 20% | Pas de privilege escalation |
| Dependency safety | 10% | Pas de deps compromises |
| Attack surface | 10% | Surface minimale, principle of least privilege |

#### QG après SECURITY_AUDITOR (évalué par TESTER)
| Critère | Poids | Mesure |
|---------|-------|--------|
| Integration tests pass | 30% | All green |
| Edge cases covered | 25% | Boundary conditions, error paths |
| Performance acceptable | 20% | Response time < SLA threshold |
| Regression free | 15% | Existing tests still pass |
| Reproducibility | 10% | Tests deterministic |

#### QG après TESTER (évalué par ADVERSARIAL_REVIEWER)
| Critère | Poids | Mesure |
|---------|-------|--------|
| Adversarial attack resistance | 35% | Fuzzing, malformed inputs |
| Business logic flaws | 25% | Can't game the system |
| Economic attacks | 20% | No value extraction exploits |
| Compliance | 10% | Meets stated requirements |
| Overall confidence | 10% | Would you deploy this to prod? |

### 4.4 Anti-Gaming des Quality Gates

**Problème :** un reviewer collude avec le coder → approuve du travail médiocre.

**Mitigations :**

1. **Reputation-weighted scoring.** Un reviewer avec un historique de "tout approuver" verra son score pondéré à la baisse. Formule : `effective_score = raw_score × reviewer_reputation_factor`, où `reputation_factor = (missions_reviewed - disputes_lost) / missions_reviewed`.

2. **Random spot-check.** 10% des QG attestations sont re-évaluées par un reviewer aléatoire tier supérieur. Si divergence > 20 points → les deux reviewers sont flaggés.

3. **Skin in the game.** Le reviewer stake sa réputation. Un reviewer dont les attestations sont disputées avec succès perd de la rep → moins de missions → incentive à être honnête.

4. **Separation structurelle.** L'agent coder et l'agent reviewer ne peuvent **jamais** appartenir au même provider. Vérifié on-chain : `require(getProvider(coderAgentId) != getProvider(reviewerAgentId))`.

5. **PLATINUM: Adversarial reviewer.** Un agent dont le JOB EXPLICITE est de trouver des problèmes. Il est payé le même montant qu'il trouve des problèmes ou non, mais sa réputation monte quand il identifie des vrais défauts (validés post-dispute).

### 4.5 Timeout & Default Behavior

```
Si un QG reviewer ne soumet pas d'attestation dans le délai SLA :
  - Après 50% du timeout : notification au reviewer
  - Après 75% du timeout : un reviewer backup est assigné
  - Après 100% du timeout : 
    - SILVER : auto-pass (client assume le risque, notifié)
    - GOLD/PLATINUM : auto-fail → partial refund
    Reviewer original : rep penalty (-5 points)
```

---

## 5. Smart Contract Changes

### 5.1 Principe directeur : Composition, pas Modification

`MissionEscrow.sol` (323 lignes, 14/14 tests verts) **ne change pas**, sauf l'ajout d'une seule fonction :

```solidity
// SEUL AJOUT à MissionEscrow.sol
function createMissionFor(
    address client,
    bytes32 agentId,
    uint256 totalAmount,
    uint256 deadline,
    string calldata ipfsMissionHash
) external onlyRole(WORKFLOW_ROLE) returns (bytes32) {
    // Identique à createMission mais avec client explicite
    // msg.sender = WorkflowEscrow contract
    // mission.client = client (le vrai client)
}
```

Impact : +15 lignes, +3 tests. Les 14 tests existants restent inchangés.

### 5.2 WorkflowEscrow.sol — Nouveau Contrat

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IMissionEscrow.sol";
import "./IAgentRegistry.sol";

contract WorkflowEscrow is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // ═══════════════════════════════════════════
    //  ENUMS
    // ═══════════════════════════════════════════
    
    enum Tier { BRONZE, SILVER, GOLD, PLATINUM }
    
    enum WorkflowState {
        CREATED,
        FUNDED,
        IN_PROGRESS,
        COMPLETED,
        FAILED,
        DISPUTED,
        CANCELLED
    }
    
    enum StageState {
        PENDING,
        ACTIVE,
        DELIVERED,
        QG_REVIEW,
        PASSED,
        FAILED,
        SKIPPED
    }
    
    enum StageRole {
        CODER,
        REVIEWER,
        SECURITY_AUDITOR,
        TESTER,
        OPTIMIZER,
        ADVERSARIAL_REVIEWER
    }

    // ═══════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════
    
    struct Stage {
        StageRole role;
        bytes32 agentId;
        bytes32 missionId;       // ref → MissionEscrow
        uint256 budgetAllocation;
        StageState state;
        bytes32 outputCID;       // IPFS hash
    }
    
    struct QualityGate {
        uint8 afterStageIndex;
        uint8 scoreThreshold;
        uint8 requiredReviewers;
        uint8 attestationCount;
        bool passed;
        mapping(address => QGAttestation) attestations;
        address[] reviewers;     // for iteration
    }
    
    struct QGAttestation {
        bytes32 reportHash;
        uint8 score;
        bool pass;
        uint256 timestamp;
        bool submitted;
    }
    
    struct Workflow {
        bytes32 workflowId;
        address client;
        Tier tier;
        uint256 totalBudget;
        uint8 stageCount;
        uint8 gateCount;
        uint8 currentStageIndex;
        WorkflowState state;
        uint256 createdAt;
        uint256 deadline;
        string ipfsSpecHash;
    }

    // ═══════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════
    
    IERC20 public usdc;
    IMissionEscrow public missionEscrow;
    IAgentRegistry public agentRegistry;
    
    uint8 public constant MAX_STAGES = 6;
    
    mapping(bytes32 => Workflow) public workflows;
    mapping(bytes32 => Stage[]) public workflowStages;     // workflowId → stages
    mapping(bytes32 => mapping(uint8 => QualityGate)) public qualityGates; // workflowId → gateIndex → QG
    
    bytes32 public constant ORCHESTRATOR_ROLE = keccak256("ORCHESTRATOR_ROLE");
    bytes32 public constant REVIEWER_ROLE = keccak256("REVIEWER_ROLE");

    // ��══════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════
    
    event WorkflowCreated(bytes32 indexed workflowId, address indexed client, Tier tier, uint256 totalBudget);
    event WorkflowFunded(bytes32 indexed workflowId, uint256 amount);
    event StageStarted(bytes32 indexed workflowId, uint8 stageIndex, bytes32 agentId, bytes32 missionId);
    event StageDelivered(bytes32 indexed workflowId, uint8 stageIndex, bytes32 outputCID);
    event QGAttestationSubmitted(bytes32 indexed workflowId, uint8 gateIndex, address reviewer, uint8 score, bool pass);
    event QGPassed(bytes32 indexed workflowId, uint8 gateIndex);
    event QGFailed(bytes32 indexed workflowId, uint8 gateIndex);
    event WorkflowCompleted(bytes32 indexed workflowId);
    event WorkflowFailed(bytes32 indexed workflowId, uint8 failedAtStage);
    event PartialRefund(bytes32 indexed workflowId, address client, uint256 amount);

    // ═══════════════════════════════════════════
    //  CORE FUNCTIONS
    // ═════════════════��═════════════════════════
    
    /// @notice Create a workflow from a tier template
    /// @param tier The quality tier
    /// @param totalBudget Total USDC budget (6 decimals)
    /// @param deadline Unix timestamp
    /// @param ipfsSpecHash IPFS hash of mission spec
    /// @param stageRoles Ordered roles for each stage
    /// @param budgetSplitBps Budget allocation per stage in basis points (must sum to 10000)
    function createWorkflow(
        Tier tier,
        uint256 totalBudget,
        uint256 deadline,
        string calldata ipfsSpecHash,
        StageRole[] calldata stageRoles,
        uint16[] calldata budgetSplitBps
    ) external returns (bytes32 workflowId) {
        // Validations
        require(stageRoles.length > 0 && stageRoles.length <= MAX_STAGES, "Invalid stage count");
        require(stageRoles.length == budgetSplitBps.length, "Mismatched arrays");
        require(deadline > block.timestamp, "Deadline in past");
        require(totalBudget >= _minBudgetForTier(tier), "Budget below tier minimum");
        
        // Validate budget split sums to 100%
        uint256 totalBps;
        for (uint8 i = 0; i < budgetSplitBps.length; i++) {
            require(budgetSplitBps[i] >= 1000, "Stage budget < 10%"); // min 10% per stage
            totalBps += budgetSplitBps[i];
        }
        require(totalBps == 10000, "Budget split must sum to 10000 bps");
        
        // Validate tier constraints
        _validateTierConstraints(tier, stageRoles);
        
        // Generate workflow ID
        workflowId = keccak256(abi.encodePacked(msg.sender, block.timestamp, ipfsSpecHash));
        
        Workflow storage wf = workflows[workflowId];
        wf.workflowId = workflowId;
        wf.client = msg.sender;
        wf.tier = tier;
        wf.totalBudget = totalBudget;
        wf.stageCount = uint8(stageRoles.length);
        wf.currentStageIndex = 0;
        wf.state = WorkflowState.CREATED;
        wf.createdAt = block.timestamp;
        wf.deadline = deadline;
        wf.ipfsSpecHash = ipfsSpecHash;
        
        // Create stages
        for (uint8 i = 0; i < stageRoles.length; i++) {
            workflowStages[workflowId].push(Stage({
                role: stageRoles[i],
                agentId: bytes32(0),
                missionId: bytes32(0),
                budgetAllocation: (totalBudget * budgetSplitBps[i]) / 10000,
                state: StageState.PENDING,
                outputCID: bytes32(0)
            }));
        }
        
        // Create quality gates (one between each stage, except for BRONZE)
        if (tier != Tier.BRONZE) {
            wf.gateCount = uint8(stageRoles.length - 1);
            for (uint8 i = 0; i < stageRoles.length - 1; i++) {
                QualityGate storage gate = qualityGates[workflowId][i];
                gate.afterStageIndex = i;
                (gate.scoreThreshold, gate.requiredReviewers) = _gateParamsForTier(tier, i);
            }
        }
        
        emit WorkflowCreated(workflowId, msg.sender, tier, totalBudget);
    }
    
    /// @notice Fund the workflow — locks USDC in this contract
    function fundWorkflow(bytes32 workflowId) external nonReentrant {
        Workflow storage wf = workflows[workflowId];
        require(wf.state == WorkflowState.CREATED, "Not in CREATED state");
        require(msg.sender == wf.client, "Not client");
        
        usdc.transferFrom(msg.sender, address(this), wf.totalBudget);
        wf.state = WorkflowState.FUNDED;
        
        emit WorkflowFunded(workflowId, wf.totalBudget);
    }
    
    /// @notice Start a stage — assigns agent and creates mission in MissionEscrow
    /// @dev Called by orchestrator after matching
    function startStage(
        bytes32 workflowId, 
        uint8 stageIndex, 
        bytes32 agentId
    ) external onlyRole(ORCHESTRATOR_ROLE) nonReentrant {
        Workflow storage wf = workflows[workflowId];
        require(wf.state == WorkflowState.FUNDED || wf.state == WorkflowState.IN_PROGRESS, "Invalid state");
        require(stageIndex == wf.currentStageIndex, "Not current stage");
        
        Stage storage stage = workflowStages[workflowId][stageIndex];
        require(stage.state == StageState.PENDING, "Stage not pending");
        
        // If not first stage, verify previous QG passed
        if (stageIndex > 0 && wf.tier != Tier.BRONZE) {
            require(qualityGates[workflowId][stageIndex - 1].passed, "Previous QG not passed");
        }
        
        // Verify agent provider != previous stage's agent provider (anti-collusion)
        if (stageIndex > 0) {
            bytes32 prevAgentId = workflowStages[workflowId][stageIndex - 1].agentId;
            address prevProvider = agentRegistry.getAgent(prevAgentId).provider;
            address newProvider = agentRegistry.getAgent(agentId).provider;
            require(prevProvider != newProvider, "Same provider as previous stage");
        }
        
        // Approve USDC for MissionEscrow
        usdc.approve(address(missionEscrow), stage.budgetAllocation);
        
        // Create mission via MissionEscrow.createMissionFor
        bytes32 missionId = missionEscrow.createMissionFor(
            wf.client,
            agentId,
            stage.budgetAllocation,
            wf.deadline,
            wf.ipfsSpecHash
        );
        
        stage.agentId = agentId;
        stage.missionId = missionId;
        stage.state = StageState.ACTIVE;
        wf.state = WorkflowState.IN_PROGRESS;
        
        emit StageStarted(workflowId, stageIndex, agentId, missionId);
    }
    
    /// @notice Agent delivers stage output
    function deliverStage(
        bytes32 workflowId, 
        uint8 stageIndex, 
        bytes32 outputCID
    ) external {
        Stage storage stage = workflowStages[workflowId][stageIndex];
        require(stage.state == StageState.ACTIVE, "Stage not active");
        
        // Verify caller is the agent's provider
        address provider = agentRegistry.getAgent(stage.agentId).provider;
        require(msg.sender == provider, "Not stage agent provider");
        
        stage.outputCID = outputCID;
        stage.state = StageState.DELIVERED;
        
        Workflow storage wf = workflows[workflowId];
        
        // If BRONZE or last stage, skip QG
        if (wf.tier == Tier.BRONZE || stageIndex == wf