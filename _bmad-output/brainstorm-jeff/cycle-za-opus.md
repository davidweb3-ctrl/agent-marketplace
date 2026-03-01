

# Cycle za — Budget-Tiered Workflows Architecture (Opus)

---

## 1. Core Insight de ce cycle

Le Budget-Tiered Workflow transforme fondamentalement la nature du produit : on passe d'un **marketplace de tâches atomiques** (1 issue → 1 agent → 1 paiement) à un **orchestrateur de pipelines qualité** où le budget du client achète non pas un agent, mais un **niveau de confiance dans le résultat**. C'est un shift architectural majeur. Jusqu'ici, `MissionEscrow` gère une relation bilatérale client↔agent. Maintenant, on introduit une entité intermédiaire — le **Workflow** — qui encapsule N missions séquentielles ou parallèles, chacune avec son propre agent, son escrow partiel, et ses quality gates. L'insight clé : **le budget ne détermine pas juste qui travaille, mais combien de couches de vérification le résultat traverse avant d'être payé**. C'est exactement ce que les enterprises achètent — pas du compute, mais de l'assurance qualité vérifiable on-chain. Cela résout directement le problème du "30% rework tax" : au lieu de refaire après coup, on paie upfront pour des étapes de validation qui catchent les erreurs en amont. Le défi technique : comment garder la composabilité et la simplicité du modèle actuel tout en ajoutant cette couche d'orchestration sans exploser la complexité gas et la surface d'attaque des smart contracts.

---

## 2. Workflow Engine Design

### 2.1 Modèle conceptuel : Pipeline DAG contraint

Le workflow n'est **pas** un DAG arbitraire (trop complexe pour V1). C'est un **pipeline ordonné avec branches conditionnelles** :

```
┌─────────────────────────────────────────────────────────────────┐
│                        WORKFLOW (on-chain)                       │
│                                                                 │
│  Stage 1        Stage 2         Stage 3        Stage 4          │
│  ┌─────────┐   ┌───────────┐   ┌──────────┐   ┌────────────┐  │
│  │  CODER  │──▶│ REVIEWER  │──▶│ SECURITY │──▶│ TEST/OPTIM │  │
│  │ Agent A │   │ Agent B   │   │ Agent C   │   │ Agent D    │  │
│  └────┬────┘   └─────┬─────┘   └─────┬────┘   └─────┬──────┘  │
│       │              │               │               │          │
│   QG₁ ▼          QG₂ ▼           QG₃ ▼           QG₄ ▼         │
│  [pass/fail]   [pass/fail]    [pass/fail]     [pass/fail]       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Trois patterns de workflow supportés (V1)

| Pattern | Description | Exemple |
|---------|-------------|---------|
| **Sequential Pipeline** | Stage N+1 commence après QG de Stage N | Code → Review → Test |
| **Parallel Fan-out** | Stages indépendantes exécutées simultanément, join gate après | Security audit ∥ Performance test |
| **Conditional Branch** | Si QG échoue, re-route vers un agent de correction avant retry | Review fail → Rework agent → Re-review |

### 2.3 Structures de données

```typescript
// Off-chain workflow definition (YAML/JSON dans IPFS)
interface WorkflowTemplate {
  templateId: string;
  tier: 'BRONZE' | 'SILVER' | 'GOLD' | 'PLATINUM';
  stages: WorkflowStage[];
  maxRetries: number;        // par stage (default: 1 pour Gold+)
  globalDeadline: number;    // seconds
  qualityTarget: number;     // score minimum global (0-100)
}

interface WorkflowStage {
  stageIndex: number;
  role: AgentRole;           // 'coder' | 'reviewer' | 'security' | 'tester' | 'optimizer'
  dependsOn: number[];       // indices des stages prérequises
  parallel: boolean;         // peut s'exécuter en parallèle avec d'autres stages
  budgetPercent: number;     // % du budget total alloué à cette stage
  qualityGate: QualityGate;
  timeoutSeconds: number;
  retryOnFail: boolean;
  fallbackStageIndex?: number; // si fail, vers quel stage de correction
}

interface QualityGate {
  type: 'automated' | 'peer_review' | 'hybrid';
  criteria: QualityCriterion[];
  minScore: number;          // 0-100, score pour passer
  timeout: number;           // auto-pass si timeout (configurable)
}

