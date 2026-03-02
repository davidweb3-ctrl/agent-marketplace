

# Cycle zv — Budget-Tiered Workflows Architecture (Opus)

---

## 1. Core Insight de ce cycle

**Le budget d'un client n'achète pas du compute, il achète un niveau de confiance vérifiable dans le résultat.** C'est la réalisation la plus structurante de ce cycle : quand une entreprise passe de $50 à $500 sur une tâche, elle ne veut pas "plus de GPU" — elle veut la certitude que le livrable est correct, sécurisé, testé, et auditré. Le marché des agents IA est saturé de solutions "one agent, one shot" sans aucune garantie de qualité. Notre différentiateur est de transformer le budget en un **pipeline de vérification multi-agents** où chaque dollar supplémentaire ajoute une couche de confiance mesurable et attestée on-chain. Concrètement : un workflow Bronze ($30) livre un résultat "best effort" d'un seul agent ; un workflow Gold ($400) livre le même résultat mais passé par 4 quality gates indépendantes avec des agents spécialisés (reviewer, security auditor, tester), chacun mettant sa stake en jeu. Le client n'achète pas 5x plus de travail — il achète une **réduction prouvée du risque de rework**, ce qui est exactement le pain point du "30% rework tax" identifié dans le PRD. Cette architecture transforme la plateforme d'un marketplace de freelances IA en un **système d'assurance qualité programmable**.

---

## 2. Workflow Engine Design

### 2.1 Principes directeurs

Le workflow engine doit respecter trois contraintes non-négociables héritées des cycles précédents :

1. **Le contrat est un FSM financier, pas un workflow engine** (cycle zu §1.1) — toute logique d'orchestration vit off-chain
2. **Composition avec MissionEscrow, pas remplacement** (cycle zu §1.2) — les 14 tests verts sont intouchables
3. **Max 6 stages** (cycle zu §1.4) — invariant de protocole hardcodé

### 2.2 Modèle : SSPW (Sequential Spine with Parallel Wings)

Le modèle retenu supporte 3 patterns, tous décomposés en un graphe de stages :

```
Pattern 1: Sequential (Bronze/Silver)
  [Code] → [Review] → [Done]

Pattern 2: Parallel Fan-out (Gold)
  [Code] → ┬─[Review]──────┐
            ├─[Security]────┤ → [Merge Gate] → [Done]
            └─[Tests]───────┘

Pattern 3: Conditional Branch (Platinum)
  [Code] → [Review] → pass? ──→ [Security] → [Tests] → [Done]
                     → fail? ──→ [Rework] → [Review] (retry, max 2)
```

### 2.3 Représentation formelle du workflow

Chaque workflow est un **DAG contraint** décrit en YAML dans la TDL (Task Definition Language) et compilé en un array de stages par l'Orchestrator :

```yaml
# TDL Extension pour workflows
workflow:
  tier: gold
  stages:
    - id: code
      role: coder
      budget_pct: 50        # % du budget total alloué à ce stage
      timeout: 3600          # seconds
      quality_gate:
        threshold: 70        # score minimum pour passer (0-100)
        reviewer_role: reviewer
      next_on_pass: [review, security]  # fan-out parallèle
      next_on_fail: null                # workflow échoue

    - id: review
      role: reviewer
      budget_pct: 15
      timeout: 1800
      quality_gate:
        threshold: 75
        reviewer_role: meta_reviewer   # reviewer du reviewer (Gold+)
      next_on_pass: [merge]
      next_on_fail: [rework]           # conditional branch

    - id: security
      role: security_auditor
      budget_pct: 20
      timeout: 2400
      quality_gate:
        threshold: 80
        reviewer_role: meta_reviewer
      next_on_pass: [merge]
      next_on_fail: null

    - id: merge
      role: orchestrator              # pas un agent, c'est le système
      budget_pct: 0
      type: join_gate                  # attend que tous les parents passent
      next_on_pass: [tests]
      next_on_fail: null

    - id: tests
      role: tester
      budget_pct: 15
      timeout: 1800
      quality_gate:
        threshold: 90                  # seuil plus élevé pour tests
        reviewer_role: null            # auto-évalué (pass/fail objectif)
      next_on_pass: [done]
      next_on_fail: null

    - id: rework
      role: coder
      budget_pct: 0                    # payé sur le contingency
      max_retries: 2
      next_on_pass: [review]
      next_on_fail: null
```

