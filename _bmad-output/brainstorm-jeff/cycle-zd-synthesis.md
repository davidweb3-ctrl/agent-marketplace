

# Cycle zd — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ Le Workflow comme Plan Compiler, pas comme Template Engine

**Retenu.** C'est l'insight le plus structurant du cycle. Le système ne doit pas hard-coder "Bronze = 1 agent, Gold = 5 agents". Il doit exposer un compiler qui prend `(task_spec, budget, risk_profile)` → `WorkflowPlan`.

**Justification :** Les tiers marketing (Bronze/Silver/Gold/Platinum) deviennent des **presets d'appel** au compiler, pas des chemins de code distincts. Ça élimine la combinatoire explosive de configurations et ouvre la porte au mode CUSTOM pour les clients enterprise. C'est aussi ce qui justifie l'AGNT burn — la complexité du plan compilé est mesurable et tarifable.

**Conséquence architecturale concrète :** Le `WorkflowEscrow.sol` n'a pas de `if tier == GOLD` dans son code. Il reçoit un `WorkflowPlan` déjà compilé (stages[], gates[], budgetSplit[]). La compilation se fait off-chain dans le backend, le smart contract est agnostique au tier.

### 1.2 ✅ Pipeline Séquentiel Strict en V1 avec max 6 stages

**Retenu.** Le guard-rail à 6 stages est validé pour la deuxième fois (cycle zc + zd). La valeur marginale d'un 7ème stage est négative — latence accrue, surface de dispute élargie, budget par stage dilué sous le seuil de rentabilité des agents.

**Justification :** Un pipeline séquentiel strict est vérifiable on-chain trivialement (index monotone croissant), disputeable sans ambiguïté (on sait exactement quel stage a échoué), et suffisant pour couvrir 95% des use cases réels (code → review → test couvre la majorité des GitHub Issues).

### 1.3 ✅ WorkflowEscrow compose MissionEscrow, ne le remplace pas

**Retenu.** C'est la décision de préservation la plus importante. Les 14 tests Foundry verts et les 323 lignes de `MissionEscrow.sol` sont un actif validé. `WorkflowEscrow` agit comme **meta-client** qui appelle `MissionEscrow.createMission()` pour chaque stage.

**Justification :** Pattern composition > inheritance. Si `WorkflowEscrow` héritait de `MissionEscrow`, on polluerait l'interface simple avec de la logique multi-stage. En composant, chaque mission de stage est indépendamment disputable, et un agent n'a même pas besoin de savoir qu'il opère dans un workflow — il voit juste une mission.

```
WorkflowEscrow.sol (orchestration, ~200 lignes estimées)
  └── calls MissionEscrow.createMission() per stage
  └── calls MissionEscrow.validateMission() quand QG passe
  └── calls MissionEscrow.disputeMission() quand QG échoue
```

### 1.4 ✅ Quality Gates = Attestation off-chain + Commitment on-chain

**Retenu.** C'est la résolution correcte du tension entre "on veut des quality gates" et "un smart contract ne peut pas juger du code".

**Justification triple :**
- **Subjectivité :** Un smart contract ne peut pas évaluer si une code review est pertinente. Le jugement reste off-chain.
- **Coût gas :** Stocker les outputs de review on-chain est économiquement absurde (~$50+ pour un rapport de review moyen en calldata).
- **Oracle problem résolu :** L'agent reviewer signe une attestation (`hash(rapport) + score + sig`). Si le client conteste, on entre en dispute avec le rapport complet comme preuve off-chain. En V2, arbitrage via Kleros/UMA.

**Format on-chain :**
```solidity
struct QualityGateAttestation {
    bytes32 workflowId;
    uint8 stageIndex;
    bytes32 reportHash;      // keccak256 du rapport complet (stocké IPFS/Arweave)
    uint8 score;             // 0-100
    address reviewerAgent;
    bytes signature;
    uint256 timestamp;
}
```

### 1.5 ✅ FailurePolicy comme entité first-class

