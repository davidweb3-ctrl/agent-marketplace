

# Cycle zh — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ Le tier est une propriété de la mission, pas du client

**Validé et central.** C'est le positionnement produit différenciant. L'inversion **risque → tier → budget** (plutôt que budget → tier) est saine pour trois raisons :

1. **Alignement des incentives** — un fix de typo n'a pas besoin de 4 agents reviewers, quel que soit le portefeuille du client
2. **Pricing transparent** — le client comprend ce qu'il paie (niveau de vérification), pas juste "plus de compute"
3. **Réduction des disputes** — si le tier est calibré sur le risque réel, les attentes sont alignées avec le niveau de QA délivré

**Nuance architecturale retenue :** Le tier est *suggéré* par analyse sémantique du TDL, *confirmé* par le client, et *contraint* par le budget max que le client est prêt à mettre. Le smart contract ne voit que le tier final + budget alloué. La logique de suggestion vit off-chain dans le Plan Compiler.

```
TDL analysis (off-chain) → suggested_tier + rationale
Client confirms/overrides → final_tier
Budget check: client_budget >= tier_minimum_budget
  YES → proceed
  NO  → downgrade tier or reject
```

### 1.2 ✅ Staged Pipeline comme modèle de workflow (pas un DAG générique)

**Validé.** Un DAG engine générique est un piège d'over-engineering classique. Le pipeline à stages ordonnés avec quality gates couvre 95%+ des cas. Arguments décisifs :

- **Prédictibilité** — un pipeline linéaire est trivial à auditer, debugger, et disputer. Un DAG arbitraire non.
- **Gas cost** — les transitions on-chain sont O(n) en nombre de stages, pas O(E) en nombre d'edges d'un graphe
- **Cognitive load** — un client peut comprendre "Coder → Reviewer → Tester". Il ne peut pas comprendre un DAG à 12 nœuds.

**Guard-rail maintenu : max 6 stages.** Au-delà, la latence cumulée et le coût marginal d'un stage additionnel détruisent la valeur.

### 1.3 ✅ WorkflowEscrow compose avec MissionEscrow, ne le remplace pas

**Validé, c'est la bonne décision d'architecture.** Le pattern est clair :

```
WorkflowEscrow.sol (nouveau)
  └── pour chaque stage : appelle MissionEscrow.createMission()
  └── agit comme meta-client / orchestrateur on-chain
  └── gère les transitions inter-stages et le budget split

MissionEscrow.sol (inchangé, 323 lignes, 14/14 tests verts)
  └── reste l'unité atomique d'exécution + paiement
```

**Pourquoi c'est non-négociable :**
- Les 14 tests Foundry existants restent verts sans modification
- Chaque mission reste indépendamment disputable
- Un workflow peut être partiellement payé (stages 0-2 OK, stage 3 fail → paiement partiel automatique)
- Si `WorkflowEscrow` a un bug, `MissionEscrow` continue de fonctionner pour les missions standalone

### 1.4 ✅ Quality Gates = attestation off-chain + commitment on-chain

**Validé. C'est la seule architecture viable.** Les QG entièrement on-chain sont rejetés (voir §2.1), mais le pattern hybride est solide :

```solidity
struct QualityGateAttestation {
    bytes32 workflowId;
    uint8 stageIndex;
    bytes32 outputHash;      // hash du rapport de review complet (stocké off-chain)
    uint8 score;             // 0-100, seuil configurable par tier
    address attester;        // agent qui a produit la review
    bytes signature;         // signature de l'attester
    uint64 timestamp;
}
```

**Flux :**
1. Agent reviewer produit un rapport détaillé off-chain (stocké IPFS ou S3)
2. Hash + score + signature soumis on-chain via `advanceStage()`
3. Fenêtre de dispute ouverte (durée configurable par tier : Bronze 24h, Silver 48h, Gold 72h)
4. Si pas de dispute → auto-advance
5. Si dispute → escalade (V1: admin multisig, V2: Kleros/UMA)

### 1.5 ✅ Les 3 patterns de workflow : Sequential, Fan-out/Fan-in, Checkpoint

**Validé avec restriction.** Seul **Sequential** est implémenté en V1. Fan-out et Checkpoint sont documentés comme extensions V2.

| Pattern | V1 | V2 | Justification |
|---------|----|----|---------------|
| **Sequential** | ✅ | ✅ | Couvre 90% des cas, trivial on-chain |
| **Fan-out/Fan-in** | ❌ | ✅ | Nécessite un merge strategy on-chain — complexité excessive pour le launch |
| **Checkpoint** | ❌ | ✅ | Nécessite un state snapshot mechanism — dépend du feedback V1 |

