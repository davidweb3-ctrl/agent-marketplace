

# Cycle zb — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ WorkflowEscrow comme Client Proxy, MissionEscrow intouché

**Verdict : Validé fermement. C'est la décision architecturale la plus importante du cycle.**

Le `WorkflowEscrow` agit comme un client proxy qui crée N sub-missions dans `MissionEscrow`. Le `MissionEscrow` (323 lignes, 14/14 tests) ne sait pas qu'il participe à un workflow. Cette séparation est exactement le bon niveau d'abstraction pour trois raisons :

1. **Composabilité préservée** — Un agent qui accepte un stage dans un workflow a exactement le même flow (accept → deliver → payout/dispute) qu'un agent solo. Pas de code spécifique workflow côté agent.
2. **Surface d'attaque minimale** — Le contrat audité et testé n'est pas modifié. Le risque de régression est zéro.
3. **Upgrade path propre** — On peut itérer sur `WorkflowEscrow` (ajouter des patterns, modifier les quality gates) sans toucher à la primitive de paiement.

**Nuance critique à ne pas perdre :** Le `WorkflowEscrow` doit détenir les USDC en custody totale, puis les transférer au `MissionEscrow` stage par stage via `createMission()`. Le client n'approuve qu'une seule transaction USDC → `WorkflowEscrow`. Le workflow gère le drip. C'est un point d'implémentation non trivial : le `WorkflowEscrow` a besoin d'un `approve` vers `MissionEscrow` à chaque stage, ce qui implique soit un approve infini (risque), soit un approve exact par stage (plus de gas, plus sûr). **Décision : approve exact par stage.** Le gas supplémentaire est négligeable vs le risque d'un approve infini sur un contrat nouvellement déployé.

### 1.2 ✅ Pipeline Contraint (pas de DAG générique)

**Verdict : Validé. Les trois patterns suffisent.**

Le choix de limiter à Sequential / Parallel Fan-out / Conditional Branch couvre >99% des cas réels sur des GitHub Issues. Un DAG arbitraire introduirait :

- Une complexité de gas O(n²) pour la résolution de dépendances on-chain
- Des cas de deadlock impossibles à résoudre sans intervention humaine
- Un surface de griefing massive (un agent bloque un nœud du DAG, tout le workflow est stuck)

**Insight additionnel :** En pratique, le pattern 1 (Sequential) représente ~95% des cas V1. Les patterns 2 et 3 devraient être **spécifiés maintenant mais implémentés en V1.5**. V1 = sequential only. Ce n'est pas du scope creep avoidance — c'est que le parallel fan-out nécessite un mécanisme de join on-chain (attente de N résultats) dont le design de dispute est non trivial.

### 1.3 ✅ Contraintes hard-codées (Max 6 stages, Min $5/stage)

**Verdict : Validé avec ajustement.**

| Contrainte | Valeur proposée | Valeur retenue | Justification |
|-----------|----------------|----------------|---------------|
| Max stages | 6 | **6** | Correct. Au-delà, la latence tue la valeur. Un workflow de 7+ stages signifie que l'issue est mal découpée. |
| Max parallel branches | 3 | **2 (V1.5)** | 3 branches parallèles = 3 disputes potentielles simultanées. 2 suffit pour le cas "dual review". |
| Max retries | 2 | **1 (V1), 2 (V2)** | Un seul retry en V1. Après 1 fail → abort + refund proportionnel. Le retry automatique est un luxe qui nécessite un agent pool fiable. |
| Max duration | `deadline × 1.5` | **`deadline + buffer_per_stage`** | Le multiplicateur est naïf. Un workflow de 2 stages et un workflow de 6 stages ne méritent pas le même buffer. Formule : `deadline_global + (N_stages × 4h)`. |
| Min budget/stage | $5 | **$5** | Correct. En dessous, aucun agent rationnel ne s'engage. Le gas + opportunity cost dépassent le payout. |

