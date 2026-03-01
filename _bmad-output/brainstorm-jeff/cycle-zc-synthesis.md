

# Cycle zc — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ Budget-Tiered Workflows comme proposition de valeur core

**Validé et renforcé.** Le reframing "assurance-as-a-service" est le meilleur angle de différenciation trouvé depuis le début des cycles. Le client achète un SLA de qualité, pas du compute. C'est défendable commercialement, c'est quantifiable, et ça crée un moat que ni Devin ni les agents open source ne peuvent répliquer facilement parce qu'ils n'ont pas le feedback loop on-chain pour prouver leurs taux de défaut historiques.

**Mais attention au piège narratif :** on ne peut promettre "probabilité de rework < 5%" qu'après avoir accumulé suffisamment de données pour calibrer le modèle. En V1, le tier est une **promesse structurelle** (nombre d'étapes de vérification), pas une **promesse statistique**. La promesse statistique vient en V2+ quand on a les données de taux de pass/fail par tier. Vendre un taux garanti sans data historique, c'est du fraud. Vendre un process structuré avec plus de checkpoints, c'est honnête et déjà valuable.

**Décision :** V1 = structural guarantee. V2 = statistical guarantee calibrée sur données réelles.

---

### 1.2 ✅ Pipeline Séquentiel Strict (V1)

**Validé sans réserve.** L'argument est maintenant triple :

1. **Simplicité d'implémentation** — une boucle `for` avec early exit, pas un DAG scheduler
2. **Simplicité de dispute** — le point de failure est toujours un stage précis identifiable par index
3. **Alignement avec le modèle de qualité** — chaque stage est un quality gate implicite ; le séquentiel force la vérification avant progression

Le parallélisme n'apporte rien pour les tailles de tâches V1 (single GitHub Issues, pas des epics). Un agent reviewer n'a pas besoin de tourner en parallèle d'un agent coder — il a besoin de l'output du coder.

---

### 1.3 ✅ Composition WorkflowEscrow → MissionEscrow (pas héritage)

**Validé.** C'est la décision architecturale la plus importante du cycle. Le pattern :

```
WorkflowEscrow.sol (new)
  └── calls MissionEscrow.createMission() per stage
  └── acts as "meta-client" address for all sub-missions
  └── holds the global budget, splits per stage
  └── advances stages by listening to MissionEscrow events
```

**Pourquoi composition > héritage ici :**

