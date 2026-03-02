

# Cycle zm — Budget-Tiered Workflows Architecture

---

## 1. Core Insight de ce cycle

**Le budget n'achète pas du compute supplémentaire — il achète une réduction quantifiable de l'incertitude sur le résultat.** C'est la bascule conceptuelle qui différencie l'Agent Marketplace de tout ce qui existe. Aujourd'hui, quand un client paie plus cher sur Fiverr ou Upwork, il achète un freelancer "mieux noté" — une heuristique faible, non vérifiable, et qui ne scale pas. Ici, chaque dollar additionnel achète un **stage de vérification indépendant** dans un pipeline dont la probabilité de défaut décroît exponentiellement. Le client ne choisit pas "quel agent" — il choisit "quel niveau de certitude que le livrable est correct". C'est un produit d'assurance qualité déguisé en marketplace. Et c'est exactement ce que le buyer enterprise comprend : il ne justifie pas "j'ai payé 3 agents" dans son procurement — il justifie "j'ai acheté un taux de défaut < 5%, et c'est NPV-positif vs. le coût de rework interne". Ce cycle traduit ce positionnement en architecture concrète : le `WorkflowEscrow.sol` qui orchestre des `MissionEscrow` séquentiels, les Quality Gates comme attestation off-chain commitée on-chain, et le tier system comme produit packagé avec pricing prédictible.

---

## 2. Workflow Engine Design

### 2.1 Modèle retenu : Pipeline séquentiel contraint

Le cycle zl a tranché : **pas de DAG arbitraire en V1**. Je valide et je durcis ce choix avec une justification technique supplémentaire.

#### Pourquoi pas un DAG ?

| Critère | Pipeline séquentiel | DAG arbitraire |
|---------|---------------------|----------------|
| Gas cost `advanceStage()` | O(1) — incrément d'index | O(n) — vérifier toutes les dépendances |
| Dispute resolution | Clair — quel stage a fail ? | Ambigu — failure causale floue si branches parallèles |
| UX client | "Étape 1 → 2 → 3, votre résultat est à l'étape 2" | "Le nœud C attend B et D, D est en dispute, C est bloqué" |
| State machine | Linéaire, ~10 états | Exponentiel, 2^n combinaisons |
| Auditabilité | Triviale — log séquentiel | Complexe — nécessite reconstruction du graphe |

#### Le pipeline comme abstraction

```
┌─────────────────────────────────────────────────────────────┐
│                    WorkflowPipeline                          │
│                                                              │
│  Stage[0]    QG[0]    Stage[1]    QG[1]    Stage[2]    QG[2]│
│  ┌──────┐  ┌─────┐  ┌──────┐   ┌─────┐  ┌──────┐   ┌─────┐│
│  │CODER │→ │PASS?│→ │REVIEW│ → │PASS?│→ │TESTER│ → │PASS?││
│  │      │  │     │  │      │   │     │  │      │   │     ││
│  └──────┘  └──┬──┘  └──────┘   └──┬──┘  └──────┘   └──┬──┘│
│               │                    │                     │   │
│          FAIL:│               FAIL:│                FAIL:│   │
│          retry│               retry│               retry│   │
│          or   │               or   │               or   │   │
│          dispute              dispute              dispute  │
└─────────────────────────────────────────────────────────────┘
```

#### Contraintes hard-coded

```solidity
uint8 constant MAX_STAGES = 6;
uint8 constant MIN_STAGES = 1;
uint8 constant MAX_RETRIES_PER_STAGE = 2;
uint256 constant MAX_STAGE_DURATION = 7 days;
uint256 constant QG_EVALUATION_WINDOW = 24 hours;
```

### 2.2 Branching conditionnel (unique exception au séquentiel)

Un seul pattern de branching est autorisé en V1 : le **fallback on QG failure**.

```
Stage[n] → QG[n] → PASS → Stage[n+1]
                 → FAIL → RetryPolicy:
                           ├── retry_count < MAX_RETRIES → re-assign Stage[n]
                           ├── retry_count >= MAX_RETRIES → DISPUTE
                           └── client_override → accept_anyway / cancel_workflow
```

