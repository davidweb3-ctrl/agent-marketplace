

# Cycle zg — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ Le budget détermine la topologie du workflow, pas juste le nombre d'agents

**Retenu.** C'est l'insight structurant du cycle. Le budget n'est pas un paramètre — il compile un plan d'exécution distinct. Un workflow à $20 et un workflow à $2000 ne sont pas le même produit avec plus de ressources ; ce sont des **produits architecturalement différents**.

**Justification :** Cela résout le problème de pricing le plus toxique des marketplaces — le client qui ne comprend pas pourquoi il paie plus. Ici, la différence est tangible : nombre de stages, présence ou absence de quality gates, profondeur de l'audit trail. Le tier n'est pas un label marketing, c'est un DAG différent.

**Guard-rail critique :** Ça ne veut PAS dire "plus de stages = mieux". Le Bronze (1 agent, 0 QG) peut être le bon choix pour 80% des issues. L'architecture doit rendre le Bronze aussi first-class que le Gold.

---

### 1.2 ✅ Plan Compiler off-chain avec commitment hash on-chain

**Retenu avec conditions strictes.** Le pattern compiled-plan est le bon :

```
Plan Compiler (off-chain) → planHash (on-chain) → WorkflowEscrow exécute les transitions
```

**Conditions de rétention :**

| Condition | Justification |
|---|---|
| **Compiler déterministe et open-source** | Tout participant peut recompiler avec les mêmes inputs et vérifier le hash. Ça neutralise la Faille #1 du Critic. |
| **Inputs du compiler publiés alongside le hash** | `TDL + budget + agent pool snapshot + tier` sont publiés on-chain ou sur IPFS. Le plan est reproducible. |
| **Pas d'optimisation opaque du matching** | Le matching scoring formula est publique. Pas de pay-to-play caché. |

**Ce que ça implique concrètement :**

```solidity
// On-chain : le minimum vital
struct WorkflowCommitment {
    bytes32 planHash;           // keccak256(full ExecutionPlan)
    bytes32 inputsHash;         // keccak256(TDL + budget + agentPool + tier)
    uint256 totalBudget;
    uint256[] stageBudgets;
    uint8 stageCount;
}
```

```
// Off-chain : publishable & reproducible
ExecutionPlan {
    inputs: { tdlCID, budget, tier, agentPoolSnapshot },
    stages: Stage[],
    qualityGates: QualityGate[],
    budgetSplits: uint256[],
    failurePolicy: FailurePolicy,
    compiledAt: timestamp,
    compilerVersion: semver
}
```

Quiconque peut appeler `PlanCompiler.compile(inputs)` et vérifier que `keccak256(output) == planHash`. Le compiler n'est pas trusté — il est **vérifié**.

---

### 1.3 ✅ WorkflowEscrow compose MissionEscrow, ne le remplace pas

**Retenu fermement.** Le `MissionEscrow.sol` (323 lignes, 14/14 tests) est le socle. `WorkflowEscrow` est un orchestrateur qui crée N missions séquentielles.

```
WorkflowEscrow.sol
├── createWorkflow(commitment, stageBudgets[])
│   └── Pour chaque stage : MissionEscrow.createMission(budget_i)
├── advanceStage(workflowId, deliverableHash, qgAttestation)
│   └── MissionEscrow.completeMission(mission_i) + createMission(mission_i+1)
├── failStage(workflowId, reason)
│   └── Branch conditionnelle selon failurePolicy du plan
└── cancelWorkflow(workflowId)
    └── Remboursement prorata des stages non-exécutés
```

**Invariant architectural :** `WorkflowEscrow` n'appelle JAMAIS `transfer()` directement. Tous les mouvements USDC passent par `MissionEscrow`. Un seul point de contrôle financier.

---

### 1.4 ✅ Quality Gates = attestations off-chain avec commitment on-chain

**Retenu.** Un smart contract ne peut pas juger de la qualité du code. Les QG sont des attestations signées.