| Critère | Héritage | Composition |
|---|---|---|
| 14 tests existants cassés ? | Oui (changement d'interface) | Non |
| MissionEscrow deployable standalone ? | Non (couplé) | Oui |
| Upgrade indépendant ? | Non | Oui |
| Audit surface | Augmentée (un seul blob) | Isolée (deux contrats distincts) |
| Gas create | Un seul deploy plus gros | Deux deploys, mais MissionEscrow déjà deployé |

**Risque identifié :** `WorkflowEscrow` est le `msg.sender` des sub-missions, ce qui signifie que le client original n'a pas de relation directe avec `MissionEscrow`. Il faut un mapping `missionId → workflowId → clientAddress` pour que les disputes remontent correctement. Ce mapping doit être dans `WorkflowEscrow`, pas dans `MissionEscrow` (qui reste agnostique).

---

### 1.4 ✅ Quality Gates = Attestation off-chain + Commitment on-chain

**Validé, et c'est probablement la décision technique la plus saine du cycle.** Le pattern exact :

```
┌─────────────────────────────────────────────────────┐
│  OFF-CHAIN                                          │
│  1. Agent reviewer exécute le review                │
│  2. Produit: rapport JSON + score (0-100)           │
│  3. Stocke rapport sur IPFS → CID                   │
│  4. Signe: sign(keccak256(workflowId, stageIndex,   │
│            CID, score, timestamp), agentPrivKey)     │
├─────────────────────────────────────────────────────┤
│  ON-CHAIN                                           │
│  5. submitAttestation(workflowId, stageIndex,       │
│     ipfsCid, score, timestamp, signature)           │
│  6. Verify signature → agent registered for stage   │
│  7. IF score >= stage.qualityThreshold → advance    │
│  8. IF score < threshold → stage FAILED             │
│  9. Emit QualityGateResult event                    │
└─────────────────────────────────────────────────────┘
```

**Pourquoi c'est sain :**
- Le jugement qualitatif reste off-chain où il a sa place
- Le commitment on-chain est vérifiable et non-répudiable
- Le client peut vérifier le rapport IPFS et disputer si l'attestation est frauduleuse
- Le coût gas est minimal (~60k gas pour un `submitAttestation`)

**Risque résiduel — l'oracle problem n'est pas résolu, il est déplacé.** Si l'agent reviewer est corrompu ou incompétent, le score est garbage. Ce risque est mitigé en V1 par la réputation (agents avec track record), et en V2 par un dispute mechanism (Kleros/UMA). En V1, le client a un recours simple : ne pas valider la dernière étape manuellement (voir 1.5).

---

### 1.5 ✅ Max 6 stages par workflow

**Validé.** Le guard-rail est à la fois une contrainte technique (boucle bornée pour gas estimation) et une contrainte produit (au-delà de 6, les temps d'exécution deviennent imprévisibles pour des Issues unitaires). Les templates concrets :

| Tier | Stages | Coût typique | SLA structurel |
|---|---|---|---|
| **Bronze** | 1 | $20-80 | Execute only. Pas de review. Le client review lui-même. Fast & cheap. |
| **Silver** | 3 | $80-250 | Execute → Review → Fix. Un pass de QA. Le standard. |
| **Gold** | 5 | $250-800 | Execute → Review → Fix → Security Audit → Final QA. Deux passes de QA + security. |
| **Platinum** | 6 | $800-2000 | Execute → Review → Fix → Security → Optimization → Final QA. Full pipeline. Pour du code critique. |

**Insight important :** Bronze n'est pas "le tier cheap" — c'est le tier "je sais ce que je veux, j'ai mes propres reviews, donnez-moi juste l'exécution". Certains clients Enterprise achèteront Bronze pour du boilerplate et Gold pour du business logic. Le tier n'est pas un ranking de prestige, c'est un paramètre de pipeline.

---

### 1.6 ✅ Modèle de données Stage avec budgetBps

**Validé avec un ajustement.** L'allocation en basis points (sur 10000) est propre et flexible. Mais le split ne doit pas être libre — chaque template a un split par défaut que le client peut ajuster dans une fourchette.

```
Silver default split:
  Execute:  5500 bps (55%) — le gros du travail
  Review:   2500 bps (25%) — reviewer senior
  Fix:      2000 bps (20%) — corrections
  
Contrainte: aucun stage < 1000 bps (10%)
Raison: en dessous de 10%, le paiement ne motive pas un agent compétent
```

**L'ajustement :** `budgetUsdc` ne doit PAS être un champ dérivé calculé off-chain. Il doit être calculé on-chain dans `createWorkflow()` pour éviter les discrepancies :

```solidity
stage.budgetUsdc = (workflow.totalBudget * stage.budgetBps) / 10000;
```

Avec un require que la somme des `budgetUsdc` == `totalBudget` (attention aux arrondis — le dernier stage absorbe le dust).

---

## 2. Décisions Rejetées

### 2.1 ❌ Taux de défaut garanti en V1

**Rejeté.** Comme expliqué en 1.1, promettre "< 5% de rework" sans data historique est irresponsable. En V1, on promet le **process**, pas l'**outcome**. Le marketing doit dire "pipeline de 5 étapes avec double QA et audit security" et non "95% satisfaction garantie".

**Pourquoi c'est important :** un smart contract qui encode un SLA statistique (genre "si taux de rework > 5%, refund automatique") nécessite un oracle qui mesure le rework. Qui définit le rework ? Le client qui ouvre une nouvelle Issue pour corriger ? C'est gameable dans les deux sens. On n'a pas la mécanique pour ça en V1.

---

### 2.2 ❌ Custom stage topology (client définit ses propres stages)

**Rejeté pour V1.** Laisser le client définir `[REVIEW, EXECUTE, REVIEW, REVIEW]` c'est un footgun. Les templates sont prédéfinis et curated. Le client choisit un tier, ajuste éventuellement le budget split, point.

**Raison supplémentaire :** les agents doivent savoir à quoi s'attendre. Un agent reviewer qui s'inscrit pour le stage 2 d'un workflow Silver sait que c'est un code review après exécution. Si le stage ordering est arbitraire, le matching agent ↔ stage devient chaotique.

**V2 ouverture :** Custom pipelines pour clients Enterprise avec track record, dans un mode "advanced" gated par la réputation du client.

---

### 2.3 ❌ WorkflowEscrow comme contrat upgradeable (proxy pattern)

**Rejeté pour V1.** Le cycle n'en parle pas explicitement mais c'est un choix implicite à rendre explicite. V1 deploy en direct, pas de proxy. Raisons :

1. La surface d'attaque d'un proxy (storage collision, delegatecall bugs) ne se justifie pas pour un contrat V1 avec un périmètre limité
2. Si on doit upgrader, on deploy un V2 et on migre les nouveaux workflows. Les anciens se terminent sur V1. C'est le pattern "immutable + migration" qui est plus simple à auditer.
3. Les fonds en escrow dans un contrat immutable inspirent plus confiance qu'un contrat dont l'admin peut changer la logique

---

### 2.4 ❌ Stage FAILED → Conditional branch automatique

**Rejeté.** Le cycle mentionne `failStage(workflowId, reason) → conditional branch` dans l'interface. Non. En V1, stage FAILED = **workflow ABORTED + refund proportionnel des stages non exécutés**. Pas de retry automatique, pas de rerouting vers un autre agent.

**Pourquoi :** le conditional branching on failure transforme le séquentiel en DAG de facto. Si un review fail, on reassigne ? On skip ? On demande au même agent de corriger ? Chaque branche est une décision produit complexe. En V1, le client reçoit un refund partiel et peut re-soumettre un nouveau workflow. Simple, prédictible, auditable.

**Mécanisme de refund :**
```
Stages complétés et payés : 0 refund (travail livré)
Stage en cours (FAILED) : refund 100% du budget de ce stage
Stages futurs (PENDING) : refund 100%
```

---

### 2.5 ❌ Platinum tier en V1

**Rejeté.** Bronze, Silver, Gold pour le launch. Platinum (6 stages avec optimisation) est un tier premium qui nécessite des agents spécialisés en performance optimization — un pool qu'on n'aura pas au launch. Mieux vaut 3 tiers bien exécutés que 4 tiers dont un est sous-staffé.

**Réintroduction :** Quand le pool d'agents security + optimization atteint 20+ agents actifs avec un score moyen > 80.

---

## 3. Nouveaux Insights

### 3.1 🆕 Le tier est un paramètre de risque, pas un ranking de prestige

C'est le shift mental le plus important du cycle. Le client ne "monte en gamme" pas pour le prestige — il achète un profil de risque. Un CTO peut légitimement utiliser Bronze pour des tâches de documentation et Gold pour du smart contract code, dans le même projet. Le tier est **par-issue**, pas **par-client**.

**Implication produit :** le UI ne doit PAS présenter les tiers comme "Basic / Standard / Premium" avec des couleurs de plus en plus dorées. Il doit les présenter comme un slider "verification depth" avec des chiffres concrets : nombre d'étapes, types de vérification, temps estimé.

---

### 3.2 🆕 WorkflowEscrow comme meta-client ouvre le multi-agent coordination sans modifier MissionEscrow

C'est un insight architectural non-trivial. `MissionEscrow` ne sait rien des workflows. Il voit juste des missions avec un `client` qui est en réalité `WorkflowEscrow`. Cela signifie que :

- **L'orchestration est entièrement dans WorkflowEscrow** — MissionEscrow reste simple et auditable
- **On peut avoir d'autres orchestrateurs** — un `BountyEscrow`, un `HackathonEscrow` qui utilisent le même `MissionEscrow` comme couche de paiement
- **Le pattern est fractal** — un workflow pourrait théoriquement créer un sub-workflow comme stage (pas en V1, mais l'architecture ne l'empêche pas)

**Risque à adresser :** Le `MissionEscrow` a probablement des checks sur `msg.sender == client` pour les appels comme `approveMission()` ou `disputeMission()`. Si `WorkflowEscrow` est le client, ces appels doivent être exposés via des fonctions relay dans `WorkflowEscrow` qui vérifient que l'appelant est le vrai client humain. Pattern :

```solidity
// WorkflowEscrow.sol
function approveStage(bytes32 workflowId, uint8 stageIndex) external {
    require(msg.sender == workflows[workflowId].clientAddress, "Not client");
    bytes32 missionId = workflows[workflowId].stages[stageIndex].missionId;
    missionEscrow.approveMission(missionId); // WorkflowEscrow is msg.sender = client in MissionEscrow
    _advanceToNextStage(workflowId);
}
```

---

### 3.3 🆕 Le quality threshold par stage crée un tuning knob continu

Pas juste pass/fail — le `qualityThreshold: uint8 (0-100)` permet au système (et potentiellement au client en V2) de calibrer la sévérité. Un Gold workflow pourrait avoir :

```
Stage 1 (Execute):  threshold = 60 (juste fonctionnel)
Stage 2 (Review):   threshold = 80 (bon niveau)  
Stage 3 (Fix):      threshold = 70 (corrections appliquées)
Stage 4 (Security): threshold = 90 (strict)
Stage 5 (Final QA): threshold = 85 (high bar)
```

Ce n'est PAS configurable par le client en V1 (trop de footguns). Les templates définissent les thresholds. Mais le fait que la donnée soit on-chain permet une calibration itérative : si on observe que les workflows Silver avec threshold 70 au review ont un taux de satisfaction client de 90%, on peut tightener à 75 pour le template Silver v2.

**C'est le début du flywheel data :** exécution → attestation scores → calibration thresholds → meilleure qualité → plus de clients → plus de data.

---

### 3.4 🆕 Le scoring on-chain est un primitif de réputation composable

Les `attestationScore` stockés on-chain pour chaque stage de chaque workflow créent un **graphe de qualité public et non-falsifiable**. Un agent qui a 50 attestations avec une médiane de 88 a une réputation quantifiable. Aucune plateforme centralisée ne peut offrir ça avec le même niveau de trustlessness.

**Implication V2+ :** Ce graphe devient un moat. Les agents investissent dans leur track record on-chain. Plus ils ont d'historique, plus ils sont attractifs. Ils ne peuvent pas migrer cet historique vers un concurrent. C'est du lock-in positif : l'agent reste non pas parce qu'il est piégé, mais parce que sa valeur accumulée est là.

---

### 3.5 🆕 Le dernier stage de tout workflow Gold+ doit nécessiter une validation client explicite

Insight de game theory : si tous les stages sont auto-avancés par attestation d'agents, un ring d'agents colluants peut faire passer un workflow entier sans que le client voie l'output. Le fix est simple mais crucial :

```
Dernier stage de Silver/Gold/Platinum:
  state = DELIVERED → attend CLIENT_APPROVAL (pas auto-advance)
  timeout: 72h → auto-approve (pour protéger l'agent)
```

Bronze : auto-approve après exécution (le client a choisi le tier "je gère moi-même").

Ce n'est pas un manque de confiance dans le système — c'est un **circuit breaker** qui empêche les runaway pipelines. Le client reste le decision maker final.

---

## 4. PRD Changes Required

### 4.1 Nouvelles sections à ajouter dans MASTER.md

| Section | Contenu | Priorité |
|---|---|---|
| `## Workflow Engine` | Architecture WorkflowEscrow, composition pattern, state machine workflow + stage | P0 — Core |
| `## Budget Tiers` | Templates Bronze/Silver/Gold, budget splits par défaut, constraints | P0 — Core |
| `## Quality Gate Protocol` | Attestation flow (off-chain + on-chain), signature scheme, threshold system | P0 — Core |
| `## Refund Mechanics` | Stage failure → proportional refund, calcul exact, edge cases | P0 — Core |
| `## Stage Types` | EXECUTE, REVIEW, SECURITY_AUDIT, TEST — définition précise de chaque type, inputs/outputs attendus | P1 — Important |

### 4.2 Sections existantes à modifier

| Section | Modification | Raison |
|---|---|---|
| `## Smart Contracts` | Ajouter `WorkflowEscrow.sol` aux contracts à implémenter, clarifier la relation avec `MissionEscrow.sol` | Nouveau contrat core |
| `## Payment Flow` | Update pour refléter le budget split par stage et les paiements séquentiels | Le flow n'est plus single-payment |
| `## Agent Matching` | Ajouter la dimension "stage type matching" — un agent s'inscrit pour des types de stages, pas juste des missions | Le matching change fondamentalement |
| `## Dispute Resolution` | Update pour disputes intra-workflow (attestation challenges) vs disputes de mission simple | Nouveau vecteur de dispute |
| `## Pricing` | Remplacer le pricing flat par le modèle tiered avec platform fee par tier | Monetization redesign |

### 4.3 Sections à supprimer ou déprioriser

| Section | Action | Raison |
|---|---|---|
| Tout ce qui mentionne des workflows parallèles ou DAG | Supprimer ou marquer V2+ | V1 = séquentiel strict |
| Taux de défaut garanti / SLA statistique | Déplacer vers V2+ roadmap | Pas de data pour calibrer |

---

## 5. Implementation Priority

### Phase 1 : Foundation (Semaine 1-2)

```
1. WorkflowEscrow.sol — Squelette
   ├── createWorkflow() avec template selection
   ├── fundWorkflow() — USDC deposit avec budget split
   ├── State machine Workflow + Stage
   ├── Budget split calculation on-chain
   └── Tests: 8-10 tests Foundry (creation, funding, state transitions)
   
2. MissionEscrow.sol — Adaptation minimale
   ├── Vérifier que createMission() accepte un contrat comme client
   ├── Ajouter event enrichi pour que WorkflowEscrow puisse écouter
   └── Tests: les 14 existants doivent rester verts + 2-3 tests d'intégration
```

**Gate:** Les deux contrats compilent, les tests passent, un workflow Bronze end-to-end fonctionne (1 stage = 1 mission).

### Phase 2 : Multi-Stage Orchestration (Semaine 3-4)

```
3. Stage advancement logic
   ├── advanceStage() — appelé quand un stage est PASSED
   ├── submitAttestation() — signature verification + threshold check
   ├── failWorkflow() — refund proportionnel
   └── Tests: 10-12 tests (Silver 3 stages, Gold 5 stages, fail at stage 2, fail at stage 4, etc.)

4. Client approval gate (dernier stage)
   ├── approveWorkflow() — client approuve le dernier stage
   ├── Auto-approve timeout (72h)
   └── Tests: 4-5 tests (approve, timeout, reject)
```

**Gate:** Un workflow Silver (3 stages) s'exécute end-to-end avec attestations et client approval.

### Phase 3 : Template Engine & Agent Matching (Semaine 5-6)

```
5. Template registry (peut être off-chain en V1)
   ├── Bronze/Silver/Gold templates avec stages prédéfinis
   ├── Budget split defaults et ranges autorisés
   ├── Quality thresholds par stage type
   └── API endpoint: GET /templates/{tier}

6. Agent matching par stage type
   ├── Agent registration: "je fais REVIEW et SECURITY_AUDIT"
   ├── Stage assignment: matching agent ↔ stage type
   └── Tests: matching scenarios
```

**Gate:** La plateforme peut onboarder un client qui choisit un tier, les agents appropriés sont assignés aux stages, le workflow s'exécute.

### Phase 4 : Integration & Hardening (Semaine 7-8)

```
7. Event indexing (The Graph ou Ponder)
   ├── WorkflowCreated, StageAdvanced, WorkflowCompleted
   ├── AttestationSubmitted, WorkflowFailed
   └── Dashboard data pour le client

8. Edge cases & security
   ├── Reentrancy sur advanceStage() + refund
   ├── Dust handling dans budget split
   ├── Timeout handling (globalDeadline)
   ├── Agent qui ne livre jamais → timeout → refund
   └── Audit interne du code
```

**Gate:** Production-ready pour un beta limité avec 5-10 clients.

---

## 6. Next Cycle Focus

### Question principale du Cycle zd :

> **Comment le matching agent ↔ stage fonctionne concrètement, et quel est le mécanisme d'incentive pour que les agents reviewers soient honnêtes ?**

C'est la question la plus critique pour deux raisons :

**1. Le matching est le goulot d'étranglement.** Un workflow Gold a 5 stages. Si le stage 3 (security audit) n'a pas d'agent disponible, le workflow entier est bloqué. Le matching doit gérer la rareté par stage type, pas par mission. Faut-il un auction par stage ? Un pool d'agents pré-qualifiés par type ? Un fallback vers un agent généraliste si le spécialiste n'est pas dispo ?

**2. L'honnêteté des reviewers est le talon d'Achille de tout le système.** L'attestation off-chain + commitment on-chain est nécessaire mais pas suffisant. Un agent reviewer qui donne systématiquement 90/100 sans vraiment reviewer est indétectable par le smart contract. Le seul signal est le taux de disputes client post-workflow. Quels incentives mécaniques (slashing, bonding, reputation stakes) pour forcer l'honnêteté ? Et comment les designer sans tuer la participation (trop de risque → les bons agents partent) ?

**Sous-questions du cycle zd :**
- Agent bonding par stage type — un agent stake du USDC pour prouver sa compétence dans un type de stage ? Montant ? Slashing conditions ?
- Review-of-review — sur Platinum, le stage 5 (Final QA) review implicitement le travail du stage 4 (Security). Peut-on formaliser ça comme un check sur le reviewer ?
- Timeout economics — si un agent ne livre pas dans le timeout, il perd son bond ? Ou juste sa place ? Quel est le coût optimal du timeout pour l'agent vs le client ?

---

## 7. Maturity Score

### **6.5 / 10**

| Dimension | Score | Justification |
|---|---|---|
| **Vision & Positioning** | 9/10 | Le reframing "assurance-as-a-service" avec tiers de risque est clair, différenciant, et commercialement viable. Le meilleur framing depuis le début. |
| **Architecture Contracts** | 7/10 | Composition WorkflowEscrow → MissionEscrow est saine. Le modèle de données est propre. Le relay pattern pour les appels client est identifié. Il manque le détail du refund math et les edge cases de reentrancy. |
| **Quality Gate Design** | 6/10 | L'attestation off-chain + commitment on-chain est la bonne approche. Mais le mécanisme anti-collusion est absent (identifié, pas résolu). Le threshold tuning est prometteur mais non validé empiriquement. |
| **Economic Model** | 5/10 | Les budget splits sont esquissés mais pas modélisés. Quelle est la platform fee par tier ? Est-ce que le split default est viable pour les agents (un agent reviewer qui reçoit 25% de $150 = $37.50 pour un code review, c'est assez ?) ? Le P&L par tier n'est pas fait. |
| **Agent Matching** | 4/10 | Identifié comme critique mais non designé. C'est le plus gros trou. Sans matching fiable par stage type, le workflow engine est un moteur sans roues. |
| **Implementation Readiness** | 7/10 | Le plan en 4 phases est réaliste. Les gates sont claires. Le fait d'avoir MissionEscrow avec 14 tests verts comme base est un vrai avantage. On peut commencer Phase 1 maintenant. |
| **Risk Mitigation** | 5/10 | Refund proportionnel est bien pensé. Mais : pas de slashing, pas de bonding, pas de dispute mechanism concret (juste "V2: Kleros"). Un agent malveillant en V1 n'a aucune conséquence financière au-delà de la réputation. |

**Synthèse :** On a une architecture solide et une proposition de valeur claire. On peut commencer à builder le WorkflowEscrow. Ce qui empêche le 8/10 : le matching et les incentives agents (cycle zd), et le modèle économique détaillé (P&L par tier, viabilité des paiements par stage). On est prêt à coder le contrat mais pas encore prêt à onboarder des agents — il faut d'abord résoudre la question "pourquoi un bon agent reviewer accepterait ce job à ce prix avec ce niveau de risque".