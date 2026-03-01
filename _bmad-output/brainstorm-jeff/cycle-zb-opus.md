

# Cycle zb — Budget-Tiered Workflows Architecture (Opus)

---

## 1. Core Insight de ce cycle

Le cycle za a posé la thèse fondatrice : **le budget achète un niveau de confiance, pas du compute**. Le cycle zb doit maintenant répondre à la question d'implémentation la plus dure : **comment orchestrer un workflow multi-agents qui est atomique du point de vue du client mais composable du point de vue on-chain, tout en gardant le `MissionEscrow.sol` existant (14/14 tests, 323 lignes) comme primitive intouchable ?**

L'insight central est le suivant : le `WorkflowEscrow` n'est pas un contrat d'escrow — c'est un **state machine d'orchestration qui agit comme un client proxy envers `MissionEscrow`**. Le client réel dépose ses USDC une seule fois dans le `WorkflowEscrow`. Celui-ci crée N sub-missions séquentiellement dans `MissionEscrow`, chacune avec son budget slice, et consomme les résultats des quality gates pour décider de l'avancement. Le contrat `MissionEscrow` ne sait pas qu'il fait partie d'un workflow — il voit un `client` (l'adresse `WorkflowEscrow`) et un `provider` (l'agent du stage). Cette séparation préserve la composabilité totale : un agent qui travaille dans un workflow a exactement le même flow qu'un agent sur une mission isolée. Le workflow est une abstraction **au-dessus**, pas **à l'intérieur** de l'escrow.

---

## 2. Workflow Engine Design

### 2.1 Le modèle : Pipeline Contraint (pas un DAG générique)

Le cycle za a validé trois patterns et rejeté le DAG arbitraire. Je les reprends et les formalise avec des contraintes strictes :

```
Pattern 1: Sequential Pipeline (95% des cas)
  Stage_1 → QG_1 → Stage_2 → QG_2 → ... → Stage_N → QG_N → DONE

Pattern 2: Parallel Fan-out + Join (cas "review par 2 reviewers indépendants")
  Stage_1 → QG_1 → ┌ Stage_2a ┐ → QG_join → Stage_3 → ...
                    └ Stage_2b ┘

Pattern 3: Conditional Branch (cas "si security audit fail → hotfix stage")
  Stage_1 → QG_1 → Stage_2 → QG_2 ─── pass ──→ Stage_3
                                   └── fail ──→ Stage_2_fix → QG_2_retry → Stage_3
```

### 2.2 Contraintes hard-codées

| Contrainte | Valeur | Raison |
|-----------|--------|--------|
| Max stages | 6 | Au-delà, latence > valeur ajoutée |
| Max parallel branches | 3 | Gas et complexité de dispute |
| Max retries (conditional) | 2 | Éviter boucles infinies ; après 2 fails → dispute |
| Max workflow duration | `deadline × 1.5` | Le client fixe un deadline global |
| Min budget par stage | $5 USDC | En-dessous, pas d'agent rationnel |

### 2.3 Modélisation on-chain

```solidity
struct WorkflowStage {
    bytes32 stageId;
    bytes32 roleHash;            // keccak256("coder"), keccak256("reviewer"), etc.
    uint256 budgetBps;           // ex: 5000 = 50% du budget total
    uint256 qualityThreshold;    // 0-100, score minimum pour passer le QG
    bytes32 dependsOn;           // stageId précédent (bytes32(0) = premier stage)
    bytes32 parallelGroupId;     // si != 0, ce stage est parallèle avec les autres du même group
    bytes32 failBranchStageId;   // stageId de fallback si QG fail (bytes32(0) = pas de fallback)
    uint8   maxRetries;          // 0, 1 ou 2
}

struct Workflow {
    bytes32 workflowId;
    address client;
    uint256 totalBudget;         // USDC déposé à la création
    uint256 releasedAmount;      // USDC déjà payé aux agents
    uint256 frozenAmount;        // USDC en escrow dans des sub-missions actives
    bytes32 templateHash;        // IPFS hash du YAML template original
    uint8   currentStageIndex;
    WorkflowState state;         // CREATED, ACTIVE, STAGE_PENDING, COMPLETED, FAILED, DISPUTED
    uint256 createdAt;
    uint256 deadline;
    mapping(bytes32 => StageExecution) stageExecutions;
}

struct StageExecution {
    bytes32 missionId;           // ID dans MissionEscrow
    bytes32 agentId;             // agent assigné
    bytes32 qgAttestationHash;  // hash(rapport QG) committé on-chain
    uint256 qgScore;
    bool    passed;
    uint8   retryCount;
    uint256 completedAt;
}
```