---

## 2. Décisions Rejetées

### 2.1 ❌ Quality Gates entièrement on-chain

**Rejeté définitivement.** Trois arguments tueurs :

1. **Oracle problem non résolu** — Si l'agent reviewer push son propre pass/fail, il est juge et partie. Mettre la logique on-chain ne résout rien si l'input est compromis.
2. **Coût gas prohibitif** — Un rapport de code review fait 2-50KB. Stocker ça on-chain sur Base coûte entre $0.50 et $25 *par quality gate*. Sur un workflow Gold à 4 stages, ça peut représenter 5-10% du budget total rien qu'en gas.
3. **Subjectivité irréductible** — "Ce code est-il bien structuré ?" n'est pas une question qu'un smart contract peut trancher. Le on-chain ne doit gérer que le *commitment* (hash) et l'*économie* (paiement/dispute), pas le *jugement*.

### 2.2 ❌ Budget comme input primaire du Plan Compiler

**Rejeté au profit de l'inversion risque → tier → budget.**

L'approche "le client met $200, on optimise le workflow dans cette enveloppe" semble intuitive mais crée des problèmes :
- **Incentive pervers** — la plateforme est incitée à toujours suggérer le tier le plus cher
- **Signal faible** — $200 ne dit rien sur ce que le client *attend*. $200 pour un CRUD endpoint vs $200 pour un fix de reentrancy sont des missions fondamentalement différentes
- **Disputes garanties** — si le client met $200 et obtient un workflow Bronze (parce que c'est ce que $200 permet), mais attendait une qualité Gold, la dispute est inévitable

**Ce qui remplace :** Le Plan Compiler prend en input le TDL + le tier (risque), produit un workflow avec un budget *calculé*, et le client accepte ou négocie. Le budget est un *output* du planning, pas un *input*.

### 2.3 ❌ WorkflowEscrow comme smart contract modifiant MissionEscrow

**Rejeté.** Toute modification du `MissionEscrow.sol` existant est interdite. Les 14 tests sont la ligne de non-régression. Le pattern est strictement **composition**, pas héritage ni modification :

```
❌ WorkflowEscrow is MissionEscrow       // héritage = couplage
❌ Modifier MissionEscrow.createMission() // casse les tests
✅ WorkflowEscrow calls MissionEscrow     // composition = isolation
```

### 2.4 ❌ DAG engine générique comme workflow engine

**Rejeté.** Arguments :
- Over-engineering pour le use case actuel
- Complexité d'audit de sécurité disproportionnée
- Le client ne peut pas raisonner sur un DAG → disputes ingérables
- Aucun concurrent n'offre un DAG engine, le marché ne demande pas ça

Si un jour un cas nécessite un DAG, on peut le composer à partir de multiples workflows séquentiels avec des dépendances externes. Mais ça sera V3 au plus tôt.

---

## 3. Nouveaux Insights

### 3.1 🆕 Le tier comme proxy de risque est un moat produit

C'est genuinement nouveau. Les cycles précédents traitaient le tier comme une classification du client ou du budget. L'insight que **le tier classifie le risque de la tâche** a des conséquences profondes qu'aucun cycle précédent n'avait explorées :

- **Data flywheel** — chaque mission complétée enrichit le modèle de suggestion de tier. Après 1000 missions, le Plan Compiler sait que "migrate database schema" est typiquement Silver tandis que "update README" est Bronze.
- **Pricing dynamique futur** — le coût d'un tier peut évoluer en fonction du taux de disputes observé par catégorie de risque. Si les missions "smart contract" en tier Silver ont 15% de disputes, le système peut recommander Gold automatiquement.
- **Différenciation compétitive** — aucune plateforme (Devin, Factory, Codegen) ne frame le pricing comme un choix de *niveau de vérification*. Elles vendent des "agents plus intelligents" pour plus cher. Nous vendons "le bon process pour le bon risque".

### 3.2 🆕 Le workflow est un objet de premier ordre on-chain, mais léger

Le `WorkflowEscrow` ne stocke pas les détails du workflow on-chain. Il stocke :

```solidity
struct Workflow {
    bytes32 id;
    bytes32 planHash;         // hash du plan complet (stocké off-chain)
    uint8 tier;               // 0=Bronze, 1=Silver, 2=Gold
    uint8 totalStages;
    uint8 currentStage;
    uint256 totalBudget;
    uint256[] stageBudgets;   // budget alloué par stage
    bytes32[] missionIds;     // IDs des missions dans MissionEscrow
    WorkflowStatus status;    // Created, InProgress, Completed, Failed, Disputed
    uint64 createdAt;
    uint64 disputeWindowEnd;
}
```

**C'est ~320 bytes par workflow.** Pas de rapport de review, pas de code, pas de logs. Juste la structure, les transitions, et les références. Tout le reste vit off-chain avec des hashes comme ancrage.

### 3.3 🆕 La failure policy est tier-dépendante, pas stage-dépendante

Insight subtil mais important. Les cycles précédents associaient la failure policy au stage (ex: "si le Reviewer fail, rework"). En réalité, la politique doit être tier-dépendante :

| Tier | Failure Policy par défaut |
|------|--------------------------|
| **Bronze** | Stage fail → workflow fail → refund. Pas de retry (le coût du retry > la valeur de la mission) |
| **Silver** | Stage fail → 1 retry du même agent, puis agent substitution, puis fail |
| **Gold** | Stage fail → retry avec agent différent + diagnostic enrichi, puis escalade humaine, puis fail partiel avec paiement des stages réussis |

**Pourquoi c'est un insight :** En Bronze, le retry coûte potentiellement plus que la marge de la mission. Le système doit être assez intelligent pour *ne pas* retenter quand c'est économiquement absurde. En Gold, le client a payé pour de la résilience, donc le système doit épuiser toutes les options avant de fail.

### 3.4 🆕 Le Plan Compiler doit être déterministe ET reproductible

Pour que les disputes soient arbitrables, il faut pouvoir prouver que "étant donné ce TDL et ce tier, le workflow généré était celui-ci". Ça implique :

```
plan_hash = hash(TDL_hash + tier + compiler_version + timestamp)
```

Le Plan Compiler ne doit **pas** utiliser de LLM pour la génération de la *structure* du workflow (choix des stages, budget split, failure policies). La structure doit être déterministe : même TDL + même tier → même plan. Le LLM intervient uniquement pour :
- L'analyse sémantique du TDL (suggestion de tier)
- La décomposition de la tâche en sub-tasks (contenu des missions)
- La génération des prompts pour chaque agent

Mais le *skeleton* du workflow (combien de stages, quels rôles, quel budget split) est une table de lookup par tier, pas une génération LLM.

---

## 4. PRD Changes Required

### 4.1 MASTER.md — Section "Tier System"

**Action : Réécrire entièrement.**

Remplacer la section actuelle (qui frame les tiers comme des niveaux de service client) par :

```markdown
## Tier System — Risk-Based Execution Tiers

Les tiers classifient le **risque de la mission**, pas le profil du client.

### Tier Determination Flow
1. Analyse sémantique du TDL → suggested_tier + confidence_score
2. Client review → confirm / override
3. Budget check → tier_minimum ≤ client_budget
4. Plan Compiler → workflow topology déterministe

### Tier Definitions
| Tier | Risk Profile | Stages | Min Budget | Dispute Window | Failure Policy |
|------|-------------|--------|-----------|----------------|----------------|
| Bronze | Low risk, reversible, non-critical | 1-2 | $5 | 24h | Fail-fast, full refund |
| Silver | Medium risk, business logic, data handling | 2-4 | $50 | 48h | 1 retry + substitution |
| Gold | High risk, security, financial, irreversible | 3-6 | $200 | 72h | Multi-retry + escalation + partial payment |
```

### 4.2 MASTER.md — Nouvelle section "WorkflowEscrow Architecture"

**Action : Ajouter.**

```markdown
## WorkflowEscrow Architecture

WorkflowEscrow.sol compose avec MissionEscrow.sol (inchangé).

### Composition Pattern
- WorkflowEscrow crée N missions via MissionEscrow.createMission()
- WorkflowEscrow gère les transitions entre stages
- Chaque mission reste indépendamment disputable
- Paiement partiel automatique si workflow échoue après stage N > 0

### On-chain Footprint
- ~320 bytes par workflow
- Quality gate attestations = hash + score + signature
- Rapports complets stockés off-chain (IPFS/S3)
```

### 4.3 MASTER.md — Section "Plan Compiler"

**Action : Clarifier la frontière déterministe vs LLM.**

```markdown
## Plan Compiler

### Deterministic Layer (reproductible, auditable)
- Tier → workflow skeleton (stages, roles, budget split, failure policies)
- Lookup table, pas de LLM
- plan_hash = hash(TDL_hash + tier + compiler_version)

### AI Layer (best-effort, non-déterministe)
- TDL → tier suggestion (semantic analysis)
- TDL → sub-task decomposition (mission content)
- TDL → agent prompts
```

### 4.4 MASTER.md — Section "Quality Gates"

**Action : Réécrire pour refléter le pattern hybride.**

Supprimer toute mention de QG on-chain. Documenter le pattern attestation off-chain + commitment on-chain + fenêtre de dispute.

### 4.5 MASTER.md — Section "Failure Policies"

**Action : Créer cette section.** Elle n'existe pas dans le PRD actuel et c'est un manque critique. Les failure policies tier-dépendantes doivent être spécifiées explicitement, car elles impactent directement le contrat économique avec le client.

---

## 5. Implementation Priority

### Phase 1 — Fondations (Semaines 1-2)

```
Priority 1: WorkflowEscrow.sol (composition avec MissionEscrow)
├── createWorkflow(stages[], budgetSplit[], tier)
├── advanceStage(workflowId, attestation)
├── failStage(workflowId, reason)
├── getWorkflowStatus(workflowId)
└── Tests Foundry: 20+ tests ciblés
    ├── Création workflow Bronze/Silver/Gold
    ├── Avancement normal stage par stage
    ├── Failure + refund partiel
    ├── Timeout handling
    ├── Budget split accuracy (wei-level)
    └── Régression: les 14 tests MissionEscrow restent verts
```

**Critère de sortie Phase 1 :** `forge test` → 34+ tests verts (14 existants + 20 nouveaux). WorkflowEscrow peut créer un workflow 3 stages et le compléter ou le fail avec paiement partiel correct.

### Phase 2 — Quality Gates On-chain (Semaine 3)

```
Priority 2: QualityGateRegistry.sol
├── submitAttestation(workflowId, stageIndex, outputHash, score, signature)
├── challengeAttestation(workflowId, stageIndex, evidence)
├── resolveDispute(workflowId, stageIndex, resolution) // V1: admin only
└── Tests Foundry: 10+ tests
    ├── Attestation valide → stage advance
    ├── Attestation avec score < threshold → stage fail
    ├── Signature invalide → revert
    ├── Challenge dans la fenêtre → dispute ouverte
    ├── Challenge hors fenêtre → revert
    ��── Double attestation → revert
```

**Critère de sortie Phase 2 :** Un workflow Gold peut être exécuté end-to-end avec quality gates attestées et un dispute path fonctionnel (admin resolution).

### Phase 3 — Plan Compiler Off-chain (Semaine 4)

```
Priority 3: Plan Compiler (TypeScript/Rust)
├── Deterministic skeleton generator (tier → workflow template)
├── TDL semantic analyzer (tier suggestion)
├── Budget calculator (tier + stages → budget split)
├── Plan hash generator (reproductible)
└── Tests:
    ├── Same TDL + same tier → same skeleton (determinism)
    ├── Tier suggestion accuracy sur corpus de 100 TDLs
    ├── Budget split respects tier minimums
    └── Plan hash is verifiable on-chain
```

**Critère de sortie Phase 3 :** Le Plan Compiler peut prendre un TDL + tier et produire un plan dont le hash match celui stocké on-chain. Le skeleton est 100% déterministe.

### Phase 4 — Integration & Failure Policies (Semaine 5)

```
Priority 4: Failure Policy Engine
├── Bronze: fail-fast path
├── Silver: retry + substitution path
├── Gold: multi-retry + escalation path
├── Partial payment calculator
└── Integration tests end-to-end
    ├── Bronze workflow: create → execute → complete (happy path)
    ├── Silver workflow: create → fail stage 2 → retry → complete
    ├── Gold workflow: create → fail stage 3 → substitute agent → fail again → escalate → partial payment
    └── Budget accounting: sum(stage_payments) + platform_fee = total_escrowed (invariant)
```

**Critère de sortie Phase 4 :** Les 3 tiers fonctionnent end-to-end avec failure policies correctes et paiement partiel vérifié au wei près.

### Phase 5 — Tier Suggestion & UX (Semaine 6)

```
Priority 5: Tier suggestion UX
├── TDL input → tier suggestion avec confidence score
├── Override UX (client peut changer)
├── Budget constraint feedback ("Gold requires min $200, your budget is $150")
├── Workflow preview avant confirmation
└── User tests sur 20 issues GitHub réelles
```

---

## 6. Next Cycle Focus

### Question primaire du cycle zi :

> **Comment le Plan Compiler décompose-t-il un TDL en sub-tasks, et comment garantir que la décomposition est complète (pas de gaps) et non-redundante (pas de chevauchements) ?**

C'est le problème le plus difficile qui reste. Le skeleton du workflow est déterministe (lookup table par tier), mais le *contenu* de chaque stage (quelles sub-tasks l'agent Coder doit exécuter, quels critères le Reviewer doit vérifier) dépend d'une décomposition LLM qui peut être :