### 2.4 Compilation du DAG

L'Orchestrator (service TypeScript off-chain) compile ce YAML en :

1. **Validation statique** : Vérifie acyclicité (DFS), max 6 stages, budget_pct sum ≤ 100%, pas de fan-out > 3 branches
2. **Topological sort** : Détermine l'ordre d'exécution
3. **Budget allocation** : Calcule les montants USDC par stage
4. **On-chain registration** : Appelle `WorkflowEscrow.createWorkflow()` avec l'array de stages compilé

```typescript
interface CompiledStage {
  stageIndex: uint8;
  role: bytes32;              // keccak256("coder"), etc.
  budgetUsdc: uint256;        // montant USDC (6 decimals)
  timeoutSeconds: uint32;
  gateThreshold: uint8;       // 0-100
  parentStages: uint8[];      // indices des stages parents
  stageType: StageType;       // EXECUTION | JOIN_GATE | CONDITIONAL
  maxRetries: uint8;
}
```

### 2.5 Invariants du workflow engine

| Invariant | Enforcement | Justification |
|-----------|-------------|---------------|
| Max 6 stages | On-chain `require` | Gas + latence + valeur marginale décroissante |
| Max fan-out 3 | Off-chain validation | Complexité de merge + surface de dispute |
| Max 2 retries | On-chain counter | Prévenir boucles infinies qui bloquent l'escrow |
| Budget sum ≤ 100% | Off-chain + on-chain | Tout surplus va au contingency (5% réservé) |
| Aucun cycle | Off-chain DFS (O(V+E)) | DAG strict — contrat ne peut pas vérifier ça en gas raisonnable |
| Timeout par stage | On-chain `block.timestamp` | Éviter les workflows zombies |

### 2.6 State machine du Workflow (on-chain)

```
WorkflowState:
  CREATED        → Client a créé et fundé le workflow
  ACTIVE         → Au moins un stage est en cours
  STAGE_PENDING  → Stage en attente d'agent (per-stage)
  STAGE_ACTIVE   → Agent en exécution (per-stage)
  STAGE_REVIEW   → Quality gate en cours (per-stage)
  STAGE_PASSED   → Gate passé, prêt pour le(s) stage(s) suivant(s)
  STAGE_FAILED   → Gate échoué, branch conditionnel ou fail global
  COMPLETED      → Tous les stages terminaux sont PASSED
  FAILED         → Un stage sans fallback a échoué
  DISPUTED       → Client conteste un résultat
  CANCELLED      → Client annule avant ACTIVE
  HALTED         → Emergency veto du client
```

```
CREATED → ACTIVE (premier stage démarre)
  Per-stage: PENDING → ACTIVE → REVIEW → PASSED | FAILED
    PASSED → déclenche stages enfants (si fan-out)
    FAILED → déclenche rework (si configuré) OU fail global
ACTIVE → COMPLETED (dernier stage PASSED)
ACTIVE → FAILED (stage critique échoue sans fallback)
ANY → HALTED (client emergency veto)
ANY → DISPUTED (via dispute mechanism existant)
```

---

## 3. Budget Tiers — Spec détaillée

### 3.1 Principes de pricing

Le tier n'est **pas** déterminé par le client directement. Le client définit un **budget total** et des **requirements** ; le système recommande le tier optimal. Le client peut forcer un tier supérieur (over-engineer) mais pas inférieur à ce que le risque de la tâche exige (déterminé par la complexité estimée et les tags).

### 3.2 Définition des tiers

#### Bronze — "Quick Ship"
| Paramètre | Valeur |
|-----------|--------|
| **Budget range** | $10 – $75 |
| **Stages** | 1 (exécution seule) |
| **Agents impliqués** | 1 (coder) |
| **Quality Gate** | Aucun formel — auto-approve 48h |
| **SLA** | Best effort, timeout 2h |
| **Insurance** | Standard (5% du budget) |
| **Use case type** | Bug fix simple, script utilitaire, refactor mineur |
| **Workflow pattern** | N/A (mission standalone via MissionEscrow existant) |
| **Dry run** | Optionnel (5min, 10% du prix) |
| **Rework** | Pas de rework automatique, dispute classique |

**Ce que le client achète :** Un résultat rapide et cheap. Aucune garantie au-delà de la réputation de l'agent.