Pas de branches parallèles, pas de conditional routing vers des stages alternatifs. Le "OPTIMIZER" en stage 5 ne s'exécute pas "si le score de sécurité est < 80" — il s'exécute toujours si le client l'a inclus dans le plan. La simplicité tue la complexité accidentelle.

### 2.3 Workflow State Machine

```
WORKFLOW_CREATED
    │
    ├── client funds escrow ──→ WORKFLOW_FUNDED
    │                              │
    │                   ┌──────────┼──────────────────────────┐
    │                   │          ▼                           │
    │                   │   STAGE_N_MATCHING                   │
    │                   │          │                           │
    │                   │          ▼                           │
    │                   │   STAGE_N_IN_PROGRESS                │
    │                   ���          │                           │
    │                   │          ▼                           │
    │                   │   STAGE_N_DELIVERED                  │
    │                   │          │                           │
    │                   │          ▼                           │
    │                   │   QG_N_EVALUATING                    │
    │                   │          │                           │
    │                   │     ┌────┴────┐                      │
    │                   │     │         │                      │
    │                   │   PASS      FAIL                     │
    │                   │     │         │                      │
    │                   │     │    ┌────┴──────┐               │
    │                   │     │    │           │               │
    │                   │     │  RETRY    DISPUTE_STAGE        │
    │                   │     │    │           │               │
    │                   │     │    └→ back to  │               │
    │                   │     │      MATCHING  │               │
    │                   │     │                ▼               │
    │                   │     │         WORKFLOW_DISPUTED      │
    │                   │     │                │               │
    │                   │     │                ▼               │
    │                   │     │         WORKFLOW_RESOLVED      │
    │                   │     │                                │
    │                   │     ▼                                │
    │                   │  n < lastStage? ──YES──→ loop       │
    │                   │     │                                │
    │                   │    NO                                │
    │                   │     │                                │
    │                   │     ▼                                │
    │                   │  WORKFLOW_COMPLETED                  │
    │                   └─────────────────────────────────────┘
    │
    └── cancel before funding ──→ WORKFLOW_CANCELLED
```

**États on-chain du workflow** (uint8 enum, pas les états de chaque mission) :

```solidity
enum WorkflowState {
    CREATED,        // 0 - plan committé, pas encore funded
    FUNDED,         // 1 - escrow total déposé
    IN_PROGRESS,    // 2 - au moins un stage actif
    COMPLETED,      // 3 - tous stages + QGs passés
    DISPUTED,       // 4 - au moins un stage en dispute
    RESOLVED,       // 5 - dispute résolue
    CANCELLED,      // 6 - annulé avant ou pendant
    REFUNDED        // 7 - fonds retournés
}
```

### 2.4 Pourquoi le parallélisme est simulable

Un client qui veut "review + security en même temps" peut créer deux workflows BRONZE indépendants sur le même input. Le résultat est le même — deux agents travaillent en parallèle — sans la complexité d'orchestration. Le merge de leurs outputs est off-chain (le client lit les deux rapports). En V2, si les données montrent que >20% des workflows GOLD+ demandent du parallélisme, on l'ajoutera comme feature first-class.

---

## 3. Budget Tiers — Spec détaillée

### 3.1 Philosophie : le tier est un produit, pas une configuration

Le client ne doit **jamais** avoir à configurer manuellement des stages, des quality gates, ou des budgets par stage. Le tier est un **produit clé en main** avec des defaults optimaux. Le PLATINUM seul permet la customisation.

### 3.2 Tier Specifications

#### BRONZE — "Get It Done"

| Paramètre | Valeur |
|-----------|--------|
| **Stages** | 1 |
| **Pipeline** | `CODER` |
| **Quality Gate** | Aucune (auto-approve 48h standard) |
| **Budget range** | $10 – $100 |
| **Fee protocole** | 10% (standard) |
| **SLA** | Best effort, deadline souple |
| **Retry policy** | 0 retry (dispute directe si insatisfait) |
| **Taux de défaut attendu** | ~30% (baseline sans review) |
| **Target persona** | Dev solo, prototypage, tâches simples |
| **Agent matching** | Best available by tag + reputation |

**Ce que ça donne concrètement :**
```
Client: "Fix this CSS bug" — Budget: $25
→ 1 agent coder, livré en 2h, auto-approve à 48h
→ Provider reçoit $22.50, insurance $1.25, burn $0.75, treasury $0.50
```

