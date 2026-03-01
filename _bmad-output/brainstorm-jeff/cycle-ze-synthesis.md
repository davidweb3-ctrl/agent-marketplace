

# Cycle ze — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ Le Plan comme primitive technique, le Tier comme preset marketing

**Justification :** C'est la décision architecturale la plus structurante du cycle. Le smart contract manipule des `WorkflowPlan` (stages[], budgetSplit[], qualityGateConfigs[]). Le concept de "tier Bronze/Silver/Gold" n'existe que dans le Compiler off-chain qui génère ces plans à partir de presets. Cela garantit que le contrat est générique et ne nécessite pas de redéploiement quand on ajuste les tiers.

**Conséquence concrète :** Aucun `enum Tier` dans le Solidity. Le tier est un `bytes32 tierLabel` stocké à titre informatif dans l'event, pas dans la logique.

### 1.2 ✅ Pipeline séquentiel strict (pas de DAG en V1)

**Justification :** L'analyse coût/bénéfice est définitive. Le pipeline couvre ~95% des use-cases GitHub Issues. L'index monotone croissant (`currentStage++`) rend la vérification on-chain triviale, la disputabilité non-ambiguë, et l'UX linéaire. Le DAG est explicitement classé comme V3+ avec un trigger clair : "quand on a >10% de workflows qui nécessitent des branches parallèles en production".

**Guard-rail confirmé :** Max 6 stages. Encodable en `uint8`, 3 bits suffisent. Au-delà, la latence et la complexité de dispute rendent le workflow contre-productif.

### 1.3 ✅ WorkflowEscrow compose MissionEscrow (ne le modifie pas)

**Justification :** Les 14 tests Foundry verts sont le socle de non-régression. `WorkflowEscrow` agit comme **meta-client** qui appelle `MissionEscrow.createMission()` pour chaque stage. Le MissionEscrow existant ne voit que des missions individuelles — il est agnostique du concept de workflow.

**Pattern exact :**
```
WorkflowEscrow.createWorkflow(...)
  └─ pour chaque stage i:
       MissionEscrow.createMission(client=address(WorkflowEscrow), agent=TBD, amount=budgetSplit[i])
```

Le `WorkflowEscrow` est le `client` du point de vue du `MissionEscrow`. Cela signifie que c'est le `WorkflowEscrow` qui appelle `approveMission()` ou `disputeMission()` sur le `MissionEscrow` — pas le client humain directement. Le client humain interagit uniquement avec `WorkflowEscrow`.

### 1.4 ✅ Quality Gates = attestation off-chain + commitment on-chain

**Justification :** Le jugement de qualité est subjectif. Le smart contract ne peut pas parser du code. Le modèle retenu est :

| Composant | Lieu | Contenu |
|-----------|------|---------|
| Rapport de review | Off-chain (IPFS/Arweave) | Analyse complète, commentaires, suggestions |
| Attestation | On-chain | `keccak256(rapport)` + `score uint8` + `signature agent reviewer` |
| Dispute window | On-chain | Timer configurable (défaut 24h) pendant lequel le client peut challenger |
| Résolution | V1: multisig platform / V2: Kleros/UMA | Arbitrage sur la base du rapport off-chain |

**L'oracle problem est résolu pragmatiquement en V1** : l'agent reviewer est un acteur économiquement distinct de l'agent exécutant (staking séparé, reputation séparée). Ce n'est pas parfait (collusion possible), mais c'est suffisant avec le dispute mechanism comme backstop.

### 1.5 ✅ State Machine du Workflow à 8 états

**Justification :** Les 8 états couvrent l'intégralité du lifecycle sans sur-ingénierie :

```
PLANNED → FUNDED → STAGE_ACTIVE → STAGE_GATING → STAGE_ACTIVE → ... → COMPLETED
                                   ↘ STAGE_FAILED → HALTED | RETRYING | REFUNDING
PLANNED → CANCELLED
FUNDED  → CANCELLED (refund total si aucun stage n'a démarré)
```

**Transitions critiques à sécuriser :**
- `FUNDED → STAGE_ACTIVE` : seul le WorkflowEscrow peut trigger (pas le client directement)
- `STAGE_GATING → STAGE_ACTIVE` : requiert attestation QG valide ET expiration dispute window sans challenge
- `STAGE_GATING → STAGE_FAILED` : trigger par dispute client OU par score QG sous seuil minimum configurable
- `RETRYING → STAGE_ACTIVE` : décrémente retryCount, revert si `retryCount == 0`
- Aucune transition ne permet de skip un stage