#### Silver — "Reviewed"
| Paramètre | Valeur |
|-----------|--------|
| **Budget range** | $50 – $250 |
| **Stages** | 2–3 (code → review, optionnel: tests) |
| **Agents impliqués** | 2–3 (coder + reviewer, optionnel: tester) |
| **Quality Gate** | 1–2 gates, threshold ≥ 70/100 |
| **SLA** | 6h max end-to-end |
| **Insurance** | Standard (5%) |
| **Use case type** | Feature medium, API endpoint, data pipeline |
| **Workflow pattern** | Sequential |
| **Dry run** | Inclus (stage 1 seulement) |
| **Rework** | 1 retry automatique si review échoue |

**Budget split par défaut :**
| Stage | Allocation | Agent |
|-------|-----------|-------|
| Code | 60% | Coder |
| Review | 25% | Reviewer |
| Tests (opt.) | 15% | Tester |

**Ce que le client achète :** Un second regard. Le reviewer a sa propre stake en jeu et est incité à être honnête — s'il approuve du mauvais code et que le client dispute, le reviewer est slashed aussi.

#### Gold — "Verified"
| Paramètre | Valeur |
|-----------|--------|
| **Budget range** | $200 – $1,000 |
| **Stages** | 4–5 (code → review + security audit en parallèle → tests → merge) |
| **Agents impliqués** | 4–5 (coder, reviewer, security auditor, tester, optimizer optionnel) |
| **Quality Gate** | 3–4 gates, threshold ≥ 75/100 (security: ≥ 80) |
| **SLA** | 12h max end-to-end, pénalité provider si dépassé |
| **Insurance** | Enhanced (7% — 2% supplémentaire prélevé sur le budget) |
| **Use case type** | Smart contract, feature critique, migration DB |
| **Workflow pattern** | SSPW (parallel fan-out pour review + security) |
| **Dry run** | Inclus + mini audit sécu sur le dry run |
| **Rework** | 2 retries, conditional branch |

**Budget split par défaut :**
| Stage | Allocation | Agent |
|-------|-----------|-------|
| Code | 40% | Coder |
| Review | 15% | Reviewer |
| Security Audit | 20% | Security Auditor |
| Tests | 15% | Tester |
| Contingency | 10% | Réservé (rework/retry) |

**Ce que le client achète :** Un audit de sécurité par un agent spécialisé + tests indépendants. L'attestation on-chain prouve que 4 agents indépendants ont validé le livrable. C'est un artefact de compliance utile pour les audits SOC2 / ISO 27001.

#### Platinum — "Enterprise Assured"
| Paramètre | Valeur |
|-----------|--------|
| **Budget range** | $1,000+ (custom) |
| **Stages** | 5–6 (code → review + security → tests → optimization → compliance check) |
| **Agents impliqués** | 5–6+ (custom mix) |
| **Quality Gate** | Tous les gates, threshold ≥ 80/100, meta-review (reviewer du reviewer) |
| **SLA** | Garanti contractuellement, pénalité auto-payée via insurance pool |
| **Insurance** | Premium (10% — dédié, avec payout cap 3x au lieu de 2x) |
| **Use case type** | Système critique, migration infra, feature réglementée |
| **Workflow pattern** | SSPW + conditional branches + meta-review |
| **Dry run** | Inclus, extended (15min au lieu de 5min) |
| **Rework** | 2 retries + escalation vers agent humain supervisé (V2) |
| **Extras** | Audit trail complet (every attestation on-chain), SLA penalty auto, dedicated dispute reviewer pool |

**Budget split par défaut :**
| Stage | Allocation | Agent |
|-------|-----------|-------|
| Code | 35% | Coder |
| Review | 12% | Reviewer |
| Security Audit | 18% | Security Auditor |
| Tests | 12% | Tester |
| Optimization | 10% | Optimizer |
| Meta-review | 5% | Meta-reviewer |
| Contingency | 8% | Réservé (rework/retry/escalation) |

### 3.3 Matrice comparative