```
Off-chain:
  ReviewerAgent exécute → produit Report { score, findings[], recommendation }
  Signe: signature = sign(keccak256(report), reviewerPrivateKey)

On-chain:
  QualityGateAttestation {
      reportHash: bytes32,
      score: uint8,           // 0-100
      pass: bool,             // score >= threshold du plan
      reviewer: address,
      signature: bytes
  }
```

**Guard-rails :**
- Le threshold est fixé dans le `ExecutionPlan` au moment de la compilation, pas au moment de l'évaluation
- Le reviewer ne peut PAS être le même agent que le coder du stage évalué (vérifiable on-chain : `require(reviewer != stageAgent)`)
- Le rapport complet est sur IPFS, seul le hash est on-chain
- En cas de dispute, le rapport complet est l'artefact d'arbitrage

---

### 1.5 ✅ Max 6 stages par workflow

**Retenu.** C'est un hard cap, pas une guideline.

```solidity
uint8 constant MAX_STAGES = 6;
require(commitment.stageCount <= MAX_STAGES, "ExcessiveComplexity");
```

**Justification empirique :** Au-delà de 6, la latence cumulée dépasse le seuil d'abandon client, le coût de coordination inter-agents dépasse les gains, et la surface de dispute explose combinatoirement.

**Mapping concret des tiers :**

| Tier | Stages | QG | Budget Range | Latency Target |
|---|---|---|---|---|
| Bronze | 1 | 0 | $5–$50 | < 30 min |
| Silver | 2–3 | 1 | $50–$300 | < 2h |
| Gold | 3–5 | 2–3 | $300–$2000 | < 8h |

---

## 2. Décisions Rejetées

### 2.1 ❌ "Plus d'agents = meilleure qualité" comme proposition de valeur

**Rejeté catégoriquement.** Le Critic a raison — c'est de la pensée magique. Brooks's Law s'applique aux agents IA comme aux humains. Le coût de transfert de contexte entre agents est réel et non résolu.

**Ce qu'on vend à la place :**

| Tier | Proposition de valeur réelle |
|---|---|
| Bronze | **Vitesse.** Un agent rapide, résultat best-effort, pour les issues triviales. |
| Silver | **Fiabilité.** Exécution + vérification. Le client sait que quelqu'un a relu. |
| Gold | **Traçabilité.** Chaîne de preuves complète. Chaque décision est justifiée, chaque artefact est signé. C'est de la compliance, pas de la qualité intrinsèque. |

**Conséquence sur le messaging :** On ne dit jamais "5 agents travaillent sur votre issue". On dit "votre livrable a été vérifié à 3 checkpoints indépendants". La valeur est dans la **réduction d'incertitude**, pas dans le nombre de bras.

---

### 2.2 ❌ WorkflowEscrow comme smart contract séparé de MissionEscrow

**Rejeté — mais nuancé.** La proposition initiale de faire du Workflow un `struct` dans MissionEscrow est elle aussi rejetée. Les deux extrêmes sont mauvais :

- **Workflow dans MissionEscrow :** Pollue le contrat simple et stable. Viole le Single Responsibility Principle.
- **Workflow totalement séparé :** Duplique la logique financière. Deux points de contrôle USDC = deux surfaces d'attaque.

**Décision retenue : Composition via interface.**

```
WorkflowEscrow.sol (nouveau contrat)
  │
  ├── Possède sa propre logique d'orchestration multi-stage
  ├── Appelle IMissionEscrow(missionEscrow).createMission() pour chaque stage
  ├── N'a JAMAIS de `IERC20.transfer()` direct
  └── Est le `client` du point de vue de MissionEscrow
```

MissionEscrow ne sait même pas qu'il est dans un workflow. Il voit juste un client (qui se trouve être un contrat) créer une mission, la fonder, la compléter. **Séparation des préoccupations parfaite.**

---

### 2.3 ❌ Arbitrage on-chain en V1

**Rejeté pour V1.** Trop de complexité, pas assez de volume pour justifier le coût d'intégration Kleros/UMA.

**V1 : Dispute = freeze + arbitrage admin multi-sig.**

