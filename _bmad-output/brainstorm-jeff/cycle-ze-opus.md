

# Cycle ze — Budget-Tiered Workflows Architecture

---

## 1. Core Insight de ce cycle

**Le smart contract ne doit pas savoir ce qu'est un "tier" — il doit savoir ce qu'est un "plan".** Les cycles précédents ont correctement identifié que le compiler est off-chain et que `WorkflowEscrow` compose `MissionEscrow`. Ce cycle ze doit maintenant résoudre le problème que personne n'a encore attaqué : **le contrat de liaison entre le plan compilé et l'exécution on-chain**. Concrètement, il manque le `WorkflowEscrow.sol` lui-même — ses structs, ses transitions d'état, sa gestion du budget partiel, et surtout sa relation exacte avec le `MissionEscrow` existant à 14 tests verts. L'insight central est que le Workflow n'est pas une "feature ajoutée au-dessus" : c'est une **réécriture du modèle mental de la plateforme**. Avant, la primitive atomique était "1 client → 1 agent → 1 mission → paiement". Désormais, c'est "1 client → 1 plan → N missions séquentielles liées par des quality gates → paiement conditionnel progressif". Tout — la réputation, les disputes, l'insurance, le matching — doit être repensé à travers cette lentille. Le tier n'est qu'un preset marketing ; le plan est l'entité technique. Et le plan est une **promesse de qualité vérifiable**, pas une promesse de compute.

---

## 2. Workflow Engine Design

### 2.1 Modèle : Pipeline séquentiel strict, pas un DAG

Retenu des cycles zc-zd, confirmé ici avec justification renforcée :

```
[Stage 0: Coder] → QG₀ → [Stage 1: Reviewer] → QG₁ → [Stage 2: Security] → QG₂ → [Stage 3: Tester] → DONE
```

**Pourquoi pas un DAG en V1 :**

| Critère | Pipeline séquentiel | DAG arbitraire |
|---------|---------------------|----------------|
| Vérification on-chain | Index monotone croissant, trivial | Topological sort on-chain, O(n²) gas |
| Disputabilité | "Stage 3 a échoué" — non-ambigu | "Branch B dépendait de A₁ et A₂" — combinatoire |
| UX client | Barre de progression linéaire | Graphe incompréhensible |
| Implémentation | ~200 lignes Solidity | ~800+ lignes, audit nightmare |
| Couverture use-cases | 95% des GitHub Issues | 99% mais 4% ne justifie pas le coût |

### 2.2 State Machine du Workflow

Le Workflow a sa propre state machine, **découplée** de celle des missions individuelles :

```
PLANNED → FUNDED → STAGE_ACTIVE → STAGE_GATING → STAGE_ACTIVE → ... → COMPLETED
                                  ↘ STAGE_FAILED → (FailurePolicy) → HALTED | RETRYING | REFUNDING
PLANNED → CANCELLED (avant funding)
FUNDED → CANCELLED (avant premier stage actif, refund total)
```

**États détaillés :**

```solidity
enum WorkflowState {
    PLANNED,        // Plan compilé soumis, pas encore funded
    FUNDED,         // USDC locked dans WorkflowEscrow
    STAGE_ACTIVE,   // Un stage est en cours (mission créée dans MissionEscrow)
    STAGE_GATING,   // Stage livré, quality gate en évaluation
    STAGE_FAILED,   // Quality gate échoué, FailurePolicy en cours
    RETRYING,       // Stage en retry (même stage, nouvel agent possible)
    COMPLETED,      // Tous les stages passés, paiements released
    HALTED,         // Échec non-récupérable, refund partiel en cours
    CANCELLED,      // Annulé par le client avant exécution
    REFUNDING       // Refund partiel en cours de calcul/exécution
}
```

### 2.3 Invariants critiques

```
INV-1: workflow.currentStageIndex est strictement monotone croissant (sauf retry)
INV-2: sum(stages[].budgetUSDC) + totalPlatformFee == workflow.totalBudgetLocked
INV-3: à tout instant, au plus 1 mission est en état non-terminal par workflow
INV-4: stages.length >= 1 && stages.length <= 6
INV-5: qualityGates.length == stages.length - 1 (pas de QG après le dernier stage)
INV-6: un retry sur le même stage n'incrémente pas currentStageIndex
INV-7: totalRetries <= maxRetriesPerStage * stages.length
```

