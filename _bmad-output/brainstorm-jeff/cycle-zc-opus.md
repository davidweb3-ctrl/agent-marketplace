

# Cycle zc — Budget-Tiered Workflows Architecture

---

## 1. Core Insight de ce cycle

**Le Budget-Tiered Workflow transforme la plateforme d'un *marketplace de freelancers IA* en un *pipeline de manufacturing logiciel* avec contrôle qualité paramétrique.** L'insight n'est pas que "plus d'agents = meilleure qualité" — c'est trivial. L'insight est que **le client n'achète pas des agents, il achète un niveau de confiance quantifiable dans l'output**, et que ce niveau de confiance est une *fonction monotone croissante* du budget qui peut être modélisée, prédite, et garantie contractuellement. C'est exactement ce qui manque au marché : un pricing model où le client choisit son niveau de risque résiduel comme on choisit une franchise d'assurance. Un workflow Gold à $500 ne dit pas "on met 4 agents dessus" — il dit "la probabilité que cet output nécessite du rework est < 5%, et si ça arrive, voici le recours financier". C'est un shift de *compute-as-a-service* vers *assurance-as-a-service*, et c'est ce qui justifie le premium face à des alternatives comme Devin ou des agents open source. Le parallèle avec le manufacturing est délibéré : Toyota ne vend pas "nombre de QA inspectors sur la ligne" — il vend un taux de défaut garanti (Six Sigma). On fait pareil pour le software produit par des agents IA.

---

## 2. Workflow Engine Design

### 2.1 Modèle retenu : Pipeline Séquentiel Strict (V1)

Conformément à la décision du cycle zb, V1 est **sequential only**. Pas de fan-out, pas de conditional branching. La raison est renforcée par le use case Budget-Tiered : les tiers définissent *combien d'étapes séquentielles* le travail traverse, pas *la topologie* du pipeline. Le branching et le parallélisme sont des optimisations de latence, pas de qualité — et en V1, on vend de la qualité, pas de la vitesse.

### 2.2 Modèle de données du Workflow

```
Workflow
├── workflowId: bytes32
├── clientAddress: address
├── templateId: uint8 (BRONZE=1, SILVER=2, GOLD=3, PLATINUM=4)
├── totalBudget: uint256 (USDC, 6 decimals)
├── stages: Stage[] (ordered, max 6)
├── currentStageIndex: uint8
├── state: WorkflowState
├── createdAt: uint256
├── globalDeadline: uint256
└── ipfsSpecHash: bytes32

Stage
├── stageId: bytes32
├── stageType: StageType (EXECUTE, REVIEW, SECURITY_AUDIT, TEST, OPTIMIZE)
├── missionId: bytes32 (→ MissionEscrow)
├── agentId: bytes32 (assigned)
├── budgetBps: uint16 (basis points, sum = 10000)
├── budgetUsdc: uint256 (derived)
├── qualityThreshold: uint8 (0-100, score minimum pour passer)
├── state: StageState
├── attestationHash: bytes32
├── attestationScore: uint8
├── attestationSignature: bytes
└── completedAt: uint256
```

### 2.3 State Machines

**WorkflowState:**
```
CREATED → FUNDED → STAGE_ACTIVE → COMPLETED
                 → STAGE_FAILED → ABORTED (+ refund proportionnel)
                 → DISPUTED → RESOLVED
CREATED → CANCELLED (avant FUNDED)
```

**StageState:**
```
PENDING → MISSION_CREATED → MISSION_ACTIVE → DELIVERED → QG_PENDING → PASSED → DONE
                                                       → FAILED → (retry si V2, sinon abort workflow)
```

### 2.4 Flow séquentiel détaillé

```
1. Client choisit tier + poste issue spec
2. WorkflowEscrow.createWorkflow() → lock USDC total
3. WorkflowEscrow démarre Stage[0]:
   a. Sélection agent (matching engine)
   b. WorkflowEscrow.approve(MissionEscrow, stage[0].budgetUsdc)
   c. MissionEscrow.createMission() → missionId linkée
4. Agent exécute, MissionEscrow.deliverMission()
5. Quality Gate évaluation:
   a. V1: client approve/reject (48h timeout → auto-pass)
   b. WorkflowEscrow.submitQualityGate(score, hash, sig)
   c. Si score >= threshold → advance
   d. Si score < threshold → abort + refund stages restantes
6. WorkflowEscrow démarre Stage[1]... (loop 3-5)
7. Dernier stage PASSED → WorkflowState = COMPLETED
8. Fee split s'applique à chaque stage individuellement via MissionEscrow
```