```
Dispute flow V1:
  Client appelle disputeStage(workflowId, stageId)
  → Stage funds gelés
  → Off-chain: admin review (rapport QG + deliverables)
  → Admin multi-sig appelle resolveDispute(workflowId, stageId, resolution)
  → resolution ∈ { REFUND_CLIENT, PAY_AGENT, SPLIT }
```

**V2 :** Kleros/UMA quand volume > 100 disputes/mois. Le contrat est designed avec un `IArbitrator` interface pour que le swap soit non-breaking.

```solidity
interface IArbitrator {
    function requestArbitration(bytes32 disputeHash, bytes calldata evidence) external returns (uint256 disputeId);
    function ruling(uint256 disputeId) external view returns (Resolution);
}
```

---

### 2.4 ❌ Tier comme paramètre runtime modifiable

**Rejeté.** Le tier est frozen au moment du `createWorkflow`. Pas de upgrade/downgrade mid-execution.

**Pourquoi :** Un changement de tier mid-workflow invalide le plan compilé, les budget splits, les QG thresholds — tout. C'est un nouveau workflow. Le client peut `cancelWorkflow` (remboursement des stages non-exécutés) et recréer un workflow avec un tier différent.

---

## 3. Nouveaux Insights

### 3.1 🆕 Le Plan Compiler est un produit en soi, pas un composant interne

Insight majeur qui n'existait pas dans les cycles précédents. Le Plan Compiler déterministe et open-source crée un nouveau type d'avantage compétitif :

- **Forkabilité :** N'importe qui peut prendre le compiler, brancher son propre agent pool, et lancer un marketplace concurrent. C'est un feature, pas un bug — ça prouve la décentralisation.
- **Auditabilité :** Les clients enterprise peuvent auditer le compiler avant de s'engager. Le code est la spec.
- **Extensibilité :** Des tiers peuvent proposer des compiler plugins (nouvelles stratégies de splitting, nouveaux failure policies) via un système de modules.

**Conséquence architecturale :** Le Plan Compiler n'est pas dans le monolithe backend. C'est un **package isolé** avec sa propre CI, ses propres tests, et sa propre release cadence.

```
packages/
├── plan-compiler/         ← Publié en open-source
│   ├── src/
│   │   ├── compiler.ts
│   │   ├── tiers/
│   │   │   ├── bronze.ts
│   │   │   ├── silver.ts
│   │   │   └── gold.ts
│   │   ├── splitters/
│   │   │   └── budget-splitter.ts
│   │   ├── matchers/
│   │   │   └── agent-matcher.ts
│   │   └── validators/
│   │       └── plan-validator.ts
│   └── tests/
│       ├── determinism.test.ts    ← Même inputs → même hash. TOUJOURS.
│       ├── tier-invariants.test.ts
│       └── budget-conservation.test.ts ← sum(stageBudgets) == totalBudget
```

---

### 3.2 🆕 La failure policy est un paramètre de premier ordre du plan, pas un afterthought

Les cycles précédents ne traitaient que le happy path. Ce cycle révèle que la gestion de l'échec est un **différenciateur de tier** :

| Tier | Failure Policy |
|---|---|
| Bronze | `ABORT_REFUND` — le stage échoue, le client est remboursé, fin. |
| Silver | `RETRY_ONCE` — un nouvel agent est matché, le stage est re-exécuté une fois. Budget pour le retry pré-alloué dans le split. |
| Gold | `RETRY_WITH_ESCALATION` — retry avec un agent de score plus élevé. Si re-fail, escalade vers le client pour décision (continue/abort/dispute). |

**Conséquence on-chain :**

```solidity
enum FailurePolicy { ABORT_REFUND, RETRY_ONCE, RETRY_WITH_ESCALATION }

struct StageState {
    Status status;           // PENDING, ACTIVE, PASSED, FAILED, RETRYING
    address agent;
    address retryAgent;      // address(0) si pas de retry
    uint8 retryCount;
    uint8 maxRetries;        // Défini par le plan
}
```

Le contrat doit connaître la failure policy pour savoir combien de budget réserver pour les retries. C'est du **budget conditionnel** — alloué mais non committed jusqu'au trigger.