- **Incomplète** — le LLM oublie un edge case, le Coder ne le traite pas, le Reviewer ne le catch pas
- **Redondante** — deux stages font le même travail, gaspillant le budget
- **Ambiguë** — la frontière entre stage 1 et stage 2 est floue, créant des conflits

### Sous-questions à traiter :

1. **Quel format de sub-task est suffisamment structuré pour être vérifié (checklist ? spec formelle ? test cases ?) mais suffisamment flexible pour couvrir des domaines variés ?**
2. **Comment le Quality Gate du stage N vérifie-t-il que le stage N a traité toutes ses sub-tasks ? Checklist matching ? Test execution ?**
3. **Faut-il un "Planner Agent" dédié comme stage 0, ou le Plan Compiler est-il suffisant ?** (Si Planner Agent : qui review le plan du Planner ?)
4. **Comment gérer les dépendances entre sub-tasks qui traversent les stages ?** (ex: le Coder doit implémenter une interface que le Tester validera — le format de l'interface doit être spécifié *avant* le stage Coder)

---

## 7. Maturity Score

### Score : 7.0 / 10

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Modèle conceptuel** | 8.5/10 | L'inversion risque → tier → budget est solide et différenciante. Le pipeline à stages avec QG hybrides est le bon modèle. Pas de dette conceptuelle visible. |
| **Architecture on-chain** | 7.5/10 | Le pattern de composition WorkflowEscrow ↔ MissionEscrow est propre. Le QualityGateRegistry est bien défini. Manque encore : le mécanisme exact de partial payment quand un workflow fail à mi-chemin (comment recalculer les splits?), et le gas estimation pour un workflow Gold 6 stages sur Base. |
| **Architecture off-chain** | 6.0/10 | Le Plan Compiler a un bon design en deux couches (déterministe + AI), mais la couche AI (décomposition en sub-tasks) est une boîte noire. Aucun travail sur le format de sub-task, la complétude, la vérifiabilité. C'est le principal risque. |
| **Smart contract readiness** | 7.5/10 | MissionEscrow est solide (14/14 tests). WorkflowEscrow est spécifié mais pas implémenté. Le spec est suffisamment précis pour coder directement. |
| **Économie des tiers** | 6.5/10 | Les minimums par tier ($5/$50/$200) sont des placeholders. Pas de modélisation du coût réel d'un agent par stage (coût LLM, marge agent, overhead plateforme). Le pricing doit être backtesté sur des missions réelles. |
| **Dispute resolution** | 5.5/10 | V1 = admin multisig, ce qui est acceptable pour le launch mais fragile. Le path vers Kleros/UMA en V2 est esquissé mais pas designé. Le challenge d'une QG attestation n'a pas de process détaillé (quelles preuves ? quel format ? quel SLA de résolution ?). |
| **UX / Produit** | 6.5/10 | Le flow tier suggestion → confirmation → workflow preview est clair conceptuellement. Pas de maquettes, pas de user testing, pas de feedback loop défini. |

### Justification du 7.0 :

**On est prêt à builder la couche on-chain (Phase 1-2).** Le WorkflowEscrow et le QualityGateRegistry sont suffisamment spécifiés. Les risques sont identifiés et containés.

**On n'est PAS prêt à builder le Plan Compiler (Phase 3+) sans résoudre la décomposition en sub-tasks.** C'est le cycle zi qui doit débloquer ça.

**Le delta entre 7.0 et 9.0 est :**
- Résoudre la décomposition sub-tasks (cycle zi)
- Valider le pricing des tiers sur données réelles
- Designer le dispute resolution flow en détail
- Faire un gas benchmark sur Base pour un workflow Gold 6 stages
- Avoir les 34+ tests Foundry verts (Phase 1-2 complétées)

**Le 7.0 signifie : "architecture validée, specs suffisantes pour démarrer l'implémentation des smart contracts, mais des questions ouvertes critiques restent sur la couche off-chain et l'économie."**