### 2.4 State Machine du Workflow

```
CREATED ──(depositFunds)──→ ACTIVE
ACTIVE ──(startStage)──→ STAGE_PENDING
STAGE_PENDING ──(QG pass + no veto)──→ ACTIVE (next stage) | COMPLETED (last stage)
STAGE_PENDING ──(QG fail, has fallback)──→ STAGE_PENDING (fallback stage)
STAGE_PENDING ──(QG fail, no fallback, retries left)──→ STAGE_PENDING (retry)
STAGE_PENDING ──(QG fail, no fallback, no retries)──→ FAILED
STAGE_PENDING ──(client veto)──→ DISPUTED
ACTIVE | STAGE_PENDING ──(deadline expired)──→ FAILED
DISPUTED ──(resolution)──→ ACTIVE | COMPLETED | REFUNDED
FAILED ──(automatic)──→ partial refund to client + pay completed stages
```

### 2.5 Le Pattern d'Appel : WorkflowEscrow comme Meta-Client

```
┌─────────────────────────────────────────┐
│ Client                                   │
│ ① createWorkflow(stages[], budget)       │
│    → deposit USDC into WorkflowEscrow    │
└────────────────┬────────────────────────┘
                 │
┌────────────────▼────────────────────────┐
│ WorkflowEscrow.sol (Orchestrator)        │
│ ② Pour chaque stage :                   │
│    a. Sélectionne agent (via Matcher)    │
│    b. Appelle MissionEscrow.createMission│
│       (client = address(this), ...)      │
│    c. Attend deliverMission              │
│    d. Vérifie QG attestation             │
│    e. Si pass : approveMission → next    │
│       Si fail : retry / branch / fail    │
└────────────────┬────────────────────────┘
                 │
┌────────────────▼────────────────────────┐
│ MissionEscrow.sol (Inchangé, 14 tests)  │
│ ③ Cycle normal : CREATED→...→COMPLETED  │
│    Ne sait PAS qu'il est dans un workflow│
└─────────────────────────────────────────┘
```

**Point critique :** Le `WorkflowEscrow` doit avoir un rôle spécial dans `MissionEscrow` (ou être un `client` standard). Je recommande **client standard** — aucune modification du `MissionEscrow`. Le `WorkflowEscrow` détient les USDC, les approuve vers `MissionEscrow` pour chaque sub-mission, et collecte les résultats. C'est clean et testable.

---

## 3. Budget Tiers — Spec Détaillée

### 3.1 Rappel décision za : Les tiers sont des templates off-chain

Le contrat ne connaît pas "Bronze" ou "Gold". Il connaît `stages[]` et `budgetSplit[]`. Les tiers sont des **YAML templates** que le GitHub Bot instancie. C'est la bonne décision. Mais il faut quand même les spécifier rigoureusement.

### 3.2 Tier Definitions

#### 🥉 Bronze — "Quick Task"

| Paramètre | Valeur |
|-----------|--------|
| Budget range | $10 – $50 USDC |
| Stages | 1 (execution uniquement) |
| Agents | 1 : Coder |
| QG | Aucun (auto-approve 48h standard) |
| SLA | Best effort, deadline client ou 72h max |
| Use case | Bug fix, script, data transform, doc update |
| Insurance | Standard (5% pool) |
| Dry run | Disponible (10% price, 5min) |

```yaml
# template: bronze.yaml
name: quick-task
tier: bronze
stages:
  - role: coder
    budget_pct: 100
    quality_gate: null
    sla_hours: 72
```

**Point clé :** Bronze = le `MissionEscrow` existant tel quel. Pas de `WorkflowEscrow` nécessaire. C'est le fallback, le MVP.

#### 🥈 Silver — "Code + Review"

| Paramètre | Valeur |
|-----------|--------|
| Budget range | $50 – $200 USDC |
| Stages | 2-3 (code → review, optionnel: tests) |
| Agents | 2-3 : Coder + Reviewer (+ Tester optionnel) |
| QG | Score ≥ 70/100 entre chaque stage |
| SLA | 48h par stage, deadline global ≤ 1 semaine |
| Use case | Feature implementation, refactoring, API endpoint |
| Insurance | Standard (5% pool) |
| Dry run | Sur stage 1 uniquement |

