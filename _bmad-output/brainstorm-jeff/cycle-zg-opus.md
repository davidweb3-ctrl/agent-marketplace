

# Cycle zg — Budget-Tiered Workflows Architecture

---

## 1. Core Insight de ce cycle

**Le budget n'est pas un input au workflow — il *est* le workflow.** Les cycles précédents ont validé que le WorkflowEscrow est une state machine financière, que le Plan Compiler est off-chain, et que les quality gates sont des attestations hashées. Ce cycle révèle l'implication architecturale de bout en bout : le budget du client ne détermine pas simplement combien d'agents on engage — il détermine la **topologie de confiance** de l'exécution. Un client qui paie $20 achète un résultat best-effort avec un seul agent. Un client qui paie $2000 achète une **chaîne de preuves vérifiables** : chaque étape atteste de la précédente, chaque quality gate réduit la probabilité de rework, et l'audit trail complet constitue un artefact de compliance. La conséquence architecturale majeure est que le Tier n'est pas un paramètre passé au système — c'est un **plan d'exécution compilé** qui encode des invariants financiers, des contraintes de matching, et des seuils de qualité dans un DAG signé. Le Plan Compiler devient le composant le plus critique du système, et le WorkflowEscrow on-chain devient un automate financier qui applique aveuglément les transitions pré-calculées. Ce renversement — le plan est le produit, pas l'exécution — est ce qui différencie fondamentalement Agent Marketplace d'un simple "hire an AI agent".

---

## 2. Workflow Engine Design

### 2.1 Modèle fondamental : Compiled Plan DAG

Le workflow n'est pas un graphe que le contrat parcourt. C'est un **plan pré-compilé** par le backend, soumis au contrat sous forme de commitment (hash), et exécuté stage par stage avec des transitions validées off-chain et des conséquences financières appliquées on-chain.

```
┌──────────────────────────────────────────────────────────────┐
│                     PLAN COMPILER (off-chain)                │
│                                                              │
│  Input:  TDL YAML + budget + tier selection                  │
│  Output: ExecutionPlan {                                     │
│            stages[],                                         │
│            qualityGates[],                                   │
│            budgetSplits[],                                   │
│            failurePolicy,                                    │
│            matchingConstraints[]                             │
│          }                                                   │
│  Commitment: planHash = keccak256(abi.encode(ExecutionPlan)) │
└──────────────────┬───────────────────────────────────────────┘
                   │ planHash + budgetSplits[] (only financial data)
                   ▼
┌──────────────────────────────────────────────────────────────┐
│                  WORKFLOW ESCROW (on-chain)                   │
│                                                              │
│  Stores:  planHash, totalBudget, stageBudgets[],             │
│           stageStates[], qualityGateThresholds[]             │
│  Does NOT store: agent addresses, matching logic,            │
│                  plan details, quality criteria               │
└──────────────────────────────────────────────────────────────┘
```

### 2.2 Les 3 Patterns de DAG (rappel cycle za, affiné)

**Pattern 1 : Sequential Pipeline** (80% des cas)
```
[Coder] → QG → [Reviewer] → QG → [Tester] → QG → [Optimizer]
```
Chaque stage prend l'output du précédent. Le budget est split linéairement. C'est le default pour Bronze, Silver, Gold.

**Pattern 2 : Parallel Fan-out** (10% des cas)
```
                ┌→ [Security Auditor] → QG ─┐
[Coder] → QG ──┤                            ├→ [Integrator] → QG → Done
                └→ [Test Writer]     → QG ──┘
```
Le stage N+1 attend **tous** les branches parallèles. Le budget des branches parallèles est réparti selon les poids du plan. Utilisé pour Gold+ quand review et tests sont indépendants.

**Pattern 3 : Conditional Branch** (10% des cas)
```
                    score ≥ 8
[Coder] → QG ──── ──────────→ [Optimizer] → Done
                │
                └── score < 8 ─→ [Fix Agent] → QG → (rejoin pipeline)
```
Le résultat du quality gate détermine la branche. Le budget pour la branche de fallback est **pré-réservé** mais non consommé si la branche principale réussit (refund au client).

### 2.3 Invariants du DAG

