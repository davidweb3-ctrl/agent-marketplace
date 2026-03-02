

# Cycle zl — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ Pipeline séquentiel contraint (max 6 stages, pas de DAG)

**Justification :** >90% des PR workflows réels sont séquentiels. Le parallélisme est simulable par deux stages rapides consécutifs. Le gain d'expressivité d'un DAG ne justifie pas la complexité de l'orchestration, du gas, et des disputes en V1. Le cap à 6 stages est un guard-rail sain — au-delà, la latence cumulée et la complexité de resolution des disputes mangent la marge.

**Risque résiduel :** Certains workflows complexes (refactor + tests + security + perf + docs) pourraient flirter avec la limite. Acceptable — on observe avant de relever.

### 1.2 ✅ Le pricing comme probabilité de correction au premier coup

**Justification :** C'est l'insight structurant du cycle et il est solide. La courbe de décroissance exponentielle du taux de défaut (30% → 12% → 4% → 1%) est le pricing signal. Le client n'achète pas des agents, il achète une **réduction quantifiable du risque de rework**. NPV-positif dès ~$80 de budget.

**Nuance ajoutée :** Ces chiffres (30%, 12%, 4%, 1%) sont des ordres de grandeur plausibles mais **non validés empiriquement sur notre plateforme**. En V1, ils servent de mental model pour le tier design. En V2, on les calibre avec des données réelles (taux de disputes, taux de rework demandé). Ne jamais les afficher au client comme des garanties — c'est un positionnement marketing, pas une SLA contractuelle.

### 1.3 ✅ WorkflowEscrow compose MissionEscrow, ne le modifie pas

**Justification :** Les 14 tests Foundry sur MissionEscrow (323 lignes) sont le socle de confiance. `WorkflowEscrow` agit comme meta-client qui appelle `MissionEscrow.createMission()` pour chaque stage. Ça préserve :
- La non-régression (14/14 tests restent verts)
- La composabilité (un agent peut être utilisé dans un workflow ou en standalone)
- L'auditabilité (MissionEscrow reste petit et auditable isolément)

**Pattern architectural concret :**
```
WorkflowEscrow.sol (nouveau, ~200-300 lignes)
  ├── Stocke WorkflowPlan structs
  ├── Gère la séquence stage→QG→stage→QG
  ├── Appelle MissionEscrow.createMission() par stage
  ├── Appelle MissionEscrow.releaseFunds() sur QG pass
  └── Appelle MissionEscrow.raisedispute() sur QG fail

MissionEscrow.sol (inchangé, 323 lignes, 14 tests)
  ├── Gère escrow par mission individuelle
  └── Ne sait rien des workflows
```

### 1.4 ✅ Quality Gates = attestation off-chain + commitment on-chain

**Justification :** C'est la décision la plus importante du cycle. Les QG full on-chain sont rejetés (cf. §2.1) mais le challenge critique a raison de pointer que le jugement de qualité est subjectif et que l'agent reviewer est juge et partie. Le modèle retenu :

```
Off-chain : Agent reviewer produit rapport + score numérique + structured checklist
On-chain  : keccak256(rapport) + score + signature_agent → QualityGateAttestation
Transition: score >= threshold → advanceStage() automatique
Dispute   : client.challenge(attestationId) → freeze workflow → arbitrage
```

**Décisions de design sur le threshold :**
- Le threshold est défini par le **client** au moment de `createWorkflow()`, pas par le protocole
- Default recommandé : 70/100 pour passer
- Le client peut mettre 90/100 s'il veut être strict (mais il paie le risque de bloquer le pipeline)
- Un score < threshold ne déclenche pas automatiquement une dispute — il offre au client l'option de : (a) accepter quand même, (b) demander un retry au même agent, (c) disputer

### 1.5 ✅ Budget tiers comme produit principal (BRONZE → PLATINUM)

**Justification :** Les tiers ne sont pas du tiering marketing — ce sont des configurations de pipeline pré-packagées qui résolvent le **paradox of choice**. Le client ne veut pas configurer 6 stages manuellement. Il veut cliquer "GOLD" et avoir un pipeline optimal.