#### SILVER — "Verified Quality"

| Paramètre | Valeur |
|-----------|--------|
| **Stages** | 2 |
| **Pipeline** | `CODER → REVIEWER` |
| **Quality Gate** | 1 QG entre coder et livraison (threshold default: 70/100) |
| **Budget range** | $50 – $300 |
| **Fee protocole** | 12% |
| **SLA** | Deadline fixe (défaut: 72h) |
| **Retry policy** | 1 retry par stage |
| **Taux de défaut attendu** | ~12% |
| **Budget split** | 70% coder / 20% reviewer / 10% protocole overhead |
| **Target persona** | Startup engineering team, tâches de production |
| **Agent matching** | Tag + reputation ≥ 60 pour coder, ≥ 70 pour reviewer |

**Ce que ça donne concrètement :**
```
Client: "Implement OAuth2 login flow" — Budget: $150
→ Stage 1: Coder agent ($94.50) — implémente
→ QG 1: Reviewer agent ($26.40) — review code, score 82/100 → PASS
→ Client reçoit code reviewé
→ Auto-approve 48h ou approval manuelle
→ Fee protocole: $18 (12%), réparti insurance/burn/treasury
→ Budget agent net: $120.90, protocole: $18, reste: $11.10 (buffer QG retry)
```

**Wait — le budget split ne fonctionne pas comme ça.** Soyons précis.

**Budget allocation SILVER (sur $150 total) :**
```
Protocole fee (12%):     $18.00
  ├── Insurance (5%):     $7.50
  ├── AGNT burn (3%):     $4.50
  ├── Treasury (2%):      $3.00
  └── Workflow overhead (2%): $3.00  ← NOUVEAU: couvre coordination
  
Agent budget ($132.00):
  ├── Coder (75%):        $99.00
  └── Reviewer (25%):     $33.00
  
Retry buffer:             $0.00 (retry réutilise le budget du stage échoué)
```

**Clarification sur le retry :** si le coder échoue et qu'un retry est déclenché, le nouveau coder est payé avec le même $99.00 qui n'a pas été release. L'ancien coder ne reçoit rien (son escrow n'a pas été libéré). Pas de budget additionnel nécessaire.

#### GOLD — "Production Grade"

| Paramètre | Valeur |
|-----------|--------|
| **Stages** | 3 |
| **Pipeline** | `CODER → REVIEWER → TESTER` |
| **Quality Gates** | 2 QGs (après coder, après reviewer) |
| **Budget range** | $200 – $1,500 |
| **Fee protocole** | 14% |
| **SLA** | Deadline fixe (défaut: 96h), pénalité -5% par 24h de retard |
| **Retry policy** | 2 retries par stage |
| **Taux de défaut attendu** | ~4% |
| **Budget split** | 55% coder / 25% reviewer / 15% tester / 5% workflow overhead |
| **Target persona** | Engineering teams, features de production, PRs critiques |
| **Agent matching** | Reputation ≥ 65 coder, ≥ 75 reviewer, ≥ 70 tester |
| **Bonus** | Rapport de test automatisé inclus dans l'EAL |

**Budget allocation GOLD (sur $500 total) :**
```
Protocole fee (14%):     $70.00
  ├── Insurance (5%):    $25.00
  ├── AGNT burn (3%):    $15.00
  ├── Treasury (2%):     $10.00
  └── Workflow overhead (4%): $20.00

Agent budget ($430.00):
  ├── Coder (55%):       $236.50
  ├── Reviewer (25%):    $107.50
  └── Tester (20%):      $86.00
```

#### PLATINUM — "Enterprise Assurance"

| Paramètre | Valeur |
|-----------|--------|
| **Stages** | 4–6, configurable |
| **Pipeline default** | `CODER → REVIEWER → SECURITY_AUDITOR → TESTER → OPTIMIZER` |
| **Quality Gates** | N-1 QGs (entre chaque stage) |
| **Budget range** | $500 – $10,000+ |
| **Fee protocole** | 16% |
| **SLA** | Contractuel, deadline hard, pénalité -10% par 24h de retard |
| **Retry policy** | 2 retries par stage, escalade auto vers agent de tier supérieur au retry 2 |
| **Taux de défaut attendu** | ~1% |
| **Budget split** | Configurable par le client avec un optimizer qui suggère le split optimal |
| **Target persona** | Enterprise, compliance, systèmes critiques |
| **Agent matching** | Reputation ≥ 80 pour tous les stages, GOLD stake tier minimum |
| **Bonus** | Audit trail complet, attestations signées, rapport IPFS pinné |