| Invariant | Rationale | Enforcement |
|-----------|-----------|-------------|
| Max 6 stages | Au-delà, coût coordination > valeur marginale | `require(stages.length <= 6)` on-chain |
| Max 2 branches parallèles | Gas et complexité de synchronisation | Plan Compiler validation |
| Max 1 conditional branch par workflow | Éviter les cascades de fallback | Plan Compiler validation |
| Chaque stage a exactement 1 quality gate | Sauf Bronze (0 QG) | Plan Compiler validation |
| Le budget total est lock à la création | Pas de top-up mid-workflow | `createWorkflow` verrouille USDC |
| Les stages complétés sont irréversibles | Paiement release = final | `advanceStage` → `MissionEscrow.approveMission()` |

### 2.4 Plan Lifecycle

```
1. CLIENT poste TDL + sélectionne tier → API backend
2. PLAN COMPILER:
   a. Parse TDL, extrait requirements
   b. Sélectionne le template de tier (ou custom pour Platinum)
   c. Calcule budget splits basé sur les rôles requis par stage
   d. Génère matchingConstraints (tags, rep min, tier min) par stage
   e. Génère qualityGateConfigs (threshold, type) par stage
   f. Signe le plan, calcule planHash
3. CLIENT review le plan (UI montre: "4 stages, $850 total, estimated 36h")
4. CLIENT approuve → tx createWorkflow(planHash, stageBudgets[], totalBudget)
5. USDC transféré au WorkflowEscrow (totalBudget)
6. Stage 1 démarre → Plan Compiler matche un agent → advanceStage(0, agentAddress)
7. Agent exécute → EAL soumis → Quality Gate évalue → score on-chain
8. Score ≥ threshold → advanceStage(1, ...) ; Score < threshold → failStage(0, ...)
9. ... repeat until final stage
10. Dernier stage complété → workflow COMPLETED, tous les fonds distribués
```

---

## 3. Budget Tiers — Spec Détaillée

### 3.1 Philosophie de pricing

Le prix n'est **pas** calculé au poids de compute. Il est calculé comme une **prime d'assurance qualité**. Plus le tier est élevé, plus le client paie pour réduire la probabilité de rework et augmenter la vérifiabilité du résultat.

**Formule conceptuelle :**
```
Prix_tier = Σ(coût_agent_stage_i) + Σ(coût_QG_j) + prime_SLA + marge_plateforme
```

### 3.2 Tier Definitions

#### Bronze — "Ship It"

| Attribut | Valeur |
|----------|--------|
| **Budget range** | $5 – $50 |
| **Stages** | 1 (executor seul) |
| **Quality Gates** | 0 — auto-accept à 48h (existant) |
| **Agents** | 1 coder |
| **Matching** | Best available, rep ≥ 30 |
| **SLA** | Best effort, pas de deadline garanti |
| **Dispute** | Standard (48h window, multisig) |
| **Output** | PR + basic EAL |
| **Insurance** | Standard 5% pool (cap 2x) |
| **Use case** | Bug fix simple, script one-off, docs update |
| **Cible** | Dev solo, side project, quick tasks |

**Workflow on-chain :** N'utilise PAS `WorkflowEscrow`. Passe directement par `MissionEscrow.createMission()`. Zéro overhead additionnel. Backward-compatible à 100%.

#### Silver — "Verify Once"

| Attribut | Valeur |
|----------|--------|
| **Budget range** | $50 – $500 |
| **Stages** | 2–3 (coder → reviewer, ou coder → tester → reviewer) |
| **Quality Gates** | 1 automated (tests pass + lint clean) |
| **Agents** | 2–3 spécialisés |
| **Matching** | Rep ≥ 50, même stack required |
| **SLA** | 72h max end-to-end |
| **Dispute** | Standard + QG attestation comme preuve |
| **Output** | PR + test results + review report + EAL chain |
| **Insurance** | Standard 5% pool |
| **Use case** | Feature implementation, API integration, refactor |
| **Cible** | Startup team, product sprint |

**Budget split default :**
```
Stage 1 (Coder):    55% du budget
Stage 2 (Reviewer): 30% du budget
QG automated:       5% du budget (paye l'agent reviewer pour l'attestation)
Platform fees:      10% (standard: 5% insurance + 3% burn + 2% treasury)
```

Wait — il y a un problème ici. Les platform fees (10%) s'appliquent au **total**, pas par stage. Ça signifie que les splits de stage doivent être calculés sur le net (après fees), ou que les fees sont prélevés à la fin. Clarifions :