**Ajout critique manquant :** il faut un **min budget total par workflow** = $25. Un workflow de 5 stages à $5 chacun est techniquement valide mais économiquement absurde (le gas d'orchestration dépasse la marge).

### 1.4 ✅ Quality Gates = Attestation off-chain + Commitment on-chain

**Verdict : Validé. C'est le bon compromis.**

Le rejet des quality gates entièrement on-chain est correct pour les raisons citées. Le modèle retenu :

```
┌─────────────────────────────────────────────────────┐
│                    OFF-CHAIN                         │
│  Agent Reviewer exécute le QG                       │
│  → Produit: rapport JSON + score 0-100              │
│  → Signe: EIP-712 signature du (hash_rapport, score)│
│  → Stocke: rapport complet sur IPFS/Arweave         │
└──────────────────┬──────────────────────────────────┘
                   │ submitQualityGate(workflowId, stageId,
                   │   reportHash, score, ipfsCid, signature)
┌──────────────────▼──────────────────────────────────┐
│                    ON-CHAIN                          │
│  WorkflowEscrow vérifie:                            │
│  1. signature valide (ecrecover → reviewer autorisé)│
│  2. score >= stage.qualityThreshold                 │
│  3. stage est dans le bon état (PENDING_QG)         │
│  → Si pass: advance to next stage                   │
│  → Si fail: conditional branch ou abort             │
│  → Client a 48h pour challenger l'attestation       │
└─────────────────────────────────────────────────────┘
```

**Point de tension identifié :** Qui est le reviewer ? Si c'est un agent du marketplace, il faut un mécanisme anti-collusion. Si c'est le client, on retombe dans l'asymétrie classique (client peut bloquer en ne validant jamais). **Décision retenue :** V1 = le client fait office de quality gate (simple approve/reject avec timeout auto-approve à 48h). V2 = reviewer agent tiers avec staking anti-collusion.

### 1.5 ✅ `budgetBps` pour la répartition inter-stages

**Verdict : Validé.** Utiliser des basis points (sur 10000) pour le split du budget est propre. Ça évite les erreurs d'arrondi et c'est un pattern standard en DeFi. Le contrat doit vérifier que `sum(budgetBps) == 10000` à la création du workflow.

---

## 2. Décisions Rejetées

### 2.1 ❌ Parallel Fan-out en V1

**Rejeté pour V1. Reporté à V1.5.**

Le fan-out parallèle (pattern 2) introduit un problème de **join synchronization** on-chain non résolu :

- **Scénario problématique :** Stage 2a complète et passe le QG. Stage 2b échoue et part en dispute. Le workflow est bloqué au join. L'agent 2a a fait son travail et mérite son paiement, mais le workflow ne peut pas avancer. Qui paie la latence de dispute ?
- **Complexité de dispute :** Dans un pipeline séquentiel, la dispute est toujours entre 2 parties (client/workflow vs agent du stage). En parallèle, on peut avoir N disputes simultanées avec des interdépendances.
- **Gas :** Le join nécessite de vérifier N conditions en une transaction, avec des edge cases (que faire si un branch timeout mais pas l'autre ?).

**Ce qui est nécessaire avant de l'implémenter :**
1. Un mécanisme de "partial completion" du workflow (certains branches terminés, d'autres non)
2. Un refund model qui gère le cas "50% du fan-out a réussi"
3. Des tests de fuzzing sur les combinaisons d'états

### 2.2 ❌ Conditional Branch automatique on-chain (V1)

**Rejeté pour V1. Simplifié.**

Le pattern 3 (if QG fail → hotfix stage) nécessite une logique de branching on-chain qui augmente la surface d'attaque du contrat. En V1 :

- **Si QG fail :** le workflow s'arrête. Le client récupère le budget non consommé. Il peut créer un nouveau workflow.
- **Pas de retry automatique.** Le retry implique de trouver un nouvel agent (ou le même) et de relancer un stage — c'est un workflow de recrutement à part entière.

**Ce qui remplace :** Le client a une option `abort_and_refund_remaining()` qui calcule le pro-rata des stages complétés et rembourse le reste.

### 2.3 ❌ `roleHash` comme primitive on-chain

**Rejeté. Déplacé off-chain.**

Stocker `keccak256("coder")`, `keccak256("reviewer")` on-chain n'ajoute aucune valeur :

- Le contrat n'a aucune logique qui utilise le rôle (il ne sait pas ce qu'est un "coder")
- Le matching agent ↔ rôle est fait par le backend/indexer
- Le gas de stockage est gaspillé

**Ce qui remplace :** Le `roleHash` existe dans le workflow template off-chain (stocké IPFS, référencé par CID on-chain dans le struct Workflow). Le contrat ne stocke que `stageId`, `budgetBps`, `qualityThreshold`, `dependsOn`, et l'adresse de l'agent assigné.

### 2.4 ❌ `parallelGroupId` en V1

**Rejeté.** Conséquence directe du rejet 2.1. Le champ n'existe pas dans le struct V1.

### 2.5 ❌ `qualityThreshold` comme score numérique on-chain

**Partiellement rejeté.**

Un score numérique 0-100 on-chain pose des problèmes :

- **Fausse précision :** Quelle est la différence entre un score de 72 et 74 ? Le reviewer ne peut pas calibrer avec cette granularité.
- **Gaming :** Le reviewer ajuste le score pour être juste au-dessus/en-dessous du threshold selon ses incentives.

**Ce qui remplace :** V1 utilise un système binaire : `PASS / FAIL` attesté par le quality gate. Le score numérique existe off-chain dans le rapport pour le contexte, mais on-chain c'est un bool. Ça simplifie massivement le contrat et rend le chemin de dispute plus clair ("la revieweuse a attesté PASS alors que le code ne compile pas" est actionnable ; "la revieweuse a mis 68 au lieu de 72" ne l'est pas).

---

## 3. Nouveaux Insights

### 3.1 🆕 Le WorkflowEscrow a un problème de liquidité par design

**Insight non couvert dans les cycles précédents.**

Le client dépose la totalité du budget upfront dans `WorkflowEscrow`. Le workflow crée les stages séquentiellement. Cela signifie :

- Stage 1 reçoit son budget, l'agent le complète, est payé.
- Stage 2 reçoit son budget... mais entre-temps, le reste du budget ($X) est **locked idle** dans `WorkflowEscrow`.

Pour un workflow de $1000 sur 5 stages qui dure 2 semaines, ~$600-800 sont locked sans produire de rendement pendant la majorité du temps. À l'échelle de la plateforme, c'est du capital inefficient.

**Implication V1 :** On accepte l'inefficience. Le capital est locked, point.

**Implication V2+ :** Intégration avec un yield protocol (Aave, etc.) pour que le budget non encore alloué à un stage génère du yield. Le yield va au client ou à la plateforme. Ce n'est **pas** du scope V1 mais ça doit être **architecturellement possible** — d'où l'importance que le `WorkflowEscrow` détienne les USDC directement (et pas via un vault intermédiaire qui rendrait l'intégration yield impossible).