| Dimension | Bronze | Silver | Gold | Platinum |
|-----------|--------|--------|------|----------|
| Agents | 1 | 2–3 | 4–5 | 5–6+ |
| Quality Gates | 0 | 1–2 | 3–4 | 5+ meta |
| Max Retries | 0 | 1 | 2 | 2 + escalation |
| SLA Enforcement | None | Soft | Hard (penalty) | Guaranteed (auto-payout) |
| Insurance Pool | 5% | 5% | 7% | 10% |
| Insurance Cap | 2x | 2x | 2x | 3x |
| On-chain Attestations | 1 (result) | 2–3 | 5–8 | 8–12+ |
| Audit Trail | Minimal | Standard | Full | Full + compliance export |
| Rework Protection | Dispute only | 1 auto-retry | 2 auto-retry | 2 + human escalation |
| Estimated rework reduction | 0% | ~40% | ~70% | ~85% |

### 3.4 Tier selection algorithm

```python
def recommend_tier(budget_usdc: float, tags: list[str], complexity_score: int) -> str:
    """
    complexity_score: 1-10, estimé par embedding similarity avec missions passées
    tags critiques: ["security", "smart-contract", "migration", "compliance", "financial"]
    """
    critical_tags = {"security", "smart-contract", "migration", "compliance", "financial"}
    has_critical = bool(set(tags) & critical_tags)
    
    if budget_usdc >= 1000 or (has_critical and complexity_score >= 8):
        return "platinum"
    elif budget_usdc >= 200 or (has_critical and complexity_score >= 5):
        return "gold"
    elif budget_usdc >= 50 or complexity_score >= 4:
        return "silver"
    else:
        return "bronze"
```

**Important :** C'est une **recommandation**, pas une obligation. Le client peut override. Mais le système affiche un warning si le client choisit Bronze pour une issue taguée `security`.

---

## 4. Quality Gates

### 4.1 Architecture (confirmée cycle zu)

```
Quality Gate = Attestation off-chain + Commitment on-chain
```

Le quality gate n'est **pas** un jugement binaire poussé par un oracle. C'est un **processus en 3 phases** :

### 4.2 Les 3 phases d'un Quality Gate

#### Phase 1 : Exécution du reviewer (off-chain)

L'agent reviewer reçoit :
- L'output du stage précédent (code diff, artefact, rapport)
- Le contexte de la mission (TDL, requirements, issue originale)
- Les critères d'évaluation spécifiques au rôle

Il produit un **Review Report** contenant :

```json
{
  "reviewId": "uuid",
  "workflowId": "bytes32",
  "stageIndex": 2,
  "reviewerAgentId": "bytes32",
  "score": 78,
  "dimensions": {
    "correctness": 85,
    "security": 70,
    "test_coverage": 75,
    "code_quality": 82,
    "documentation": 68
  },
  "issues_found": [
    {
      "severity": "medium",
      "description": "SQL injection possible in user input handler",
      "file": "src/handlers/user.ts",
      "line": 42,
      "suggestion": "Use parameterized queries"
    }
  ],
  "verdict": "PASS_WITH_WARNINGS",
  "timestamp": 1709337600,
  "nonce": "unique-nonce-v4"
}
```

#### Phase 2 : Vérification par l'Orchestrator (off-chain)

L'Orchestrator :
1. Vérifie que le score est cohérent avec les dimensions (weighted average ± 5%)
2. Vérifie que le reviewer a bien exécuté dans le timeout
3. Compare le score avec le threshold du stage
4. Si pass : prépare l'attestation on-chain
5. Si fail : route vers le conditional branch (rework ou fail)

**Anti-gaming :** L'Orchestrator maintient une distribution statistique des scores par reviewer. Un reviewer qui donne systématiquement 100/100 ou 0/100 est flaggé. Z-score > 2.5 → enquête automatique, suspension temporaire.

#### Phase 3 : Commitment on-chain

```solidity
function submitGateAttestation(
    bytes32 workflowId,
    uint8 stageIndex,
    bytes32 attestationHash,      // keccak256(full report JSON)
    uint8 score,                   // 0-100, en clair on-chain
    bytes calldata reviewerSig,    // EIP-712 signature de l'agent reviewer
    bytes calldata orchestratorSig // co-signature de l'orchestrator
) external onlyOrchestrator {
    Stage storage stage = workflows[workflowId].stages[stageIndex];
    require(stage.state == StageState.REVIEW, "NOT_IN_REVIEW");
    require(score <= 100, "INVALID_SCORE");
    
    // Vérifier les deux signatures
    require(_verifyReviewerSig(workflowId, stageIndex, attestationHash, score, reviewerSig), "INVALID_REVIEWER_SIG");
    require(_verifyOrchestratorSig(workflowId, stageIndex, attestationHash, score, orchestratorSig), "INVALID_ORCH_SIG");
    
    stage.attestationHash = attestationHash;
    stage.gateScore = score;
    stage.attestedAt = block.timestamp;
    
    if (score >= stage.gateThreshold) {
        stage.state = StageState.PASSED;
        _releaseStageFunds(workflowId, stageIndex);
        emit StagePasssed(workflowId, stageIndex, score);
    } else {
        if (stage.retryCount < stage.maxRetries) {
            stage.retryCount++;
            stage.state = StageState.PENDING; // restart
            emit StageRetry(workflowId, stageIndex, stage.retryCount);
        } else {
            stage.state = StageState.FAILED;
            emit StageFailed(workflowId, stageIndex, score);
            _handleWorkflowFailure(workflowId, stageIndex);
        }
    }
}
```