**Décision : Fees prélevés au niveau workflow, pas au niveau stage.**

```
Client paie:     $200 (totalBudget)
Platform fees:   $20 (10% → 5% insurance, 3% burn, 2% treasury)
Net distribué:   $180
  → Stage 1:    $180 × 60% = $108 (coder)
  → Stage 2:    $180 × 33% = $59.40 (reviewer)
  → QG cost:    $180 × 7% = $12.60 (QG agent/automated check)
```

C'est plus propre que de prélever 10% sur chaque mission interne. Ça évite aussi le double-dip de fees quand `WorkflowEscrow` crée des sous-missions via `MissionEscrow`.

**⚠️ Implication critique :** Les sous-missions créées par `WorkflowEscrow` dans `MissionEscrow` doivent être flaggées `isWorkflowStage = true` pour **bypass le fee split** du `MissionEscrow` (les fees sont déjà prélevés au niveau workflow). Sinon : 10% au workflow + 10% par stage = 30% de fees sur un Silver 3-stage. Inacceptable.

#### Gold — "Prove It"

| Attribut | Valeur |
|----------|--------|
| **Budget range** | $500 – $5,000 |
| **Stages** | 3–4 (coder → reviewer → security auditor → tester) |
| **Quality Gates** | 2 (1 automated + 1 peer review) |
| **Agents** | 3–4 spécialisés, dont au moins 1 GOLD-tier staker |
| **Matching** | Rep ≥ 70, stack match obligatoire, heartbeat < 5min |
| **SLA** | 48h max, pénalité provider si dépassement (5% slash) |
| **Dispute** | Enhanced — QG attestations + EAL chain comme preuves. Multisig avec bias vers preuves objectives. |
| **Output** | PR + tests + security report + review + EAL chain + coverage report |
| **Insurance** | 7% pool (vs 5% standard) — prime augmentée pour couverture étendue |
| **Use case** | Production feature, API critique, integration tierce |
| **Cible** | Growth startup, team de 20+, pre-Series B |

**Budget split default :**
```
Client paie:          $1,000
Platform fees:        $100 (10%: 5% insurance → $50 raised to 7% = $70, 3% burn = $30, 2% treasury = $20 → wait...)
```

Hmm, le fee split change pour Gold (7% insurance vs 5%). Il faut recalculer. Options :

**Option A :** Garder les 10% fixes, redistribuer les proportions internes.
```
Gold: 10% total → 7% insurance / 1.5% burn / 1.5% treasury
```

**Option B :** Augmenter le fee total pour Gold/Platinum.
```
Gold: 12% total → 7% insurance / 3% burn / 2% treasury
```

**Décision : Option B.** Les tiers supérieurs paient un premium justifié par l'insurance étendue. C'est transparent pour le client (le pricing est affiché upfront) et ça renforce le pool d'insurance proportionnellement au risque (missions plus grosses = risque absolu plus élevé).

| Tier | Total Fee | Insurance | Burn | Treasury |
|------|-----------|-----------|------|----------|
| Bronze | 10% | 5% | 3% | 2% |
| Silver | 10% | 5% | 3% | 2% |
| Gold | 12% | 7% | 3% | 2% |
| Platinum | 15% | 10% | 3% | 2% |

**Gold budget split :**
```
Client paie:          $1,000
Platform fees:        $120 (12%)
Net distribué:        $880
  → Stage 1 (Coder):           $880 × 45% = $396
  → Stage 2 (Reviewer):        $880 × 20% = $176
  → Stage 3 (Security):        $880 × 20% = $176
  → Stage 4 (Tester):          $880 × 10% = $88
  → QG costs (2 gates):        $880 × 5% = $44
```

#### Platinum — "Trust But Verify Everything"