### 3.2 🆕 Le timeout auto-approve comme mécanisme anti-griefing du client

Le client est le quality gate en V1. S'il ne valide jamais, l'agent est stuck. Le timeout de 48h avec auto-approve résout ça, mais crée un nouveau vecteur :

- **Attack :** Un client malveillant soumet une issue, un agent fait le stage 1 (40% du budget), le client ne valide rien pendant 48h (auto-approve), mais conteste le stage 2 via dispute. Le client a obtenu le travail du stage 1 "gratuitement" en termes de friction, et bloque le stage 2 en dispute pour récupérer les 60% restants.

**Mitigation :** L'auto-approve du stage N déclenche le paiement du stage N **et** l'engagement du budget du stage N+1 dans `MissionEscrow`. Le client perd le droit de récupérer le budget du stage N+1 une fois le stage N est auto-approved. Cela crée une escalation d'engagement : plus le workflow avance, plus le client a de skin-in-the-game.

### 3.3 🆕 Le struct `WorkflowStage` on-chain doit être minimal

Après les rejets de `roleHash`, `parallelGroupId`, et du score numérique, le struct V1 on-chain se réduit à :

```solidity
struct WorkflowStage {
    uint256 budgetBps;          // part du budget total (basis points)
    address assignedAgent;      // address(0) = pas encore assigné
    uint48 deadline;            // timestamp deadline pour ce stage
    StageStatus status;         // PENDING | ACTIVE | QG_PENDING | PASSED | FAILED | DISPUTED
}

struct Workflow {
    address client;
    uint256 totalBudget;        // USDC total déposé
    uint256 currentStageIndex;  // index du stage actif
    bytes32 specCid;            // IPFS CID du workflow spec complet (roles, descriptions, etc.)
    uint48 globalDeadline;      // timestamp max pour tout le workflow
    WorkflowStatus status;      // CREATED | ACTIVE | COMPLETED | ABORTED | DISPUTED
    WorkflowStage[] stages;     // array ordonné (V1: séquentiel)
}
```

C'est ~5 slots de storage pour le Workflow + ~3 slots par stage. Un workflow de 4 stages = ~17 slots = ~340k gas pour la création. Acceptable.

### 3.4 🆕 Le problème de l'assignation d'agent par stage

**Nouveau problème non adressé :** Qui assigne les agents à chaque stage ?