### 4.3 Critères de scoring par rôle

| Rôle | Dimensions évaluées | Poids | Threshold Bronze/Silver/Gold/Platinum |
|------|---------------------|-------|--------------------------------------|
| **Reviewer** | Correctness (40%), Code Quality (30%), Documentation (15%), Test Coverage (15%) | Weighted avg | —/70/75/80 |
| **Security Auditor** | Vulnerability Scan (50%), Input Validation (20%), Auth/AuthZ (20%), Data Protection (10%) | Weighted avg | —/—/80/85 |
| **Tester** | Test Pass Rate (60%), Coverage % (25%), Edge Cases (15%) | Weighted avg | —/—/75/80 |
| **Optimizer** | Performance Delta (40%), Resource Usage (30%), Maintainability (30%) | Weighted avg | —/—/—/70 |
| **Meta-reviewer** | Consistency (40%), Thoroughness (30%), Accuracy (30%) | Weighted avg | —/—/—/80 |

### 4.4 Quality Gate pour tests : cas spécial

Les tests sont le seul quality gate **objectivement vérifiable**. L'agent tester produit :
- Un test suite
- Un rapport d'exécution avec pass/fail/coverage

Le score est **mécaniquement calculé**, pas subjectif :

```python
test_score = (
    0.60 * (tests_passed / tests_total * 100) +
    0.25 * min(coverage_pct, 100) +
    0.15 * (edge_cases_covered / edge_cases_identified * 100)
)
```

L'Orchestrator peut vérifier ce score en rejouant les tests dans un sandbox. C'est le gate le plus trustless de la chaîne.

### 4.5 Dispute sur un Quality Gate

Si le client conteste un quality gate (ex: "le reviewer a donné 85/100 mais le code a un bug évident") :

1. Le rapport complet est récupéré via IPFS (hash vérifié on-chain)
2. 3 dispute reviewers indépendants (du `ReviewerRegistry`) évaluent
3. Si 2/3 donnent raison au client → stage FAILED, reviewer slashed
4. Si 2/3 donnent raison au reviewer → dispute rejetée, client perd la dispute fee

---

## 5. Smart Contract Changes

### 5.1 Nouveau contrat : `WorkflowEscrow.sol`

Le contrat ne remplace **rien**. Il s'ajoute et compose avec `MissionEscrow.sol` existant.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MissionEscrow.sol";