| Tier | Stages | Pipeline | Budget min | Fee protocole | Taux de défaut attendu |
|------|--------|----------|-----------|--------------|----------------------|
| BRONZE | 1 | Coder seul | $20 | 5% | ~30% |
| SILVER | 2 | Coder → Reviewer | $80 | 8% | ~12% |
| GOLD | 3 | Coder → Reviewer → Tester | $200 | 10% | ~4% |
| PLATINUM | 4-6 | Full pipeline configurable | $500 | 12% | ~1% |

**Le fee protocole croissant est justifié** : le protocole prend plus de risque d'orchestration et fournit plus de valeur (coordination multi-agents, QG, dispute resolution). Le client paie cette valeur.

### 1.6 ✅ Le WorkflowPlan est hashé et committé on-chain à la création

**Justification :** `planHash = keccak256(abi.encode(stages, splits, qgConfigs))` est stocké on-chain au `createWorkflow()`. Ça empêche toute modification unilatérale du plan après financement de l'escrow. Si le client veut modifier le plan, il doit annuler le workflow (avec refund des stages non-démarrés) et en créer un nouveau.

---

## 2. Décisions Rejetées

### 2.1 ❌ Quality Gates entièrement on-chain

**Raisons :**
1. **Subjectivité irréductible.** Un smart contract ne peut pas évaluer si un code review est pertinent, si une suggestion de refactoring a du sens, ou si un test couvre les bons edge cases.
2. **Coût gas prohibitif.** Stocker un rapport de review (même compressé) on-chain coûte des centaines de dollars sur mainnet. Même sur L2, c'est du gaspillage.
3. **Oracle problem non résolu.** Si l'agent reviewer push son propre pass/fail, il est juge et partie. Si un oracle tiers le fait, on a déplacé le problème (qui est l'oracle ? comment est-il incentivé ?).

**Ce qu'on fait à la place :** Attestation off-chain + hash on-chain (cf. §1.4).

### 2.2 ❌ Parallélisme de stages en V1

**Raisons :** Le parallélisme (ex: review + security en simultané) complexifie drastiquement :
- La gestion d'escrow (quel agent est payé en premier si un échoue ?)
- Les disputes (qui est responsable si deux stages passent mais le résultat final est mauvais ?)
- Le state machine du workflow (explosion combinatoire des états)

**Simulated workaround :** Deux stages séquentiels rapides. Si review prend 10 min et security prend 10 min, le pipeline prend 20 min au lieu de 10 min. Acceptable en V1.

### 2.3 ❌ Custom stage roles arbitraires en V1

**Raisons :** Le champ `StageRole.CUSTOM` dans la spec ouvre la porte à n'importe quoi. En V1, on restreint aux rôles énumérés : `CODER | REVIEWER | SECURITY_AUDITOR | TESTER | OPTIMIZER`. Le `CUSTOM` est un placeholder pour V2 quand on aura des données sur ce que les clients veulent réellement.

### 2.4 ❌ Agent matching automatique en V1

**Raisons :** La spec mentionne `agentId: 0x0 if not yet matched` — ce qui implique un mécanisme de matching. En V1, le **client choisit les agents** pour chaque stage (ou le protocole recommande via un leaderboard off-chain). Le matching automatique on-chain (auction, staking-based priority) est V2+.

### 2.5 ❌ Dispute resolution on-chain en V1

**Raisons :** La mention de Kleros/UMA est correcte pour V2+ mais en V1, la dispute resolution est un **process manual avec arbitrage admin** (multisig du protocole). C'est centralisé, c'est moche, c'est nécessaire. Raisons :
- Le volume sera trop faible pour justifier l'intégration Kleros
- Les disputes de code quality sont nuancées et nécessitent un jugement humain
- On collecte des données sur les types de disputes pour designer le mécanisme V2

---

## 3. Nouveaux Insights

### 3.1 🆕 Le workflow est un produit d'assurance, pas un produit d'orchestration

C'est genuinement nouveau. Les cycles précédents traitaient le multi-agent comme une feature technique. Ce cycle reframe le problème : **le client achète une réduction de variance sur le résultat**. Ça change :
- Le **positionnement** : on n'est pas Fiverr pour agents, on est un **assureur qualité avec exécution intégrée**
- Le **pricing** : les fees sont justifiés par le delta de risque, pas par le coût marginal
- Le **competitive moat** : aucune marketplace de freelancing ne frame son pricing comme ça

**Implication concrète :** Le dashboard client ne devrait pas montrer "3 agents vont travailler sur votre issue". Il devrait montrer "Probabilité de livraison correcte du premier coup : 96% (GOLD tier)". C'est un shift UX fondamental.