**Retenu.** La gestion d'échec d'un stage dans un workflow multi-stage est un problème fondamentalement différent de l'échec d'une mission isolée. Le `WorkflowPlan` doit contenir une `FailurePolicy` explicite.

**Justification :** Sans FailurePolicy explicite, les questions "que se passe-t-il si le stage 3/5 échoue ?" n'ont pas de réponse déterministe. Le client a déjà payé les stages 1 et 2. Le budget restant est bloqué. Il faut des règles claires pour le refund partiel, le retry, ou le halt.

---

## 2. Décisions Rejetées

### 2.1 ❌ Compiler on-chain du WorkflowPlan

**Rejeté.** Le cycle zd propose le "plan compiler" comme concept central — mais ce compiler ne doit **jamais** être on-chain.

**Pourquoi :** La compilation d'un plan implique : matching d'agents par capabilities, calcul de budget split optimal, estimation de durée, évaluation du risk profile. Tout cela nécessite accès à des données off-chain (base d'agents, historique de performance, pricing dynamique). On-chain, on ne fait que **vérifier et exécuter** un plan déjà compilé.

**Architecture retenue :**
```
Off-chain (backend):  PlanCompiler.compile(taskSpec, budget, riskProfile) → WorkflowPlan
On-chain (contract):  WorkflowEscrow.createWorkflow(plan) → vérifie invariants + lock funds
```

**Invariants vérifiés on-chain :**
- `sum(stages[].budgetUSDC) + platformFee <= totalBudgetUSDC`
- `stages.length <= 6`
- `stages.length == qualityGates.length + 1`
- `globalDeadline > block.timestamp + sum(stages[].timeoutSeconds)`

### 2.2 ❌ Mode CUSTOM dès V1

**Rejeté.** Le cycle propose que les clients enterprise puissent fournir des contraintes custom (`min_review_passes: 3`, `require_security_audit: true`) et que le compiler génère un plan custom.

**Pourquoi :** En V1, on n'a ni la base d'agents ni le volume pour que le plan compiler custom soit fiable. Un client qui demande `require_security_audit: true` et qu'aucun agent security n'est disponible → mauvaise UX. Les presets sont suffisants pour valider le product-market fit. Le mode CUSTOM est un lever V2 une fois qu'on a :
- 50+ agents actifs avec capabilities taggées
- Historique de performance par agent/capability
- Un matching engine avec fallback strategies

**V1 :** 3 presets (Bronze, Silver, Gold). Pas de Platinum, pas de Custom.

### 2.3 ❌ StageRole comme enum on-chain

**Rejeté.** Le cycle propose `role: CODER | REVIEWER | SECURITY | TESTER | OPTIMIZER | CUSTOM` comme champ du Stage on-chain.

**Pourquoi :** Le rôle d'un stage n'a aucune sémantique pour le smart contract. Le contrat n'a pas besoin de savoir si le stage 2 est un "reviewer" ou un "tester" — il a juste besoin de savoir qu'un agent a été assigné, que le timeout n'est pas dépassé, et que l'attestation QG est signée. Le role est metadata off-chain, stocké dans le plan YAML et sur IPFS, pas dans le storage Solidity à $2000/slot.

**Conséquence :** Le Stage on-chain se simplifie :
```solidity
struct Stage {
    uint8 index;
    address assignedAgent;     // set at matching time
    uint256 budgetUSDC;
    uint256 timeoutSeconds;
    StageStatus status;        // PENDING | ACTIVE | COMPLETED | FAILED | SKIPPED
}
```

### 2.4 ❌ `SKIP_IF_BRONZE` comme failureAction

**Rejeté.** Le cycle propose que les QualityGates puissent avoir `failureAction: "SKIP_IF_BRONZE"`, ce qui signifie que le tier influence le comportement runtime du smart contract.

**Pourquoi :** C'est une violation directe de la décision 1.1 (le contrat est agnostique au tier). Si Bronze a moins de quality gates, c'est parce que le **plan compilé** contient moins de stages/gates — pas parce que le contrat skip des gates conditionnellement. Le tier est un input du compiler off-chain, pas du runtime on-chain.

**Action retenue :** Le compiler génère un plan Bronze avec 1-2 stages et 0-1 QG. Le compiler génère un plan Gold avec 3-5 stages et 2-4 QG. Le contrat exécute ce qu'on lui donne sans savoir ce qu'est "Bronze".

### 2.5 ❌ RETRY_ONCE comme logique on-chain en V1

**Rejeté.** Le retry automatique d'un stage implique : re-matching d'un agent (le même ? un autre ?), re-allocation de budget (depuis quelle réserve ?), re-démarrage de timeout. C'est une surface de complexité massive pour V1.

**Pourquoi :** Le retry nécessite un agent disponible, un budget non-épuisé, et une politique claire sur "est-ce qu'on réutilise le même agent ou pas". En V1, si un stage échoue → HALT + refund proportionnel des stages non-exécutés. Le client peut relancer un nouveau workflow. Le retry automatique est V2.

---

## 3. Nouveaux Insights

### 3.1 🆕 Le WorkflowEscrow comme meta-client résout le problème d'identité on-chain

Insight non-trivial : si `WorkflowEscrow` appelle `MissionEscrow.createMission()`, alors **le `msg.sender` de chaque mission de stage est le contrat `WorkflowEscrow`**, pas le client humain. Ça a trois conséquences profondes :

1. **Le client humain n'interagit qu'avec WorkflowEscrow.** Une seule transaction `createWorkflow()` + une seule approbation USDC. Pas de `n` approbations pour `n` stages.

2. **Les agents voient le WorkflowEscrow comme client.** Ils n'ont pas besoin de savoir qu'un humain est derrière. Ça préserve la composabilité — un workflow peut être lancé par un autre agent, pas seulement par un humain.

3. **Le dispute path est à deux niveaux.** Agent dispute le MissionEscrow (sa mission spécifique). Client dispute le WorkflowEscrow (le workflow global). Le WorkflowEscrow doit pouvoir initier des disputes sur les MissionEscrow sous-jacents au nom du client.

**Action requise :** `MissionEscrow` doit avoir un concept de "delegate client" ou le `WorkflowEscrow` doit être whitelisté comme client autorisé. À designer proprement.

### 3.2 🆕 Le budget split est le vrai mécanisme de signaling

Le cycle parle de budget tiers, mais l'insight plus profond est : **la façon dont le budget est réparti entre stages est elle-même un signal de qualité pour les agents.**

Exemple concret sur une Issue à $500 budget :
- Bronze split: `[$500]` → 1 stage, 1 agent prend tout
- Silver split: `[$350, $150]` → coder $350, reviewer $150
- Gold split: `[$250, $100, $80, $70]` → coder, reviewer, tester, security

Le **ratio budget du stage / difficulté perçue** détermine quels agents acceptent le travail. Si le budget reviewer est trop faible ($20 pour reviewer 2000 lignes), aucun agent qualifié ne bid → le matching échoue → le plan est invalid avant même de démarrer.

**Conséquence pour le plan compiler :** Le compiler doit vérifier que chaque stage a un budget au-dessus du **seuil minimum viable** pour le type de travail demandé. Si ce n'est pas le cas, il doit soit réduire le nombre de stages, soit rejeter le plan et demander un budget plus élevé.

### 3.3 🆕 Le timeout cascade est un risque non-adressé

Si un workflow Gold a 4 stages avec chacun un timeout de 24h, le worst case est 96h. Mais le `globalDeadline` du workflow peut être inférieur à `sum(timeouts)` si le client veut le résultat en 48h. 

**Le problème :** Si le stage 1 utilise 20h sur ses 24h autorisées, les stages suivants sont squeezés. Le stage 4 pourrait n'avoir que 4h au lieu de 24h.

**Solution proposée :** Le timeout de chaque stage n'est pas fixe — il est calculé dynamiquement comme `min(stage.maxTimeout, globalDeadline - block.timestamp - sum(remaining_stages.minTimeout))`. Cela signifie que chaque stage a un timeout qui se contracte si les stages précédents trainent.

**Décision :** V1 = timeouts fixes par stage, le compiler s'assure que `sum(timeouts) <= globalDeadline - now` comme invariant pré-déploiement. Le timeout dynamique est V2.

### 3.4 🆕 Le plan compiler off-chain est un chokepoint de centralisation — et c'est OK pour V1

L'architecture proposée est : compilation off-chain → exécution on-chain. Cela signifie que le plan compiler est un single point of trust. Un compiler malveillant pourrait :
- Assigner des agents complices
- Sur-facturer les stages
- Générer des plans sous-optimaux pour maximiser les fees

**Pourquoi c'est acceptable en V1 :** Le client voit le plan compilé avant de le signer et soumettre la transaction. Il peut vérifier le budget split, les agents assignés (si publics), et les timeouts. C'est un modèle "trust but verify" classique. En V2, on peut rendre le compiler vérifiable (ZK proof du matching, ou multiples compilers en compétition).

**Guard-rail V1 :** Le client signe le plan complet dans sa transaction `createWorkflow()`. Il ne peut pas être modifié après soumission. Le contrat vérifie les invariants structurels (pas de stage à $0, pas de timeout à 0, budget sum = total).

---

## 4. PRD Changes Required

### 4.1 Section à CRÉER : `workflow-engine.md`

Nouveau document dans le PRD couvrant :
- Modèle formel du `WorkflowPlan` (version simplifiée vs cycle zd — sans role enum, sans tier awareness on-chain)
- Lifecycle state machine du workflow (CREATED → STAGE_N_ACTIVE → STAGE_N_GATED → ... → COMPLETED | HALTED)
- Interaction pattern WorkflowEscrow ↔ MissionEscrow
- Budget split invariants
- Timeout model (V1: statique, V2: dynamique)

### 4.2 Section à MODIFIER : `smart-contracts.md`

- Ajouter `WorkflowEscrow.sol` au registry des contrats
- Spécifier l'interface : `createWorkflow()`, `advanceStage()`, `haltWorkflow()`, `claimRefund()`
- Spécifier la relation composition avec `MissionEscrow.sol`
- Ajouter le concept de "delegate client" dans `MissionEscrow` pour supporter l'appel depuis `WorkflowEscrow`

### 4.3 Section à MODIFIER : `token-economics.md`

- Définir la formule de burn AGNT en fonction de la complexité du plan (nombre de stages × budget total × risk multiplier)
- Clarifier que le burn se fait au `createWorkflow()`, pas à chaque stage
- Spécifier le mécanisme de rebate si le workflow est HALTED prématurément (burn partiel inversé via mint ? ou pas de rebate ?)

### 4.4 Section à MODIFIER : `tier-system.md` (ou à créer)

- Définir les 3 presets V1 : Bronze (1 stage, 0 QG), Silver (2 stages, 1 QG), Gold (3-4 stages, 2-3 QG)
- Spécifier les paramètres de chaque preset comme input du compiler, pas comme logique on-chain
- Expliquer que les presets sont des raccourcis UX, pas des entités architecturales

### 4.5 Section à MODIFIER : `quality-gates.md` (ou à créer)

- Modèle d'attestation off-chain + commitment on-chain
- Format de l'attestation (hash, score, sig, timestamp)
- Storage du rapport complet (IPFS avec pinning SLA)
- Dispute flow quand un client challenge une attestation QG
- Seuil de score configurable par gate dans le plan

### 4.6 Section à MODIFIER : `dispute-resolution.md`

- Distinguer disputes de mission (agent vs client sur un stage) et disputes de workflow (client vs plateforme sur le plan global)
- Ajouter le two-tier dispute model (insight 3.1)
- Spécifier que `WorkflowEscrow` peut initier des disputes sur `MissionEscrow` au nom du client

---

## 5. Implementation Priority

### Phase 1 : Foundation (Semaine 1-2)

| # | Composant | Effort | Dépendance | Livrable |
|---|-----------|--------|------------|----------|
| 1 | `MissionEscrow` delegate client support | S | Aucune | PR: ajouter `authorizedCaller` mapping + modifier, tests |
| 2 | `WorkflowEscrow.sol` — structures de données | M | #1 | PR: structs WorkflowPlan, Stage, QualityGateAttestation, state enum |
| 3 | `WorkflowEscrow.sol` — `createWorkflow()` | M | #2 | PR: validation invariants, USDC lock total, stockage plan, event |
| 4 | Tests Foundry Phase 1 | M | #1-3 | 8-10 tests: création valide, rejection invariants violés, lock funds |

**Milestone :** Un workflow peut être créé on-chain avec N stages, le budget total est locké, chaque stage est enregistré mais non-démarré.

### Phase 2 : Execution (Semaine 3-4)

| # | Composant | Effort | Dépendance | Livrable |
|---|-----------|--------|------------|----------|
| 5 | `WorkflowEscrow.sol` — `advanceStage()` | L | #3 | PR: transition stage, appel MissionEscrow.createMission() pour stage suivant, paiement stage complété |
| 6 | `WorkflowEscrow.sol` — QG attestation verification | M | #5 | PR: vérification signature + score threshold, pass/fail logic |
| 7 | `WorkflowEscrow.sol` — `haltWorkflow()` + refund | M | #5 | PR: halt, calcul refund proportionnel, USDC release |
| 8 | Tests Foundry Phase 2 | L | #5-7 | 12-15 tests: advance happy path, QG fail �� halt, timeout → halt, refund calcul |

**Milestone :** Un workflow complet peut s'exécuter : stage 1 → QG pass → stage 2 → QG pass → complete → paiements distribués. Et inversement : stage 1 → QG fail → halt → refund.

### Phase 3 : Plan Compiler (Semaine 5-6)

| # | Composant | Effort | Dépendance | Livrable |
|---|-----------|--------|------------|----------|
| 9 | `PlanCompiler` service off-chain | L | Aucune (parallélisable) | Service TypeScript: input (taskSpec, budget, tierPreset) → output WorkflowPlan |
| 10 | Preset definitions (Bronze/Silver/Gold) | S | #9 | Config YAML des 3 presets avec paramètres |
| 11 | Budget split optimizer | M | #9 | Algorithme de répartition budget par stage basé sur rôle estimé et seuils minimum |
| 12 | API endpoint `POST /workflows/compile` | M | #9-11 | Endpoint REST retournant un WorkflowPlan signé prêt à soumettre on-chain |

**Milestone :** Un client peut soumettre une Issue + budget + tier → recevoir un plan compilé → soumettre on-chain en une transaction.

### Phase 4 : Integration (Semaine 7-8)

| # | Composant | Effort | Dépendance | Livrable |
|---|-----------|--------|------------|----------|
| 13 | Agent matching integration | L | #9, agents registry | Le compiler assigne des agents réels aux stages basé sur capabilities + reputation |
| 14 | IPFS integration pour QG reports | M | #6 | Upload rapport review → IPFS → hash on-chain |
| 15 | Frontend workflow creation flow | L | #12 | UI: select Issue → select tier → preview plan → approve USDC → create workflow |
| 16 | E2E test: workflow complet Bronze | L | #1-15 | Test end-to-end: Issue → compile → create → execute → pay |

**Milestone :** Un workflow Bronze (1 stage) fonctionne end-to-end en production. C'est le MVP shippable.

---

## 6. Next Cycle Focus

### Question primaire du Cycle ze :

> **Comment le WorkflowEscrow gère-t-il le paiement conditionnel inter-stages quand l'escrow total est locké dès le début ?**

C'est la question d'implémentation la plus critique non-résolue. Deux designs en tension :

**Option A — Lock total, release séquentiel :**
Le budget total est locké dans `WorkflowEscrow` au `createWorkflow()`. À chaque `advanceStage()`, le budget du stage complété est transféré à l'agent depuis le pool locké. Si halt → le reste est refundé au client.

- ✅ Simple, une seule transaction USDC du client
- ❌ Le `WorkflowEscrow` détient potentiellement $10K+ pendant des jours → risque de smart contract amplifié

**Option B — Lock par stage, progressive :**
Seul le budget du stage actif est locké dans `MissionEscrow`. Le reste est dans le wallet du client avec une approbation USDC suffisante. À chaque avancement, le `WorkflowEscrow` pull le budget du stage suivant.

- ✅ Exposition réduite à chaque instant
- ❌ Le client peut révoquer l'approbation entre deux stages → workflow bloqué
- ❌ Multiple transactions client-side

**Option C — Hybrid : lock total dans WorkflowEscrow, mais transfert au MissionEscrow par stage :**
Le client lock tout dans `WorkflowEscrow`. Ce dernier ne transfert au `MissionEscrow` que le budget du stage actif. Les fonds restent dans `WorkflowEscrow` entre deux stages.

- ✅ Une seule approbation client
- ✅ Exposition du `MissionEscrow` limitée à un stage
- ⚠️ Le `WorkflowEscrow` reste un gros pot → audit critique

**Le cycle ze doit trancher entre A, B, et C** en modélisant les scénarios de dispute, de timeout, et de refund partiel pour chaque option. C'est le cœur du design smart contract.

### Question secondaire :

> **Comment intégrer le burn AGNT au lifecycle du workflow — au create, à chaque stage, ou au complete ?**

Le burn au `createWorkflow()` est le plus simple mais pénalise le client si le workflow halt. Le burn au `complete` est le plus fair mais le client peut gripper le système (créer des workflows qu'il n'a pas l'intention de finir pour geler des agents sans burn).

---

## 7. Maturity Score

### Score : 6.5 / 10

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Modèle conceptuel** | 8/10 | Le "plan compiler" est un insight fort et différenciant. La séparation compiler off-chain / executor on-chain est architecturalement saine. |
| **Design smart contract** | 6/10 | La composition WorkflowEscrow → MissionEscrow est validée en principe mais non-implémentée. Le "delegate client" pattern n'est pas encore designé. Le flow de fonds inter-stages (question cycle ze) est non-tranché. |
| **Quality Gates** | 6/10 | Le modèle attestation off-chain + commitment on-chain est correct mais le dispute flow n'est pas spécifié au-delà de "V2: Kleros/UMA". Que se passe-t-il en V1 quand un client dispute une attestation QG ? Qui tranche ? |
| **Token economics workflow** | 4/10 | Le burn AGNT par complexité de plan est mentionné mais non-formulé. Aucune simulation de unit economics par tier. On ne sait pas si un workflow Gold est rentable pour la plateforme après burn. |
| **Implementation readiness** | 7/10 | La roadmap 8 semaines est réaliste. Le socle MissionEscrow 14/14 tests est solide. La Phase 1 peut commencer immédiatement. |
| **V1 scope clarity** | 7/10 | Les rejects sont clairs (pas de CUSTOM, pas de RETRY, pas de tier on-chain). On sait ce qu'on ne build pas. Il reste des zones grises (dispute QG V1, flow de fonds, AGNT burn timing). |

**Synthèse :** On est sorti de la phase "concept" et entré en phase "pre-implementation". Le modèle mental est solide, la composition smart contract est identifiée, les rejects sont tranchés. Mais trois questions bloquantes restent ouvertes (flow de fonds inter-stages, dispute QG en V1, AGNT burn formula) et doivent être résolues avant d'écrire le premier line de Solidity du `WorkflowEscrow`. Le cycle ze doit les trancher.

**Critère pour passer à 8/10 :** Le cycle ze tranche le flow de fonds (Option A/B/C), spécifie le dispute QG V1 (même si c'est "admin multisig tranche manuellement"), et pose une formule de burn AGNT même simplifiée. Avec ça, on peut commencer à coder Phase 1.