```yaml
name: code-review
tier: silver
stages:
  - role: coder
    budget_pct: 60
    quality_gate:
      type: peer_review
      threshold: 70
      reviewer_role: reviewer
    sla_hours: 48
  - role: reviewer
    budget_pct: 25
    quality_gate:
      type: auto_check  # lint + tests pass
      threshold: 80
    sla_hours: 24
  - role: tester          # optionnel
    budget_pct: 15
    quality_gate: null
    sla_hours: 24
    optional: true
```

**Budget split example ($100) :**
- Coder: $54 (60% × $90 provider share)
- Reviewer: $22.50 (25% × $90)
- Tester: $13.50 (15% × $90)
- Insurance: $5, Burn: $3, Treasury: $2

#### 🥇 Gold — "Full QA Pipeline"

| Paramètre | Valeur |
|-----------|--------|
| Budget range | $200 – $1,000 USDC |
| Stages | 4-5 (code → review → security → tests → optimize) |
| Agents | 4-5 spécialisés |
| QG | Score ≥ 80/100, security audit ≥ 90/100 |
| SLA | 24-48h par stage, deadline global ≤ 2 semaines |
| Use case | Smart contract, critical feature, data pipeline |
| Insurance | Enhanced (7% pool, 3x payout cap) |
| Client veto | 24h window entre chaque stage |
| Conditional branch | Si security fail → hotfix stage automatique |

```yaml
name: full-qa
tier: gold
max_retries_global: 2
stages:
  - role: coder
    budget_pct: 40
    quality_gate:
      type: peer_review
      threshold: 80
      reviewer_role: reviewer
    sla_hours: 48
  - role: reviewer
    budget_pct: 15
    quality_gate:
      type: attestation
      threshold: 80
    sla_hours: 24
  - role: security_auditor
    budget_pct: 20
    quality_gate:
      type: security_scan
      threshold: 90
      tools: [semgrep, slither, mythril]
    sla_hours: 48
    on_fail:
      branch_to: hotfix
  - role: tester
    budget_pct: 15
    quality_gate:
      type: coverage_check
      threshold: 80  # 80% coverage minimum
    sla_hours: 24
  - role: optimizer
    budget_pct: 10
    quality_gate: null
    sla_hours: 24
branches:
  hotfix:
    role: coder
    budget_pct: 0  # payé par le coder original (slash ou re-travail)
    quality_gate:
      type: security_scan
      threshold: 90
    sla_hours: 24
    max_retries: 1
```

**Point controversé : le hotfix stage.** Qui paie ? Trois options :

| Option | Mécanisme | Recommandation |
|--------|-----------|----------------|
| A: Le coder original retravaille gratis | Slash partiel de son paiement si le fix prend trop de temps | ✅ V1 — simple, incentive aligné |
| B: Budget additionnel du client | Client paie un supplément pour le fix | ❌ Mauvais signal — le client paie pour un défaut |
| C: Insurance pool | L'assurance couvre le re-travail | ⚠️ V2 — si les données montrent que c'est fréquent |

**Décision recommandée :** Option A. Le coder a déjà été "assigné" le stage. Si son output fail le security QG, il retravaille dans le cadre de sa mission existante (le `MissionEscrow` est encore en `IN_PROGRESS`). Son paiement n'est releasé que quand le QG passe. S'il ne fix pas dans le délai, sa mission est `DISPUTED` et il risque un slash de son stake.

#### 💎 Platinum — "Enterprise Full Audit"

| Paramètre | Valeur |
|-----------|--------|
| Budget range | $1,000+ USDC |
| Stages | 6 (max) + audit trail complet |
| Agents | 6 spécialisés + reviewers indépendants |
| QG | Score ≥ 90/100 partout, security ≥ 95/100 |
| SLA | Contractuel, pénalités en AGNT si dépassé |
| Use case | Smart contract audit, compliance, enterprise migration |
| Insurance | Premium (10% pool, 5x payout cap, dedicated) |
| Client veto | 48h window, arbitrage fast-track |
| Parallel stages | Security + Tests en parallèle (fan-out) |
| Compliance | Full EAL trail, IPFS pinning permanent, SOC2-ready export |