**Budget allocation PLATINUM default (sur $2,000, 5 stages) :**
```
Protocole fee (16%):      $320.00
  ├── Insurance (5%):     $100.00
  ├── AGNT burn (3%):     $60.00
  ├── Treasury (2%):      $40.00
  └── Workflow overhead (6%): $120.00

Agent budget ($1,680.00):
  ├── Coder (40%):        $672.00
  ├── Reviewer (20%):     $336.00
  ├── Security (18%):     $302.40
  ├── Tester (14%):       $235.20
  └── Optimizer (8%):     $134.40
```

### 3.3 Tableau comparatif des tiers

| | BRONZE | SILVER | GOLD | PLATINUM |
|---|--------|--------|------|----------|
| Stages | 1 | 2 | 3 | 4-6 |
| Quality Gates | 0 | 1 | 2 | 3-5 |
| Fee protocole | 10% | 12% | 14% | 16% |
| Retries | 0 | 1 | 2 | 2 + escalade |
| SLA | Best effort | 72h | 96h + pénalité | Contractuel |
| Min reputation | Aucun | 60+ | 65+ | 80+ |
| Min stake tier | NONE | BRONZE | SILVER | GOLD |
| Défaut attendu | ~30% | ~12% | ~4% | ~1% |
| Budget min | $10 | $50 | $200 | $500 |
| Insurance active | ✗ | ✓ | ✓ | ✓ (2x cap) |
| Audit trail | Basic | Standard | Complet | Complet + signé |

### 3.4 Ce qui est challengeable dans ce design

**Challenge 1 : Les taux de défaut sont inventés.**
Oui. C'est le point faible. 30% → 12% → 4% → 1% est un mental model plausible mais non validé. La solution : en V1, on ne les affiche pas au client comme des promesses. On les utilise en interne pour calibrer le pricing. En V2, on les calcule empiriquement : `defect_rate(tier) = disputes(tier) / total_missions(tier)` et on publie les chiffres réels. C'est un avantage compétitif massif — on est les seuls à avoir ces données.

**Challenge 2 : Le fee protocole croissant est-il juste ?**
Oui, parce que le risque opérationnel du protocole croît avec le nombre de stages. Un BRONZE qui fail = 1 dispute simple. Un PLATINUM qui fail au stage 4 = 3 stages déjà payés, un agent qui dispute, un client furieux, et un arbitrage complexe. Le 6% supplémentaire de workflow overhead du PLATINUM couvre ce risque réel.

**Challenge 3 : $500 minimum pour PLATINUM, c'est pas cher pour de l'enterprise.**
Correct. C'est le prix d'entrée pour tester. Les vraies missions enterprise seront $2k-$10k+. Le $500 minimum est là pour que le tier ne soit pas abusé par des missions triviales qui ne justifient pas 5 stages.

---

## 4. Quality Gates

### 4.1 Architecture : Attestation off-chain, commitment on-chain

La décision du cycle zl est correcte et je l'affine.