interface QualityCriterion {
  name: string;              // 'tests_pass' | 'no_critical_vulns' | 'coverage_above_80' | 'review_score'
  weight: number;            // poids dans le score final
  automated: boolean;        // exécutable sans humain
}
```

### 2.4 Choix architectural critique : On-chain vs Off-chain

| Composant | On-chain | Off-chain | Justification |
|-----------|----------|-----------|---------------|
| Workflow existence & budget lock | ✅ | | Fonds sécurisés, immutable |
| Stage transitions & escrow splits | ✅ | | Paiements trustless |
| Quality gate scores | | ✅ (IPFS hash) | Trop de data pour on-chain |
| Orchestration logic (quel agent next) | | ✅ (API) | Complexité gas prohibitive |
| Stage completion attestation | ✅ (hash) | ✅ (full EAL) | Hash on-chain, détail IPFS |

**Principe directeur** : Le smart contract est un **state machine + escrow splitter**. Toute la logique d'orchestration, de matching, et de quality assessment vit off-chain avec des attestations hashées on-chain.

---

## 3. Budget Tiers — Spec détaillée

### 3.1 Définition des tiers

| Tier | Stages | Budget Range | SLA Deadline | Quality Target | Retry | Insurance | Audit Trail |
|------|--------|-------------|--------------|----------------|-------|-----------|-------------|
| **Bronze** | 1 (coder) | $10–$50 | 24h | 60/100 | 0 | Standard (5%) | Minimal (EAL) |
| **Silver** | 2–3 (coder + reviewer) | $50–$200 | 48h | 75/100 | 1 | Standard (5%) | Standard (EAL + review report) |
| **Gold** | 4–5 (coder + reviewer + security + tests) | $200–$1,000 | 72h | 85/100 | 2 | Enhanced (7%) | Full (EAL + reviews + vuln scan + test report) |
| **Platinum** | 6+ (full pipeline + optimizer + compliance) | $1,000+ | Custom | 95/100 | 3 | Premium (10%) | Enterprise (tout + compliance cert + SLA breach penalties) |

### 3.2 Composition détaillée par tier

#### Bronze — "Ship it"
```yaml
stages:
  - role: coder
    budgetPercent: 100
    qualityGate:
      type: automated
      criteria:
        - { name: "builds_successfully", weight: 50, automated: true }
        - { name: "basic_tests_pass", weight: 50, automated: true }
      minScore: 60
```

#### Silver — "Review it"
```yaml
stages:
  - role: coder
    budgetPercent: 65
    qualityGate:
      type: automated
      criteria:
        - { name: "builds_successfully", weight: 30, automated: true }
        - { name: "tests_pass", weight: 40, automated: true }
        - { name: "lint_clean", weight: 30, automated: true }
      minScore: 70
  - role: reviewer
    budgetPercent: 35
    dependsOn: [0]
    qualityGate:
      type: peer_review
      criteria:
        - { name: "code_quality_score", weight: 40, automated: false }
        - { name: "no_obvious_bugs", weight: 30, automated: false }
        - { name: "follows_spec", weight: 30, automated: false }
      minScore: 75
```

#### Gold — "Harden it"
```yaml
stages:
  - role: coder
    budgetPercent: 45
    qualityGate: { type: automated, minScore: 75 }
  - role: reviewer
    budgetPercent: 20
    dependsOn: [0]
    qualityGate: { type: peer_review, minScore: 80 }
  - role: security_auditor
    budgetPercent: 20
    dependsOn: [0]     # Parallel with reviewer
    parallel: true
    qualityGate:
      type: hybrid
      criteria:
        - { name: "no_critical_vulns", weight: 50, automated: true }
        - { name: "no_high_vulns", weight: 30, automated: true }
        - { name: "manual_review_score", weight: 20, automated: false }
      minScore: 85
  - role: tester
    budgetPercent: 15
    dependsOn: [1, 2]  # After review AND security
    qualityGate:
      type: automated
      criteria:
        - { name: "coverage_above_80", weight: 40, automated: true }
        - { name: "integration_tests_pass", weight: 40, automated: true }
        - { name: "performance_acceptable", weight: 20, automated: true }
      minScore: 85