```yaml
name: enterprise-audit
tier: platinum
max_retries_global: 2
parallel_allowed: true
compliance:
  eal_retention: permanent
  ipfs_pin: true
  export_format: [json, pdf]
stages:
  - role: architect
    budget_pct: 20
    quality_gate:
      type: design_review
      threshold: 90
      reviewers: 2  # fan-out: 2 reviewers indépendants
    sla_hours: 72
  - role: coder
    budget_pct: 25
    quality_gate:
      type: peer_review
      threshold: 90
      reviewer_role: senior_reviewer
    sla_hours: 72
  - role: security_auditor
    budget_pct: 20
    parallel_group: qa_parallel
    quality_gate:
      type: formal_verification
      threshold: 95
      tools: [certora, echidna, slither]
    sla_hours: 96
    on_fail:
      branch_to: security_remediation
  - role: tester
    budget_pct: 15
    parallel_group: qa_parallel  # même group = parallèle avec security
    quality_gate:
      type: coverage_check
      threshold: 90
    sla_hours: 48
  - role: optimizer
    budget_pct: 10
    quality_gate:
      type: gas_benchmark
      threshold: 85
    sla_hours: 48
  - role: compliance_reviewer
    budget_pct: 10
    quality_gate:
      type: attestation
      threshold: 90
    sla_hours: 48
branches:
  security_remediation:
    role: security_specialist
    budget_pct: 0  # covered by insurance for platinum
    quality_gate:
      type: formal_verification
      threshold: 95
    sla_hours: 48
    max_retries: 2
```

### 3.3 Tableau Comparatif Final

| Aspect | 🥉 Bronze | 🥈 Silver | 🥇 Gold | 💎 Platinum |
|--------|----------|----------|---------|------------|
| **Budget** | $10-50 | $50-200 | $200-1K | $1K+ |
| **Stages** | 1 | 2-3 | 4-5 | 6 |
| **Agents** | 1 | 2-3 | 4-5 | 6+ |
| **QG Threshold** | N/A | 70+ | 80+ (sec: 90+) | 90+ (sec: 95+) |
| **SLA** | Best effort | 48h/stage | 24-48h/stage | Contractuel |
| **Insurance** | 5% / 2x cap | 5% / 2x cap | 7% / 3x cap | 10% / 5x cap |
| **Client Veto** | N/A | Non | 24h | 48h |
| **Parallel** | Non | Non | Non | Oui |
| **Conditional Branch** | Non | Non | Oui | Oui |
| **Retries** | 0 | 0 | 2 | 2 |
| **EAL** | Basic | Standard | Full | Permanent + export |
| **Contract** | MissionEscrow | WorkflowEscrow | WorkflowEscrow | WorkflowEscrow |
| **Target Rework Reduction** | ~0% | ~40% | ~70% | ~90% |

---

## 4. Quality Gates

### 4.1 Rappel décision za : QG = attestation off-chain + commitment on-chain

Le contrat vérifie uniquement :
1. L'attestation existe (hash non-nul)
2. Elle est signée par un agent autorisé pour ce rôle/stage
3. Le score dépasse le threshold configuré

### 4.2 Taxonomie des Quality Gate Types

| QG Type | Description | Qui produit | Objectivité | Coût |
|---------|-------------|-------------|------------|------|
| `auto_check` | Lint, build, tests pass | CI agent automatique | 100% objectif | Quasi-nul |
| `coverage_check` | % couverture tests | CI agent | 100% objectif | Quasi-nul |
| `security_scan` | Semgrep, Slither, Mythril | Security agent | 90% objectif | Modéré |
| `gas_benchmark` | Gas usage vs baseline | Benchmark agent | 100% objectif | Faible |
| `peer_review` | Code review humanoïde | Reviewer agent | 60% subjectif | Modéré |
| `design_review` | Architecture review | Senior reviewer(s) | 70% subjectif | Élevé |
| `attestation` | Déclaration signée | Reviewer | Variable | Faible |
| `formal_verification` | Certora/Echidna | Verification agent | 95% objectif | Élevé |

### 4.3 Scoring Protocol

Chaque QG produit un **QualityReport** off-chain stocké sur IPFS :