```
┌──────────────────────────────────────────────────┐
│                  OFF-CHAIN                        │
│                                                   │
│  1. Stage[n] agent livre son output (code, PR)    │
│  2. Output stocké IPFS → outputCID               │
│  3. QG agent (reviewer) reçoit outputCID          │
│  4. QG agent évalue :                             │
│     - Structured checklist (10 critères)          │
│     - Score numérique 0-100                       │
│     - Commentaires textuels                       │
│     - Rapport complet → IPFS → reportCID          │
│  5. QG agent signe :                              │
│     sig = sign(keccak256(workflowId, stageIndex,  │
│            outputCID, reportCID, score, timestamp))│
│                                                   │
└──────────────────┬───────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────┐
│                  ON-CHAIN                         │
│                                                   │
│  submitQualityGate(                               │
│    workflowId,                                    │
│    stageIndex,                                    │
│    outputCID,      // hash of deliverable         │
│    reportCID,      // hash of review report       │
│    score,          // 0-100                        │
│    signature       // reviewer's sig              │
│  )                                                │
│                                                   │
│  Contract vérifie :                               │
│  ✓ signature valide (ecrecover)                   │
│  ✓ reviewer == assigned QG agent pour ce stage    │
│  ✓ score est uint8 (0-255, capped 100)           │
│  ✓ workflow est en état STAGE_N_DELIVERED         │
│  ✓ dans la fenêtre QG_EVALUATION_WINDOW (24h)    │
│                                                   │
│  Si score >= threshold :                          │
│    → advanceStage() automatique                   │
│    → release escrow du stage[n] au provider       │
│    → emit QualityGatePass(workflowId, n, score)   │
│                                                   │
│  Si score < threshold :                           │
│    → workflow passe en STAGE_N_QG_FAILED          │
│    → client a 48h pour :                          │
│      (a) acceptOverride() → advance anyway        │
│      (b) requestRetry() → re-match stage[n]       │
│      (c) disputeStage() → freeze + arbitrage      │
│    → si 48h sans action → auto-retry si retries   │
│      dispo, sinon auto-dispute                    │
│                                                   │
└──────────────────────────────────────────────────┘
```

### 4.2 Structured Checklist (le "quoi" de l'évaluation)

Le score ne peut pas être un nombre magique. Le reviewer évalue sur une checklist structurée dont les critères dépendent du `StageRole` :

#### CODER Stage Checklist
| Critère | Poids | Description |
|---------|-------|-------------|
| Correctness | 25% | Le code résout-il le problème décrit dans l'issue ? |
| Completeness | 20% | Toutes les acceptance criteria sont-elles couvertes ? |
| Code Quality | 15% | Lisibilité, conventions, DRY |
| No Regressions | 15% | Les tests existants passent-ils encore ? |
| Edge Cases | 10% | Les cas limites sont-ils gérés ? |
| Documentation | 10% | Comments, docstrings, changelog |
| Security Basics | 5% | Pas de vulnérabilités évidentes |

#### REVIEWER Stage Checklist
| Critère | Poids | Description |
|---------|-------|-------------|
| Review Thoroughness | 30% | Le review couvre-t-il tout le diff ? |
| Actionability | 25% | Les commentaires sont-ils actionnables ? |
| Correctness of Feedback | 25% | Le feedback est-il techniquement correct ? |
| False Positive Rate | 20% | Le reviewer n'a-t-il pas flaggé des non-problèmes ? |

#### TESTER Stage Checklist
| Critère | Poids | Description |
|---------|-------|-------------|
| Coverage | 30% | % de branches/lignes couvertes par les tests |
| Edge Cases | 25% | Cas limites testés |
| Test Quality | 20% | Tests lisibles, maintenables, pas de faux positifs |
| Regression Suite | 15% | Suite complète pour éviter les régressions futures |
| Performance | 10% | Tests de charge si applicable |

#### SECURITY_AUDITOR Stage Checklist
| Critère | Poids | Description |
|---------|-------|-------------|
| OWASP Top 10 | 30% | Aucune vulnérabilité OWASP détectée |
| Dependency Audit | 25% | Pas de CVE connues dans les deps |
| Access Control | 20% | Permissions correctes |
| Data Validation | 15% | Inputs sanitizés |
| Secrets Management | 10% | Pas de secrets hardcodés |

### 4.3 Score computation

```python
def compute_qg_score(checklist_results: List[ChecklistItem]) -> int:
    """
    Chaque item: { criterion, weight, score_0_100, evidence_cid }
    Score final = weighted average, arrondi à l'entier
    """
    total_weight = sum(item.weight for item in checklist_results)
    weighted_sum = sum(item.weight * item.score for item in checklist_results)
    return round(weighted_sum / total_weight)
```

Le score est calculé **off-chain** par l'agent reviewer. On-chain, seul le score final (uint8) est committé. La checklist détaillée est dans le rapport IPFS (reportCID). En cas de dispute, l'arbitre lit le rapport IPFS.

### 4.4 Threshold Design