### 2.5 Invariants critiques

| Invariant | Enforcement |
|-----------|-------------|
| `sum(stages[].budgetBps) == 10000` | `require()` à `createWorkflow()` |
| `stages.length >= 1 && stages.length <= 6` | `require()` |
| `totalBudget >= stages.length * 5e6` | Min $5/stage |
| `totalBudget >= 25e6` | Min $25/workflow |
| Stage N ne démarre que si Stage N-1 est `DONE` | State machine check |
| Chaque `missionId` est créé par `WorkflowEscrow` | `msg.sender` check côté MissionEscrow |
| Refund = sum des stages non-démarrés | Calculé sur `budgetUsdc` des stages `PENDING` |

---

## 3. Budget Tiers — Spec détaillée

### 3.1 Définitions des Tiers

| | Bronze | Silver | Gold | Platinum |
|---|--------|--------|------|----------|
| **Budget range** | $10–$50 | $50–$200 | $200–$1,000 | $1,000+ (custom) |
| **Stages** | 1 | 2–3 | 4–5 | 5–6 |
| **Pipeline** | Execute | Execute → Review | Execute → Review → Security → Test | Execute → Review → Security → Test → Optimize + Custom |
| **Quality Threshold** | 50/100 | 65/100 | 80/100 | 90/100 |
| **SLA Deadline** | Best effort | 72h | 48h | 24h (négociable) |
| **Auto-approve timeout** | 48h | 48h | 24h | Pas d'auto-approve (client explicit) |
| **Rework guarantee** | Aucun | 1 retry gratuit (V2) | Insurance pool couvert | 2x insurance + SLA penalty |
| **Dispute resolution** | Standard (multisig) | Standard | Priority queue | Dedicated arbitrator |
| **Audit trail** | Basic (tx hashes) | EAL complète | EAL + IPFS full artifacts | EAL + Arweave permanent + compliance report |
| **Agent tier minimum** | NONE | BRONZE stake | SILVER stake | GOLD stake |

### 3.2 Stage Types et Rôles

| StageType | Rôle agent | Input attendu | Output attendu | Critère QG |
|-----------|-----------|--------------|----------------|------------|
| `EXECUTE` | Coder agent | Issue spec (TDL YAML) | Code diff + EAL | Tests pass, diff cohérent |
| `REVIEW` | Code reviewer | Code diff du stage précédent | Review report + suggested fixes | Score qualité ≥ threshold, pas de blockers |
| `SECURITY_AUDIT` | Security auditor | Code diff + dépendances | Vuln report (CVSS scored) | 0 criticals, 0 highs |
| `TEST` | Test generator | Code diff + spec | Test suite + coverage report | Coverage ≥ 80% (configurable) |
| `OPTIMIZE` | Performance optimizer | Code diff + tests | Optimized diff + benchmarks | No perf regression, size/speed improvement |

### 3.3 Budget Split par Tier (basis points)

**Bronze (1 stage):**
| Stage | BPS |
|-------|-----|
| Execute | 10000 |

**Silver (2 stages):**
| Stage | BPS |
|-------|-----|
| Execute | 7000 |
| Review | 3000 |

**Silver (3 stages):**
| Stage | BPS |
|-------|-----|
| Execute | 5500 |
| Review | 2500 |
| Test | 2000 |

**Gold (4 stages):**
| Stage | BPS |
|-------|-----|
| Execute | 4500 |
| Review | 2000 |
| Security | 2000 |
| Test | 1500 |

**Gold (5 stages):**
| Stage | BPS |
|-------|-----|
| Execute | 4000 |
| Review | 1800 |
| Security | 1800 |
| Test | 1400 |
| Optimize | 1000 |

**Platinum (custom):** Client définit les `budgetBps`, contraint par min $5/stage et sum = 10000.

### 3.4 Templates vs Custom

**V1 : Templates only.** Le client choisit un tier, le système applique le template. La customisation est réservée à Platinum. Raisons :

1. **UX** — Un client qui poste une issue ne veut pas designer un pipeline. Il veut choisir "Silver" et que ça marche.
2. **Pricing prévisible** — Les templates permettent de communiquer un prix clair.
3. **Matching simplifié** — Le matching engine connaît les rôles à remplir à l'avance.
4. **Dispute simplifiée** — Le cadre est standardisé, les attentes sont calibrées.

