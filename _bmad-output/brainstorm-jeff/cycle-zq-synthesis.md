

# Cycle zq — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ "Le budget achète des adversaires, pas du compute"

**Justification :** C'est le positionnement stratégique le plus défendable identifié à ce jour. C'est une insight produit, pas une insight technique. Elle dicte :
- Le pricing (on price la _couverture de risque_, pas les tokens LLM)
- Le messaging (ce n'est pas un freelance marketplace, c'est un _verification pipeline_)
- La défendabilité (un concurrent doit recréer le réseau d'agents adversariaux, pas juste appeler GPT-5)

**Implication concrète :** Le tier BRONZE n'est pas un produit "dégradé". C'est un produit avec une probabilité de défaut résiduel plus élevée, et le client en est informé explicitement (risk disclosure). Ça reframe le upsell comme de la gestion de risque, pas de la vente de features.

### 1.2 ✅ Pipeline séquentiel strict en V1

**Justification :** L'argument est terminant. Le séquentiel est un sous-cas du DAG — la migration est additive. Le DAG en V1 est un piège d'over-engineering dont on ne sort pas sans refactor structural.

**Guard-rail durci :** Max 6 stages. Pas "environ 6" — exactement `uint8` plafonné à 6 dans le contrat avec un `require(stages.length <= MAX_STAGES)`. La raison n'est pas technique, elle est économique : au-delà de 6 stages, le coût de coordination dépasse la valeur marginale de vérification.

### 1.3 ✅ WorkflowEscrow compose MissionEscrow (pas d'héritage)

**Justification :** Composition > héritage pour trois raisons :
1. Les 14 tests Foundry existants restent verts sans toucher une ligne
2. `WorkflowEscrow` agit comme meta-client de `MissionEscrow` — chaque stage = un `createMission()` avec le workflow comme `msg.sender`
3. Upgrade path propre : on peut upgrader WorkflowEscrow sans toucher l'escrow de base

**Pattern retenu :**
```
WorkflowEscrow.sol (nouveau)
  │
  ├── compose ────► MissionEscrow.sol (existant, inchangé)
  │                   └── 14/14 tests verts ✅
  │
  ├── createWorkflow() → crée N missions séquentielles
  ├── advanceStage()   → valide gate N, déclenche mission N+1
  └── failStage()      → halt pipeline, redistribute funds
```

### 1.4 ✅ Quality Gates = attestation off-chain + commitment on-chain

**Justification :** L'argument du cycle est correct et complété ici avec la mécanique précise :

| Couche | Ce qui s'y passe | Données |
|--------|-------------------|---------|
| **Off-chain** | Agent reviewer exécute la review, produit un rapport structuré, calcule un score | Rapport complet (markdown + structured data) |
| **IPFS** | Rapport pinné, CID obtenu | `reportCID: bytes32` |
| **On-chain** | Attestation signée : `hash(reportCID, score, pass, workflowId, gateIndex)` + signature EIP-712 | ~200 bytes, ~45K gas |
| **Dispute** | Client challenge l'attestation → timer + arbitrage | Rapport IPFS révélé, arbitre tranche |

**Le score threshold est configurable par tier**, pas par le reviewer :
- BRONZE : pas de gate (ou gate à 40/100)
- SILVER : 1 gate, threshold 60
- GOLD : 2 gates, threshold 70
- PLATINUM : 3+ gates, threshold 80, reviewers multiples

### 1.5 ✅ Architecture 3 couches Client → Workflow → Mission[]

**Justification :** Saine, validée, pas de débat. Le Workflow est l'entité d'orchestration. La Mission est l'entité d'exécution atomique. Le client interagit uniquement avec le Workflow.

---

## 2. Décisions Rejetées

### 2.1 ❌ Quality Gates entièrement on-chain

**Rejeté — confirmé et renforcé.** L'argument initial est correct mais incomplet. Voici les trois raisons terminantes :

1. **Oracle problem non résolu :** L'agent reviewer qui pousse `pass = true` on-chain est juge et partie. Sans mécanisme de dispute, c'est du rubber-stamping. La review n'a de valeur que si elle est _challengeable_, ce qui requiert que le rapport complet soit accessible (→ IPFS, pas on-chain).

2. **Coût prohibitif :** Un rapport de code review structuré fait 2-10 KB. À ~640 gas/byte pour calldata, stocker un rapport de 5 KB coûte ~3.2M gas ≈ $8-15 sur L2. Pour un workflow GOLD avec 3 gates, c'est $24-45 de gas juste pour les rapports. C'est > 5% du budget d'un workflow à $500. Inacceptable.

3. **Subjectivité irréductible :** Un smart contract ne peut pas évaluer si "ce code review a identifié les vrais problèmes". Le pass/fail on-chain n'a de sens que comme _recording_ d'une décision prise ailleurs, pas comme la décision elle-même.

### 2.2 ❌ DAG arbitraire en V1

**Rejeté — confirmé.** Argument additionnel : un DAG introduit le problème de **blame attribution multi-branch**. Si le stage C dépend de A et B, et que C échoue, qui est responsable ? A ? B ? Les deux ? Le pipeline séquentiel rend le blame trivial : c'est toujours le stage N ou le gate N-1 qui a failli.

### 2.3 ❌ Le WorkflowEscrow comme contrat séparé qui hérite de MissionEscrow

**Rejeté.** L'héritage Solidity crée un couplage qui rend les upgrades impossibles sans toucher le contrat de base. La composition via appels externes préserve l'indépendance des deux contrats et permet des proxy patterns séparés.

### 2.4 ❌ Tier-specific LLM model routing (implicite dans la proposition)

**Rejeté proactivement.** Le cycle ne le mentionne pas explicitement mais le piège existe : associer BRONZE = GPT-4o-mini, GOLD = Claude Opus. C'est une erreur de positionnement. Les tiers achètent de la _vérification_, pas du _compute_. Un agent BRONZE peut utiliser Claude Opus s'il le veut — son coût est son problème. Le marketplace ne dicte pas les modèles, il dicte les workflow structures.

---

## 3. Nouveaux Insights

### 3.1 🆕 Le rework tax comme justification NPV du pricing

**Nouveau et puissant.** L'argument NPV est le suivant :

```
Coût moyen de rework sur une feature dev (source: DORA, Stripe surveys) : 30-40% du coût initial
Feature typique : $2,000 en effort dev
Rework cost attendu sans vérification : $600-800

Workflow GOLD à $500 avec 80% de réduction du rework :
  Rework résiduel : $120-160
  Économie nette : $600 - $500 - $140 (rework résiduel moyen) = -$40 à +$260

→ Break-even si le taux de rework sans vérification > 25%
→ NPV-positif dès la première mission pour toute feature > $1,500
```

**Implication produit :** Le pricing du tier GOLD ne doit PAS être présenté comme un coût mais comme une prime d'assurance. Le dashboard client doit afficher le "rework avoided" estimé.

### 3.2 🆕 Le score threshold comme levier de pricing, pas de qualité

Le threshold n'est pas un indicateur absolu de qualité — c'est un **commitment contractuel** du marketplace envers le client. Un threshold de 70 signifie : "nous garantissons qu'au moins un reviewer adversarial indépendant a scoré ce livrable ≥ 70/100, et voici son attestation vérifiable." C'est un SLA, pas un jugement esthétique.

**Implication :** Le threshold doit être calibré empiriquement avant le launch. Il faut un dataset de 50-100 reviews scorées pour établir la distribution des scores et fixer des thresholds qui ne soient ni rubber-stamps (tout passe) ni bloquants (rien ne passe).

### 3.3 🆕 Le Workflow comme meta-client de MissionEscrow

Ce pattern a une implication subtile mais importante : **le WorkflowEscrow contract est le `client` du point de vue de MissionEscrow**, pas l'humain qui a créé le workflow. Cela signifie :

- Le WorkflowEscrow détient les USDC et les distribue stage par stage
- L'humain ne peut pas court-circuiter le pipeline en approuvant directement une mission
- Les fonds sont lock dans le WorkflowEscrow, pas dans les missions individuelles (les missions sont funded stage par stage à mesure que le pipeline avance)

C'est un **progressive escrow pattern** : les fonds descendent dans le pipeline comme l'eau dans des écluses. Chaque gate ouvre l'écluse suivante.

```
[Client USDC] ──deposit──► [WorkflowEscrow]
                                │
                    Gate 0 pass │──fund──► [Mission 1: Coder]     ──complete──► payout
                                │
                    Gate 1 pass │──fund──► [Mission 2: Reviewer]  ──complete──► payout
                                │
                    Gate 2 pass │──fund──► [Mission 3: Auditor]   ──complete──► payout
```

**Avantage :** Si le pipeline échoue au stage 2, les fonds des stages 3-6 ne sont jamais engagés et sont retournables. Le client ne paie que pour le travail effectivement réalisé et validé.

### 3.4 🆕 La dispute attribution est triviale en pipeline séquentiel

En pipeline séquentiel, la responsabilité est déterministe :
- Si le stage N échoue → l'agent du stage N est responsable (mauvaise exécution)
- Si le stage N réussit mais le stage N+1 révèle des défauts que le gate N aurait dû attraper → le reviewer du gate N est responsable (mauvaise validation)
- Si les deux sont en conflit → arbitrage, mais avec seulement 2 parties en cause

En DAG, cette attribution explose combinatoirement. C'est un argument de plus pour le pipeline V1.

---

## 4. PRD Changes Required

### 4.1 MASTER.md — Sections à créer

| Section | Contenu | Priorité |
|---------|---------|----------|
| `## Workflow Engine` | Nouvelle section top-level décrivant le pipeline séquentiel, les tiers, les quality gates | P0 |
| `### Tier Definitions` | Table formelle BRONZE/SILVER/GOLD/PLATINUM avec stages, gates, thresholds, budget ranges | P0 |
| `### Progressive Escrow Pattern` | Description du funding stage-by-stage, conditions de release, refund on pipeline failure | P0 |
| `### Quality Gate Attestation Protocol` | Flow off-chain → IPFS → on-chain, format EIP-712, dispute window | P0 |
| `### Budget Allocation Model` | Comment le budget total est réparti entre stages (pourcentages par tier) | P1 |

### 4.2 MASTER.md — Sections à modifier

| Section existante | Modification | Raison |
|-------------------|-------------|--------|
| `## Smart Contracts` | Ajouter `WorkflowEscrow.sol` comme nouveau contrat composant `MissionEscrow.sol` | Nouvelle couche d'orchestration |
| `## Mission Lifecycle` | Préciser que les missions peuvent être standalone OU partie d'un workflow | Backward compatibility |
| `## Pricing` | Refondre autour du modèle "budget achète des adversaires" + justification NPV rework | Positionnement stratégique |
| `## Agent Roles` | Ajouter `SECURITY_AUDITOR`, `ADVERSARIAL_REVIEWER`, `OPTIMIZER` comme rôles formels | Tiers GOLD/PLATINUM |

### 4.3 Fichiers à créer

| Fichier | Contenu |
|---------|---------|
| `contracts/WorkflowEscrow.sol` | Contrat d'orchestration de workflow |
| `test/WorkflowEscrow.t.sol` | Tests Foundry pour le workflow engine |
| `docs/TIER_SPEC.md` | Spécification formelle des tiers avec exemples |
| `docs/QUALITY_GATE_PROTOCOL.md` | Protocole d'attestation détaillé |

---

## 5. Implementation Priority

### Phase 1 — Foundation (Sprint 1-2, ~2 semaines)

```
1. WorkflowEscrow.sol — struct Workflow + createWorkflow()
   - Compose MissionEscrow existant
   - Supporte 1-6 stages séquentiels
   - Progressive funding (ne fund que le stage courant)
   - Tests: createWorkflow, fundWorkflow, stage count validation
   
2. advanceStage() — transition séquentielle
   - Vérifie que le stage N est COMPLETED
   - Fund automatiquement le stage N+1 via MissionEscrow.createMission()
   - Tests: happy path 3 stages, fail on skip, fail on double-advance

3. failStage() + refund partiel
   - Halt le pipeline au stage N
   - Refund les fonds non-engagés (stages N+1 à max)
   - Tests: fail at stage 2/4, verify refund amounts
```

**Critère de sortie Phase 1 :** WorkflowEscrow avec 10+ tests Foundry verts, pipeline séquentiel sans quality gates, progressive funding fonctionnel. Ceci est le **MVP interne** — déjà utilisable pour des workflows BRONZE (coder-only, pas de gate).

### Phase 2 — Quality Gates (Sprint 3-4, ~2 semaines)

```
4. QualityGateAttestation on-chain
   - Struct attestation (reviewerAddress, reportHash, score, pass, sig)
   - EIP-712 typed data signing pour les attestations
   - submitAttestation() + validateSignature()
   - Tests: valid attestation, invalid sig, wrong reviewer, score below threshold

5. Gate-gated advancement
   - advanceStage() requiert N attestations passing pour le gate correspondant
   - Configurable: requiredReviewers par gate (1 pour SILVER, 2 pour GOLD)
   - Tests: advance with 1/1 attestation, fail with 0/1, advance with 2/2 for GOLD

6. Dispute window
   - Timer après attestation submission (e.g., 24h)
   - Client peut flaguer une attestation comme disputée → freeze le pipeline
   - Résolution V1: admin/multisig (V2: Kleros)
   - Tests: dispute within window, dispute after window expires, resolution unfreezes
```

**Critère de sortie Phase 2 :** Workflows SILVER et GOLD fonctionnels end-to-end avec quality gates attestés. 20+ tests Foundry verts total.

### Phase 3 — Tier Formalization & Off-chain (Sprint 5-6, ~2 semaines)

```
7. Tier presets on-chain
   - Mapping tier → (stage count, gate count, thresholds, reviewer counts)
   - createWorkflow() peut accepter un tier enum au lieu de config manuelle
   - Tests: create each tier, verify correct stage/gate setup

8. Off-chain orchestrator (backend)
   - Service qui écoute les events WorkflowEscrow
   - Match les agents aux stages par rôle + réputation
   - Soumet les CID IPFS des livrables
   - Trigger les reviewers quand un stage complète

9. Agent matching for quality gates
   - Reviewers ne peuvent PAS être le même agent que le coder du stage précédent
   - Sélection par réputation + spécialisation
   - Anti-collusion: reviewers assignés après que le livrable soit soumis (commit-reveal light)
```

**Critère de sortie Phase 3 :** Système end-to-end démontrable avec un workflow GOLD complet : Issue GitHub → Coder → Gate → Reviewer → Gate → livrable final. Premier test avec des agents réels.

### Dépendances critiques

```
Phase 1 ──────► Phase 2 ──────► Phase 3
   │                │                │
   │                │                └── Requiert: IPFS pinning infra
   │                └── Requiert: EIP-712 signing library
   └── Requiert: MissionEscrow.sol stable (✅ déjà 14/14)
```

---

## 6. Next Cycle Focus

### Question primaire : **Comment l'off-chain orchestrator match les agents aux stages sans introduire de centralisation ?**

C'est la question la plus critique pour deux raisons :

1. **Le matching est le point de centralisation maximal.** Si un serveur centralisé décide quel agent fait quel stage, tout le théâtre de la décentralisation s'effondre. Le marketplace opérateur devient un middleman classique avec du DeFi en déco.

2. **Le matching anti-collusion pour les quality gates est non-trivial.** L'agent reviewer doit être :
   - Compétent dans le domaine (sinon la review est du bruit)
   - Indépendant du coder (sinon rubber-stamping)
   - Incité à reviewer sérieusement (sinon pass systématique pour toucher le paiement)
   - Assigné après soumission du livrable (sinon pré-arrangement possible)

**Sous-questions à résoudre :**
- Commit-reveal pour l'assignation des reviewers ? (le reviewer est révélé après soumission du CID)
- Stake-at-risk pour les reviewers ? (le reviewer perd un stake si sa review est disputée avec succès)
- Reputation-weighted random selection ? (les agents les mieux notés ont plus de chances d'être sélectionnés comme reviewers, mais pas de manière déterministe)
- Quel est le degré acceptable de centralisation en V1 ? (probablement : matching centralisé, mais avec transparency logs et migration path vers matching décentralisé)

### Question secondaire : **Quel est le budget split optimal par tier ?**

Proposition initiale à challenger :

| Tier | Coder | Reviewer 1 | Reviewer 2 | Auditor | Platform fee |
|------|-------|------------|------------|---------|-------------|
| BRONZE | 85% | — | — | — | 15% |
| SILVER | 60% | 20% | — | — | 20% |
| GOLD | 45% | 15% | 15% | 10% | 15% |
| PLATINUM | 35% | 12% | 12% | 12% | 14% | 15% platform + rework pool |

Le coder reçoit un pourcentage décroissant en absolu mais le budget total augmente, donc son payout absolu peut augmenter. À valider avec des simulations.

---

## 7. Maturity Score

### Score : 6.5 / 10

**Justification :**

| Dimension | Score | Commentaire |
|-----------|-------|-------------|
| **Vision produit** | 8/10 | L'insight "adversaires > compute" est forte, différenciante, et actionable. Le positionnement est clair. |
| **Architecture on-chain** | 7/10 | Pipeline séquentiel + composition MissionEscrow + progressive escrow = sain et buildable. Il manque la spécification formelle des edge cases (timeout, abandon mid-pipeline, agent no-show). |
| **Quality Gate Protocol** | 6/10 | L'approche attestation off-chain + commitment on-chain est correcte. Mais le dispute resolution est encore "V2: Kleros" — c'est un hand-wave sur le composant le plus critique. Sans dispute crédible, les attestations sont du théâtre. Il faut au minimum un mécanisme V1 (multisig admin + bond). |
| **Matching & Anti-collusion** | 4/10 | Identifié comme critique mais non résolu. C'est le gap le plus dangereux — un matching naïf détruit la valeur de toute l'architecture adversariale. |
| **Pricing / Economics** | 5/10 | L'argument NPV rework est convaincant mais les splits par tier sont des placeholders. Aucune simulation, aucune validation que les payouts sont suffisants pour attirer des agents de qualité à chaque rôle. |
| **Implementation readiness** | 7/10 | La Phase 1 est prête à coder demain. Les dépendances sont claires, le socle MissionEscrow est stable. |
| **Edge cases & failure modes** | 5/10 | Insuffisamment traités. Que se passe-t-il si : aucun reviewer ne claim un gate ? Un agent disparaît mid-stage ? Le client dispute toutes les attestations systématiquement pour récupérer ses fonds ? |

**Pour atteindre 8/10 :**
- Résoudre le matching/anti-collusion (cycle suivant)
- Spécifier les failure modes et timeout de chaque stage/gate
- Définir le dispute mechanism V1 (même simple : multisig + bond + timer)
- Simuler les economics avec des payouts réels et valider que les agents sont incités à chaque rôle

**Pour atteindre 9/10 :**
- Audit informel du contrat WorkflowEscrow par un second dev
- Prototype off-chain orchestrator fonctionnel
- 3+ scénarios end-to-end testés avec des agents réels (même manuellement)

**Verdict :** On est au stade où l'architecture est _sound_ mais les mécanismes de sécurité économique (anti-collusion, dispute, incentive alignment) sont encore des placeholders. La Phase 1 est buildable immédiatement. Les Phases 2-3 requièrent les réponses du prochain cycle pour ne pas builder sur du sable.