### 2.4 Progression inter-stages

```
┌───────────────────────���─────────────────────────────────────────┐
│                    WORKFLOW LIFECYCLE                            │
│                                                                 │
│  Client                WorkflowEscrow           MissionEscrow   │
│    │                        │                        │          │
│    ├─createWorkflow(plan)──→│                        │          │
│    │                        ├─lockFunds(totalUSDC)──→│          │
│    │                        │                        │          │
│    │                        ├─advanceToNextStage()───→│          │
│    │                        │  └─createMission()─────→├─[stage0]│
│    │                        │                        │          │
│    │                        │←─missionDelivered()────┤          │
│    │                        ├─evaluateQualityGate()   │          │
│    │                        │  (off-chain attestation)│          │
│    │                        │                        │          │
│    │                        ├─IF pass: advanceStage()→│          │
│    │                        │  └─createMission()─────→├─[stage1]│
│    │                        │                        │          │
│    │                        ├─IF fail: applyFailure() │          │
│    │                        │  └─retry OR halt        │          │
│    │                        │                        │          │
│    │                        ├─[last stage delivered]──→│          │
│    │                        ├─finalizeWorkflow()      │          │
│    │                        │  └─release all funds    │          │
│    │←─WorkflowCompleted────┤                        │          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Budget Tiers — Spec détaillée

### 3.1 Rappel : Les tiers sont des presets du PlanCompiler, pas du code on-chain

```typescript
// backend/src/compiler/presets.ts
const TIER_PRESETS: Record<TierName, CompilerPreset> = {
  BRONZE: { ... },
  SILVER: { ... },
  GOLD:   { ... },
};
// On-chain: WorkflowEscrow ne connaît QUE le WorkflowPlan résultant.
```

### 3.2 Spécification par tier

#### Bronze — "Ship Fast"

| Paramètre | Valeur |
|-----------|--------|
| **Stages** | 1 (Coder uniquement) |
| **Quality Gates** | 0 (auto-approve à 48h standard) |
| **Budget range** | $10 – $50 USDC |
| **SLA** | Best effort, pas de deadline garanti |
| **Agents** | 1 agent, matching par tags + reputation ≥ 30 |
| **FailurePolicy** | `REFUND_FULL` — pas de retry |
| **Target** | Solo dev, quick fix, typo, docs, simple refactor |
| **Différence vs mission simple** | Aucune — un Bronze **EST** une mission simple via MissionEscrow directement. Pas besoin de WorkflowEscrow. |

**Décision architecturale importante :** Un Bronze ne crée **pas** de Workflow. Il utilise directement `MissionEscrow.createMission()`. Cela préserve la backward compatibility et évite un overhead on-chain inutile pour la majorité des missions simples.

Critère de routage :
```typescript
if (plan.stages.length === 1 && plan.qualityGates.length === 0) {
    // Route vers MissionEscrow directement
    return missionEscrow.createMission(plan.stages[0]);
} else {
    // Route vers WorkflowEscrow
    return workflowEscrow.createWorkflow(plan);
}
```

#### Silver — "Ship Right"

| Paramètre | Valeur |
|-----------|--------|
| **Stages** | 2 (Coder → Reviewer) |
| **Quality Gates** | 1 (post-code, pre-merge) |
| **Budget range** | $50 – $200 USDC |
| **Budget split** | 65% Coder / 25% Reviewer / 10% platform fees |
| **SLA** | Deadline souple (client-set, default 72h) |
| **Agent requirements** | Coder: rep ≥ 40, tag match. Reviewer: rep ≥ 60, `can_review: true` |
| **QG threshold** | Score ≥ 70/100 pour passer |
| **FailurePolicy** | `RETRY_ONCE_THEN_REFUND` — retry stage échoué avec nouvel agent, puis refund du reste si re-échoue |
| **Max retries** | 1 par stage |
| **Target** | Startup engineering team, feature dev, bug fixes non-triviaux |

#### Gold — "Ship Secure"

| Paramètre | Valeur |
|-----------|--------|
| **Stages** | 4 (Coder → Reviewer → Security Auditor → Tester) |
| **Quality Gates** | 3 |
| **Budget range** | $200 – $1,000 USDC |
| **Budget split** | 45% Coder / 20% Reviewer / 20% Security / 10% Tester / 5% platform fees |
| **SLA** | Deadline ferme (default 1 semaine, contractuel) |
| **Agent requirements** | Coder: rep ≥ 50, tag match. Reviewer: rep ≥ 65. Security: rep ≥ 75, `security_certified: true`. Tester: rep ≥ 50 |
| **QG thresholds** | Score ≥ 75/100 pour stages 1-2, ≥ 85/100 pour security stage |
| **FailurePolicy** | `RETRY_TWICE_THEN_HALT` — 2 retries par stage, puis halt + refund partiel prorata |
| **Max retries** | 2 par stage (8 max total) |
| **Insurance** | Oui — insurance pool couvre jusqu'à 2x valeur mission si breach post-completion |
| **Target** | Enterprise, fintech, healthtech, tout code touchant des données sensibles |

### 3.3 Le Platinum n'existe pas en V1

Confirmé du cycle zd. Le mode Custom/Platinum nécessite :
- 50+ agents actifs avec capabilities vérifiées
- Historique de matching fiable
- Fallback strategies quand un type d'agent n'est pas disponible

**V1 scope : Bronze, Silver, Gold uniquement.**

### 3.4 Tableau comparatif synthétique

```
┌──────────┬────────┬──────────┬───────────────────────────┬──────────┬──────────────┐
│ Tier     │ Stages │ QG       │ Agents (min rep)          │ Budget   │ FailPolicy   │
├──────────┼────────┼──────────┼───────────────────────────┼──────────┼──────────────┤
│ Bronze   │ 1      │ 0        │ Coder (30)                │ $10-50   │ Refund full  │
│ Silver   │ 2      │ 1        │ Coder(40) + Reviewer(60)  │ $50-200  │ Retry 1x     │
│ Gold     │ 4      │ 3        │ C(50)+R(65)+S(75)+T(50)   │ $200-1k  │ Retry 2x     │
└──────────┴────────┴──────────┴───────────────────────────┴──────────┴──────────────┘
```

---

## 4. Quality Gates

### 4.1 Architecture : Off-chain judgment, On-chain commitment

Confirmé du cycle zd. Un smart contract ne peut pas juger de la qualité du code. Mais il peut :
- Vérifier qu'une attestation signée a été soumise
- Vérifier que le score dépasse le seuil configuré
- Déclencher la progression ou l'échec du stage

```
┌─────────────────────────────────────────────────────────────────┐
│                   QUALITY GATE FLOW                             │
│                                                                 │
│  Stage N Agent         Backend           WorkflowEscrow         │
│      │                    │                    │                 │
│      ├─delivers output───→│                    │                 │
│      │                    ├��assigns reviewer───→│                │
│      │                    │                    │                 │
│  Reviewer Agent           │                    │                 │
│      │←─receives output───┤                    │                 │
│      ├─produces report────→│                    │                │
│      │  (score + details)  │                    │                │
│      │                    ├─pins report→IPFS    │                │
│      │                    ├─submitGateAttest()──→│               │
│      │                    │  (reportHash,score, │                │
│      │                    │   reviewerSig)      │                │
│      │                    │                    ├─verify sig      │
│      │                    │                    ├─check score≥thr │
│      │                    │                    ├─IF pass: advance│
│      │                    │                    ├─IF fail: policy │
│      │                    │                    │                 │
└──────────────────────────────────────────────────���──────────────┘
```

### 4.2 Struct on-chain

```solidity
struct QualityGateConfig {
    uint8 minScore;            // 0-100, seuil de passage
    uint256 timeoutSeconds;    // Temps max pour l'évaluation
    bool requiresSpecialist;   // Si true, reviewer doit avoir capability spécifique
    bytes32 requiredCapability; // e.g., keccak256("security_audit")
}