### 1.6 ✅ Budget partiel progressif avec locked/released/refundable

**Justification :** Le client lock le budget total à la création du workflow. Le `WorkflowEscrow` gère trois compteurs :

```solidity
struct WorkflowBudget {
    uint128 totalLocked;      // immutable après funding
    uint128 totalReleased;    // cumulatif, monotone croissant
    uint128 totalRefundable;  // calculé = totalLocked - totalReleased - currentStageBudget
}
```

Le release est progressif : chaque stage validé (QG passed + dispute window expired) trigger un `release` de `budgetSplit[i]` vers l'agent de ce stage. En cas de HALT, le `totalRefundable` est renvoyé au client.

---

## 2. Décisions Rejetées

### 2.1 ❌ Quality Gates entièrement on-chain (évaluation de qualité dans le contrat)

**Rejeté.** Raisons déjà documentées : subjectivité du jugement, coût gas prohibitif, oracle problem non-résolu. Le contrat ne stocke que des hashes et des scores, jamais le contenu de l'évaluation.

### 2.2 ❌ WorkflowEscrow hérite de MissionEscrow

**Rejeté.** L'héritage (`is MissionEscrow`) créerait un couplage fort, rendrait les 14 tests fragiles, et violerait le SRP. La composition (`WorkflowEscrow` détient une référence `IMissionEscrow` et l'appelle) est strictement supérieure. Elle permet aussi de déployer `WorkflowEscrow` indépendamment et de pointer vers un `MissionEscrow` déjà deployé et audité.

### 2.3 ❌ Création des missions de tous les stages à la création du workflow

**Rejeté.** Créer N missions d'un coup au moment de `createWorkflow` a trois problèmes :
1. **Gas spike** : créer 6 missions en une tx est coûteux et imprévisible
2. **Agent pas encore connu** : le matching de l'agent du stage 3 n'a pas de sens quand le stage 1 n'est même pas commencé — l'output du stage 1 influence le profil idéal pour le stage 2
3. **Lock prématuré** : si le workflow est HALTED au stage 2, les missions 3-6 existent inutilement on-chain

**Décision retenue :** Lazy creation — la mission du stage `i+1` est créée **uniquement quand le QG du stage `i` est passé**. Le matching agent pour le stage `i+1` se fait à ce moment-là avec le contexte complet.

### 2.4 ❌ Retry illimité en cas d'échec de stage

**Rejeté.** Un retry illimité crée un workflow zombie qui lock du capital indéfiniment. **Décision retenue :** `maxRetries` configurable par stage dans le plan, avec un hard cap protocol de 2 retries. Au-delà, le workflow passe en HALTED et le budget restant devient refundable.

### 2.5 ❌ Le client choisit manuellement l'agent de chaque stage

**Rejeté pour le flow par défaut.** Le matching est fait par le Compiler/Matcher off-chain en fonction du profil requis par le stage (skill tags, reputation minimum, disponibilité). Le client peut **override** le choix proposé, mais le flow par défaut est automatique. Raison : le client n'a pas la compétence pour évaluer si un agent est bon en "security audit Solidity" — c'est le travail du système de réputation.

---

## 3. Nouveaux Insights

### 3.1 🆕 Le WorkflowEscrow comme meta-client du MissionEscrow

C'est la trouvaille architecturale clé de ce cycle. Aucun cycle précédent n'avait explicité que le `WorkflowEscrow` **est le client** du point de vue du `MissionEscrow`. Le client humain → interagit avec WorkflowEscrow → qui interagit avec MissionEscrow en son nom. Cela crée une séparation propre :

```
Humain (EOA) ←→ WorkflowEscrow (orchestration, budget, QG)
                      ↕
               MissionEscrow (exécution atomique, paiement unitaire)
```

**Implication non triviale :** `MissionEscrow` doit accepter un **contrat** comme `client`, pas seulement un EOA. Vérifier que le MissionEscrow actuel (323 lignes) n'a pas de `require(msg.sender == tx.origin)` ou équivalent qui bloquerait ça. Si oui, c'est le **seul** changement autorisé dans MissionEscrow.

### 3.2 🆕 Le budget split n'est pas linéaire — il suit une courbe de valeur

Insight original : les cycles précédents parlaient de "répartition du budget entre stages" sans préciser la logique. En réalité, la répartition devrait refléter la **valeur ajoutée** de chaque stage, pas une division égale :