```typescript
interface QualityReport {
  reportId: string;              // UUID
  workflowId: bytes32;
  stageId: bytes32;
  reviewerAgentId: bytes32;
  reviewerAddress: address;      // pour vérification de signature on-chain
  
  // Score composite
  overallScore: number;          // 0-100
  subscores: {
    correctness: number;         // 0-100 — le code fait-il ce qui est demandé ?
    security: number;            // 0-100 — vulnérabilités détectées ?
    quality: number;             // 0-100 — lisibilité, patterns, best practices
    tests: number;               // 0-100 — couverture, pertinence des tests
    performance: number;         // 0-100 — gas, latence, memory
  };
  
  // Détails
  findings: Finding[];           // liste de problèmes trouvés
  toolOutputs: {                 // outputs bruts des outils automatiques
    tool: string;
    output: string;
    passedRules: number;
    totalRules: number;
  }[];
  
  // Verdict
  passed: boolean;               // overallScore >= threshold
  recommendation: 'approve' | 'revise' | 'reject';
  
  // Provenance
  timestamp: number;
  signature: string;             // EIP-712 sig du reviewer
  ealReference: bytes32;         // lien vers le Execution Attestation Log du stage
}
```

### 4.4 Anti-Gaming des Quality Gates

Le risque n°1 est la **collusion reviewer-coder**. Un reviewer caoutchouc qui donne 100/100 à tout.

**Mécanismes de défense :**

| Mécanisme | Description | Implémentation |
|-----------|-------------|----------------|
| **Spot-check random** | 10% des QG sont re-évalués par un reviewer indépendant | Off-chain scheduler, résultat comparé ; écart > 20 points → flag |
| **Reviewer rotation** | Un reviewer ne peut pas reviewer le même coder plus de 3 fois sur 30 jours | Tracking off-chain, enforcement dans le Matcher |
| **Reviewer reputation séparée** | La réputation reviewer est distincte de la réputation coder | Champ `reviewerScore` dans `Reputation` struct |
| **Stake reviewer** | Les reviewers ont aussi du stake, slashable si spot-check échoue | `ProviderStaking` existant — le reviewer est aussi un provider |
| **Score variance tracking** | Un reviewer qui donne toujours 95+ est suspect | Off-chain analytics, flag automatique |
| **Client escalation** | Le client peut toujours disputer, même après QG pass | 24/48h veto window (cycle za) |

### 4.5 Flow détaillé d'un Quality Gate

```
1. Stage N agent complète sa mission → deliverMission(missionId, resultHash)
2. WorkflowEscrow reçoit l'event MissionDelivered
3. Orchestrator off-chain déclenche le QG :
   a. Sélectionne le reviewer agent (Matcher, en excluant l'agent du stage)
   b. Envoie le résultat (IPFS hash) au reviewer
   c. Reviewer produit un QualityReport, le signe, le stocke sur IPFS
   d. Reviewer appelle submitQualityAttestation(workflowId, stageId, reportHash, score, signature)
4. WorkflowEscrow vérifie :
   a. ecrecover(reportHash, signature) == reviewer.address ✓
   b. reviewer est autorisé pour ce rôle ✓
   c. score >= stage.qualityThreshold ✓
5. Si PASS :
   a. Client veto window démarre (24h Gold, 48h Platinum, 0 Silver)
   b. Si pas de veto → approveMission dans MissionEscrow → fonds releasés → next stage
6. Si FAIL :
   a. Si failBranchStageId != 0 → déclenche le branch
   b. Sinon, si retryCount < maxRetries → retry avec le même agent
   c. Sinon → workflow FAILED, partial refund
```

### 4.6 On-Chain : Minimal et Vérifiable

```solidity
function submitQualityAttestation(
    bytes32 workflowId,
    bytes32 stageId,
    bytes32 reportHash,
    uint256 score,
    bytes calldata signature
) external {
    Workflow storage wf = workflows[workflowId];
    WorkflowStage memory stage = wf.stages[stageId];
    StageExecution storage exec = wf.stageExecutions[stageId];
    
    // Vérifier que le stage est en attente de QG
    require(exec.missionId != bytes32(0), "Stage not started");
    require(exec.qgAttestationHash == bytes32(0), "QG already submitted");
    
    // Vérifier la signature du reviewer
    address reviewer = ECDSA.recover(
        keccak256(abi.encodePacked(workflowId, stageId, reportHash, score)),
        signature
    );
    require(agentRegistry.isAuthorizedReviewer(reviewer, stage.roleHash), "Unauthorized reviewer");
    
    // Stocker l'attestation
    exec.qgAttestationHash = reportHash;
    exec.qgScore = score;
    exec.passed = score >= stage.qualityThreshold;
    
    if (exec.passed) {
        // Démarrer la veto window
        exec.completedAt = block.timestamp;
        emit QualityGatePassed(workflowId, stageId, score);
    } else {
        _handleQGFailure(workflowId, stageId, exec);
    }
}
```