| Attribut | Valeur |
|----------|--------|
| **Budget range** | $5,000+ (custom quote) |
| **Stages** | 4–6 (coder → reviewer → security → tester → optimizer → compliance) |
| **Quality Gates** | 2–3 (automated + peer + client approval gate) |
| **Agents** | 4–6, dont ≥2 GOLD-tier stakers, 1 minimum avec security specialization |
| **Matching** | Rep ≥ 85, GOLD staker tier required, stack match + track record in similar missions |
| **SLA** | Custom deadline, contractual. Pénalité provider: 10% slash si SLA breach. Client SLA: guaranteed completion or 100% refund. |
| **Dispute** | Premium — Dedicated human reviewer in the loop (multisig member), QG attestations, full EAL audit trail. Résolution en 24h. |
| **Output** | PR + tests + security audit report + review + optimization report + compliance checklist + full EAL chain + IPFS-pinned audit trail |
| **Insurance** | 10% pool, payout cap raised to 3x mission value |
| **Use case** | Financial system, healthcare, enterprise API, regulated industry |
| **Cible** | Enterprise, Series B+, regulated sectors |

**Budget split : custom.** Le client travaille avec le Plan Compiler pour définir stages, splits, agents requirements. Le Compiler propose un plan, le client approuve. Pas de template fixe.

**Guard-rail pricing :** Le Compiler impose un **floor** par stage pour éviter les plans dégénérés :
```
Min per stage: $200 (Platinum)
Min per QG:    $100 (Platinum)
Min total:     $5,000
```

### 3.3 Tier Selection Logic

Le client peut :
1. **Choisir explicitement** un tier (Bronze/Silver/Gold/Platinum)
2. **Laisser le système recommander** basé sur le budget et la complexité du TDL

**Auto-detection heuristic (Plan Compiler) :**
```python
def recommend_tier(budget_usdc: int, tdl: TaskDefinition) -> Tier:
    complexity = estimate_complexity(tdl)  # LOW/MED/HIGH/CRITICAL
    
    if budget_usdc < 50 or complexity == "LOW":
        return Tier.BRONZE
    elif budget_usdc < 500 or complexity == "MED":
        return Tier.SILVER
    elif budget_usdc < 5000 or complexity == "HIGH":
        return Tier.GOLD
    else:
        return Tier.PLATINUM

def estimate_complexity(tdl: TaskDefinition) -> str:
    signals = {
        "file_count": len(tdl.affected_files),
        "has_security_tags": any(t in SECURITY_TAGS for t in tdl.tags),
        "has_db_changes": "migration" in tdl.description.lower(),
        "multi_service": len(tdl.services) > 1,
        "external_api": tdl.has_external_dependencies,
    }
    score = sum(WEIGHTS[k] * v for k, v in signals.items())
    if score > 8: return "CRITICAL"
    if score > 5: return "HIGH"
    if score > 2: return "MED"
    return "LOW"
```

Le client peut **override** la recommandation dans les deux sens (underspend ou overspend). Un warning est affiché si le budget semble insuffisant pour la complexité détectée.

---

## 4. Quality Gates

### 4.1 Taxonomie des Quality Gates

| Type | Name | Évaluateur | Critère | Tiers |
|------|------|-----------|---------|-------|
| `QG_NONE` | Auto-accept | Timer (48h) | Aucun — auto-approve | Bronze |
| `QG_AUTOMATED` | CI/CD Check | Automated pipeline | Tests pass + lint + coverage ≥ threshold | Silver+ |
| `QG_PEER_REVIEW` | Agent Review | Agent reviewer (différent du coder) | Score ≥ threshold (0-10) | Gold+ |
| `QG_SECURITY` | Security Scan | Agent security specialist | No critical/high vulns, OWASP check pass | Gold+ |
| `QG_CLIENT_APPROVAL` | Client Sign-off | Client humain | Explicit approve transaction | Platinum |

### 4.2 Quality Gate Attestation Protocol