```solidity
struct StageBudget {
    uint256 primaryAmount;   // Payé à l'agent si succès
    uint256 retryReserve;    // Retenu pour retry potentiel. Si pas de retry → remboursé au client
}
// Invariant: sum(primaryAmount + retryReserve) == totalBudget - platformFee
```

---

### 3.3 🆕 L'audit trail comme produit du Gold tier, pas comme side-effect

Le Gold tier ne produit pas seulement un meilleur code. Il produit un **artefact de compliance** :

```json
{
  "workflowId": "0xabc...",
  "auditTrail": {
    "planCommitment": { "hash": "0x...", "inputsCID": "Qm..." },
    "stages": [
      {
        "stage": 0,
        "agent": "0x...",
        "deliverableCID": "Qm...",
        "qualityGate": {
          "reviewer": "0x...",
          "reportCID": "Qm...",
          "score": 87,
          "pass": true,
          "attestationTx": "0x..."
        },
        "completionTx": "0x...",
        "paymentTx": "0x..."
      }
    ],
    "totalCost": 750,
    "totalDuration": "4h32m",
    "chainOfCustody": ["planHash", "stage0Hash", "qg0Hash", "stage1Hash", "..."]
  }
}
```

**Cet artefact est valuable même si le code est identique.** Pour une entreprise qui doit prouver que son code AI-generated a été reviewé, testé, et validé par des processus traçables, c'est un document de conformité. C'est pourquoi le Gold tier justifie son prix — pas parce que le code est meilleur, mais parce que la **preuve que le processus est rigoureux** a une valeur en soi.

---

### 3.4 🆕 Le "agent pool snapshot" résout le problème de la vérifiabilité du matching

Pour que le Plan Compiler soit véritablement déterministe et vérifiable, il a besoin d'inputs déterministes. Le pool d'agents disponibles change en temps réel. Solution :

```
Au moment de la compilation :
1. Snapshot du pool d'agents éligibles (skills match + disponibilité + score)
2. Snapshot publié sur IPFS → agentPoolCID
3. Plan compilé avec ce snapshot comme input
4. inputsHash = keccak256(tdlCID, budget, tier, agentPoolCID)
```

Quiconque peut vérifier :
- "Ce plan a été compilé avec ce pool d'agents"
- "Cet agent a été sélectionné parce qu'il avait le meilleur score dans ce snapshot"
- "Le matching n'a pas été biaisé"

**Trade-off accepté :** Le snapshot a une TTL courte (5 min). Si un agent meilleur devient disponible 1 minute après la compilation, tant pis. La vérifiabilité vaut plus que l'optimalité.

---

## 4. PRD Changes Required

### 4.1 `MASTER.md` — Section "Workflow Engine"

**Action :** Réécrire entièrement. La section actuelle décrit un workflow comme une séquence de missions. Elle doit décrire le **Budget-Tiered Compiled Plan** model.

**Contenu requis :**
- Définition des 3 tiers avec failure policies
- Architecture Plan Compiler → planHash → WorkflowEscrow
- Diagramme de séquence pour chaque tier (Bronze/Silver/Gold)
- Budget conservation invariant : `sum(stageBudgets) + platformFee == totalBudget`

---

### 4.2 `MASTER.md` — Section "Smart Contracts"

**Action :** Ajouter `WorkflowEscrow.sol` comme nouveau contrat composant `MissionEscrow.sol`.

**Contenu requis :**
- Interface `IWorkflowEscrow`
- Struct `WorkflowCommitment`
- State machine du workflow : `CREATED → STAGE_N_ACTIVE → STAGE_N_REVIEW → ... → COMPLETED | ABORTED`
- Diagramme d'interaction WorkflowEscrow ↔ MissionEscrow

---

### 4.3 `MASTER.md` — Section "Quality Assurance"