```

#### Platinum — "Certify it"
```yaml
# Gold stages + :
  - role: optimizer
    budgetPercent: 10
    dependsOn: [3]
    qualityGate: { type: hybrid, minScore: 90 }
  - role: compliance_auditor
    budgetPercent: 8
    dependsOn: [4]
    qualityGate:
      type: peer_review
      criteria:
        - { name: "license_compliance", weight: 25, automated: true }
        - { name: "data_handling_review", weight: 25, automated: false }
        - { name: "documentation_complete", weight: 25, automated: false }
        - { name: "sla_requirements_met", weight: 25, automated: false }
      minScore: 95
```

### 3.3 Dynamic Tier Recommendation

Le client spécifie un budget. Le système recommande un tier :

```typescript
function recommendTier(budget: number, tags: string[], clientHistory: ClientProfile): TierRecommendation {
  // Base tier from budget
  let baseTier = budget < 50 ? 'BRONZE' 
    : budget < 200 ? 'SILVER' 
    : budget < 1000 ? 'GOLD' 
    : 'PLATINUM';
  
  // Upgrade signals
  if (tags.includes('security') || tags.includes('smart-contract')) {
    baseTier = upgradeTier(baseTier); // Security-sensitive → force at least Gold
  }
  if (clientHistory.averageDisputeRate > 0.15) {
    baseTier = upgradeTier(baseTier); // High dispute history → more QA
  }
  
  return { tier: baseTier, estimatedCost: calculateTierCost(baseTier, tags), stages: getStagesForTier(baseTier) };
}
```

---

## 4. Quality Gates

### 4.1 Architecture des Quality Gates

Les quality gates sont le **cœur du value prop**. Si elles sont bullshit (toujours pass), le système est inutile. Si elles sont trop strictes, les workflows deadlockent.

```
┌─────────────────────────────────────────────────────┐
│                  QUALITY GATE ENGINE                  │
│                                                       │
│  Input: Stage output (EAL + artifacts + IPFS CID)    │
│                                                       │
│  ┌───��──────────┐  ┌──────────────┐  ┌────────────┐ │
│  │  Automated    │  │  Peer Agent  │  │  Hybrid    │ │
│  │  Checks      │  │  Review      │  │  (both)    │ │
│  │              │  │              │  │            │ │
│  │ - CI pass    │  │ - Score 0-10 │  │ - Auto +   │ │
│  │ - Coverage   │  │ - Comments   │  │   manual   │ │
│  │ - Lint       │  │ - Approve/   │  │   scoring  │ │
│  │ - Vuln scan  │  │   Request    │  │            │ │
│  │ - Perf bench │  │   changes    │  │            │ │
│  └──────┬───────┘  └──────┬───────┘  └──────┬─────┘ │
│         │                 │                 │        │
│         ▼                 ▼                 ▼        │
│  ┌─────────────────────────────────────────────────┐ │
│  │            SCORE AGGREGATOR                      │ │
│  │  weighted_score = Σ(criterion.weight × score)    │ │
│  │  result = weighted_score >= gate.minScore        │ │
│  │           ? PASS : FAIL                          │ │
│  └──────────────────────┬──────────────────────────┘ │
│                         │                             │
│            ┌────────────┼────────────┐                │
│            ▼            ▼            ▼                │
│          PASS        FAIL         FAIL+RETRY          │
│     (next stage)  (workflow     (rework agent         │
│                    halted,       + re-evaluate)        │
│                    partial                             │
│                    refund)                              │
└─────────────────────────────────────────────────────┘
```

### 4.2 Critères objectifs par type de stage

| Stage Role | Automated Criteria | Agent-Review Criteria |
|------------|-------------------|----------------------|
| **Coder** | Build passes, lint clean, basic tests pass, no security hotspots (Semgrep) | — |
| **Reviewer** | Diff size reasonable, no force-push, PR template filled | Code clarity (0-10), spec adherence (0-10), maintainability (0-10) |
| **Security Auditor** | No critical/high CVEs (Snyk/Trivy), no known vuln patterns | Manual audit score (0-10), risk assessment |
| **Tester** | Coverage ≥ threshold, all tests pass, no flaky tests, perf within bounds | Edge case coverage (0-10) |
| **Optimizer** | Bundle size delta, latency delta, memory delta | Architecture quality (0-10) |
| **Compliance** | License check (SPDX), SBOM generated | Documentation completeness (0-10), data handling review (0-10) |

### 4.3 Anti-gaming des Quality Gates

**Problème** : Un reviewer-agent pourrait rubber-stamp pour collecter sa bounty plus vite.

**Mitigations** :
1. **Spot-check aléatoire** : 10% des reviews sont re-évaluées par un agent tiers. Si le score diverge de >30%, le reviewer est pénalisé.
2. **Reviewer ne connaît pas le coder** : L'identité de l'agent coder n'est pas révélée au reviewer (review aveugle).
3. **Skin in the game** : Le reviewer stake une fraction de sa bounty. Si spot-check révèle rubber-stamping, slash.
4. **Score calibration** : Le score moyen d'un reviewer est tracké. Deviation significative → review weight réduit.

```solidity
// Dans le contrat, on ne stocke que le hash du QG result
event QualityGateEvaluated(
    bytes32 indexed workflowId,
    uint8 stageIndex,
    bool passed,
    uint256 score,
    bytes32 evidenceHash  // IPFS hash of full QG report
);
```

### 4.4 Failure Modes

| Scenario | Handling |
|----------|----------|
| Stage fails, retries available | Re-assign même agent ou nouveau, budget retry = 30% du budget stage original (pris sur insurance pool) |
| Stage fails, no retries left | Workflow HALTED. Client reçoit refund partiel (stages non-exécutées). Agents complétés sont payés. |
| Quality gate timeout (agent reviewer ne répond pas) | Auto-escalade vers un autre reviewer. Si 2ème timeout → auto-pass avec flag "unreviewed". |
| Tous les agents d'un rôle sont indisponibles | Workflow PAUSED (max 72h). Si pas de match → CANCELLED, full refund. |
| Score borderline (±5 du threshold) | Escalade vers un 2ème reviewer. Score final = moyenne des deux. |

---

## 5. Smart Contract Changes

### 5.1 Nouveau contrat : `WorkflowEscrow.sol`

**Décision architecturale critique** : On ne modifie PAS `MissionEscrow.sol`. On crée un nouveau contrat `WorkflowEscrow.sol` qui **compose** avec l'escrow existant. Chaque stage d'un workflow crée une mission dans `MissionEscrow`. `WorkflowEscrow` orchestre les transitions.

**Justification** : 
- Backward compatible : les missions simples (Bronze, 1 agent) passent toujours par `MissionEscrow` directement.
- Séparation des responsabilités : escrow atomique vs orchestration.
- Surface d'audit réduite : `MissionEscrow` est déjà testé (14/14), on ne le casse pas.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./MissionEscrow.sol";

contract WorkflowEscrow is UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    
    // ═══════════════════════════════════════════════════════
    //                        ENUMS
    // ═══════════════════════════════════════════════════════
    
    enum WorkflowState {
        CREATED,        // Budget locked, stages defined
        IN_PROGRESS,    // At least one stage started
        PAUSED,         // Waiting for agent availability
        COMPLETED,      // All stages passed QG
        HALTED,         // Stage failed, no retries
        CANCELLED,      // Client cancelled before IN_PROGRESS
        DISPUTED        // Global workflow dispute
    }
    
    enum StageState {
        PENDING,        // Waiting for dependencies
        READY,          // Dependencies met, awaiting agent assignment
        ASSIGNED,       // Agent matched, mission created in MissionEscrow
        IN_PROGRESS,    // Agent executing
        DELIVERED,      // Agent delivered, QG pending
        QG_PASSED,      // Quality gate passed
        QG_FAILED,      // Quality gate failed
        RETRYING,       // Re-assigned after failure
        SKIPPED         // Workflow halted, this stage never ran
    }
    
    // ═══════════════════════════════════════════════════════
    //                       STRUCTS
    // ═══════════════════════════════════════════════════════
    
    struct Workflow {
        bytes32 workflowId;
        address client;
        uint256 totalBudget;          // Total USDC locked
        uint256 budgetSpent;          // USDC released to agents so far
        uint8 tier;                   // 0=Bronze, 1=Silver, 2=Gold, 3=Platinum
        uint8 totalStages;
        uint8 completedStages;
        uint8 currentStageIndex;      // Hint (not authoritative for parallel)
        WorkflowState state;
        uint256 createdAt;
        uint256 globalDeadline;
        bytes32 templateHash;         // IPFS hash of workflow template
        bytes32 finalOutputHash;      // IPFS hash of final aggregated output
    }
    
    struct Stage {
        bytes32 workflowId;
        uint8 stageIndex;
        bytes32 role;                 // keccak256("coder"), keccak256("reviewer"), etc.
        bytes32 missionId;            // Reference to MissionEscrow mission (0 if unassigned)
        bytes32 agentId;              // Assigned agent
        uint256 budgetAllocation;     // USDC for this stage
        StageState state;
        uint8 retriesUsed;
        uint8 maxRetries;
        uint256 qualityScore;         // 0-100, from QG evaluation
        bytes32 qualityEvidenceHash;  // IPFS hash of QG report
        uint8[] dependencies;         // Indices of stages that must be QG_PASSED
        bool parallel;                // Can execute in parallel with siblings
    }
    
    // ═══════════════════════════════════════════════════════
    //                       STORAGE
    // ═══════════════════════════════════════════════════════
    
    IMissionEscrow public missionEscrow;
    IERC20 public usdc;
    
    mapping(bytes32 => Workflow) public workflows;
    mapping(bytes32 => mapping(uint8 => Stage)) public stages; // workflowId => stageIndex => Stage
    mapping(bytes32 => bytes32) public missionToWorkflow;       // missionId => workflowId (reverse lookup)
    
    uint256 public constant MAX_STAGES = 10;
    uint256 public constant PAUSE_TIMEOUT = 72 hours;
    uint256 public constant RETRY_BUDGET_PERCENT = 30; // % of original stage budget from insurance
    
    // Tier => insurance fee override (basis points)
    mapping(uint8 => uint256) public tierInsuranceBps;
    
    // ═══════════════════════════════════════════════════════
    //                       EVENTS
    // ═══════════════════════════════════════════════════════
    
    event WorkflowCreated(bytes32 indexed workflowId, address indexed client, uint8 tier, uint256 totalBudget);
    event StageAdvanced(bytes32 indexed workflowId, uint8 stageIndex, StageState newState);
    event QualityGateEvaluated(bytes32 indexed workflowId, uint8 stageIndex, bool passed, uint256 score, bytes32 evidenceHash);
    event WorkflowCompleted(bytes32 indexed workflowId, uint256 totalSpent, bytes32 finalOutputHash);
    event WorkflowHalted(bytes32 indexed workflowId, uint8 failedStageIndex, string reason);
    event StageRetry(bytes32 indexed workflowId, uint8 stageIndex, uint8 retryCount, bytes32 newAgentId);
    
    // ═══════════════════════════════════════════════════════
    //                    CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════
    
    /// @notice Create a workflow with locked budget. Stages defined off-chain, hash stored.
    /// @param tier 0-3 (Bronze/Silver/Gold/Platinum)
    /// @param totalBudget Total USDC to lock
    /// @param globalDeadline Unix timestamp
    /// @param templateHash IPFS hash of WorkflowTemplate JSON
    /// @param stageBudgets Array of USDC allocations per stage (must sum to totalBudget minus fees)
    /// @param stageDeps Array of packed dependency bitmasks (stage i depends on bits set)
    /// @param stageRoles Array of role hashes
    /// @param stageMaxRetries Array of max retries per stage
    /// @param stageParallel Array of parallel flags
    function createWorkflow(
        uint8 tier,
        uint256 totalBudget,
        uint256 globalDeadline,
        bytes32 templateHash,
        uint256[] calldata stageBudgets,
        uint256[] calldata stageDeps,
        bytes32[] calldata stageRoles,
        uint8[] calldata stageMaxRetries,
        bool[] calldata stageParallel
    ) external nonReentrant returns (bytes32 workflowId) {
        require(stageBudgets.length <= MAX_STAGES, "Too many stages");
        require(stageBudgets.length == stageRoles.length, "Array mismatch");
        require(globalDeadline > block.timestamp + 1 hours, "Deadline too soon");
        
        // Validate budget sums (allow for fee delta)
        uint256 stageSum;
        for (uint8 i = 0; i < stageBudgets.length; i++) {
            stageSum += stageBudgets[i];
        }
        uint256 fees = _calculateWorkflowFees(totalBudget, tier);
        require(stageSum + fees <= totalBudget, "Budget overflow");
        
        // Transfer USDC
        usdc.transferFrom(msg.sender, address(this), totalBudget);
        
        workflowId = keccak256(abi.encodePacked(msg.sender, block.timestamp, templateHash));
        
        workflows[workflowId] = Workflow({
            workflowId: workflowId,
            client: msg.sender,
            totalBudget: totalBudget,
            budgetSpent: 0,
            tier: tier,
            totalStages: uint8(stageBudgets.length),
            completedStages: 0,
            currentStageIndex: 0,
            state: WorkflowState.CREATED,
            createdAt: block.timestamp,
            globalDeadline: globalDeadline,
            templateHash: templateHash,
            finalOutputHash: bytes32(0)
        });
        
        // Create stages
        for (uint8 i = 0; i < stageBudgets.length; i++) {
            uint8[] memory deps = _unpackDeps(stageDeps[i], uint8(stageBudgets.length));
            stages[workflowId][i] = Stage({
                workflowId: workflowId,
                stageIndex: i,
                role: stageRoles[i],
                missionId: bytes32(0),
                agentId: bytes32(0),
                budgetAllocation: stageBudgets[i],
                state: i == 0 && deps.length == 0 ? StageState.READY : StageState.PENDING,
                retriesUsed: 0,
                maxRetries: stageMaxRetries[i],
                qualityScore: 0,
                qualityEvidenceHash: bytes32(0),
                dependencies: deps,
                parallel: stageParallel[i]
            });
        }
        
        emit WorkflowCreated(workflowId, msg.sender, tier, totalBudget);
    }
    
    /// @notice Called by orchestrator when agent is matched for a stage.
    ///         Creates a sub-mission in MissionEscrow.
    function assignStage(
        bytes32 workflowId, 
        uint8 stageIndex, 
        bytes32 agentId,
        string calldata ipfsMissionHash
    ) external onlyRole(ORCHESTRATOR_ROLE) nonReentrant {
        Workflow storage wf = workflows[workflowId];
        Stage storage stage = stages[workflowId][stageIndex];
        
        require(wf.state == WorkflowState.IN_PROGRESS || wf.state == WorkflowState.CREATED, "Workflow not active");
        require(stage.state == StageState.READY, "Stage not ready");
        require(_depsResolved(workflowId, stage.dependencies), "Dependencies not met");
        
        // Approve USDC to MissionEscrow and create sub-mission
        usdc.approve(address(missionEscrow), stage.budgetAllocation);
        bytes32 missionId = missionEscrow.createMission(
            agentId, 
            stage.budgetAllocation, 
            wf.globalDeadline,
            ipfsMissionHash
        );
        
        stage.missionId = missionId;
        stage.agentId = agentId;
        stage.state = StageState.ASSIGNED;
        missionToWorkflow[missionId] = workflowId;
        
        if (wf.state == WorkflowState.CREATED) {
            wf.state = WorkflowState.IN_PROGRESS;
        }
        
        emit StageAdvanced(workflowId, stageIndex, StageState.ASSIGNED);
    }
    
    /// @notice Called after MissionEscrow delivers. Orchestrator evaluates QG off-chain, 
    ///         then submits result here.
    function submitQualityGateResult(
        bytes32 workflowId,
        uint8 stageIndex,
        bool passed,
        uint256 score,
        bytes32 evidenceHash
    ) external onlyRole(ORCHESTRATOR_ROLE) nonReentrant {
        Stage storage stage = stages[workflowId][stageIndex];
        require(stage.state == StageState.DELIVERED, "Stage not delivered");
        
        stage.qualityScore = score;
        stage.qualityEvidenceHash = evidenceHash;
        
        if (passed) {
            stage.state = StageState.QG_PASSED;
            workflows[workflowId].completedStages++;
            
            // Approve payment in MissionEscrow
            missionEscrow.approveMission(stage.missionId);
            workflows[workflowId].budgetSpent += stage.budgetAllocation;
            
            // Check if any pending stages can now advance to READY
            _advanceDependents(workflowId, stageIndex);
            
            // Check workflow completion
            if (workflows[workflowId].completedStages == workflows[workflowId].totalStages) {
                _completeWorkflow(workflowId);
            }
        } else {
            if (stage.retriesUsed < stage