```
┌─────────────────────────────────────────────────────────────┐
│  QUALITY GATE ATTESTATION FLOW                              │
│                                                             │
│  1. Stage N agent completes work → delivers EAL             │
│  2. Plan Compiler routes output to QG agent/service         │
│  3. QG evaluator produces:                                  │
│     - report: { findings[], score, recommendation }         │
│     - reportHash = keccak256(report)                        │
│  4. QG evaluator signs: sig = sign(reportHash, evaluatorKey)│
│  5. Plan Compiler submits to WorkflowEscrow:                │
│     submitQualityGate(workflowId, stageId, score,           │
│                       reportHash, evaluatorSig)             │
│  6. WorkflowEscrow verifies:                                │
│     - evaluator is registered for this QG role              │
│     - evaluator ≠ stage agent (independence)                │
│     - score format valid (0-100)                            │
│  7. WorkflowEscrow applies threshold:                       │
│     - score ≥ threshold → advanceStage()                    │
│     - score < threshold → failStage()                       │
│  8. Report stored on IPFS, hash immutable on-chain          │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 Thresholds par Tier

| Tier | QG_AUTOMATED threshold | QG_PEER_REVIEW threshold | QG_SECURITY threshold |
|------|----------------------|-------------------------|---------------------|
| Silver | 60/100 (tests pass) | N/A | N/A |
| Gold | 70/100 | 65/100 | 70/100 (no high/critical) |
| Platinum | 80/100 | 75/100 | 80/100 + manual confirm |

### 4.4 Quality Gate Anti-Gaming

**Problème :** L'agent reviewer pourrait rubber-stamp (toujours donner 100/100) pour maximiser ses paiements sans effort.

**Mitigations :**

1. **Reviewer Reputation Impact :** Si un stage post-QG génère un dispute **et que le client gagne**, le reviewer perd de la réputation proportionnellement au score qu'il a donné. Score élevé + dispute perdu = grosse pénalité rep.

```
rep_penalty = (reviewer_score / 100) × base_penalty
```
Un reviewer qui donne 95/100 à du code buggy perd 95% de la pénalité max. Incentive : être honnête.

2. **Spot-check by Platform :** 5% des QG Gold/Platinum sont re-évalués par un second reviewer indépendant. Si l'écart entre les deux scores est > 20 points, le premier reviewer est flaggé. 3 flags = suspension.

3. **Reviewer Selection :** Le reviewer ne peut pas être :
   - Le même provider que le coder
   - Un agent du même provider
   - Un agent avec < 10 missions complétées en review
   - Un agent qui a reviewé > 50% des missions du même coder (collusion detection)

4. **Score Distribution Analysis (V2) :** Un reviewer dont la distribution de scores est statistiquement aberrante (toujours 90+, ou toujours 50-) est flaggé pour investigation automatique.

### 4.5 QG_AUTOMATED — Spec Concrète

L'automated quality gate n'est pas un "agent" au sens marketplace. C'est un **service d'infrastructure** opéré par la plateforme.

```yaml
# QG_AUTOMATED pipeline
steps:
  - name: checkout
    action: git_clone(pr_branch)
  - name: install
    action: npm_install || pip_install  # detected from repo
  - name: lint
    action: eslint || ruff || clippy
    weight: 15  # score contribution
  - name: typecheck
    action: tsc --noEmit || mypy
    weight: 15
  - name: unit_tests
    action: npm test || pytest
    weight: 40
  - name: coverage
    action: nyc || coverage.py
    weight: 20
    threshold: 70%  # coverage minimum
  - name: security_scan
    action: semgrep --config auto
    weight: 10
    
# Score = Σ(step_pass �� weight)
# Ex: all pass = 100, tests fail = 60 max
```

Le coût de QG_AUTOMATED est **fixe** par exécution (pas basé sur le budget mission). Estimé à $2-5 en compute. C'est absorbé dans les frais de stage, pas facturé séparément.

---

## 5. Smart Contract Changes

### 5.1 Architecture Contractuelle Étendue

```
                    ┌─────────────────────┐
                    │    AGNTToken.sol     │
                    │    (unchanged)       │
                    └──────────┬──────────┘
                               │
    ┌──────────────────────────┼──────────────────────────┐
    │                          │                          │
    ▼                          ▼                          ▼
┌──────────────┐    ┌──────────────────┐    ┌──────────────────┐
│ProviderStaking│    │  MissionEscrow   │    │  AgentRegistry   │
│  (unchanged)  │    │  (minor change)  │    │   (unchanged)    │
└──────────────┘    └─────��──┬─────────┘    └──────────────────┘
                             │ composes
                             ▼
                    ┌──────────────────┐
                    │ WorkflowEscrow   │
                    │   (NEW)          │
                    └──────────────────┘
```

### 5.2 MissionEscrow.sol — Modifications Minimales

**Changement unique : ajouter un flag `isWorkflowStage` pour bypass les platform fees.**

```solidity
// AJOUT dans la struct Mission
struct Mission {
    // ... existing fields ...
    bool isWorkflowStage;  // NEW: true if created by WorkflowEscrow
}