Options :
1. **Client pré-assigne** tous les agents à la création → Irréaliste. Le client ne connaît pas les agents.
2. **Agents bid sur le workflow complet** → Un seul agent fait tout. Pas multi-agent.
3. **Agents bid stage par stage, dynamiquement** → Le workflow avance, le stage N+1 est ouvert au bidding quand le stage N est PASSED.

**Décision : Option 3.** C'est la seule qui est compatible avec un marketplace. Implication : quand un stage passe le QG, le stage suivant entre dans un état `OPEN` et les agents peuvent `bid()`. Le premier agent accepté par le workflow (auto-match ou client-match) déclenche la création de la sub-mission dans `MissionEscrow`.

**Risque identifié :** Latence inter-stage. Entre le moment où le stage N est PASS et le moment où un agent bid et est assigné au stage N+1, il peut s'écouler des heures/jours. La deadline globale doit absorber ce délai.

**Mitigation :** Le workflow spec peut inclure des "preferred agents" par stage (off-chain). Le backend notifie ces agents en priorité. Si pas de bid en X heures, le stage devient ouvert au pool général.

### 3.5 🆕 Abort & Refund : le calcul pro-rata n'est pas trivial

Quand un workflow avorte (QG fail, timeout, dispute), le client récupère le budget non consommé. Mais "non consommé" n'est pas simple :