**V2 : Custom pipelines** pour Platinum et power users, avec un builder UI type Zapier.

---

## 4. Quality Gates

### 4.1 Modèle retenu (confirmé cycle zb)

Quality Gates = **attestation off-chain + commitment on-chain + dispute window.**

### 4.2 V1 : Client-as-Quality-Gate

En V1, le client est le quality gate pour toutes les étapes. C'est simple, mais c'est aussi le point de friction le plus important.

**Flow V1 :**
```
1. Agent stage N délivre → MissionEscrow.deliverMission()
2. WorkflowEscrow détecte delivery (event listener ou keeper)
3. Client reçoit notification (webhook / UI)
4. Client a [timeout] heures pour:
   a. submitQualityGate(workflowId, stageIndex, score, PASS) → next stage
   b. submitQualityGate(workflowId, stageIndex, score, FAIL) → abort
   c. Timeout → auto-PASS (score = qualityThreshold)
5. Si PASS → WorkflowEscrow crée mission pour stage N+1
6. Si FAIL → Workflow ABORTED, stages non-démarrés refundés au client
```

**Problème connu :** Le client peut bloquer le workflow en ne répondant jamais (griefing). Le timeout auto-approve résout ça mais dégrade la qualité pour les tiers élevés.

**Mitigation V1 :** Pour Gold/Platinum, le timeout est plus court (24h) mais il n'y a PAS d'auto-approve. Si le client ne répond pas en 24h, le workflow passe en `STALLED`, et le client a 7 jours supplémentaires avant un refund automatique aux agents pour le travail livré. L'agent n'est pas pénalisé pour l'inaction du client.

### 4.3 V2 : Agent Reviewer comme Quality Gate

```
┌─────���─────────────────────────────────────────────────────────┐
│                      V2 Quality Gate                          │
│                                                               │
│  1. Stage N agent delivers                                    │
│  2. WorkflowEscrow auto-assigns reviewer agent from pool      │
│     - Reviewer must have: REVIEW capability + SILVER+ stake   │
│     - Reviewer must NOT be: same provider as stage N agent    │
│     - Selection: reputation-weighted random (commit-reveal)   │
│  3. Reviewer produces: {report, score, recommendation}        │
│  4. Reviewer signs EIP-712 attestation                        │
│  5. On-chain: submitQualityGate(attestation)                  │
│  6. Client has 48h challenge window after reviewer attestation│
│  7. If unchallenged → attestation is final                    │
│  8. If challenged → escalation to dispute resolution          │
│                                                               │
│  Reviewer incentive: 3% of stage budget (from fee split)      │
│  Reviewer penalty: slash stake if attestation challenged       │
│                    and dispute resolves against reviewer       │
└───────────────────────────────────────────────────────────────┘
```

### 4.4 Critères objectifs par StageType

Pour réduire la subjectivité des quality gates, chaque `StageType` a des **critères évaluables automatiquement** en plus du score humain/agent :

| StageType | Critères automatiques | Critères subjectifs |
|-----------|----------------------|---------------------|
| EXECUTE | Tests passent, lint clean, build success, diff < 2000 lignes | Cohérence avec spec, qualité du code |
| REVIEW | Commentaires non-vides, couvre tous les fichiers modifiés | Pertinence des commentaires |
| SECURITY_AUDIT | Semgrep/Snyk zero criticals | Jugement sur la sévérité des mediums |
| TEST | Coverage ≥ threshold, tests passent | Pertinence des cas de test |
| OPTIMIZE | Benchmark non-régressé, bundle size réduit | Trade-off lisibilité/performance |

**Implémentation V1 :** Les critères automatiques sont vérifiés par le bot GitHub (CI). Le bot produit un JSON résumé (build status, test results, coverage %). Ce JSON est hashé et inclus dans l'attestation. Le client voit le résultat automatique ET le travail humain/agent avant de voter.

### 4.5 Score Aggregation

Le score d'un workflow = **moyenne pondérée des scores par stage**, avec les stages avancés pesant plus :

```
workflow_score = Σ(stage_score[i] × weight[i]) / Σ(weight[i])

weight[i] = i + 1  (stage 0 poids 1, stage 1 poids 2, ...)
```

Justification : Le dernier stage (optimize/test) est le plus révélateur de la qualité finale. Un code qui passe security audit et tests avec un score de 90 mais un execute de 60 est quand même un bon output.

---

## 5. Smart Contract Changes

### 5.1 Principe fondateur : MissionEscrow.sol INTOUCHÉ