// MODIFICATION dans createMission (ou nouvelle fonction)
function createWorkflowStageMission(
    bytes32 agentId,
    uint256 amount,         // montant net, fees déjà prélevés
    uint256 deadline,
    string calldata ipfsMissionHash,
    bytes32 workflowId      // reference au workflow parent
) external onlyWorkflowEscrow returns (bytes32) {
    // Crée une mission SANS prélever de fees (elles sont au niveau workflow)
    // Le provider reçoit 100% du amount
    // ...
}

// AJOUT modifier
modifier onlyWorkflowEscrow() {
    require(msg.sender == workflowEscrowAddress, "Not workflow escrow");
    _;
}

// AJOUT setter (admin only, UUPS upgrade)
function setWorkflowEscrow(address _workflowEscrow) external onlyRole(ADMIN_ROLE) {
    workflowEscrowAddress = _workflowEscrow;
}
```

**Impact sur les tests existants :** ZÉRO. Les 14 tests existants utilisent `createMission()` qui reste inchangé. `createWorkflowStageMission()` est une **nouvelle** fonction, pas une modification. Le flag `isWorkflowStage` default à `false` pour toutes les missions existantes.

### 5.3 WorkflowEscrow.sol — Nouveau Contrat

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MissionEscrow.sol";
import "./AGNTToken.sol";

contract WorkflowEscrow is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // ══════════════════════════════════════════════════════════
    // TYPES
    // ══════════════════════════════════════════════════════════

    enum WorkflowState {
        CREATED,        // Plan committed, budget locked
        IN_PROGRESS,    // At least 1 stage started
        COMPLETED,      // All stages completed
        FAILED,         // A stage failed and abort policy triggered
        CANCELLED,      // Client cancelled before any stage started
        DISPUTED        // At least 1 stage in dispute
    }

    enum StageState {
        PENDING,        // Not yet started
        ACTIVE,         // Mission created, agent working
        QG_PENDING,     // Work delivered, awaiting quality gate
        PASSED,         // QG passed, funds released to agent
        FAILED,         // QG failed
        RETRYING,       // Failed, re-assigned to new agent
        DISPUTED,       // In dispute
        SKIPPED         // Conditional branch not taken
    }

    enum QualityGateType {
        NONE,           // Bronze: auto-accept
        AUTOMATED,      // CI/CD pipeline
        PEER_REVIEW,    // Agent reviewer
        SECURITY_SCAN,  // Security specialist
        CLIENT_APPROVAL // Platinum: client signs
    }

    enum FailurePolicy {
        ABORT_REFUND,   // Refund all remaining stages
        RETRY_ONCE,     // Allow 1 retry per stage
        RETRY_TWICE     // Allow 2 retries per stage (Platinum)
    }

    enum TierLevel {
        BRONZE,     // Not actually used here (goes direct to MissionEscrow)
        SILVER,
        GOLD,
        PLATINUM
    }

    struct QualityGateConfig {
        QualityGateType gateType;
        uint16 threshold;       // 0-100 score threshold
        address evaluator;      // address(0) if not yet assigned
    }

    struct Stage {
        bytes32 missionId;          // MissionEscrow mission ID (set when started)
        uint256 budgetAllocation;   // USDC amount for this stage (net of fees)
        StageState state;
        QualityGateConfig qualityGate;
        uint8 retryCount;
        bytes32 qgReportHash;       // IPFS hash of QG report
        uint16 qgScore;             // Actual score received
        address agent;              // Resolved agent (set at stage start)
        uint256 startedAt;
        uint256 completedAt;
    }

    struct Workflow {
        bytes32 workflowId;
        address client;
        bytes32 planHash;           // keccak256 of the full execution plan
        uint256 totalBudget;        // Total USDC locked
        uint256 platformFees;       // Total fees (varies by tier)
        uint256 netBudget;          // totalBudget - platformFees
        TierLevel tier;
        FailurePolicy failurePolicy;
        WorkflowState state;
        uint8 currentStage;         // Index of current active stage
        uint8 totalStages;
        uint256 createdAt;
        uint256 completedAt;
        uint256 deadline;           // SLA deadline (0 = no SLA)
    }

    // ══════════════════════════════════════════════════════════
    // STORAGE
    // ══════════════════════════════════════════════════════════

    IERC20 public usdc;
    AGNTToken public agntToken;
    Mission