struct QualityGateResult {
    bytes32 reportHash;        // keccak256 du rapport IPFS
    uint8 score;               // 0-100
    address reviewer;          // Adresse de l'agent reviewer
    bytes signature;           // EIP-712 sig du reviewer sur (workflowId, stageIndex, reportHash, score)
    uint256 submittedAt;
    bool passed;               // score >= config.minScore
}
```

### 4.3 Qui est le reviewer ? Conflit d'intérêt et anti-collusion

**Problème critique :** Si le provider du coder et du reviewer est le même, le reviewer a intérêt à rubber-stamp le code pour que le workflow avance et que les deux agents soient payés.

**Mitigations V1 :**

| Mitigation | Mécanisme | Coût |
|------------|-----------|------|
| **Provider exclusion** | L'agent reviewer ne peut PAS appartenir au même provider que l'agent du stage évalué | ~0 gas (check `provider != prevProvider`) |
| **Reputation at stake** | Un reviewer dont les évaluations sont fréquemment disputées perd de la rep | Off-chain, delay effect |
| **Spot-check sampling** | 10% des QG sont re-évalués par un second reviewer tiré aléatoirement. Divergence > 30 points → flag les deux | Backend cost, ~10% overhead |
| **Client challenge window** | Le client a 24h pour contester un QG pass avant que le stage suivant démarre | 24h latency per stage |

```solidity
// Dans WorkflowEscrow.submitQualityGateAttestation()
function _validateReviewer(bytes32 workflowId, uint8 stageIndex, address reviewer) internal view {
    Workflow storage wf = workflows[workflowId];
    Stage storage evaluatedStage = wf.stages[stageIndex];
    
    // Anti-collusion: reviewer ne peut pas être du même provider
    address stageProvider = IAgentRegistry(registry).getAgent(evaluatedStage.agentId).provider;
    address reviewerProvider = IAgentRegistry(registry).getAgentByAddress(reviewer).provider;
    require(stageProvider != reviewerProvider, "SAME_PROVIDER_CONFLICT");
    
    // Reviewer doit avoir la capability requise si spécifiée
    QualityGateConfig storage gateConfig = wf.qualityGates[stageIndex];
    if (gateConfig.requiresSpecialist) {
        require(
            IAgentRegistry(registry).hasCapability(reviewer, gateConfig.requiredCapability),
            "REVIEWER_LACKS_CAPABILITY"
        );
    }
}
```

### 4.4 Timeout des Quality Gates

Si le reviewer ne soumet pas d'attestation dans `timeoutSeconds` :
- **Option A (retenue) :** Le stage est considéré comme `PASSED` par défaut (optimistic) — cohérent avec l'auto-approve de 48h existant
- **Option B (rejetée) :** Le stage est considéré comme `FAILED` — trop punitif pour le coder qui a livré, risque de griefing par reviewer absent

Justification : L'analogie avec l'auto-approve existant est forte. Si personne ne conteste dans le délai, on assume que c'est OK. Le client conserve sa fenêtre de dispute.

**Valeur par défaut :** `timeoutSeconds = 86400` (24h) pour Silver, `43200` (12h) pour Gold (exigence SLA plus élevée, agents reviewer attendus plus réactifs).

---

## 5. Smart Contract Changes

### 5.1 Nouveau contrat : `WorkflowEscrow.sol`

**Principes :**
- Compose `MissionEscrow`, ne le modifie pas
- UUPS upgradeable (cohérent avec le reste du stack)
- Le `MissionEscrow` ne sait PAS qu'il est appelé par un workflow

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMissionEscrow {
    function createMission(bytes32 agentId, uint256 totalAmount, uint256 deadline, string calldata ipfsMissionHash) external returns (bytes32);
    function approveMission(bytes32 missionId) external;
    function disputeMission(bytes32 missionId, string calldata reason) external;
    function getMissionState(bytes32 missionId) external view returns (uint8);
}

interface IAgentRegistry {
    function getAgent(bytes32 agentId) external view returns (address provider);
    function hasCapability(bytes32 agentId, bytes32 capability) external view returns (bool);
}

contract WorkflowEscrow is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // ─── Constants ──────────────────────────────────
    uint8 public constant MAX_STAGES = 6;
    uint8 public constant MAX_RETRIES_PER_STAGE = 2;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    // ─── Enums ──────────────────────────────────────
    enum WorkflowState {
        PLANNED,
        FUNDED,
        STAGE_ACTIVE,
        STAGE_GATING,
        STAGE_FAILED,
        RETRYING,
        COMPLETED,
        HALTED,
        CANCELLED,
        REFUNDING
    }
    
    enum FailurePolicy {
        REFUND_FULL,            // Bronze: no retry
        RETRY_ONCE_THEN_REFUND, // Silver: 1 retry then refund remaining
        RETRY_TWICE_THEN_HALT   // Gold: 2 retries then halt + partial refund
    }
    
    // ─── Structs ────────────────────────────────────
    struct StageConfig {
        bytes32 agentId;            // Matched agent (0 if not yet matched)
        uint256 budgetUSDC;         // Budget for this stage
        uint256 timeoutSeconds;     // Max execution time
        bytes32 ipfsSpecHash;       // Stage-specific spec on IPFS
    }
    
    struct QualityGateConfig {
        uint8 minScore;
        uint256 timeoutSeconds;
        bool requiresSpecialist;
        bytes32 requiredCapability;
    }
    
    struct QualityGateResult {
        bytes32 reportHash;
        uint8 score;
        address reviewer;
        bytes signature;
        uint256 submittedAt;
        bool passed;
    }
    
    struct Workflow {
        bytes32 workflowId;
        address client;
        uint256 totalBudgetUSDC;
        uint256 platformFeeUSDC;
        WorkflowState state;
        FailurePolicy failurePolicy;
        uint8 stageCount;
        uint8 currentStageIndex;
        uint256 globalDeadline;
        uint256 createdAt;
        uint256 completedAt;
        bytes32 ipfsPlanHash;         // Full compiled plan on IPFS
        
        // Retry tracking
        mapping(uint8 => uint8) retriesPerStage;
        uint8 totalRetries;
        
        // Stage configs (indexed by stage position)
        mapping(uint8 => StageConfig) stages;
        
        // Quality gate configs (indexed, gates.length == stages.length - 1)
        mapping(uint8 => QualityGateConfig) qualityGates;
        
        // Quality gate results
        mapping(uint8 => QualityGateResult) gateResults;
        
        // Mission IDs created in MissionEscrow (per stage, supports retries)
        mapping(uint8 => bytes32) activeMissionIds;
        
        // Budget tracking
        uint256 totalPaidOut;
        uint256 totalRefunded;
    }
    
    // ─── State ──────────────────────────────────────
    IMissionEscrow public missionEscrow;
    IAgentRegistry public agentRegistry;
    IERC20 public usdc;
    
    mapping(bytes32 => Workflow) public workflows;
    mapping(bytes32 => bool) public workflowExists;
    
    // Client → active workflow IDs
    mapping(address => bytes32[]) public clientWorkflows;
    
    uint256 public workflowCount;
    
    // ─── Events ─────────────────────────────────────
    event WorkflowCreated(bytes32 indexed workflowId, address indexed client, uint8 stageCount, uint256 totalBudget);
    event WorkflowFunded(bytes32 indexed workflowId, uint256 amount);
    event StageStarted(bytes32 indexed workflowId, uint8 stageIndex, bytes32 missionId, bytes32 agentId);
    event StageDelivered(bytes32 indexed workflowId, uint8 stageIndex, bytes32 missionId);
    event QualityGateSubmitted(bytes32 indexed workflowId, uint8 stageIndex, uint8 score, bool passed);
    event StageRetried(bytes32 indexed workflowId, uint8 stageIndex, uint8 retryCount);
    event WorkflowCompleted(bytes32 indexed workflowId, uint256 totalPaid);
    event WorkflowHalted(bytes32 indexed workflowId, uint8 failedStageIndex, string reason);
    event WorkflowRefunded(bytes32 indexed workflowId, uint256 refundAmount);
    event WorkflowCancelled(bytes32 indexed workflowId);
    
    // ─── Core Functions ─────────────────────────────
    
    /// @notice Creates a workflow from a compiled plan
    /// @dev Bronze missions (1 stage, 0 gates) should bypass this and use MissionEscrow directly
    function createWorkflow(
        StageConfig[] calldata stages,
        QualityGateConfig[] calldata gates,
        FailurePolicy failurePolicy,
        uint256 globalDeadline,
        string calldata ipfsPlanHash
    ) external nonReentrant returns (bytes32 workflowId) {
        // Validate invariants
        require(stages.length >= 2, "USE_MISSION_ESCROW_FOR_SINGLE_STAGE");
        require(stages.length <= MAX_STAGES, "TOO_MANY_STAGES");
        require(gates.length == stages.length - 1, "GATES_STAGES_MISMATCH");
        require(globalDeadline > block.timestamp, "DEADLINE_IN_PAST");
        
        // Calculate totals
        uint256 totalStageBudget = 0;
        uint256 totalMinTimeout = 0;
        for (uint8 i = 0; i < stages.length; i++) {
            require(stages[i].budgetUSDC > 0, "ZERO_STAGE_BUDGET");
            require(stages[i].timeoutSeconds > 0, "ZERO_STAGE_TIMEOUT");
            totalStageBudget += stages[i].budgetUSDC;
            totalMinTimeout += stages[i].timeoutSeconds;
        }
        for (uint8 i = 0; i < gates.length; i++) {
            totalMinTimeout += gates[i].timeoutSeconds;
        }
        
        uint256 platformFee = _calculatePlatformFee(totalStageBudget);
        uint256 totalBudget = totalStageBudget + platformFee;
        
        require(globalDeadline >= block.timestamp + totalMinTimeout, "DEADLINE_TOO_TIGHT");
        
        // Generate workflow ID
        workflowId = keccak256(abi.encodePacked(msg.sender, block.timestamp, workflowCount++));
        
        // Store workflow
        Workflow storage wf = workflows[workflowId];
        wf.workflowId = workflowId;
        wf.client = msg.sender;
        wf.totalBudgetUSDC = totalBudget;
        wf.platformFeeUSDC = platformFee;
        wf.state = WorkflowState.PLANNED;
        wf.failurePolicy = failurePolicy;
        wf.stageCount = uint8(stages.length);
        wf.currentStageIndex = 0;
        wf.globalDeadline = globalDeadline;
        wf.createdAt = block.timestamp;
        wf.ipfsPlanHash = keccak256(abi.encodePacked(ipfsPlanHash));
        
        for (uint8 i = 0; i < stages.length; i++) {
            wf.stages[i] = stages[i];
        }
        for (uint8 i = 0; i < gates.length; i++) {
            wf.qualityGates[i] = gates[i];
        }
        
        workflowExists[workflowId] = true;
        clientWorkflows[msg.sender].push(workflowId);
        
        emit WorkflowCreated(workflowId, msg.sender, uint8(stages.length), totalBudget);
    }
    
    /// @notice Fund the workflow — locks USDC
    function fundWorkflow(bytes32 workflowId) external nonReentrant {
        Workflow storage wf = workflows[workflowId];
        require(wf.client == msg.sender, "NOT_CLIENT");
        require(wf.state == WorkflowState.PLANNED, "NOT_PLANNED");
        
        require(
            usdc.transferFrom(msg.sender, address(this), wf.totalBudgetUSDC),
            "USDC_TRANSFER_FAILED"
        );
        
        wf.state = WorkflowState.FUNDED;
        emit WorkflowFunded(workflowId, wf.totalBudgetUSDC);
    }
    
    /// @notice Start the next stage — creates a mission in MissionEscrow
    /// @dev Called by OPERATOR_ROLE (backend) after matching agent
    function startNextStage(
        bytes32 workflowId, 
        bytes32 agentId
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        Workflow storage wf = workflows[workflowId];
        require(
            wf.state == WorkflowState.FUNDED || 
            wf.state == WorkflowState.STAGE_GATING ||  // after QG pass
            wf.state == WorkflowState.RETRYING,         // retry
            "INVALID_STATE_FOR_START"
        );
        require(block.timestamp < wf.globalDeadline, "WORKFLOW_EXPIRED");
        
        uint8 idx = wf.currentStageIndex;
        StageConfig storage stage = wf.stages[idx];
        stage.agentId = agentId;
        
        // Approve USDC for MissionEscrow
        usdc.approve(address(missionEscrow), stage.budgetUSDC);
        
        // Create mission in MissionEscrow — WorkflowEscrow acts as the "client"
        bytes32 missionId = missionEscrow.createMission(
            agentId,
            stage.budgetUSDC,
            block.timestamp + stage.timeoutSeconds,
            string(abi.encodePacked(stage.ipfsSpecHash)) // Stage spec
        );
        
        wf.activeMissionIds[idx] = missionId;
        wf.state = WorkflowState.STAGE_ACTIVE;
        
        emit StageStarted(work