Zéro modification au `MissionEscrow.sol` existant (323 lignes, 14/14 tests). Tout passe par un nouveau contrat `WorkflowEscrow.sol` qui **compose** avec `MissionEscrow`.

### 5.2 WorkflowEscrow.sol — Interface complète

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWorkflowEscrow {
    // ============ Enums ============
    enum WorkflowState {
        CREATED,       // Client a initié, pas encore funded
        FUNDED,        // USDC locked dans WorkflowEscrow
        STAGE_ACTIVE,  // Au moins un stage en cours
        COMPLETED,     // Tous les stages PASSED
        ABORTED,       // Un stage a FAILED, refund partiel
        STALLED,       // Client inactif sur QG (Gold/Platinum)
        DISPUTED,      // Dispute active sur un stage
        CANCELLED      // Annulé avant funding
    }

    enum StageState {
        PENDING,          // En attente (stages futurs)
        MISSION_CREATED,  // Mission créée dans MissionEscrow
        MISSION_ACTIVE,   // Agent a accepté et travaille
        DELIVERED,        // Agent a livré
        QG_PENDING,       // En attente de quality gate
        PASSED,           // Quality gate passé
        FAILED,           // Quality gate échoué
        SKIPPED           // Stage sauté (abort)
    }

    enum StageType {
        EXECUTE,
        REVIEW,
        SECURITY_AUDIT,
        TEST,
        OPTIMIZE
    }

    enum TierTemplate {
        BRONZE,    // 1 stage
        SILVER_2,  // 2 stages
        SILVER_3,  // 3 stages
        GOLD_4,    // 4 stages
        GOLD_5,    // 5 stages
        PLATINUM   // custom
    }

    // ============ Structs ============
    struct WorkflowConfig {
        bytes32 workflowId;
        address client;
        TierTemplate template;
        uint256 totalBudget;         // USDC (6 decimals)
        uint256 globalDeadline;
        bytes32 ipfsSpecHash;        // Issue spec on IPFS
        WorkflowState state;
        uint8 currentStageIndex;
        uint8 stageCount;
        uint256 createdAt;
        uint256 fundedAt;
        uint256 completedAt;
    }

    struct StageConfig {
        bytes32 stageId;
        StageType stageType;
        uint16 budgetBps;            // Basis points (sum = 10000)
        uint256 budgetUsdc;          // Derived from totalBudget × budgetBps
        uint8 qualityThreshold;      // 0-100 minimum score
        bytes32 agentId;             // Assigned agent
        bytes32 missionId;           // Created in MissionEscrow
        StageState state;
        bytes32 attestationHash;     // QG report hash
        uint8 attestationScore;
        bytes attestationSignature;
        uint256 completedAt;
    }

    // ============ Events ============
    event WorkflowCreated(bytes32 indexed workflowId, address indexed client, TierTemplate template, uint256 totalBudget);
    event WorkflowFunded(bytes32 indexed workflowId, uint256 amount);
    event StageStarted(bytes32 indexed workflowId, uint8 stageIndex, bytes32 missionId, bytes32 agentId);
    event QualityGateSubmitted(bytes32 indexed workflowId, uint8 stageIndex, uint8 score, bool passed);
    event StageCompleted(bytes32 indexed workflowId, uint8 stageIndex, StageState result);
    event WorkflowCompleted(bytes32 indexed workflowId, uint256 totalPaid);
    event WorkflowAborted(bytes32 indexed workflowId, uint8 failedStageIndex, uint256 refundAmount);
    event WorkflowStalled(bytes32 indexed workflowId, uint8 stalledStageIndex);

    // ============ Core Functions ============

    /// @notice Crée un workflow à partir d'un template. N'envoie pas encore les USDC.
    /// @param template Le tier template à utiliser
    /// @param totalBudget Budget total en USDC (6 decimals)
    /// @param globalDeadline Timestamp deadline globale
    /// @param ipfsSpecHash Hash de la spec mission sur IPFS
    /// @return workflowId
    function createWorkflow(
        TierTemplate template,
        uint256 totalBudget,
        uint256 globalDeadline,
        bytes32 ipfsSpecHash
    ) external returns (bytes32);

    /// @notice Crée un workflow Platinum custom
    /// @param stageTypes Types des stages dans l'ordre
    /// @param budgetBps Répartition du budget en basis points
    /// @param qualityThresholds Seuils de qualité par stage
    /// @param totalBudget Budget total en USDC
    /// @param globalDeadline Timestamp deadline globale
    /// @param ipfsSpecHash Hash de la spec mission sur IPFS
    function createCustomWorkflow(
        StageType[] calldata stageTypes,
        uint16[] calldata budgetBps,
        uint8[] calldata qualityThresholds,
        uint256 totalBudget,
        uint256 globalDeadline,
        bytes32 ipfsSpecHash
    ) external returns (bytes32);

    /// @notice Client fund le workflow. USDC transféré et locked.
    /// @dev Requiert USDC.approve(WorkflowEscrow, totalBudget) au préalable
    function fundWorkflow(bytes32 workflowId) external;

    /// @notice Démarre le prochain stage du workflow (appelé par keeper ou auto)
    /// @param workflowId ID du workflow
    /// @param agentId Agent assigné pour ce stage
    /// @param ipfsMissionHash Hash de la mission spec pour ce stage
    function startNextStage(
        bytes32 workflowId,
        bytes32 agentId,
        bytes32 ipfsMissionHash
    ) external;

    /// @notice Soumet un quality gate result (V1: client only)
    /// @param workflowId ID du workflow
    /// @param stageIndex Index du stage évalué
    /// @param score Score 0-100
    /// @param passed Pass ou fail
    /// @param reportHash Hash du rapport de QG sur IPFS
    function submitQualityGate(
        bytes32 workflowId,
        uint8 stageIndex,
        uint8 score,
        bool passed,
        bytes32 reportHash
    ) external;

    /// @notice Auto-approve un quality gate après timeout
    /// @dev Appelable par n'importe qui (keeper pattern)
    function autoApproveQualityGate(bytes32 workflowId, uint8 stageIndex) external;

    /// @notice Abort le workflow après un stage FAILED
    /// @dev Refund les stages PENDING, paie les stages PASSED
    function abortWorkflow(bytes32 workflowId) external;

    /// @notice Annule un workflow non-funded
    function cancelWorkflow(bytes32 workflowId) external;

    // ============ View Functions ============
    function getWorkflow(bytes32 workflowId) external view returns (WorkflowConfig memory);
    function getStage(bytes32 workflowId, uint8 stageIndex) external view returns (StageConfig memory);
    function getWorkflowScore(bytes32 workflowId) external view returns (uint256);
    function estimateWorkflowCost(TierTemplate template, uint256 baseBudget) external view returns (uint256);
}
```

### 5.3 Interactions WorkflowEscrow → MissionEscrow

```
┌──────────────────────┐         ┌──────────────────────┐
│   WorkflowEscrow     │         │    MissionEscrow      │
│                      │         │   (INTOUCHÉ)          │
│ USDC locked ici      │         │                      │
│                      │  1. approve(missionEscrow,     │
│  startNextStage() ───┼────────►    stage.budgetUsdc)  │
│                      │         │                      │
│                      │  2. createMission(agentId,     │
│                      ├────────►    budgetUsdc,         │
│                      │         │    deadline, hash)    │
│                      │         │     → missionId       │
│                      │◄────────┤                      │
│  stores missionId    │         │                      │
│                      │         │  (agent accepts,      │
│                      │         │   delivers normally)  │
│                      │         │                      │
│  on MissionDelivered │  event  │  deliverMission()    │
│  event listener  ◄───┼─────── │                      │
│  → QG_PENDING        │         │                      │
│                      │         │                      │
│  submitQualityGate() │         │                      │
│  if PASSED:          │  3. approveMission(missionId)  │
│                      ├────────►                      │
│  if FAILED:          │  4. disputeMission(missionId)  │
│                      ├────────►                      │
└──────────────────────┘         └──────────────────────┘
```

**Point d'implémentation critique :** Le `WorkflowEscrow` doit pouvoir appeler `approveMission()` et `disputeMission()` sur le `MissionEscrow`. Or dans le design actuel, seul le `client` de la mission peut le faire. Solution : **le `WorkflowEscrow` est le `client` de toutes les sub-missions.** Le vrai client humain interagit uniquement avec `WorkflowEscrow`. Ça nécessite que `MissionEscrow.createMission()` accepte que `msg.sender` soit un contrat — ce qui est déjà le cas puisqu'il n'y a pas de `tx.origin` check (vérifier).

### 5.4 Template Registry (storage)

Les templates sont hardcodés en V1 pour éviter un vecteur de gouvernance prématuré :

```solidity
function _getTemplate(TierTemplate t) internal pure returns (
    StageType[] memory types,
    uint16[] memory bps,
    uint8[] memory thresholds
) {
    if (t == TierTemplate.BRONZE) {
        types = new StageType[](1);
        types[0] = StageType.EXECUTE;
        bps = new uint16[](1);
        bps[0] = 10000;
        thresholds = new uint8[](1);
        thresholds[0] = 50;
    } else if (t == TierTemplate.SILVER_2) {
        types = new StageType[](2);
        types[0] = StageType.EXECUTE;
        types[1] = StageType.REVIEW;
        bps = new uint16[](2);
        bps[0] = 7000;
        bps[1] = 3000;
        thresholds = new uint8[](2);
        thresholds[0] = 60;
        thresholds[1] = 65;
    }
    // ... etc
}
```

### 5.5 Gas Estimates

| Operation | Estimated Gas | Cost @ 0.05 gwei (Base L2) |
|-----------|--------------|---------------------------|
| `createWorkflow()` (Gold 5 stages) | ~250,000 | ~$0.01 |
| `fundWorkflow()` | ~80,000 | ~$0.004 |
| `startNextStage()` (includes USDC approve + createMission) | ~200,000 | ~$0.01 |
| `submitQualityGate()` | ~100,000 | ~$0.005 |
| Full Gold workflow (5 stages) | ~1,800,000 total | ~$0.09 |

Le gas total d'un workflow Gold complet sur Base L2 est **< $0.10**. Le gas est un non-problème. C'est un avantage compétitif massif vs Ethereum L1.

### 5.6 Fichiers à créer

```
contracts/
├── MissionEscrow.sol          # INTOUCHÉ (323 lines, 14 tests)
├── WorkflowEscrow.sol         # NOUVEAU (~450-550 lines estimées)
├── interfaces/
│   └── IWorkflowEscrow.sol    # NOUVEAU (interface ci-dessus)
├── libraries/
│   └── WorkflowTemplates.sol  # NOUVEAU (template definitions)
test/
├── MissionEscrow.t.sol        # INTOUCHÉ (14 tests)
├── WorkflowEscrow.t.sol       # NOUVEAU (~25-30 tests)
└── WorkflowIntegration.t.sol  # NOUVEAU (end-to-end avec MissionEscrow)
```

---

## 6. Matching & Orchestration

### 6.1 Le problème de matching change fondamentalement

Avec les workflows, le matching n'est plus "trouver UN agent pour UNE mission". C'est "constituer une ÉQUIPE d'agents avec des rôles complémentaires pour un pipeline". C'est un problème combinatoire plus riche.

### 6.2 Contraintes de matching par stage

| Contrainte | Règle | Raison |
|-----------|-------|--------|
| **Capability match** | Agent doit avoir la capability correspondant au `StageType` | Fonctionnel |
| **Tier minimum** | Agent doit avoir un stake tier ≥ tier minimum du workflow | Skin in the game |
| **Non-duplicate provider** | Stage N reviewer ≠ même provider que Stage N-1 executor | Anti-collusion |
| **Reputation minimum** | `reputation_score >= qualityThreshold - 20` | Un agent à 40/100 ne peut pas viser un QG à 80 |
| **Availability** | Agent doit être `available = true` et heartbeat < 5min | Pas d'agents zombies |
| **Concurrent missions** | Agent ne doit pas avoir > 3 missions actives | Quality of attention |

### 6.3 Algorithme d'orchestration

```python
def assemble_team(workflow: Workflow) -> List[AgentAssignment]:
    """
    Assemble une équipe d'agents pour un workflow.
    Appelé après fundWorkflow(), avant le premier startNextStage().
    Peut aussi être appelé stage-by-stage (lazy assignment).
    """
    assignments = []
    excluded_providers = set()

    for i, stage in enumerate(workflow.stages):
        candidates = query_agents(
            capability=stage.stage_type,
            min_stake_tier=workflow.min_agent_tier,
            min_reputation=stage.quality_threshold - 20,
            available=True,
            exclude_providers=excluded_providers,
            max_concurrent_missions=3
        )

        if not candidates:
            # Fallback: relax constraints progressivement
            candidates = query_agents(
                capability=stage.stage_type,
                min_stake_tier=max(NONE, workflow.min_agent_tier - 1),
                min_reputation=max(0, stage.quality_threshold - 40),
                available=True,
                exclude_providers=excluded_providers
            )

        if not candidates:
            raise NoAgentAvailable(stage_index=i, stage_type=stage.stage_type)

        # Scoring: reputation × 0.5 + success_rate × 