| Stage | Rôle | % budget typique (tier Gold) | Justification |
|-------|------|-------------------------------|---------------|
| 0 | Coder | 40-50% | Produit l'artifact principal |
| 1 | Reviewer | 15-20% | Feedback structurel |
| 2 | Security | 20-25% | Spécialiste, rare, cher |
| 3 | Tester | 10-15% | Vérifie, ne crée pas |

**Le Compiler encode ces ratios par défaut dans les presets de tier**, mais le client peut les ajuster dans les bornes min/max fixées par le protocol (ex: aucun stage ne peut avoir <5% ou >60% du budget total).

### 3.3 🆕 La FailurePolicy comme entité configurable dans le plan

Cycle précédent mentionnait HALTED/RETRYING/REFUNDING comme états, mais sans expliquer **qui décide** de la transition. Nouvel insight : la `FailurePolicy` est définie à la compilation du plan et stockée on-chain :

```solidity
struct FailurePolicy {
    uint8 maxRetries;           // 0, 1, ou 2 (hard cap)
    bool autoRetryOnFail;       // true = retry automatique avec nouvel agent, false = HALT et attente client
    uint8 minScoreToPass;       // score QG minimum (0-100), en dessous = échec
    bool refundOnHalt;          // true = refund auto du budget restant, false = attente action client
    uint32 haltTimeoutSeconds;  // après ce délai en HALTED sans action, refund auto
}
```

Cela élimine l'ambiguïté opérationnelle : pas de décision humaine à prendre dans le hot path, sauf si `autoRetryOnFail = false`.

### 3.4 🆕 La réputation doit être scopée par rôle dans le workflow

Les cycles précédents traitaient la réputation comme un score unique. Mais un agent qui est excellent en coding peut être médiocre en security review. **La réputation doit être indexée par `(agent, role)`**, pas par `(agent)` seul.

```
reputationScore[agent][CODER]    = 87
reputationScore[agent][REVIEWER] = 62
reputationScore[agent][SECURITY] = 0  // jamais fait
reputationScore[agent][TESTER]   = 91
```

Cela change le modèle de matching : le Compiler query `reputationScore[agent][stageRole] >= plan.stages[i].minReputation`.

### 3.5 🆕 Le dispute model change fondamentalement avec les workflows

Avec une mission atomique, le dispute est binaire : le client conteste, un arbitre tranche, l'agent est payé ou pas. Avec un workflow multi-stage, les disputes sont **localisées** et **cascadantes** :

- **Dispute locale** : "Le reviewer du stage 1 a donné pass alors que le code est buggé" → conteste l'attestation QG spécifique
- **Dispute cascade** : Si le stage 0 (coding) est rétrospectivement jugé mauvais après le stage 2 (security), que se passe-t-il pour les paiements déjà releasés aux stages 0 et 1 ?

**Décision V1 (pragmatique) :** Les paiements releasés sont **finaux**. On ne clawback pas. Le dispute ne peut porter que sur le stage **courant** ou le stage **précédent immédiat** (window de 1 stage). C'est une simplification assumée. Le risque est couvert par les quality gates : si les QG sont bien calibrés, un problème au stage 0 est détecté au stage 1, pas au stage 4.

**V2 :** Exploration d'un mécanisme de clawback partiel avec staking agent comme collatéral.

---

## 4. PRD Changes Required

### 4.1 `MASTER.md` — Section "Smart Contract Architecture"

| Changement | Détail | Priorité |
|------------|--------|----------|
| **Ajouter** `WorkflowEscrow.sol` spec | Structs, state machine, fonctions publiques, events. Inclure le pattern meta-client. | P0 |
| **Ajouter** `FailurePolicy` struct | Définition complète avec les 5 champs documentés en 3.3 | P0 |
| **Modifier** scope de `MissionEscrow.sol` | Documenter explicitement qu'il accepte des contrats comme `client`, pas seulement des EOA. Vérifier et documenter la non-présence de `tx.origin` checks. | P0 |
| **Ajouter** section "Budget Management" | Modèle `totalLocked/totalReleased/totalRefundable`, courbe de répartition par défaut, bornes min/max par stage | P0 |
| **Modifier** section "Reputation System" | Passer de `score(agent)` à `score(agent, role)`. Documenter les rôles : CODER, REVIEWER, SECURITY, TESTER. | P1 |
| **Ajouter** section "Dispute Model — Workflows" | Disputes localisées, window de 1 stage, paiements finaux après release, pas de clawback V1 | P1 |
| **Modifier** section "Quality Gates" | Remplacer toute mention de QG on-chain par le modèle attestation off-chain + commitment on-chain | P0 |
| **Ajouter** section "Tier Presets" | Documenter que les tiers sont des presets du Compiler, pas des entités on-chain. Inclure les presets par défaut (Bronze=1 stage, Silver=2-3 stages, Gold=3-4+ stages) | P1 |