| Tier | Default Threshold | Client Configurable ? |
|------|------------------|-----------------------|
| BRONZE | N/A (pas de QG) | N/A |
| SILVER | 70/100 | Oui, range 50-95 |
| GOLD | 70/100 | Oui, range 50-95 |
| PLATINUM | 75/100 | Oui, range 60-95 |

**Pourquoi pas 100 ?** Un threshold de 100 est un piège : aucun agent ne livrera parfaitement. Un client qui met 100 bloquera son propre pipeline indéfiniment. Le cap à 95 est un guard-rail UX.

**Pourquoi pas en dessous de 50 ?** En dessous de 50, le QG est un rubber stamp. Autant ne pas avoir de QG. Le minimum à 50 (SILVER/GOLD) et 60 (PLATINUM) force un minimum de rigueur.

### 4.5 Anti-gaming des Quality Gates

**Risque 1 : Collusion coder-reviewer.** Si le coder et le reviewer sont du même provider, le reviewer peut donner un score artificiellement élevé.

**Mitigation :** Le contrat vérifie `providers[stage_n_agent] != providers[qg_n_agent]`. Deux agents du même provider ne peuvent pas être dans des stages consécutifs du même workflow. Ça force la diversité.

```solidity
function _validateNoProviderCollusion(
    bytes32 workflowId, 
    uint8 stageIndex
) internal view {
    address stageProvider = missions[workflow.stageMissionIds[stageIndex]].provider;
    address qgProvider = missions[workflow.qgMissionIds[stageIndex]].provider;
    require(stageProvider != qgProvider, "WF: provider collusion");
}
```

**Risque 2 : Reviewer paresseux.** Le reviewer donne 80/100 à tout le monde pour être payé vite.

**Mitigation :** Spot-check QA existant (du cycle za). 10% des QG attestations sont re-évaluées par un troisième agent aléatoire. Si le score dévie de > 20 points, le reviewer est flaggé. 3 flags = slash de son stake et désactivation temporaire.

**Risque 3 : Client qui met un threshold de 95 pour obtenir un travail parfait au prix d'un SILVER.**

**Mitigation :** Pas de mitigation technique nécessaire. Si le seuil est trop haut, le pipeline va boucler en retries, puis disputer, et le client paie le même budget sans recevoir de résultat. Le marché corrige : les clients rationnels apprendront vite que 70 est le sweet spot.

---

## 5. Smart Contract Changes

### 5.1 Principe fondateur : MissionEscrow.sol reste INCHANGÉ

Les 14 tests Foundry restent verts. `WorkflowEscrow.sol` est un **nouveau contrat** qui compose `MissionEscrow` en tant que meta-client. `MissionEscrow` ne sait pas qu'il est utilisé dans un workflow — pour lui, chaque stage est une mission indépendante.

### 5.2 WorkflowEscrow.sol — Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPS} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from 
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IMissionEscrow} from "./interfaces/IMissionEscrow.sol";

interface IWorkflowEscrow {

    // ─── Enums ────��──────────────────────────────────────────

    enum WorkflowState {
        CREATED,
        FUNDED,
        IN_PROGRESS,
        COMPLETED,
        DISPUTED,
        RESOLVED,
        CANCELLED,
        REFUNDED
    }

    enum StageRole {
        CODER,
        REVIEWER,
        SECURITY_AUDITOR,
        TESTER,
        OPTIMIZER
    }

    enum QGOutcome {
        PENDING,
        PASSED,
        FAILED,
        OVERRIDDEN,  // client accepted despite fail
        DISPUTED
    }

    enum WorkflowTier {
        BRONZE,
        SILVER,
        GOLD,
        PLATINUM
    }

    // ─── Structs ─────────────────────────────────────────────

    struct StageConfig {
        StageRole role;
        uint256 budgetAllocation;    // in USDC base units
        uint256 deadline;            // max duration for this stage
        uint8 maxRetries;
        uint8 minAgentReputation;    // 0-100
    }

    struct QualityGateConfig {
        uint8 threshold;             // 0-100, score needed to pass
        uint256 evaluationWindow;    // seconds for QG agent to submit
        uint256 reviewBudget;        // USDC paid to QG reviewer agent
    }

    struct WorkflowPlan {
        bytes32 workflowId;
        address client;
        WorkflowTier tier;
        uint8 stageCount;
        StageConfig[6] stages;       