**Action :** Créer cette section (n'existe pas). Documenter le système d'attestation QG.

**Contenu requis :**
- Format `QualityGateAttestation`
- Threshold management (défini dans le plan, appliqué on-chain)
- Dispute flow V1 (admin multi-sig) avec interface `IArbitrator` pour V2
- Matrice reviewer independence (reviewer ≠ coder, vérification on-chain)

---

### 4.4 `MASTER.md` — Section "Plan Compiler"

**Action :** Créer cette section. C'est un composant architecturalement distinct.

**Contenu requis :**
- Inputs/outputs du compiler
- Propriété de déterminisme (même inputs → même hash)
- Publication des inputs (IPFS CIDs)
- Vérification par tiers (n'importe qui peut recompiler)
- Test suite : determinism tests, budget conservation tests, tier invariant tests

---

### 4.5 `MASTER.md` — Nouvelle section "Messaging & Value Proposition by Tier"

**Action :** Créer. Documenter ce que chaque tier vend réellement.

```
Bronze: "Fast execution, best-effort, for straightforward tasks"
Silver: "Verified execution — your deliverable has been independently reviewed"
Gold:   "Auditable execution — full chain of custody, compliance-ready artifacts"
```

**Ne jamais dire :** "5 agents working on your issue" / "More agents, better results"

---

## 5. Implementation Priority

### Phase 1 : Foundation (Semaines 1–2)

```
Priority 1: Plan Compiler package
├── Tier definitions (Bronze/Silver/Gold)
├── Budget splitter (avec retry reserves)
├── Determinism test suite
├── Plan serialization + hashing
└── Milestone: compile(inputs) → ExecutionPlan, identical hash on re-run
```

**Justification :** Tout dépend du Plan Compiler. Pas de WorkflowEscrow sans plan à exécuter. Pas de matching sans contraintes compilées. C'est le critical path.

```
Priority 2: WorkflowEscrow.sol
├── WorkflowCommitment struct + storage
├── createWorkflow() avec planHash + stageBudgets[]
├── Stage state machine (PENDING → ACTIVE → PASSED/FAILED)
├── Composition avec MissionEscrow (createMission par stage)
├── Budget conservation invariant (tested)
└── Milestone: 14 existing tests green + 10 new workflow tests green
```

### Phase 2 : Quality Gates (Semaines 3–4)

```
Priority 3: Quality Gate attestation system
├── QualityGateAttestation struct on-chain
├── submitAttestation() avec signature verification
├── Threshold check against plan
├── Reviewer independence check (reviewer ≠ stageAgent)
└── Milestone: Full Silver tier workflow executable end-to-end

Priority 4: Failure policies
├── ABORT_REFUND implementation
├── RETRY_ONCE avec retry reserve management
├── RETRY_WITH_ESCALATION flow
└── Milestone: All 3 failure policies tested with edge cases
```

### Phase 3 : Verification & Audit (Semaines 5–6)

```
Priority 5: Plan verification system
├── IPFS publication of plan inputs
├── inputsHash on-chain
├── Verification endpoint (recompile + compare hash)
└── Milestone: Any external party can verify any plan

Priority 6: Audit trail generation
├── Gold tier audit artifact builder
├── Chain of custody construction
├── IPFS publication of full audit trail
└── Milestone: Gold tier workflow produces compliance-ready JSON artifact
```

### Phase 4 : Dispute Resolution V1 (Semaine 7)

```
Priority 7: Dispute system V1
├── disputeStage() → freeze funds
├── IArbitrator interface (implemented by AdminArbitrator for V1)
├── resolveDispute() via multi-sig
├── Resolution types: REFUND_CLIENT, PAY_AGENT, SPLIT
└── Milestone: Dispute can be raised, resolved, and funds distributed correctly
```

---

## 6. Next Cycle Focus

### Question centrale du cycle suivant :

> **Comment le Plan Compiler gère-t-il la sélection d'agents pour chaque stage quand le pool est dynamique, les compétences sont auto-déclarées, et la reputation est bootstrappée (cold start) ?**

C'est la question la plus critique non résolue. Le Plan Compiler est défini, le WorkflowEscrow est designé, mais le **matching engine** — le composant qui décide quel agent exécute quel stage — est une boîte noire.

**Sous-questions à traiter :**

| # | Question | Pourquoi c'est critique |
|---|---|---|
| 1 | **Comment les agents déclarent-ils leurs skills ?** | Skills auto-déclarés = spam. Skills prouvés = friction d'onboarding. Trade-off fondamental. |
| 2 | **Comment bootstrap la reputation ?** | Les premiers agents n'ont pas d'historique. Comment les matcher sans data ? Elo initial ? Stake-weighted trust ? Proof-of-skill challenges ? |
| 3 | **Le matching est-il push ou pull ?** | Push (le compiler assigne) vs Pull (les agents bid). Push est plus simple, pull est plus décentralisé. |
| 4 | **Comment éviter le monopole des top agents ?** | Si le matching est purement score-based, les meilleurs agents prennent tout. Long tail d'agents sous-utilisés. Faut-il un mécanisme de distribution ? |
| 5 | **Comment l'agent pool snapshot interagit avec le matching ?** | Le snapshot fige le pool, mais un agent peut devenir indisponible entre le snapshot et l'assignment. Race condition fondamentale. |
| 6 | **Quel est le format du skill taxonomy ?** | Freeform tags ? Enum ? Ontologie hiérarchique ? Ça détermine la précision du matching et la friction d'onboarding. |

---

## 7. Maturity Score

### Score : 6.5 / 10

| Dimension | Score | Justification |
|---|---|---|
| **Modèle conceptuel** | 8/10 | Le budget-as-topology insight est solide. Les tiers sont bien définis. La proposition de valeur par tier (vitesse/fiabilité/traçabilité) est crédible et différenciante. |
| **Architecture smart contracts** | 7/10 | WorkflowEscrow composant MissionEscrow est propre. La state machine est claire. Les invariants financiers sont identifiés. Il manque un prototype implémenté. |
| **Plan Compiler** | 6/10 | Le design est posé mais non implémenté. La propriété de déterminisme est déclarée mais non testée. Le format du plan est esquissé mais pas spécifié formellement. Le plan compiler est le composant le plus risqué — et il est en spec, pas en code. |
| **Quality Gates** | 5/10 | Le pattern attestation est correct mais la mécanique de reviewer assignment est floue. Comment on s'assure qu'un reviewer compétent est disponible pour un Silver tier ? Qui paie le reviewer s'il rejette ? Le modèle économique du reviewing est sous-spécifié. |
| **Matching Engine** | 3/10 | Quasi-inexistant. C'est le trou béant. Pas de skill taxonomy, pas de reputation model, pas de matching algorithm. Le Plan Compiler ne peut pas compiler un plan sans savoir quels agents sont éligibles et comment les scorer. |
| **Failure handling** | 6/10 | Les 3 failure policies sont définies conceptuellement. Les retry reserves sont un bon insight. Mais les edge cases ne sont pas explorés : que se passe-t-il si le retry agent échoue aussi ? Si le reviewer et l'agent disputent ? Si le client abandon mid-workflow ? |
| **Implémentation** | 4/10 | Zéro ligne de code pour le workflow layer. MissionEscrow est stable (14/14 tests) mais WorkflowEscrow est entièrement sur papier. Le Plan Compiler est un design doc. |

### Justification du 6.5 :

**Ce qui tire vers le haut :** L'insight fondamental est puissant et actionnable. L'architecture est cohérente de bout en bout — chaque composant a un rôle clair et des invariants identifiés. La décision de composition (WorkflowEscrow appelle MissionEscrow) est élégante et préserve la stabilité du code existant. La réponse au Critic (compiler open-source + vérifiable) est convaincante et transforme une faiblesse en force.

**Ce qui tire vers le bas :** Zéro implémentation du workflow layer. Le matching engine est un trou noir qui bloque le Plan Compiler, qui bloque le WorkflowEscrow, qui bloque tout. L'économie du reviewing (qui paie les reviewers, combien, que se passe-t-il si pas de reviewer disponible) est dangereusement sous-spécifiée. On ne peut pas builder tant que le matching n'est pas résolu.

**Pour atteindre 8/10 il faut :**
1. Un Plan Compiler fonctionnel avec determinism tests qui passent
2. Un matching engine minimal (même naïf — round-robin par skill tag)
3. WorkflowEscrow.sol déployé en testnet avec 20+ tests Foundry
4. Un Bronze tier workflow exécutable end-to-end (même avec un seul agent hardcodé)