### 4.2 `MASTER.md` — Section "Off-chain Components"

| Changement | Détail | Priorité |
|------------|--------|----------|
| **Ajouter** spec du Workflow Compiler | Input (issue + tier preset + client overrides) → Output (WorkflowPlan solidity-compatible). Incluant le budget split algorithm. | P0 |
| **Ajouter** spec du Stage Matcher | Comment il sélectionne l'agent pour le stage `i+1` après QG pass du stage `i`. Inputs : role, min reputation, disponibilité, output du stage précédent. | P1 |
| **Ajouter** spec du QG Evaluator | L'agent ou service off-chain qui produit le rapport + score, le signe, et soumet l'attestation on-chain. | P1 |

### 4.3 Nouveau fichier recommandé : `WORKFLOW_SPEC.md`

Vu la taille de la spec workflow, recommander un fichier dédié référencé depuis MASTER.md. Contenu :
- State machine diagram (Mermaid)
- Struct definitions (Solidity pseudocode)
- Transition table exhaustive (from → to, conditions, effects)
- Gas estimates par opération
- Séquence diagram complète d'un workflow Gold heureux
- Séquence diagram d'un workflow avec échec stage + retry + halt

---

## 5. Implementation Priority

### Phase 1 : Fondation (Semaine 1-2)

```
P0-a: Audit MissionEscrow.sol pour compatibilité contrat-comme-client
       → Vérifier absence de tx.origin
       → Ajouter interface IMissionEscrow si inexistante
       → Tests : MissionEscrow appelé par un contrat mock (3-4 tests)
       → Livrable : MissionEscrow inchangé OU diff minimal + tests verts

P0-b: WorkflowEscrow.sol — Structs et storage
       → WorkflowPlan, StageConfig, FailurePolicy, WorkflowBudget, WorkflowState
       → createWorkflow() + funding logic
       → Tests : création + funding + annulation (6-8 tests)
       → Livrable : Contrat déployable sur testnet, fonctions de lecture
```

### Phase 2 : Lifecycle heureux (Semaine 3-4)

```
P0-c: WorkflowEscrow.sol — advanceStage flow
       → Lazy creation de mission via MissionEscrow
       → Quality gate attestation submission
       → Dispute window timer
       → Stage completion + budget release
       → Tests : workflow complet 2 stages sans échec (8-10 tests)
       → Livrable : Happy path end-to-end sur testnet

P0-d: WorkflowEscrow.sol — failure + retry flow
       → FailurePolicy execution
       → Retry avec nouvel agent
       → HALT + refund
       → Timeout auto-refund
       → Tests : échec + retry + halt + timeout (8-10 tests)
       → Livrable : Sad paths couverts
```

### Phase 3 : Off-chain (Semaine 5-6)

```
P1-a: Workflow Compiler (TypeScript)
       → Tier presets → WorkflowPlan generation
       → Budget split algorithm avec bornes
       → Tests : presets Bronze/Silver/Gold génèrent des plans valides

P1-b: QG Evaluator mock
       → Agent signe un rapport, produit attestation
       → Intégration avec advanceStage on-chain
       → Tests : attestation valide/invalide/expirée

P1-c: Stage Matcher
       → Query reputation par (agent, role)
       → Sélection + assignment
       → Tests : matching avec contraintes de reputation
```

### Phase 4 : Intégration (Semaine 7-8)

```
P1-d: E2E test
       → Client crée workflow Gold (4 stages) via Compiler
       → Stages exécutés séquentiellement par agents mock
       → QG pass/fail testés
       → Un retry déclenché
       → Paiements vérifiés à chaque étape
       → Livrable : Test d'intégration complet, scenario Gold

P2: Reputation scoped par rôle
       → Migration du modèle reputation existant
       → Indexation (agent, role)
       → Intégration avec Matcher
```

### Estimation totale : 8 semaines pour V1 workflow-complete

**Dépendances critiques :**
- Phase 1a gate Phase 2 (si MissionEscrow nécessite des changements, tout glisse)
- Phase 2 gate Phase 3b (le Compiler doit produire des plans que le contrat accepte)

---

## 6. Next Cycle Focus

### Question principale du Cycle zf :

> **Comment le Quality Gate Evaluator est-il incité économiquement à être honnête, et comment le dispute resolution fonctionne-t-il concrètement pour les workflows multi-stage ?**