contract WorkflowEscrow is UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    
    // ──────── Constants ────────
    uint8 public constant MAX_STAGES = 6;
    uint8 public constant MAX_FAN_OUT = 3;
    uint8 public constant MAX_RETRIES = 2;
    uint256 public constant CONTINGENCY_BPS = 500; // 5%
    
    bytes32 public constant ORCHESTRATOR_ROLE = keccak256("ORCHESTRATOR_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    // ──────── Enums ────────
    enum WorkflowState { CREATED, ACTIVE, COMPLETED, FAILED, DISPUTED, CANCELLED, HALTED }
    enum StageState { PENDING, ACTIVE, REVIEW, PASSED, FAILED, SKIPPED }
    enum StageType { EXECUTION, JOIN_GATE, CONDITIONAL }
    enum Tier { BRONZE, SILVER, GOLD, PLATINUM }
    
    // ──────── Structs ────────
    struct Stage {
        bytes32 role;              // keccak256 du rôle ("coder", "reviewer", etc.)
        bytes32 agentId;           // agent assigné (0 si pas encore matché)
        bytes32 missionId;         // mission créée dans MissionEscrow
        uint256 budgetUsdc;        // budget alloué (6 decimals)
        uint32 timeoutSeconds;
        uint8 gateThreshold;       // 0-100
        uint8[] parentStages;      // indices des stages parents
        StageType stageType;
        StageState state;
        uint8 maxRetries;
        uint8 retryCount;
        bytes32 attestationHash;   // hash du rapport QG
        uint8 gateScore;           // score en clair
        uint256 activatedAt;
        uint256 attestedAt;
    }
    
    struct Workflow {
        bytes32 workflowId;
        address client;
        Tier tier;
        uint256 totalBudget;       // montant USDC total
        uint256 contingencyBudget; // réserve pour retries
        uint256 releasedTotal;     // total déjà libéré
        uint8 stageCount;
        WorkflowState state;
        uint256 createdAt;
        uint256 completedAt;
        string ipfsTdlHash;       // hash du TDL YAML complet
    }
    
    // ──────── State ────────
    mapping(bytes32 => Workflow) public workflows;
    mapping(bytes32 => Stage[]) public workflowStages; // workflowId → stages
    
    IERC20 public usdc;
    MissionEscrow public missionEscrow;
    
    uint256 public workflowCount;
    
    // ──────── Events ────────
    event WorkflowCreated(bytes32 indexed workflowId, address indexed client, Tier tier, uint256 totalBudget);
    event StageActivated(bytes32 indexed workflowId, uint8 stageIndex, bytes32 agentId);
    event StageDelivered(bytes32 indexed workflowId, uint8 stageIndex, bytes32 resultHash);
    event StagePassed(bytes32 indexed workflowId, uint8 stageIndex, uint8 score);
    event StageFailed(bytes32 indexed workflowId, uint8 stageIndex, uint8 score);
    event StageRetry(bytes32 indexed workflowId, uint8 stageIndex, uint8 retryCount);
    event WorkflowCompleted(bytes32 indexed workflowId, uint256 totalReleased);
    event WorkflowFailed(bytes32 indexed workflowId, uint8 failedStageIndex);
    event WorkflowHalted(bytes32 indexed workflowId, address client);
    event ContingencyUsed(bytes32 indexed workflowId, uint256 amount, string reason);
    
    // ──────── Core Functions ─────���──
    
    function createWorkflow(
        Tier tier,
        bytes32[] calldata roles,
        uint256[] calldata budgets,
        uint32[] calldata timeouts,
        uint8[] calldata thresholds,
        uint8[][] calldata parentStages,
        StageType[] calldata stageTypes,
        uint8[] calldata maxRetries,
        string calldata ipfsTdlHash
    ) external nonReentrant returns (bytes32) {
        uint8 stageCount = uint8(roles.length);
        require(stageCount > 0 && stageCount <= MAX_STAGES, "INVALID_STAGE_COUNT");
        require(
            roles.length == budgets.length &&
            roles.length == timeouts.length &&
            roles.length == thresholds.length &&
            roles.length == parentStages.length &&
            roles.length == stageTypes.length &&
            roles.length == maxRetries.length,
            "ARRAY_LENGTH_MISMATCH"
        );
        
        uint256 totalBudget;
        for (uint8 i = 0; i < stageCount; i++) {
            totalBudget += budgets[i];
            require(parentStages[i].length <= MAX_FAN_OUT, "FAN_OUT_EXCEEDED");
            require(maxRetries[i] <= MAX_RETRIES, "MAX_RETRIES_EXCEEDED");
            // Vérifier que les parents ont des indices valides et < i (enforce DAG)
            for (uint8 j = 0; j < parentStages[i].length; j++) {
                require(parentStages[i][j] < i, "INVALID_PARENT_INDEX");
            }
        }
        
        uint256 contingency = (totalBudget * CONTINGENCY_BPS) / 10000;
        uint256 grandTotal = totalBudget + contingency;
        
        // Transfer USDC from client
        require(usdc.transferFrom(msg.sender, address(this), grandTotal), "TRANSFER_FAILED");
        
        bytes32 workflowId = keccak256(abi.encodePacked(
            msg.sender, block.timestamp, workflowCount++
        ));
        
        Workflow storage wf = workflows[workflowId];
        wf.workflowId = workflowId;
        wf.client = msg.sender;
        wf.tier = tier;
        wf.totalBudget = totalBudget;
        wf.contingencyBudget = contingency;
        wf.stageCount =