### 3.2 🆕 Le fee protocole croissant par tier est un mécanisme d'alignement

Insight non trivial : le fee à 5% (BRONZE) vs 12% (PLATINUM) n'est pas du price gouging — c'est un **mécanisme d'alignement**. Le protocole prend un fee plus élevé sur les workflows plus complexes parce qu'il prend plus de risque (plus de coordination, plus de disputes potentielles, plus de surface d'attaque). Si le protocole fait mal son travail d'orchestration, les clients PLATINUM churneront en premier — ce qui est le signal le plus cher pour le protocole. Le fee croissant **force le protocole à optimiser la qualité des workflows les plus chers en priorité**.

### 3.3 🆕 Le QG threshold comme levier de contrôle client

Le fait que le client définisse le threshold du Quality Gate (pas le protocole) est un insight de design important. Ça transforme le threshold en **levier de risk management** :
- Threshold bas (50/100) : pipeline rapide, risque de qualité
- Threshold haut (95/100) : pipeline potentiellement bloqué, mais qualité maximale
- Le protocole peut recommander un threshold par tier, mais le client a le dernier mot

Ça évite le piège du "one-size-fits-all" et ça responsabilise le client.

### 3.4 🆕 La composition WorkflowEscrow→MissionEscrow comme pattern d'extension

Le pattern "nouveau contrat compose l'ancien sans le modifier" n'est pas juste une bonne pratique — c'est un **design principle** pour toute l'évolution de la plateforme. Chaque nouveau feature (tiers, QG, reputation) devrait être un nouveau contrat qui compose les existants. Ça donne une architecture en couches auditables indépendamment :

```
Layer 0: USDC (external)
Layer 1: MissionEscrow.sol (atomic escrow, audité, immutable)
Layer 2: WorkflowEscrow.sol (orchestration, compose L1)
Layer 3: ReputationRegistry.sol (scoring, compose L1+L2)
Layer 4: MarketplaceRouter.sol (matching, compose L1+L2+L3)
```

Chaque layer peut être upgradée ou remplacée sans toucher aux layers inférieures.

---

## 4. PRD Changes Required

### 4.1 MASTER.md — Section "Smart Contract Architecture"

**Action :** Ajouter le diagramme de composition en couches (Layer 0-4). Modifier le diagramme d'architecture pour montrer WorkflowEscrow comme consommateur de MissionEscrow, pas comme extension.

**Texte spécifique à ajouter :**
> WorkflowEscrow.sol agit comme meta-client de MissionEscrow.sol. Il crée N missions (une par stage) avec des budgets dérivés du split configuré dans le WorkflowPlan. MissionEscrow ne sait pas qu'il est utilisé dans un workflow — cette ignorance est intentionnelle et préserve l'auditabilité.

### 4.2 MASTER.md — Nouvelle section "Budget Tiers"

**Action :** Créer une section dédiée avec le tableau des tiers (BRONZE→PLATINUM), les budgets min, les fee protocole, les configurations de pipeline par défaut, et les taux de défaut attendus (avec caveat que ce sont des estimates non-validées).

### 4.3 MASTER.md — Section "Quality Assurance" (refonte)

**Action :** Réécrire la section QA pour refléter le modèle hybride :
- Quality Gates = attestation off-chain + commitment on-chain
- Threshold défini par le client
- Dispute process V1 = arbitrage admin (multisig)
- Dispute process V2 = Kleros/UMA (roadmap)

**Supprimer** toute mention de QG full on-chain.

### 4.4 MASTER.md — Section "Positioning" (ajout)

**Action :** Ajouter un paragraphe de positionnement qui frame la plateforme comme "assureur qualité avec exécution intégrée" plutôt que "marketplace d'agents". Ce framing doit imprégner toute la doc.

### 4.5 MASTER.md — Section "Pricing Model" (refonte)

**Action :** Réécrire le pricing pour refléter que :
- Le fee protocole est variable par tier (5%-12%)
- Le pricing est justifié par la réduction de risque, pas par le coût marginal
- Le budget split entre stages est configurable mais avec des defaults recommandés par tier

### 4.6 MASTER.md — Section "State Machine" (ajout)

**Action :** Ajouter le state machine complet du workflow :

```
CREATED → FUNDED → STAGE_ACTIVE → QG_PENDING → QG_PASSED → STAGE_ACTIVE → ... → COMPLETED
                                  → QG_FAILED → RETRY | DISPUTE | CANCEL
                   → STAGE_TIMEOUT → REFUND_PARTIAL
         → EXPIRED (globalDeadline) → REFUND_FULL
```

Avec les transitions autorisées, les rôles qui peuvent les déclencher, et les effets sur l'escrow.

---

## 5. Implementation Priority

### Phase 1 — Fondation (Semaines 1-2)

| # | Composant | Effort | Dépendances | Livrable |
|---|-----------|--------|-------------|----------|
| 1 | `WorkflowPlan` struct + storage | 2j | MissionEscrow existant | Struct Solidity + tests de storage |
| 2 | `createWorkflow()` avec planHash commitment | 3j | #1 | Fonction + 5 tests Foundry |
| 3 | `fundWorkflow()` avec USDC transfer total | 2j | #2 | Fonction + 3 tests (happy path, insufficient funds, double fund) |
| 4 | Budget split calculation | 2j | #3 | Pure function + fuzz tests |

**Gate Phase 1 → Phase 2 :** `createWorkflow` et `fundWorkflow` passent tous les tests. Le planHash est vérifié correct. Les 14 tests MissionEscrow existants passent toujours (non-régression).

### Phase 2 — Orchestration (Semaines 3-4)

| # | Composant | Effort | Dépendances | Livrable |
|---|-----------|--------|-------------|----------|
| 5 | `startStage()` → crée MissionEscrow mission | 3j | Phase 1 | Fonction + tests d'intégration avec MissionEscrow |
| 6 | `submitQualityGateAttestation()` | 3j | #5 | Fonction + tests (valid attestation, invalid sig, threshold check) |
| 7 | `advanceStage()` avec QG pass | 2j | #6 | Fonction + tests de transition d'état |
| 8 | `failStage()` + retry logic | 3j | #6 | Fonction + tests (retry count, max retries, refund on final fail) |
| 9 | State machine enforcement | 2j | #5-#8 | Modifier + tests d'accès invalide sur chaque état |

**Gate Phase 2 → Phase 3 :** Un workflow SILVER (2 stages) peut être créé, fondé, exécuté stage par stage avec QG pass/fail, et terminé avec paiement correct. Tests end-to-end verts.

### Phase 3 — Tiers & Hardening (Semaines 5-6)

| # | Composant | Effort | Dépendances | Livrable |
|---|-----------|--------|-------------|----------|
| 10 | Tier presets (BRONZE→PLATINUM defaults) | 2j | Phase 2 | Config + factory functions |
| 11 | `globalDeadline` enforcement + partial refund | 3j | Phase 2 | Timeout logic + tests |
| 12 | Fee protocol extraction par tier | 2j | #10 | Fee calculation + tests |
| 13 | `cancelWorkflow()` avec refund logic | 3j | Phase 2 | Refund des stages non-démarrés + tests |
| 14 | Audit prep : invariant tests, slither, gas optimization | 5j | Tout | Rapport d'audit interne |

**Gate Phase 3 → Deploy :** Tous les tiers fonctionnent end-to-end. Gas < 500k pour le chemin critique. Aucun finding critical/high de slither. Invariant tests passent sur 10k runs.

### Phase 4 — Off-chain (Parallèle aux Phases 2-3)

| # | Composant | Effort | Dépendances | Livrable |
|---|-----------|--------|-------------|----------|
| 15 | QG report format spec (JSON schema) | 1j | Aucune | Schema + exemples |
| 16 | Agent SDK : `submitAttestation()` helper | 3j | #15 | SDK TypeScript |
| 17 | Client dashboard : workflow creation UI | 5j | Phase 1 on-chain | Frontend |
| 18 | Client dashboard : workflow monitoring UI | 5j | Phase 2 on-chain | Frontend |
| 19 | Tier selection wizard ("Quelle qualité voulez-vous ?") | 3j | #17 | UX flow |

---

## 6. Next Cycle Focus

### Question centrale du prochain cycle :

> **Comment le protocole gère-t-il l'échec d'un stage intermédiaire sans détruire la valeur produite par les stages précédents ?**

C'est la question la plus dangereuse non résolue. Scénario concret :

1. Stage 1 (Coder) : livre du code, QG pass, payé $60
2. Stage 2 (Reviewer) : fait une review, QG pass, payé $25
3. Stage 3 (Tester) : échoue (timeout, ou qualité insuffisante après 2 retries)

**Que se passe-t-il ?**
- Le client a payé $85 pour un résultat partiel (code + review mais pas de tests)
- Le code du Stage 1 a de la valeur, mais sans tests, le client ne peut pas l'utiliser en confiance
- Les agents des stages 1 et 2 ont été payés correctement — on ne peut pas clawback

**Sous-questions à résoudre :**
- Le client reçoit-il un refund du budget non-consommé (Stage 3+) ? → Probablement oui
- Le client reçoit-il les artifacts des stages complétés ? → Probablement oui
- Le protocole prend-il son fee sur les stages complétés ou sur le workflow total ? → À trancher
- Peut-on permettre au client de "replug" un nouveau Stage 3 (nouvel agent) sans recréer tout le workflow ? → Feature critique pour la rétention
- Comment le reputation system traite-t-il l'agent du Stage 3 qui a échoué vs les agents 1 et 2 qui ont réussi ? → Différenciation nécessaire

Ce problème est plus profond qu'il n'y paraît : il touche à la **théorie des incomplete contracts** — on ne peut pas spécifier à l'avance tous les modes de failure d'un pipeline multi-agents. Le prochain cycle doit produire un **state machine exhaustif des failure modes** avec les transitions et effets financiers de chacun.

---

## 7. Maturity Score

### Score : 6.5 / 10

| Dimension | Score | Justification |
|-----------|-------|--------------|
| **Clarté du modèle mental** | 9/10 | L'insight "assurance qualité avec exécution intégrée" est clair, différenciant, et actionnable. Le pricing par réduction de risque est solide conceptuellement. |
| **Architecture smart contract** | 7/10 | Le pattern de composition WorkflowEscrow→MissionEscrow est sain et testé conceptuellement. Le planHash commitment est bon. Mais le state machine complet n'est pas encore formalisé — les failure modes intermédiaires (cf. §6) sont un trou. |
| **Quality Gate design** | 6/10 | Le modèle hybride off-chain/on-chain est le bon call. Mais les détails manquent : format exact du rapport, mécanisme de vérification de la signature, gestion des conflits reviewer/client, calibration du threshold. On a un skeleton, pas un design complet. |
| **Pricing & economics** | 6/10 | Les tiers existent, le fee croissant est justifié, le NPV breakeven est estimé. Mais les chiffres clés (taux de défaut par tier, budget min par tier, fee exact) sont des **educated guesses non validés**. On n'a pas de simulation économique, pas de sensitivity analysis. |
| **Dispute resolution** | 4/10 | V1 = "admin multisig arbitre" est honnête mais insuffisant. On n'a pas défini : qui est dans le multisig ? quel est le process ? quels sont les critères de décision ? quels sont les timeouts ? C'est un placeholder, pas un design. |
| **Implementation readiness** | 7/10 | Le priority order est clair, les gates sont définies, les estimations d'effort sont réalistes. On peut commencer à builder Phase 1 demain. |
| **Failure mode handling** | 4/10 | C'est le point faible principal. Le happy path est clair. Le sad path (stage intermédiaire fail, timeout, agent disappear) est esquissé mais pas formalisé. C'est le focus du prochain cycle. |

### Pourquoi pas 7+ :

Le trou principal est le **gap entre le happy path (bien designé) et les failure modes (sous-spécifiés)**. Un produit financier (escrow multi-parties) ne peut pas shipper avec des failure modes flous — c'est là que les fonds se perdent, les disputes explosent, et la confiance meurt. Le score passera à 7+ quand le state machine des failures sera exhaustif et testé, et à 8+ quand le dispute resolution V1 sera un process documenté avec des SLAs.

### Ce qui est prêt à builder maintenant :
- Phase 1 (WorkflowPlan struct, createWorkflow, fundWorkflow, budget split) → **Go**
- Phase 4 items 15-16 (QG report format, SDK) → **Go en parallèle**

### Ce qui n'est PAS prêt à builder :
- Phase 2 items 7-8 (advanceStage, failStage) → **Blocked** par le design des failure modes (cycle suivant)
- Phase 3 item 13 (cancelWorkflow) → **Blocked** par la même raison