---

## 5. Smart Contract Changes

### 5.1 Principe fondamental : MissionEscrow.sol reste INCHANGÉ

Zéro modification à `MissionEscrow.sol`. Les 14 tests restent verts. Le nouveau contrat est **additionnel**, pas un remplacement.

### 5.2 Nouveau contrat : `WorkflowEscrow.sol`

**Héritage et composition :**

```
WorkflowEscrow.sol
├── Initializable (UUPS)
├── UUPSUpgradeable
├── AccessControlUpgradeable
├── ReentrancyGuardUpgradeable
├── PausableUpgradeable
│
├── Compose: IMissionEscrow (interface du contrat existant)
├── Compose: IAgentRegistry (pour vérifier les agents)
├── Compose: IProviderStaking (pour vérifier les stakes)
└── Compose: IERC20 (USDC)
```

### 5.3 Interface complète

```solidity
interface IWorkflowEscrow {
    
    // ─── Enums ───
    enum WorkflowState {
        CREATED,         // Workflow créé, pas encore funded
        FUNDED,          // USDC déposés
        ACTIVE,          // Au moins un stage en cours
        STAGE_PENDING,   // En attente de QG ou veto
        COMPLETED,       // Tous les stages passés
        FAILED,          // Un stage a échoué sans recours
        DISPUTED,        // Client a contesté
        CANCELLED,       // Annulé avant ACTIVE
        REFUNDED         // Remboursé (partiel ou total)
    }
    
    // ─── Events ───
    event WorkflowCreated(bytes32 indexed workflowId, address indexed client, uint256 totalBudget, uint8 stageCount);
    event WorkflowFunded(bytes32 indexed workflowId, uint256 amount);
    event StageStarted(bytes32 indexed workflowId, bytes32 indexed stageId, bytes32 missionId, bytes32 agentId);
    event QualityGatePassed(bytes32 indexed workflowId, bytes32 indexed stageId, uint256 score);
    event QualityGateFailed(bytes32 indexed workflowId, bytes32 indexed stageId, uint256 score, uint8 retriesLeft);
    event StageCompleted(bytes32 indexed workflowId, bytes32 indexed stageId, uint256 paidAmount);
    event VetoWindowStarted(bytes32 indexed workflowId, bytes32 indexed stageId, uint256 deadline);
    event ClientVetoed(bytes32 indexed workflowId, bytes32 indexed stageId, string reason);
    event WorkflowCompleted(bytes32 indexed workflowId, uint256 totalPaid, uint256 totalRefunded);
    event WorkflowFailed(bytes32 indexed workflowId, bytes32 failedStageId, uint256 refundedAmount);
    event BranchActivated(bytes32 indexed workflowId, bytes32 fromStageId, bytes32 toBranchId);
    
    // ─── Core Functions ───
    
    /// @notice Crée un workflow avec ses stages. Ne transfère pas encore de fonds.
    /// @param templateHash IPFS hash du YAML template
    /// @param stages Tableau ordonné des stages
    /// @param deadline Timestamp deadline global
    /// @return workflowId
    function createWorkflow(
        bytes32 templateHash,
        WorkflowStage[] calldata stages,
        uint256 deadline
    ) external returns (bytes32 workflowId);
    
    /// @notice Dépose les USDC et active le workflow
    /// @param workflowId ID du workflow
    /// @param amount Montant USDC (doit matcher totalBudget calculé)
    function fundWorkflow(bytes32 workflowId, uint256 amount) external;
    
    /// @notice Démarre le prochain stage en créant une sub-mission dans MissionEscrow
    /// @dev Appelé par l'orchestrator (rôle ORCHESTRATOR_ROLE)
    /// @param workflowId ID du workflow
    /// @param stageId ID du stage à démarrer
    /// @param agentId Agent sélectionné par le matcher
    function startStage(
        bytes32 workflowId,
        bytes32 stageId,
        bytes32 agentId
    ) external;
    
    /// @notice Soumet l'attestation QG pour un stage
    /// @param workflowId ID du workflow
    /// @param stageId ID du stage
    /// @param reportHash IPFS hash du Quality