- Stages complétés et payés → irréversible (l'agent a été payé via `MissionEscrow.release()`)
- Stage actif (agent en cours de travail) → en dispute ou en cours dans `MissionEscrow`. Le `WorkflowEscrow` ne peut pas récupérer ces fonds tant que la sub-mission n'est pas résolue.
- Stages futurs (pas encore commencés) → récup��rables immédiatement car jamais envoyés à `MissionEscrow`.

**Formule de refund :**
```
refund = totalBudget - sum(budget_stages_completed) - budget_stage_active_in_escrow
```

Le `budget_stage_active_in_escrow` est récupéré quand/si la dispute se résout en faveur du client. Le `WorkflowEscrow` doit tracker deux valeurs : `budgetSpent` (payé aux agents) et `budgetLocked` (dans une sub-mission active). Le refund instantané = `totalBudget - budgetSpent - budgetLocked`.

---

## 4. PRD Changes Required

### 4.1 Section "Smart Contract Architecture" — Mise à jour majeure

**Ajouter :** L'architecture à 2 contrats avec séparation des responsabilités :

```
MissionEscrow.sol (EXISTANT - NE PAS MODIFIER)
├── createMission()
├── acceptMission()
├── deliverMission()
├── approveMission() / disputeMission()
└── 14/14 tests, 323 lignes, primitive de paiement

WorkflowEscrow.sol (NOUVEAU)
├── createWorkflow(stages[], specCid)     // client dépose USDC
├── bidStage(workflowId, stageIndex)      // agent bid sur un stage
├── assignAgent(workflowId, stageIndex, agent) // workflow assigne
├── submitQualityGate(workflowId, stageIndex, passed, reportHash, sig)
├── abortWorkflow(workflowId)             // client abort → refund pro-rata
├── advanceStage(workflowId)              // internal: crée sub-mission dans MissionEscrow
└── claimStagePayment(workflowId, stageIndex) // agent claim quand sub-mission resolved
```

### 4.2 Section "Quality Gates" — Nouvelle section

**Ajouter :**

- V1 : Quality Gate = Client approve/reject avec auto-approve timeout (48h)
- Mécanisme : client appelle `submitQualityGate(workflowId, stageIndex, true/false, reportHash, "")` — pas de signature tierce en V1
- Si le client ne répond pas en 48h → auto-approve → stage avance
- Si le client rejette → workflow avorte → refund pro-rata (stages futurs uniquement)
- V2 : Quality Gate = Reviewer agent tiers avec signature EIP-712 et dispute via arbitrage

### 4.3 Section "Budget Tiers" — Mise à jour

**Modifier :** Intégrer les contraintes hard-codées comme des paramètres du contrat :

```solidity
uint256 public constant MAX_STAGES = 6;
uint256 public constant MIN_BUDGET_PER_STAGE = 5e6; // 5 USDC
uint256 public constant MIN_TOTAL_BUDGET = 25e6;     // 25 USDC
uint48 public constant QG_TIMEOUT = 48 hours;
uint48 public constant STAGE_BUFFER = 4 hours;
```

### 4.4 Section "Agent Assignment" — Nouvelle section

**Ajouter :**

- Modèle d'assignation dynamique par stage (option 3)
- Flow : Stage PASSED → Next Stage OPEN → Agents bid → Client/Auto assign → Sub-mission created
- Preferred agents (off-chain hint, pas de garantie on-chain)
- Latence inter-stage absorbée par `STAGE_BUFFER` dans le deadline global

### 4.5 Section "Abort & Refund" — Nouvelle section

**Ajouter :**

- Trois catégories de budget : `spent` (irreversible), `locked` (dans sub-mission active), `available` (récupérable)
- Refund instantané = `totalBudget - budgetSpent - budgetLocked`
- `budgetLocked` récupéré post-résolution de dispute
- Seul le client peut déclencher `abortWorkflow()` (V1)
- Abort déclenche la cancellation de toute sub-mission active dans `MissionEscrow` (si possible — dépend de l'état de la mission)

### 4.6 Section "Dispute Resolution" — Mise à jour

**Ajouter :**

- V1 : Dispute = le client a rejeté un stage ET l'agent conteste → freeze du workflow. Résolution manuelle (admin multisig en V1, Kleros en V2).
- Une dispute sur un stage N ne bloque PAS le refund des stages N+2, N+3, etc. (jamais créés dans MissionEscrow → immédiatement récupérables).
- Le stage N+1 est bloqué si N est en dispute (dependency).

---

## 5. Implementation Priority

### Phase 1 : WorkflowEscrow Core (Semaine 1-2)

**Objectif :** Workflow séquentiel basique, fonctionnel.

| Tâche | Priorité | Estimation | Dépendance |
|-------|----------|------------|------------|
| `WorkflowEscrow.sol` — struct Workflow + WorkflowStage | P0 | 2j | Aucune |
| `createWorkflow()` — validation, dépôt USDC, init stages | P0 | 2j | Structs |
| `advanceStage()` — crée sub-mission dans MissionEscrow | P0 | 3j | createWorkflow |
| `submitQualityGate()` — client pass/fail, timeout auto-approve | P0 | 2j | advanceStage |
| `abortWorkflow()` — refund pro-rata | P0 | 2j | advanceStage |
| Tests Foundry : 20+ tests couvrant happy path + edge cases | P0 | 3j | Toutes les fonctions |

**Critère de succès :** Un workflow de 3 stages séquentiels peut être créé, chaque stage assigné à un agent différent, quality gates passées, et paiement distribué correctement. 20/20 tests verts.

### Phase 2 : Agent Bidding & Assignment (Semaine 3)

| Tâche | Priorité | Estimation | Dépendance |
|-------|----------|------------|------------|
| `bidStage()` — agent bid sur un stage OPEN | P0 | 1j | Phase 1 |
| `assignAgent()` — client ou auto-assign | P0 | 1j | bidStage |
| Intégration avec MissionEscrow.createMission() au moment de l'assignation | P0 | 2j | assignAgent |
| Event emission pour indexing (The Graph) | P1 | 1j | Phase 1 |
| Tests : bid conflict, reassignment, deadline expiry | P0 | 2j | Tout |

### Phase 3 : Dispute & Edge Cases (Semaine 4)

| Tâche | Priorité | Estimation | Dépendance |
|-------|----------|------------|------------|
| Gestion dispute propagée (stage dispute → workflow freeze) | P0 | 2j | Phase 2 |
| Abort pendant un stage actif (interaction avec MissionEscrow) | P0 | 2j | Phase 2 |
| Timeout handling (global deadline, stage deadline, QG timeout) | P0 | 2j | Phase 2 |
| Fuzz testing (Foundry invariant tests) | P1 | 3j | Tout |
| Gas optimization | P2 | 2j | Tout |

### Phase 4 : Off-chain Infrastructure (Semaine 5-6)

| Tâche | Priorité | Estimation | Dépendance |
|-------|----------|------------|------------|
| Workflow template IPFS storage + CID verification | P1 | 2j | Phase 1 |
| Backend : stage completion → notify next stage agents | P0 | 3j | Phase 2 |
| Subgraph (The Graph) pour workflow state tracking | P1 | 3j | Phase 3 |
| Frontend : workflow creation wizard | P1 | 4j | Subgraph |
| Frontend : workflow progress dashboard | P1 | 3j | Subgraph |

---

## 6. Next Cycle Focus

### La question la plus importante du cycle zc :

> **Comment le système sélectionne-t-il l'agent optimal pour chaque stage d'un workflow, étant donné que les stages ont des rôles différents (coder, reviewer, security auditor) et que la sélection doit être à la fois rapide (minimiser la latence inter-stage) et fiable (minimiser le risque de fail) ?**

Ce problème se décompose en :

1. **Agent Reputation Model** — Comment mesurer la compétence d'un agent sur un rôle spécifique ? Historique de missions complétées, taux de dispute, score moyen des QG... Quels metrics, comment les pondérer, où les stocker (on-chain vs off-chain) ?

2. **Matching Algorithm** — Quand un stage s'ouvre, le système doit-il :
   - Attendre les bids et laisser le client choisir (marketplace classique, lent)
   - Auto-assigner le "meilleur" agent disponible (rapide mais centralisé)
   - Utiliser un mécanisme d'enchères (premier bid au prix demandé gagne)
   - Permettre des "agent pools" pré-qualifiés par rôle

3. **Cold Start** — Au lancement, aucun agent n'a de réputation. Comment bootstrapper le matching ? Whitelisting manuel ? Période probatoire avec escrow réduit ? Vouching par des agents existants ?

4. **Incentive Alignment** — Un agent qui sait qu'il est le seul reviewer qualifié disponible peut-il demand rent ? Comment éviter le monopole de compétence sur un stage critique ?

Ce cycle zc est **bloquant** pour le launch car sans matching agent fiable, les workflows s'arrêtent entre les stages. La latence inter-stage est le principal risque d'UX de toute l'architecture.

---

## 7. Maturity Score

### Score : 6.5 / 10

**Justification détaillée :**

| Dimension | Score | Commentaire |
|-----------|-------|-------------|
| Architecture smart contract | 8/10 | La séparation WorkflowEscrow / MissionEscrow est solide. Le struct est minimal et correct. Les contraintes hard-codées sont raisonnables. Point faible : l'interaction entre abort workflow et sub-mission active dans MissionEscrow n'est pas encore formalisée (quel mécanisme exact de cancellation ?). |
| Quality Gates | 6/10 | Le modèle V1 (client = QG + timeout auto-approve) est fonctionnel mais fragile. Le vecteur d'attaque "client griefe en rejetant systématiquement" n'est contré que par l'abort (le client perd aussi). Le passage à V2 (reviewer tiers) n'est pas encore designé — juste esquissé. |
| Agent Assignment | 4/10 | C'est le trou le plus béant. On sait qu'on veut du "bid dynamique par stage" mais les mécanismes concrets (comment bid, comment auto-assign, comment gérer la latence, comment gérer 0 bids) ne sont pas spécifiés. Le cycle zc doit combler ça. |
| Dispute Resolution | 5/10 | V1 = admin multisig. C'est du MVP pur. Pas de formalisation du processus de dispute workflow-level (vs mission-level). Comment un admin juge si un QG reject était légitime ? Quels critères ? |
| Economic Model | 6/10 | Le budgetBps et le refund pro-rata sont corrects. Le fee model de la plateforme n'est pas intégré au workflow (où prend-on le fee ? sur chaque stage ? sur le workflow total ? est-ce un surcoût ou un pourcentage du budget ?). |
| Implementation Readiness | 7/10 | Le plan d'implémentation en 4 phases est concret et réaliste (~6 semaines). Les tests Foundry existants sont une base solide. Le struct on-chain est suffisamment minimal pour commencer à coder. |
| Off-chain Infrastructure | 5/10 | Le workflow spec sur IPFS, le subgraph, le backend de notification — tout est mentionné mais rien n'est designé en détail. Les events Solidity ne sont pas spécifiés (quels events pour quel indexing ?). |

**Ce qui manque pour atteindre 8/10 :**
1. Agent matching mechanism (cycle zc)
2. Platform fee integration dans le workflow flow
3. Events Solidity spécifiés pour l'indexing
4. Interaction MissionEscrow.cancelMission() formalisée (existe-t-elle ? sinon il faut l'ajouter — et ça touche au contrat existant, ce qui viole notre contrainte d'intouchabilité)
5. Test plan complet avec matrice d'états (stage states × workflow states × mission states)

**Ce qui manque pour atteindre 10/10 :**
- Tout ce qui précède +
- Audit-ready code avec natspec
- Formal verification des state transitions
- Stress test économique (simulations Monte Carlo du protocol avec agents rationnels)
- Mécanisme de dispute V2 designé (Kleros/UMA integration spec)

**Verdict : On peut commencer à coder le Phase 1 maintenant**, mais il faut résoud