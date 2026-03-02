

# Cycle zt — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ Le budget achète de la densité de vérification, pas du compute

**Validé et promu en principe fondateur du pricing.**

C'est l'insight stratégique la plus forte de tous les cycles. Elle résout simultanément trois problèmes :
- **Différenciation** : impossible à commoditiser (le compute est commodité, la chaîne de preuve ne l'est pas)
- **Pricing power** : le client ne compare pas au coût GPU, il compare au coût d'un audit humain (10-100x plus cher)
- **Clarté produit** : le tier name correspond directement au nombre de regards indépendants

**Conséquence concrète :** la page pricing ne dit pas "Bronze = 1 agent, Gold = 3 agents". Elle dit "Bronze = exécution, Silver = exécution + review, Gold = exécution + double review indépendante, Platinum = exécution + review + security audit + optimisation". Chaque tier ajoute un **type de regard**, pas juste un nombre.

### 1.2 ✅ Sequential Spine with Parallel Wings (SSPW) comme modèle de workflow

**Validé.** C'est le sweet spot entre expressivité et complexité implémentation.

Justification :
- Un DAG engine générique est un projet en soi (Temporal, Airflow, etc.) — hors scope pour un MVP
- Un pipeline purement séquentiel ne capture pas le cas Gold (2 reviewers indépendants en parallèle, condition essentielle pour que les regards soient réellement indépendants)
- SSPW se modélise comme un **array avec un champ `parallelGroup`** — trivial à implémenter, trivial à raisonner

**Guard-rail maintenu :** max 6 stages. Tout workflow proposé avec >6 stages est rejeté par le contrat.

### 1.3 ✅ WorkflowEscrow compose avec MissionEscrow, ne le remplace pas

**Validé. Décision architecturale critique.**

`WorkflowEscrow` agit comme un **meta-client** qui appelle `MissionEscrow.createMission()` pour chaque stage. Les 14 tests Foundry existants restent verts. Aucune modification de `MissionEscrow.sol`.

```
WorkflowEscrow.sol
  │
  ├── createWorkflow(issueId, tier, stages[], budgets[], gateConfigs[])
  │     └── Verrouille le budget total en USDC
  │
  ├── activateStage(workflowId, stageIndex)
  │     └── Appelle MissionEscrow.createMission() pour ce stage
  │     └── Transfère le budget partiel depuis le pool workflow
  │
  ├── submitGateAttestation(workflowId, gateIndex, artifactHash, score, sig)
  │     └── Vérifie signature agent reviewer
  │     └── Si pass → activateStage(next)
  │     └── Si fail → branch logic (retry / refund / escalate)
  │
  └── finalizeWorkflow(workflowId)
        └── Libère les fonds restants / déclenche les payouts via MissionEscrow
```

**Risque identifié et mitigé :** `WorkflowEscrow` détient le budget global et le distribue aux `Mission` individuelles. Ça crée un pool intermédiaire. Le contrat doit avoir un `emergencyWithdraw` owner-gated (timelock 48h) pour le cas où le workflow engine a un bug. Ce n'est pas idéal du point de vue trustless, mais c'est acceptable pour V1 avec un volume <$100K.

### 1.4 ✅ Quality Gates = attestation off-chain avec commitment on-chain

**Validé. C'est la bonne architecture.**

Le cycle Opus proposait des gates on-chain avec `pass/fail` stocké dans le contrat. Le challenge a raison de rejeter ça :

| Aspect | Full on-chain (rejeté) | Hybrid attestation (retenu) |
|--------|----------------------|---------------------------|
| Coût gas | Stocker le rapport = prohibitif | Stocker hash(rapport) + score + sig = ~50K gas |
| Subjectivité | Le contrat ne peut pas juger | L'agent signe, le client peut disputer |
| Latence | Attente de tx confirmation | Off-chain instantané, on-chain async |
| Auditabilité | Tout on-chain = transparent | Hash on-chain + rapport sur IPFS = vérifiable |

**Flux concret :**
```
1. Agent Reviewer exécute review off-chain
2. Produit: {rapport_markdown, score: 0-100, artifact_hashes[], timestamp}
3. Signe: keccak256(abi.encode(workflowId, gateIndex, score, artifactHash))
4. Submit on-chain: submitGateAttestation(workflowId, gateIndex, artifactHash, score, sig)
5. Contrat vérifie: ecrecover(sig) == agent assigné au stage reviewer
6. Si score >= threshold (configurable par tier, default 70): advanceStage()
7. Si score < threshold: stage.state = FAILED, déclenche retry/refund logic
8. Client a 24h pour challenger l'attestation (V1: pause + arbitrage manuel)
```

### 1.5 ✅ Les 4 tiers Bronze/Silver/Gold/Platinum sont les bons

**Validé, mais avec une précision importante :** Platinum est **V2 uniquement**. Le MVP shippe Bronze + Silver + Gold.

Justification du cut :
- Platinum introduit des rôles (SECURITY_AUDITOR, OPTIMIZER) qui nécessitent des agents spécialisés pas encore disponibles sur le marketplace
- 3 tiers suffisent pour valider le modèle "plus de regards = plus cher"
- Platinum peut être ajouté sans breaking change (c'est juste un template de workflow avec plus de stages)

### 1.6 ✅ Budget split explicite par stage

**Validé.** Chaque stage a un budget alloué au moment de la création du workflow, pas calculé dynamiquement.

Ratios par défaut (overridable par le client) :

| Tier | Coder | Reviewer A | Reviewer B | Platform fee |
|------|-------|-----------|-----------|-------------|
| Bronze | 85% | — | — | 15% |
| Silver | 65% | 20% | — | 15% |
| Gold | 55% | 15% | 15% | 15% |

Le 15% platform fee est prélevé à la création du workflow et envoyé au treasury. Il ne transite pas par MissionEscrow. Les budgets stage sont nets de fee.

---

## 2. Décisions Rejetées

### 2.1 ❌ DAG engine générique

**Rejeté définitivement.** SSPW couvre 95% des cas utiles. Les 5% restants (branches conditionnelles complexes, loops, fan-out dynamique) ne sont pas des use cases de V1-V3. Si un jour on a besoin d'un DAG engine, on intègrera Temporal côté orchestration off-chain, pas on-chain.

### 2.2 ❌ Quality Gates entièrement on-chain (décision du cycle Opus)

**Rejeté.** Voir §1.4. L'attestation hybride est supérieure sur tous les axes.

### 2.3 ❌ Reviewer comme juge et partie

**Rejeté implicitement dans l'architecture, mais il faut le rendre explicite.**

Le challenge soulève le point : "qui pousse le pass/fail ? Si c'est l'agent reviewer, il est juge et partie." C'est vrai, mais la mitigation est architecturale :

- En **Gold**, les deux reviewers sont **indépendants et ne voient pas le résultat de l'autre** (parallel wings). Si les deux passent, la confiance est élevée. S'il y a divergence, c'est un signal fort → escalade.
- Le **client** est le juge final en V1 (il peut rejeter l'attestation dans les 24h).
- En V2, un **arbitre tiers** (Kleros/UMA) résout les disputes quand client et agent sont en désaccord.

**Mais attention :** en **Silver**, il n'y a qu'un seul reviewer. Ce reviewer a un incentive à passer rapidement pour être payé. Mitigation V1 : le reviewer est payé **après** acceptation client (pas après sa propre attestation). Son paiement est conditionné à l'absence de dispute dans les 24h.

### 2.4 ❌ Platinum en V1

**Rejeté pour V1.** Voir §1.5.

### 2.5 ❌ Stages dynamiques (ajout/suppression de stages en cours de workflow)

**Rejeté.** Le workflow est immutable après création. Si le client veut changer la topologie, il annule le workflow (avec refund partiel pour les stages non démarrés) et en crée un nouveau. Raison : la mutabilité du workflow crée un surface d'attaque massive (client qui supprime le stage reviewer après que le coder a livré, reviewer qui demande l'ajout d'un stage supplémentaire pour se payer deux fois, etc.).

### 2.6 ❌ Score de quality gate entièrement automatisé (tests pass/fail uniquement)

**Rejeté comme seul mécanisme.** Les tests automatisés sont un **input** du quality gate, pas le quality gate lui-même. Un reviewer peut passer un stage même si 2 tests sur 50 échouent (faux positifs, tests flaky), et peut fail un stage même si tous les tests passent (code correct mais architecture catastrophique, failles de sécurité non couvertes par les tests).

Le score du gate est un **jugement** de l'agent reviewer, informé par les résultats automatisés mais pas déterminé par eux.

---

## 3. Nouveaux Insights

### 3.1 🆕 Le modèle économique est un marché d'attestations, pas un marché de compute

C'est le prolongement de l'insight §1.1, mais avec une conséquence non évidente : **les agents reviewers sont plus précieux que les agents coders sur ce marketplace.**

Pourquoi : le code va se commoditiser (Claude, GPT, Codex produisent du code similaire). La review indépendante et attestée est plus rare et plus defensible. Le marketplace devrait donc :
- Avoir un **reputation system** séparé pour les reviewers
- Permettre aux agents de se spécialiser en review (et de facturer plus cher à l'heure)
- À terme, permettre aux **clients de choisir leur reviewer** (comme on choisit son auditeur financier)

**Impact PRD :** le scoring/reputation system doit distinguer les rôles. Un agent avec 100 missions coder réussies n'est pas qualifié pour review. Les deux tracks sont indépendantes.

### 3.2 🆕 Le parallel group crée un problème de consensus jamais adressé

Quand Gold a deux reviewers parallèles, que se passe-t-il quand :
- **A passe, B passe** → trivial, workflow avance
- **A passe, B fail** → ???
- **A fail, B fail** → trivial, workflow échoue / retry
- **A livre, B ne livre jamais** → ???

Aucun cycle précédent n'a spécifié la **merge logic**. Proposition :

```
MergePolicy:
  UNANIMOUS:  tous doivent passer (default pour Gold — c'est le point du double review)
  MAJORITY:   >50% doivent passer (utile pour Platinum avec 3+ reviewers)
  ANY:        au moins un passe (trop laxiste, non recommandé)

Timeout handling:
  Si un reviewer dans un parallel group n'a pas livré après X heures:
    - Son stage est marqué TIMED_OUT
    - Il ne reçoit pas de paiement
    - La merge logic s'applique sur les stages restants
    - Si aucun stage restant ne satisfait la policy → FAIL

Divergence handling (A passe, B fail):
  1. Le workflow est PAUSED (pas FAILED)
  2. Le client est notifié avec les deux rapports
  3. Le client a 48h pour:
     a. Accepter (force pass) → workflow avance, les deux reviewers sont payés
     b. Rejeter (force fail) → workflow retourne au coder pour fix
     c. Ne rien faire → default to FAIL, refund stages non complétés
```

**C'est nouveau** et c'est une pièce architecturale critique qui manquait.

### 3.3 🆕 Le WorkflowEscrow a besoin d'un state machine formel

Les cycles précédents ont des états pour les Missions (Created → Accepted → Delivered → Completed/Disputed). Mais le **Workflow** a ses propres états qui ne sont pas une simple agrégation des états des stages :

```
WorkflowState:
  CREATED        → Budget lockée, stages définis, aucun agent matché
  MATCHING        → Le matching engine cherche des agents pour les stages
  IN_PROGRESS    → Au moins un stage est actif
  GATE_PENDING   → Un quality gate est en attente d'attestation
  PAUSED         → Divergence dans un parallel group, ou dispute client
  COMPLETED      → Tous les stages passés, livrable final accepté
  FAILED         → Échec non récupérable, refund logic activée
  CANCELLED      → Annulé par le client avant complétion

Transitions légales:
  CREATED → MATCHING          (quand le client confirme et le budget est lock)
  MATCHING → IN_PROGRESS      (quand le premier stage est activé)
  IN_PROGRESS → GATE_PENDING  (quand un stage livre et son gate s'active)
  GATE_PENDING → IN_PROGRESS  (quand le gate passe et le next stage démarre)
  GATE_PENDING → PAUSED       (divergence parallèle ou dispute)
  PAUSED → IN_PROGRESS        (client résout la divergence)
  PAUSED → FAILED             (timeout sur la pause)
  IN_PROGRESS → COMPLETED     (dernier gate passé)
  ANY → CANCELLED             (client cancel — refund partiel calculé)
  ANY → FAILED                (3 retries épuisés sur un stage, ou timeout global)
```

**Ce state machine doit être implémenté on-chain** dans `WorkflowEscrow.sol`. Il doit être exhaustif (toute transition non listée est un revert). C'est la colonne vertébrale de la robustesse du système.

### 3.4 🆕 Le matching engine doit résoudre un problème d'allocation multi-slot

Les cycles précédents traitent le matching comme "1 issue → 1 agent". Avec les workflows tiered, le matching devient : "1 workflow → N agents avec des rôles différents, matchés séquentiellement ou en parallèle."

Contraintes du matching :
1. **Exclusion** : un agent ne peut pas être coder ET reviewer sur le même workflow (indépendance des regards)
2. **Timing** : les stages séquentiels sont matchés au moment de l'activation (pas au début du workflow), parce que le matching dépend de la dispo des agents à ce moment
3. **Spécialisation** : les agents doivent déclarer leurs rôles supportés (CODER, REVIEWER, SECURITY_AUDITOR, etc.)
4. **Budget fit** : l'agent doit accepter le budget alloué au stage (pas le budget total du workflow)

**Architecture proposée :**
```
Matching strategy:
  - Stage 0 (CODER): matché immédiatement à la création du workflow
  - Stages suivants: matchés just-in-time quand le stage précédent passe son gate
  - Parallel stages: matchés simultanément quand le gate d'avant passe

Agent profile extension:
  Agent {
    ...existing fields...
    roles: StageRole[]          // [CODER, REVIEWER]
    maxConcurrentMissions: uint8 // Contrôle de charge
    minBudgetPerMission: uint256 // Ne pas proposer des missions sous-payées
  }
```

### 3.5 🆕 Retry logic : le stage fail n'est pas la fin du workflow

Un insight manquant dans les cycles précédents : quand un stage fail, le comportement par défaut ne devrait pas être "workflow fail + refund total". Ça détruit la valeur créée par les stages précédents.

```
Retry policy (par stage, configurable):
  maxRetries: uint8 (default: 1 pour Bronze, 2 pour Silver/Gold)

  On stage fail:
    if retries_remaining > 0:
      - Même agent ou nouvel agent? → Configurable. Default: nouvel agent.
      - Le budget du stage est ré-alloué (l'agent qui a fail n'est pas payé)
      - Le workflow reste IN_PROGRESS
    else:
      - Workflow → FAILED
      - Refund: stages non démarrés → 100% refund
      - Stages complétés avec succès → agents payés (travail effectué)
      - Stage en cours (failed) → 0% à l'agent
      - Platform fee → non refundable (couvre les coûts d'orchestration)
```

**Implication contractuelle :** le refund n'est plus binaire (tout ou rien). C'est un **refund partiel calculé** basé sur les stages complétés. Ça nécessite que `WorkflowEscrow` track le budget par stage et le statut de chaque stage indépendamment — ce qui est déjà dans le design SSPW.

---

## 4. PRD Changes Required

### 4.1 `MASTER.md` — Section Architecture

**Ajouter :** Un diagramme d'architecture à 3 couches :
```
┌─────────────────────────────────────┐
│         Client Interface            │
│  (GitHub App / Web Dashboard)       │
└──────────────┬──────────────────────┘
               │ createWorkflow()
┌──────────────▼──────────────────────┐
│       WorkflowEscrow.sol            │
│  ┌──────────────────────────────┐   │
│  │ Workflow State Machine       │   │
│  │ Stage[] + QualityGate[]      │   │
│  │ Budget allocation            │   │
│  │ Merge logic (parallel)       │   │
│  │ Retry policy                 │   │
│  └──────────┬───────────────────┘   │
└─────────────┼───────────────────────┘
              │ createMission() per stage
┌─────────────▼───────────────────────┐
│       MissionEscrow.sol             │
│  (Existing — 323 lines, 14 tests)  │
│  Individual agent payment & dispute │
└─────────────────────────────────────┘
```

### 4.2 `MASTER.md` — Section Pricing

**Remplacer** la section pricing existante par :

> **Pricing Model: Verification Density Tiers**
>
> Le prix ne reflète pas le coût de compute mais le nombre de regards indépendants attestant la qualité du livrable.
>
> | Tier | Stages | Regards indépendants | Budget typique | Use case |
> |------|--------|---------------------|---------------|----------|
> | Bronze | 1 (coder) + auto gate | 0 humain-like | $20-100 | Scripts, fixes simples, docs |
> | Silver | 2 (coder + reviewer) | 1 | $100-500 | Features standard, APIs |
> | Gold | 3 (coder + 2 reviewers //) | 2 indépendants | $300-2000 | Features critiques, code prod |
> | Platinum (V2) | 4-6 (coder + reviewers + security + optimizer) | 3-5 | $1000-10000 | Smart contracts, infra critique |

### 4.3 `MASTER.md` — Section Smart Contracts

**Ajouter** le contrat `WorkflowEscrow.sol` avec :
- Le state machine complet (§3.3)
- La merge policy pour parallel groups (§3.2)
- La retry policy (§3.5)
- Le budget split par stage (§1.6)
- La gate attestation hybride (§1.4)

### 4.4 `MASTER.md` — Section Matching Engine

**Modifier** pour intégrer :
- Multi-slot matching (§3.4)
- Contrainte d'exclusion (un agent ≠ coder et reviewer sur le même workflow)
- Just-in-time matching pour les stages non-initiaux
- Extension du profil agent avec roles et capacity

### 4.5 `MASTER.md` — Section Reputation

**Ajouter** :
- Tracks de réputation séparées par rôle (§3.1)
- Un agent coder 5★ n'est pas automatiquement un reviewer qualifié
- La réputation reviewer est pondérée par l'accord/désaccord avec les autres reviewers (signal de calibration en Gold)

### 4.6 Nouveau fichier : `docs/WORKFLOW_SPEC.md`

Document dédié contenant :
- La spécification formelle du state machine
- Les templates de workflow par tier
- Les formules de budget split
- Les timeout par stage et par tier
- Les règles de refund partiel
- Les exemples de workflows (happy path + failure paths)

---

## 5. Implementation Priority

### Phase 1 — Foundation (Semaines 1-3)

**Objectif :** WorkflowEscrow avec Bronze uniquement (régression = 0 sur MissionEscrow)

| # | Composant | Effort | Dépendances |
|---|-----------|--------|-------------|
| 1.1 | `WorkflowEscrow.sol` — struct Workflow, Stage, state machine (CREATED→MATCHING→IN_PROGRESS→COMPLETED) | 3j | MissionEscrow.sol stable |
| 1.2 | `WorkflowEscrow.sol` — createWorkflow() avec budget lock USDC | 2j | 1.1 |
| 1.3 | `WorkflowEscrow.sol` — activateStage() → appelle MissionEscrow.createMission() | 2j | 1.1 + 1.2 |
| 1.4 | `WorkflowEscrow.sol` — finalizeWorkflow() | 1j | 1.3 |
| 1.5 | Tests Foundry : Bronze happy path (create → activate → deliver → complete) | 2j | 1.1-1.4 |
| 1.6 | Tests Foundry : Bronze failure (timeout, cancel, refund) | 2j | 1.5 |
| 1.7 | Vérifier 14 tests MissionEscrow toujours verts | 0.5j | 1.1-1.6 |

**Livrable :** WorkflowEscrow déployable sur testnet, Bronze workflow fonctionnel, 20+ tests.

### Phase 2 — Silver & Gates (Semaines 4-6)

| # | Composant | Effort | Dépendances |
|---|-----------|--------|-------------|
| 2.1 | Gate attestation : `submitGateAttestation()` avec vérification signature | 3j | Phase 1 |
| 2.2 | Sequential stage advancement (stage 0 → gate → stage 1) | 2j | 2.1 |
| 2.3 | Agent profile extension : roles[], maxConcurrent | 2j | Matching engine existant |
| 2.4 | Matching engine : contrainte d'exclusion coder ≠ reviewer | 1j | 2.3 |
| 2.5 | Retry logic : fail → re-match → retry (1 retry max) | 3j | 2.2 |
| 2.6 | Tests Foundry : Silver happy path + gate pass/fail + retry | 3j | 2.1-2.5 |
| 2.7 | Refund partiel : calcul et exécution | 2j | 2.5 |

**Livrable :** Silver workflow fonctionnel avec quality gates, retry, refund partiel. ~35+ tests.

### Phase 3 — Gold & Parallel (Semaines 7-9)

| # | Composant | Effort | Dépendances |
|---|-----------|--------|-------------|
| 3.1 | Parallel group support : activateStage() pour un groupe | 3j | Phase 2 |
| 3.2 | Merge gate : attente de tous les stages d'un groupe, merge policy | 4j | 3.1 |
| 3.3 | Divergence handling : PAUSED state, client resolution, timeout | 3j | 3.2 |
| 3.4 | Just-in-time matching pour parallel reviewers | 2j | 3.1 + 2.3 |
| 3.5 | Tests Foundry : Gold happy path, divergence, timeout, cancel mid-workflow | 4j | 3.1-3.4 |
| 3.6 | Gas optimization audit (batch operations, storage packing) | 2j | 3.1-3.5 |

**Livrable :** Gold workflow fonctionnel avec parallel reviewers et merge logic. ~50+ tests. Deployable mainnet.

### Phase 4 — Production Hardening (Semaines 10-12)

| # | Composant | Effort | Dépendances |
|---|-----------|--------|-------------|
| 4.1 | Emergency withdraw avec timelock | 2j | Phase 3 |
| 4.2 | Event emission complète pour indexing (The Graph) | 2j | Phase 3 |
| 4.3 | Client dispute flow (pause workflow, escalation) | 3j | Phase 3 |
| 4.4 | Integration tests end-to-end (GitHub issue → workflow → payout) | 4j | 4.1-4.3 |
| 4.5 | Audit externe (ou peer review intensif) | 5j | 4.4 |
| 4.6 | Mainnet deployment + monitoring | 2j | 4.5 |

**Livrable :** Production-ready avec Bronze/Silver/Gold, dispute handling, emergency controls.

---

## 6. Next Cycle Focus

### Question principale : **Comment le matching engine sélectionne-t-il le reviewer ?**

Le coder est matché par le système existant (bid/accept ou auto-match). Mais le reviewer est un rôle nouveau avec des contraintes nouvelles :

1. **Indépendance** : le reviewer ne doit pas avoir de relation avec le coder (même opérateur ? même cluster d'agents ?)  — Comment détecter et empêcher la collusion entre un coder-agent et un reviewer-agent opérés par la même entité ?

2. **Compétence** : le reviewer doit comprendre le langage/framework du livrable. Comment évaluer ça sans historique ? Cold start problem pour les reviewers.

3. **Incentive alignment** : le reviewer est payé pour reviewer, pas pour approuver. Comment éviter le rubber-stamping (approuver systématiquement en 30 secondes pour maximiser le throughput) ? Métriques de quality of review ? Temps minimum ? Score de divergence avec les autres reviewers (en Gold) ?

4. **Pricing du review** : le budget reviewer est un % du budget total. Mais un review d'un changement de 5 lignes et un review de 500 lignes ont des coûts très différents. Faut-il un pricing dynamique du review basé sur la taille du diff ?

5. **Skin in the game reviewer** : le reviewer devrait-il staker pour attester ? Si un reviewer approuve du code qui est ensuite disputé avec succès par le client, le reviewer perd son stake. Ça crée un vrai skin in the game. Mais ça crée aussi une barrière à l'entrée. Quel est le bon trade-off ?

### Questions secondaires :

- **Template registry** : faut-il un registre on-chain des templates de workflow (Bronze/Silver/Gold) ou est-ce que c'est hardcodé dans `WorkflowEscrow` ? Un registre permettrait d'ajouter des tiers custom sans redéployer le contrat.
- **Workflow composability** : un workflow peut-il référencer un autre workflow comme stage ? (Ex: un Platinum workflow dont le stage security_audit est lui-même un Silver workflow avec son propre coder + reviewer). Probablement V3+, mais à anticiper architecturalement.
- **Cross-chain** : le workflow est sur Base, mais les agents pourraient être sur d'autres chains. Comment gérer le multi-chain ? Probablement hors scope, mais la question sera posée.

---

## 7. Maturity Score

### Score : 7.0 / 10

| Dimension | Score | Justification |
|-----------|-------|--------------|
| **Core model clarity** | 9/10 | L'insight "budget = densité de vérification" est limpide, différenciante et actionnable. C'est la meilleure idée de tous les cycles. |
| **Architecture smart contract** | 7/10 | Le pattern WorkflowEscrow composant MissionEscrow est sain. Le state machine est spécifié. Les structures de données sont définies. Il manque les détails d'implémentation Solidity (modifiers, access control, reentrancy guards) mais c'est normal à ce stade. |
| **Parallel group handling** | 6/10 | Le merge policy est spécifié (§3.2) mais jamais implémenté ni testé. La divergence handling (A passe, B fail) est le cas le plus complexe et il repose sur une intervention client avec timeout. C'est fragile. Il faut le prototyper pour valider que le UX est acceptable. |
| **Quality gate mechanism** | 7/10 | L'attestation hybride est la bonne approche. Mais la question "qui vérifie que le reviewer a réellement fait une review approfondie vs rubber-stamp" n'a pas de réponse technique satisfaisante en V1. La réponse est sociale/économique (réputation + skin in the game) et ça n'est pas encore spécifié. |
| **Matching engine** | 5/10 | Le multi-slot matching est identifié comme besoin mais pas spécifié. La contrainte d'exclusion est triviale. Le just-in-time matching ajoute de la complexité au flow. Le cold start des reviewers n'est pas résolu. C'est le maillon le plus faible. |
| **Economic model** | 6/10 | Les ratios de budget split sont proposés mais pas