**Justification :** C'est le plus grand trou dans l'architecture actuelle. On a défini que l'attestation est off-chain avec commitment on-chain, mais :

1. **Incentive alignment du reviewer** : Si l'agent reviewer est payé pour passer le QG, il est incité à toujours donner "pass" pour encaisser sa part de budget. Quel mécanisme empêche ça ? Staking ? Réputation ? Slashing ? Pas encore défini.

2. **Dispute mechanics concrètes** : "Le client peut challenger" — mais comment ? Avec quelles preuves ? Qui arbitre ? Quel est le coût de disputer ? (Si gratuit, spam de disputes. Si payant, barrier pour les petits clients.) Quel est le timeline exact ?

3. **Le gap économique du stage Security** : Un audit security sérieux coûte 5-20k USD. Un workflow Gold sur une issue à 500 USD ne peut pas se payer un vrai audit. Comment le tier system gère-t-il ce delta entre l'attente ("security audit") et la réalité ("automated scan + sanity check") sans tromper le client ?

4. **Dispute cascade en pratique** : On a dit "pas de clawback V1, window de 1 stage". Mais que se passe-t-il si le Tester (stage 3) découvre que le code du Coder (stage 0) était fondamentalement mauvais et que le Reviewer (stage 1) l'a laissé passer ? Le client a payé stages 0 et 1 pour rien. Comment la FailurePolicy gère-t-elle ce cas sans clawback ?

**Sous-questions à résoudre :**
- Spec le `DisputeManager.sol` (ou module dans WorkflowEscrow)
- Spec le modèle économique du reviewer (cost of dishonesty > cost of honesty)
- Définir les "tiers de vérification" réels (ce que chaque tier achète vraiment en termes de QG rigor)
- Explorer si un "QG Evaluator" distinct des agents de stage est viable (tiers de confiance spécialisé)

---

## 7. Maturity Score

### Score : 6.5 / 10

**Breakdown :**

| Dimension | Score | Commentaire |
|-----------|-------|-------------|
| Smart Contract Architecture | 7/10 | WorkflowEscrow design est solide. Structs, state machine, composition pattern — tout est cohérent. Il manque le Solidity réel et les gas estimates. |
| Quality Gates | 5/10 | Le modèle attestation off-chain + commitment on-chain est correct, mais l'incentive alignment du reviewer est un trou béant. Sans ça, les QG sont du théâtre de sécurité. |
| Budget Management | 7/10 | Locked/released/refundable est propre. Le budget split par courbe de valeur est un bon insight. Il manque la gestion des edge cases (que se passe-t-il si l'USDC se dépeg pendant un workflow long ?). |
| Dispute Resolution | 4/10 | "Le client peut challenger" est insuffisant. Pas de spec du flow, pas de coûts, pas d'arbitrage. C'est le plus gros trou. |
| Off-chain Components | 5/10 | Compiler et Matcher sont identifiés mais pas spécifiés. Le QG Evaluator est flou. Rien sur l'infrastructure (où tourne le Compiler ? qui le scale ?). |
| Reputation System | 6/10 | Le scopage par rôle est un bon insight. Mais le mécanisme de calcul, de decay, et d'anti-gaming n'est pas défini. |
| Tier Presets | 7/10 | La séparation tier=marketing / plan=technique est clean. Les presets par défaut sont sensés. |
| Test Coverage Strategy | 7/10 | Le plan de test par phase est concret. Les 14 tests existants comme non-régression sont un bon ancrage. |
| E2E Viability | 5/10 | On peut builder le happy path. Mais sans dispute resolution solide et sans incentive alignment des reviewers, le système n'est pas trustless — il est trust-the-reviewer. |
| Production Readiness | 4/10 | Loin. Pas d'audit, pas de gas optimization, pas de upgrade path (proxy pattern ?), pas de monitoring on-chain, pas de rate limiting. |

**Justification du 6.5 :** L'architecture structurelle est saine et les décisions de design sont bien justifiées. On a un modèle mental cohérent avec des structs concrètes. Mais les deux piliers de confiance du système — **Quality Gates fiables** et **Dispute Resolution fonctionnelle** — sont sous-spécifiés. Sans eux, on a un bel escrow progressif mais pas une garantie de qualité. Le prochain cycle doit attaquer frontalement l'incentive design. On n'est pas prêt à builder le workflow complet, mais on est prêt à builder la Phase 1 (fondation + structs + happy path) pendant que le cycle zf résout les questions d'incentive.

**Trigger pour passer à 8/10 :** Dispute Resolution spec complète + Reviewer incentive model validé économiquement + au moins un gas benchmark réel sur testnet.