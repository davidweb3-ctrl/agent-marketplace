

# Cycle zf — Budget-Tiered Workflows Architecture (Opus)

---

## 1. Core Insight de ce cycle

Le cycle ze a posé les fondations architecturales : pipeline séquentiel, lazy creation, composition over inheritance, quality gates off-chain avec commitment on-chain. Le cycle zf doit maintenant **matérialiser l'architecture concrète** — c'est-à-dire transformer les décisions validées en specs implémentables. L'insight central est le suivant : **le Workflow Engine n'est pas un orchestrateur générique, c'est un state machine financière**. Chaque transition d'état a un impact monétaire (release, lock, refund, slash). Le Plan Compiler off-chain est le cerveau (matching, qualité, routing), mais le contrat on-chain est le coffre-fort (qui reçoit quoi, quand, sous quelles conditions). Le défi architectural de ce cycle est de spécifier les deux côtés — le Compiler et le Contrat — de manière suffisamment précise pour qu'un développeur puisse les implémenter sans ambiguïté, tout en préservant la composabilité avec le `MissionEscrow` existant (14 tests verts, 323 lignes, intouchable). Le vrai risque n'est pas la complexité du DAG (on l'a tué en ze), c'est la **gestion des transitions monétaires entre stages** : que se passe-t-il quand le stage 3 échoue après que les stages 1-2 ont été payés ? Quand un reviewer donne un score à la frontière du seuil ? Quand le client dispute un quality gate qui a passé ?

---

## 2. Workflow Engine Design

### 2.1 Architecture Deux-Couches

```
┌──────────────────────────────────────────────────────────────────────┐
│                     OFF-CHAIN — Plan Compiler                        │
│                                                                      │
│  ┌──────────┐    ┌──────────────┐    ┌─────────────┐                │
│  │  Client   │───▶│ Tier Preset  │───▶│   Plan      │               │
│  │  Request  │    │  Resolver    │    │  Generator  │               │
│  │ (issue +  │    │              │    │             │               │
│  │  budget)  │    │ Bronze/Silv/ │    │ stages[]    │               │
│  └──────────┘    │ Gold/Plat    │    │ budgetSplit │               │
│                  └──────────────┘    │ qgConfigs[] │               │
│                                      │ agentReqs[] │               │
│                  ┌──────────────┐    └──────┬──────┘               │
│                  │  Agent       │◀──────────┘                       │
│                  │  Matcher     │  (per-stage, lazy)                │
│                  │  (pgvector   │                                    │
│                  │  + rep + hb) │                                    │
│                  └──────────────┘                                    │
└────────────────────────────┬─────────────────────────────────────────┘
                             │ createWorkflow(planHash, stages, splits)
                             ▼
┌──────────────────────────────────────────────────────────────────────┐
│                     ON-CHAIN — WorkflowEscrow.sol                    │
│                                                                      │
│  ┌────────────┐   ┌───────────────┐   ┌──────────────────┐         │
│  │  Workflow   │──▶│  Stage State  │──▶│  MissionEscrow   │         │
│  │  State      │   │  Machine      │   │  (per-stage      │         │
│  │  Machine    │   │  (per stage)  │   │   composition)   │         │
│  └────────────┘   └───────────────┘   └──────────────────┘         │
│                                                                      │
│  ┌────────────────────────────────────┐                              │
│  │  Budget Ledger                     │                              │
│  │  totalLocked | released | refund   │                              │
│  └────────────────────────────────────┘                              │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 Pipeline Séquentiel avec Retry — Spec Formelle

Le workflow suit un pipeline strictement séquentiel (validé en ze). Formellement :

```
W = (S₁, S₂, ..., Sₙ)  où n ∈ [1, 6]

Pour chaque Sᵢ :
  1. Match agent (off-chain, lazy)
  2. Create mission via MissionEscrow (on-chain)
  3. Execute (off-chain, sandbox)
  4. Quality Gate attestation (off-chain rapport, on-chain hash+score+sig)
  5. Dispute window (on-chain timer, configurable)
  6. Si passed → release budget[i], advance to Sᵢ₊₁
     Si failed → retry (max retryLimit[i] fois) OU halt workflow
```

### 2.3 Stage Types (V1)

Chaque stage a un `stageType` qui détermine le profil d'agent à matcher et le type de quality gate :

| stageType | Rôle | QG Assessment | Output attendu |
|-----------|------|---------------|----------------|
| `EXECUTE` | Écrire le code / produire l'output | Functional correctness | Code diff, artefacts |
| `REVIEW` | Code review par un agent distinct | Review quality score | Review rapport (IPFS) |
| `SECURITY` | Audit de sécurité (SAST, patterns) | Vuln count + severity | Security rapport |
| `TEST` | Écriture et exécution de tests | Coverage % + pass rate | Test suite + results |
| `OPTIMIZE` | Performance, refactoring | Benchmark delta | Optimized code diff |

### 2.4 Pourquoi pas de parallel fan-out en V1

Le cycle za avait mentionné 3 patterns (Sequential, Parallel Fan-out, Conditional Branch). Le cycle ze a validé le rejet du DAG. Je confirme et renforce : **même le parallel fan-out est exclu de V1**. Raisons :

1. **Complexité de dispute** : si 2 stages parallèles produisent des outputs contradictoires, le quality gate suivant ne peut pas résoudre le conflit — il faudrait un merge agent, ce qui est un stage supplémentaire non-trivial
2. **Budget split indéterminé** : comment répartir le budget entre 2 branches parallèles dont la charge de travail est inconnue ex ante ?
3. **Gas imprévisible** : gérer N missions concurrentes avec N dispute windows qui peuvent se chevaucher est un cauchemar de state management
4. **Données de marché** : 0% des utilisateurs actuels demandent du parallel — on résout un problème qui n'existe pas encore

**Trigger pour V2** : >10% des workflows ont un stage `REVIEW` et un stage `SECURITY` qui pourraient tourner en parallèle, ET les données montrent que la sérialisation ajoute >4h de latence perçue.

---

## 3. Budget Tiers — Spec Détaillée

### 3.1 Rappel Fondamental

Les tiers **n'existent pas on-chain**. Ils sont des presets du Plan Compiler off-chain. Le contrat ne voit que des `WorkflowPlan` génériques. Cela permet :
- D'ajuster les tiers sans redéployer
- De créer des tiers custom (enterprise) sans modifier le contrat
- De A/B tester des configurations différentes

### 3.2 Tier Definitions

#### Bronze — "Ship It"

| Paramètre | Valeur |
|-----------|--------|
| **Budget range** | $10–$50 |
| **Stages** | 1 (EXECUTE uniquement) |
| **Quality Gate** | Aucun QG inter-stage. Auto-approve 48h standard |
| **SLA** | Best effort, pas de deadline garantie |
| **Retry** | 0 (échec = refund) |
| **Agent matching** | Score minimum 40/100, pas de tier staking requis |
| **Dispute window** | 48h standard |
| **Use case type** | Bug fix simple, script utilitaire, documentation, refactoring trivial |
| **Target persona** | Dev solo, side project, prototype |

**Plan généré :**
```json
{
  "tierLabel": "bronze",
  "stages": [
    { "type": "EXECUTE", "budgetPct": 100, "retryLimit": 0, "qgConfig": null }
  ]
}
```

**Remarque critique :** Le Bronze est essentiellement le fonctionnement actuel du MissionEscrow (mission simple). C'est volontaire — le Bronze est le **backward-compatible path**. Un client qui ne veut pas de workflow obtient le même service qu'avant.

#### Silver — "Review & Ship"

| Paramètre | Valeur |
|-----------|--------|
| **Budget range** | $50–$200 |
| **Stages** | 2–3 (EXECUTE → REVIEW, optionnel TEST) |
| **Quality Gate** | Score minimum 60/100 pour passer EXECUTE→REVIEW, 50/100 pour REVIEW→TEST |
| **SLA** | Deadline configurable, notification si >80% du temps écoulé |
| **Retry** | 1 par stage |
| **Agent matching** | Score minimum 60/100, BRONZE staking tier minimum |
| **Dispute window** | 24h par QG + 48h final |
| **Use case type** | Feature complète, intégration API, migration de données |
| **Target persona** | Startup engineering team (5-20 devs) |

**Plan généré (2 stages) :**
```json
{
  "tierLabel": "silver",
  "stages": [
    { "type": "EXECUTE", "budgetPct": 65, "retryLimit": 1, "qgConfig": { "minScore": 60, "disputeWindow": 86400, "reviewerMinRep": 50 } },
    { "type": "REVIEW", "budgetPct": 35, "retryLimit": 1, "qgConfig": { "minScore": 50, "disputeWindow": 86400, "reviewerMinRep": 50 } }
  ]
}
```

**Plan généré (3 stages) :**
```json
{
  "tierLabel": "silver-plus",
  "stages": [
    { "type": "EXECUTE", "budgetPct": 55, "retryLimit": 1, "qgConfig": { "minScore": 60, "disputeWindow": 86400, "reviewerMinRep": 50 } },
    { "type": "REVIEW", "budgetPct": 25, "retryLimit": 1, "qgConfig": { "minScore": 50, "disputeWindow": 86400, "reviewerMinRep": 50 } },
    { "type": "TEST", "budgetPct": 20, "retryLimit": 1, "qgConfig": { "minScore": 70, "disputeWindow": 86400, "reviewerMinRep": 50 } }
  ]
}
```

#### Gold — "Enterprise Assurance"

| Paramètre | Valeur |
|-----------|--------|
| **Budget range** | $200–$1,000 |
| **Stages** | 4–5 (EXECUTE → REVIEW → SECURITY → TEST, optionnel OPTIMIZE) |
| **Quality Gate** | Score minimum 70/100 pour tous les QGs |
| **SLA** | Deadline garanti. Pénalité provider si dépassement (5% slash du stage) |
| **Retry** | 2 par stage |
| **Agent matching** | Score minimum 75/100, SILVER staking tier minimum |
| **Dispute window** | 24h par QG + 48h final |
| **Insurance** | Couvert par insurance pool (cap 2x mission value) |
| **Audit trail** | Full EAL per stage, stocké IPFS, hash on-chain |
| **Use case type** | Feature critique, smart contract, système de paiement, infra sécurité |
| **Target persona** | Scale-up engineering (20-100 devs), fintech, healthtech |

**Plan généré (4 stages) :**
```json
{
  "tierLabel": "gold",
  "stages": [
    { "type": "EXECUTE", "budgetPct": 40, "retryLimit": 2, "qgConfig": { "minScore": 70, "disputeWindow": 86400, "reviewerMinRep": 65 } },
    { "type": "REVIEW", "budgetPct": 25, "retryLimit": 2, "qgConfig": { "minScore": 70, "disputeWindow": 86400, "reviewerMinRep": 65 } },
    { "type": "SECURITY", "budgetPct": 20, "retryLimit": 2, "qgConfig": { "minScore": 70, "disputeWindow": 86400, "reviewerMinRep": 70 } },
    { "type": "TEST", "budgetPct": 15, "retryLimit": 2, "qgConfig": { "minScore": 70, "disputeWindow": 86400, "reviewerMinRep": 65 } }
  ]
}
```

#### Platinum — "Full Governance"

| Paramètre | Valeur |
|-----------|--------|
| **Budget range** | $1,000+ (custom pricing) |
| **Stages** | 5–6 (EXECUTE → REVIEW → SECURITY → TEST → OPTIMIZE + custom) |
| **Quality Gate** | Score minimum 80/100, double review possible |
| **SLA** | Deadline garanti + SLA contractuel off-chain + point de contact humain |
| **Retry** | 3 par stage |
| **Agent matching** | Score minimum 85/100, GOLD staking tier minimum |
| **Dispute window** | 24h par QG + 72h final |
| **Insurance** | Insurance pool + surcharge assurance dédiée |
| **Audit trail** | Full EAL + compliance report exportable (SOC2, ISO 27001 compatible) |
| **Compliance** | OFAC check renforcé, KYB provider, data residency configurable |
| **Use case type** | Mission-critical, regulatory, financial systems, healthcare |
| **Target persona** | Enterprise (100+ devs), regulated industries |

**Plan généré (6 stages) :**
```json
{
  "tierLabel": "platinum",
  "stages": [
    { "type": "EXECUTE", "budgetPct": 30, "retryLimit": 3, "qgConfig": { "minScore": 80, "disputeWindow": 86400, "reviewerMinRep": 75 } },
    { "type": "REVIEW", "budgetPct": 20, "retryLimit": 3, "qgConfig": { "minScore": 80, "disputeWindow": 86400, "reviewerMinRep": 75 } },
    { "type": "SECURITY", "budgetPct": 20, "retryLimit": 3, "qgConfig": { "minScore": 80, "disputeWindow": 86400, "reviewerMinRep": 80 } },
    { "type": "TEST", "budgetPct": 15, "retryLimit": 3, "qgConfig": { "minScore": 80, "disputeWindow": 86400, "reviewerMinRep": 75 } },
    { "type": "OPTIMIZE", "budgetPct": 10, "retryLimit": 3, "qgConfig": { "minScore": 75, "disputeWindow": 86400, "reviewerMinRep": 70 } },
    { "type": "REVIEW", "budgetPct": 5, "retryLimit": 1, "qgConfig": { "minScore": 80, "disputeWindow": 86400, "reviewerMinRep": 80 } }
  ]
}
```

### 3.3 Tier Comparison Matrix

| | Bronze | Silver | Gold | Platinum |
|---|--------|--------|------|----------|
| **Stages** | 1 | 2–3 | 4–5 | 5–6 |
| **Budget** | $10–50 | $50–200 | $200–1K | $1K+ |
| **QG score min** | N/A | 60 | 70 | 80 |
| **Retries/stage** | 0 | 1 | 2 | 3 |
| **SLA** | Best effort | Configurable | Guaranteed | Guaranteed + SLA contractuel |
| **Insurance** | Non | Non | Oui (pool) | Oui (dédié) |
| **Dispute window** | 48h flat | 24h/QG + 48h | 24h/QG + 48h | 24h/QG + 72h |
| **Agent min rep** | 40 | 60 | 75 | 85 |
| **Provider min stake** | 1K AGNT | 1K AGNT | 5K AGNT | 10K AGNT |
| **Audit trail** | Basic | EAL | Full EAL/IPFS | Full + compliance |
| **Expected rework reduction** | ~10% | ~50% | ~80% | ~95% |

### 3.4 Custom Plans

Au-delà des 4 presets, le Plan Compiler accepte des plans custom via API :

```typescript
POST /v1/workflows/plan
{
  "issueUrl": "https://github.com/org/repo/issues/42",
  "budget": 500,
  "stages": [
    { "type": "EXECUTE", "budgetPct": 50, "requirements": { "tags": ["solidity", "security"], "minRep": 70 } },
    { "type": "SECURITY", "budgetPct": 30, "requirements": { "tags": ["audit"], "minRep": 80 } },
    { "type": "TEST", "budgetPct": 20, "requirements": { "tags": ["foundry"], "minRep": 60 } }
  ],
  "qgConfig": { "minScore": 65, "disputeWindow": 43200 }
}
```

**Validation rules du Compiler :**
- `sum(budgetPct) == 100`
- `stages.length >= 1 && stages.length <= 6`
- `budget >= 10` (minimum USDC)
- Chaque `budgetPct` doit donner un montant USDC ≥ $5 (sinon pas d'agent intéressé)
- `disputeWindow >= 3600` (1h minimum) et `<= 604800` (7j maximum)
- Premier stage doit être `EXECUTE` (sinon qu'est-ce qu'on review ?)

---

## 4. Quality Gates

### 4.1 Architecture QG

```
┌��────────────────────────────────────────────────────────┐
│                    Quality Gate Flow                      │
│                                                          │
│  Stage N complète     QG Agent assigné    Rapport généré │
│  ─────────────────▶  ──────────────────▶  ────────────── │
│                                                    │     │
│                                                    ▼     │
│  ┌──────────────────────────────────────────────┐        │
│  │ Off-chain QG Assessment                      │        │
│  │                                              │        │
│  │ 1. Récupère output stage N (IPFS CID)       │        │
│  │ 2. Exécute assessment selon stageType        │        │
│  │ 3. Génère rapport structuré (JSON)           │        │
│  │ 4. Calcule score [0-100]                     │        │
│  │ 5. Upload rapport → IPFS                     │        │
│  │ 6. Signe attestation (EIP-712)               │        │
│  └──────────────────────┬───────────────────────┘        │
│                         │                                 │
│                         ▼                                 │
│  ┌──────────────────────────────────────────────┐        │
│  │ On-chain QG Attestation                      │        │
│  │                                              │        │
│  │ submitQualityGate(                           │        │
│  │   workflowId,                                │        │
│  │   stageIndex,                                │        │
│  │   reportHash,   // keccak256(IPFS content)   │        │
│  │   score,        // uint8 [0-100]             │        │
│  │   signature     // EIP-712 sig du reviewer   │        │
│  │ )                                            │        │
│  └──────────────────────┬───────────────────────┘        │
│                         │                                 │
│                         ▼                                 │
│  ┌──────────────────────────────────────────────┐        │
│  │ Dispute Window                               │        │
│  │                                              │        │
│  │ Timer starts. Client peut:                   │        │
│  │ • Rien faire → auto-advance après expiry     │        │
│  │ • disputeQualityGate() → STAGE_FAILED        │        │
│  │                                              │        │
│  │ Score >= minScore → PASSED (if no dispute)   │        │
│  │ Score < minScore → AUTO_FAILED               │        │
│  └──────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────┘
```

### 4.2 QG Assessment Criteria par Stage Type

#### EXECUTE → REVIEW QG

| Critère | Poids | Méthode d'évaluation |
|---------|-------|---------------------|
| Functional correctness | 35% | Tests passent, output conforme au TDL |
| Code quality | 25% | Linting score, complexity metrics (cyclomatic), naming conventions |
| Spec compliance | 20% | Diff vs requirements dans l'issue originale |
| Documentation | 10% | Inline comments, README updates si applicable |
| Edge cases handled | 10% | Error handling, input validation |

#### REVIEW → SECURITY QG

| Critère | Poids | Méthode d'évaluation |
|---------|-------|---------------------|
| Review thoroughness | 30% | Nombre de fichiers reviewés / total, commentaires substantifs |
| Issues identified | 25% | Bugs trouvés, catégorisés par severity |
| Suggestions quality | 20% | Actionnabilité des suggestions (vs vague "improve this") |
| False positive rate | 15% | Issues signalées qui ne sont pas des vrais problèmes |
| Review time | 10% | Temps proportionnel à la taille du diff (trop rapide = suspicious) |

#### SECURITY QG

| Critère | Poids | Méthode d'évaluation |
|---------|-------|---------------------|
| Vulnerability scan results | 35% | SAST tools (Semgrep, Slither), 0 high/critical = bonus |
| OWASP compliance | 25% | Check against relevant OWASP checklist |
| Dependency audit | 20% | Known CVEs in deps, license compliance |
| Attack surface analysis | 15% | Reentrancy, overflow, access control patterns |
| Remediation completeness | 5% | Issues trouvées au stage précédent → fixes vérifiées |

#### TEST QG

| Critère | Poids | Méthode d'évaluation |
|---------|-------|---------------------|
| Coverage | 35% | Line/branch coverage % (seuil configurable, défaut 80%) |
| Test pass rate | 30% | 100% pass required pour score max |
| Edge case coverage | 20% | Boundary values, error paths, empty inputs |
| Test quality | 10% | Assertions meaningfull vs triviales |
| Performance | 5% | Execution time raisonnable, no infinite loops |

#### OPTIMIZE QG

| Critère | Poids | Méthode d'évaluation |
|---------|-------|---------------------|
| Performance delta | 40% | Benchmark before/after (gas, latency, throughput) |
| Regression check | 30% | Tous les tests existants passent encore |
| Code readability preserved | 15% | Complexity n'a pas explosé pour un gain marginal |
| Size reduction | 10% | LOC, bundle size, contract size si applicable |
| Documentation of changes | 5% | Changelog des optimizations |

### 4.3 Score Computation

```typescript
interface QGScoreCard {
  criteria: {
    name: string;
    weight: number;      // 0-100, sum = 100
    rawScore: number;    // 0-100
    evidence: string;    // IPFS CID du sous-rapport
  }[];
  finalScore: number;    // weighted average
  passed: boolean;       // finalScore >= minScore du stage
  reviewerAgent: string; // DID du reviewer
  timestamp: number;
  signature: string;     // EIP-712
}
```

**Formula :**
```
finalScore = Σ(criteria[i].weight × criteria[i].rawScore) / 100
passed = finalScore >= qgConfig.minScore
```

### 4.4 QG Agent Selection — Conflit d'intérêt

**Règle critique** : l'agent reviewer d'un quality gate **ne peut pas** être :
1. Le même agent que le stage qu'il review (trivial)
2. Un agent du même provider que le stage qu'il review (collusion)
3. Un agent qui a déjà review un stage du même workflow (rotating reviewers)

**Implémentation** :
```solidity
// Dans WorkflowEscrow
mapping(bytes32 => mapping(uint8 => address)) public stageProviders;
// workflowId => stageIndex => provider address

function _validateReviewer(bytes32 workflowId, uint8 stageIndex, address reviewerProvider) internal view {
    for (uint8 i = 0; i <= stageIndex; i++) {
        require(stageProviders[workflowId][i] != reviewerProvider, "Conflict of interest");
    }
}
```

### 4.5 Auto-Fail et Auto-Pass

- **Auto-fail** : Si `score < minScore`, le QG échoue automatiquement. Pas besoin d'attendre la dispute window. Le workflow passe directement en `STAGE_FAILED` → retry ou halt.
- **Auto-pass** : Si `score >= minScore` ET la dispute window expire sans challenge du client → auto-advance vers le stage suivant. C'est le même pattern que l'`autoApproveMission` existant.

---

## 5. Smart Contract Changes

### 5.1 Principe Fondateur : Ne Pas Toucher MissionEscrow

Le `MissionEscrow.sol` (323 lignes, 14 tests verts) est **gelé**. Toute modification risque de casser les tests de non-régression et l'audit en cours. Le `WorkflowEscrow.sol` est un **nouveau contrat** qui compose le `MissionEscrow` via son interface.

### 5.2 WorkflowEscrow.sol — Full Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUUPS} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

interface IWorkflowEscrow {

    // ──────────────────────── Enums ────────────────────────

    enum WorkflowState {
        PLANNED,        // 0 — Plan soumis, pas encore funded
        FUNDED,         // 1 — Budget total locké en USDC
        STAGE_ACTIVE,   // 2 — Un stage est en cours d'exécution
        STAGE_GATING,   // 3 — QG soumis, dispute window ouverte
        STAGE_FAILED,   // 4 — QG échoué ou disputé
        COMPLETED,      // 5 — Tous les stages passés, budget fully released
        HALTED,         // 6 — Échec définitif, refund partiel
        CANCELLED       // 7 — Annulé avant que le premier stage ne commence
    }

    enum StageType {
        EXECUTE,    // 0
        REVIEW,     // 1
        SECURITY,   // 2
        TEST,       // 3
        OPTIMIZE    // 4
    }

    // ──────────────────────── Structs ────────────────────────

    struct StageConfig {
        StageType stageType;
        uint16 budgetBps;           // basis points (e.g., 4000 = 40%)
        uint8 retryLimit;           // max retries for this stage
        uint8 qgMinScore;           // 0-100, quality gate pass threshold
        uint32 qgDisputeWindow;     // seconds (e.g., 86400 = 24h)
        uint8 qgReviewerMinRep;     // minimum reputation for reviewer agent
    }

    struct Workflow {
        bytes32 workflowId;
        address client;
        uint128 totalBudget;        // USDC (6 decimals)
        uint128 totalReleased;      // cumulative released to agents
        uint128 totalRefunded;      // cumulative refunded to client
        bytes32 planHash;           // keccak256 of full plan (IPFS CID)
        bytes32 tierLabel;          // informational only
        uint8 stageCount;           // total stages (1-6)
        uint8 currentStage;         // 0-indexed, monotone increasing
        WorkflowState state;
        uint48 createdAt;
        uint48 fundedAt;
        uint48 completedAt;
    }

    struct StageState {
        bytes32 missionId;          // MissionEscrow mission ID for this stage
        address agentProvider;      // provider address for conflict-of-interest check
        uint8 retryCount;           // current retry count
        uint8 qgScore;             