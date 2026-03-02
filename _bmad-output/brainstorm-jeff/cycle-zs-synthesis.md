

# Cycle zs — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ Le budget achète une topologie de vérification, pas du compute

**Validé comme insight fondateur du positioning.** C'est le moat defensible. Le corollaire opérationnel est que le pricing n'est pas indexé sur le coût marginal des LLM calls (race to the bottom assurée) mais sur la **structure du pipeline de confiance**. Cela aligne le business model sur la valeur perçue (confiance dans le livrable) plutôt que sur le coût de production.

**Nuance retenue :** L'insight est vrai *à condition* que l'indépendance des regards soit réelle. Si tous les agents utilisent le même LLM sous le capot (GPT-4o → GPT-4o → GPT-4o), l'indépendance est un théâtre. L'implémentation doit donc soit (a) imposer des modèles différents par stage, soit (b) imposer des prompts structurellement orthogonaux (un agent code, un autre ne voit que les tests, un autre ne voit que l'interface publique), soit (c) les deux. On retient **(b) comme V1, (a)+(b) comme V2** — l'orthogonalité des inputs est plus impactante et moins coûteuse que la diversité des modèles.

### 1.2 ✅ Sequential Spine with Parallel Wings (SSPW) comme modèle unique

**Validé.** Les 3 patterns (Linear, Fan-out Review, Full Pipeline) couvrent les cas Bronze→Platinum. Le guard-rail de 6 stages max est confirmé — au-delà, on entre dans du "quality theater" qui ajoute de la latence sans valeur marginale.

**Décision d'implémentation :** Le `parallelGroup: uint8` dans `Stage` est le bon mécanisme minimal. Les stages avec `parallelGroup = 0` sont séquentiels. Les stages avec le même `parallelGroup > 0` s'exécutent en parallèle et doivent tous compléter avant la gate suivante. Pas besoin de DAG engine — c'est un array ordonné avec des groupes. Simple, auditible, suffisant.

### 1.3 ✅ WorkflowEscrow compose MissionEscrow, ne le remplace pas

**Validé fermement.** Les 14 tests Foundry verts sur `MissionEscrow.sol` (323 lignes) sont le socle de non-régression. `WorkflowEscrow` est un meta-client qui appelle `MissionEscrow.createMission()` par stage. Chaque stage = une mission indépendante avec son propre escrow. Le workflow orchestre les transitions.

```
WorkflowEscrow.sol (nouveau)
│
│  createWorkflow(tier, stages[], budgetSplit[])
│  ├── Pour chaque stage: MissionEscrow.createMission(...)
│  ├── Enregistre l'ordre des stages + gates
│  └── Lock le budget total
│
│  advanceStage(workflowId, artifactHash, attestation)
│  ├── Vérifie gate précédente passée
│  ├── Appelle MissionEscrow.completeMission(stageN)
│  ├── Déclenche MissionEscrow.createMission(stageN+1) ou unlock final
│  ���── Émet WorkflowStageAdvanced event
│
│  disputeStage(workflowId, stageIndex)
│  └── Délègue à MissionEscrow.dispute(missionId)
```

**Propriété critique préservée :** Chaque mission/stage peut être disputée indépendamment. Un échec au stage 3 ne bloque pas le paiement des stages 1-2 déjà validés.

### 1.4 ✅ Quality Gates = attestation off-chain + commitment on-chain

**Validé.** C'est la seule architecture viable pour V1 :

| Composant | Localisation | Justification |
|-----------|-------------|---------------|
| Rapport de review complet | IPFS (off-chain) | Coût gas, taille arbitraire |
| Hash du rapport + score + signature | On-chain | Vérifiabilité, non-répudiation |
| Logique pass/fail (score ≥ threshold) | On-chain | Déterministe, auditable |
| Jugement subjectif de qualité | Off-chain (agent) | Impossible on-chain |
| Dispute sur le jugement | On-chain trigger → off-chain arbitrage | V1: client override, V2: Kleros/UMA |

Le flow on-chain est minimal et déterministe :
```solidity
function submitGateAttestation(
    bytes32 workflowId,
    uint8 gateIndex,
    bytes32 reportHash,    // IPFS CID du rapport
    uint8 score,           // 0-100
    bytes calldata sig     // signature de l'agent reviewer
) external {
    require(score >= gates[gateIndex].requiredScore, "Gate failed");
    require(recoverSigner(reportHash, score, sig) == stages[gateIndex].agentId);
    gates[gateIndex].passed = true;
    gates[gateIndex].attestationHash = reportHash;
    // auto-advance si conditions remplies
}
```

### 1.5 ✅ 3 topologies seulement en V1

**Validé.** Constraint intentionnelle. On ne build pas un workflow engine générique — on build 3 templates tarifés.

| Tier | Pattern | Stages | Gates | Budget Range |
|------|---------|--------|-------|-------------|
| BRONZE | Linear simple | 1 (coder seul) | 1 (auto-lint) | $5–$50 |
| SILVER | Linear + review | 2 (coder → reviewer) | 2 (lint + attestation) | $50–$200 |
| GOLD | Fan-out review | 3-4 (coder → 2 reviewers parallèles → merge) | 3 (lint + dual attestation + merge gate) | $200–$1000 |
| PLATINUM | Full pipeline | 4-6 (coder → reviewers → security → optimizer) | 4-5 | $1000+ |

**Décision critique :** PLATINUM est V2. On shippe Bronze/Silver/Gold. Trois patterns, pas quatre. Le full pipeline introduit des complexités de dispute multi-stage qui nécessitent un arbitrage plus sophistiqué que le client-override de V1.

---

## 2. Décisions Rejetées

### 2.1 ❌ Workflow comme smart contract séparé par instance

Proposé implicitement par le `workflowId: bytes32` — chaque workflow pourrait être un contrat déployé. **Rejeté.** Le coût de déploiement d'un contrat par workflow est prohibitif ($5-20 en gas sur mainnet, même L2 c'est $0.50-2). Un seul `WorkflowEscrow.sol` avec un mapping `workflowId → Workflow` est suffisant. Le pattern est le même que `MissionEscrow` : un singleton avec state interne.

### 2.2 ❌ Quality Gates entièrement on-chain avec logique d'évaluation

**Rejeté** (confirmé du challenge). Le smart contract ne sait pas si un code review est pertinent. Il sait seulement vérifier un score signé contre un threshold. L'évaluation qualitative reste off-chain.

### 2.3 ❌ Budget allocation dynamique entre stages

Le cycle proposait `budgetAllocation: uint256` par stage. L'idée sous-jacente est que le budget pourrait être réalloué dynamiquement si un stage coûte moins que prévu. **Rejeté pour V1.** La réallocation dynamique introduit un vecteur d'attaque : un agent coder pourrait rush un livrable médiocre, récupérer le budget excédentaire via un agent reviewer complice. Le budget est **fixé à la création** du workflow selon le tier. Les splits sont déterministes :

| Tier | Coder | Reviewer(s) | Security | Gate/Infra |
|------|-------|-------------|----------|------------|
| BRONZE | 90% | — | — | 10% |
| SILVER | 65% | 25% | — | 10% |
| GOLD | 50% | 20%×2 | — | 10% |

Le 10% "Gate/Infra" couvre les coûts de gas, IPFS pinning, et la marge plateforme. En V2, on pourra introduire des bonus conditionnels (reviewer payé plus si le score de qualité global est élevé), mais pas de réallocation libre.

### 2.4 ❌ SLA Deadlines on-chain avec auto-slash

Le modèle propose `slaDeadline: uint64` par stage. L'auto-expiry est dangereuse : si un agent est à 95% de completion et que le deadline arrive, le contrat slash automatiquement. **Rejeté pour V1.** Le deadline est informationnel — le client peut déclencher manuellement un `expireStage()` après le deadline, mais il n'y a pas d'auto-execution. L'auto-slash nécessite un keeper (Chainlink Automation / Gelato) et un modèle de pénalité plus fin. V2.

### 2.5 ❌ PLATINUM tier en V1

Comme justifié en 1.5. Le full pipeline avec security auditor + optimizer crée un graphe de responsabilité trop complexe pour le mécanisme de dispute V1 (client-override). Quand 5 agents ont touché le code et qu'un bug survient, qui est responsable ? Le coder qui a introduit le bug ? Le reviewer qui ne l'a pas vu ? Le security auditor qui l'a manqué ? Ce problème de **causal attribution dans un pipeline multi-agent** est un sujet de recherche à part entière. On ne le résout pas en V1.

---

## 3. Nouveaux Insights

### 3.1 🆕 L'indépendance des regards est le vrai produit — pas les agents

C'est la première fois qu'on articule clairement que le moat n'est pas dans la qualité des agents individuels (commoditisés) mais dans la **topologie de vérification**. Cela change le positioning :

- **Avant :** "Nos agents codent mieux" → impossible à défendre, model providers font mieux
- **Après :** "Notre pipeline de vérification produit des livrables auditables" → défendable, car c'est un produit de plateforme, pas un produit d'IA

**Impact PRD :** Le positioning section doit être réécrit autour de ce concept. Le comparable n'est plus Devin/Replit Agent mais les **cabinets d'audit** et les **pipelines CI/CD** — on est le "CI/CD for AI-generated code where each stage is independently attested."

### 3.2 🆕 Le risque de "théâtre d'indépendance" est existentiel

Si les reviewers utilisent le même modèle avec le même context que le coder, la review est un rubber stamp. Ce n'est pas un edge case — c'est le **default outcome** si on ne design pas contre. Concrètement :

- **Problème :** Agent A (GPT-4o) code → Agent B (GPT-4o) review → B va naturellement trouver le code "bon" car il raisonne de la même façon
- **Solution V1 :** **Information asymmetry by design.** Le reviewer ne reçoit PAS le code + l'issue. Il reçoit le code + les tests + la spécification de l'interface attendue. Il n'a pas accès à l'issue originale ni au raisonnement du coder. Ça force un regard structurellement différent.
- **Solution V2 :** Model diversity enforced. Le workflow engine impose que si stage N utilise le provider X, stage N+1 doit utiliser le provider Y.

C'est un insight d'architecture agent fondamental qui n'était pas dans les cycles précédents.

### 3.3 🆕 Le flywheel data est sous-estimé

Chaque workflow complété produit un triplet `(issue_complexity, tier_chosen, outcome_quality)`. Sur 1000 workflows, on peut commencer à prédire : "pour ce type d'issue, le tier Silver a un taux de succès de 73%, le tier Gold de 94%." Ça permet :

1. **Recommandation de tier** : "Pour cette issue, nous recommandons Gold — historiquement 94% de succès vs 73% en Silver"
2. **SLA probabilistes** : "Gold tier: 90% de probabilité de livraison satisfaisante sous 4h" → contractualisable
3. **Pricing dynamique** : Les tiers deviennent des courbes continues, pas des steps discrets

**Ce flywheel est le vrai moat long-terme.** Plus que le smart contract, plus que l'UX. Les données de qualité par topologie sont uniques et non-réplicables.

### 3.4 🆕 Le pattern "meta-client" crée une clean separation of concerns

`WorkflowEscrow` comme meta-client de `MissionEscrow` est élégant et nouveau dans notre architecture. Les propriétés :

- `MissionEscrow` ne sait pas qu'il est dans un workflow — il traite chaque mission indépendamment
- `WorkflowEscrow` gère l'orchestration, les gates, et les transitions
- Le client interagit **uniquement** avec `WorkflowEscrow`
- Les agents interagissent avec `MissionEscrow` (ils ne savent pas non plus qu'ils sont dans un workflow)

Cette ignorance mutuelle est une feature : elle simplifie le modèle mental de chaque acteur et rend le système composable. On peut ajouter des types de workflows (bounties, continuous maintenance, etc.) sans modifier `MissionEscrow`.

---

## 4. PRD Changes Required

### 4.1 `MASTER.md` — Section Architecture

**Ajouter :** Diagramme d'architecture 3 couches :
```
┌─────────────────────────────────────────┐
│           Client Interface               │
│  (GitHub App / Dashboard / API)          │
└────────────────┬────────────────────────┘
                 │
┌────────────────▼────────────────────────┐
│         WorkflowEscrow.sol               │
│  ┌──────���──────────────────────────┐     │
│  │ Workflow Registry                │     │
│  │ Tier Templates (B/S/G)          │     │
│  │ Stage Orchestration              │     │
│  │ Quality Gate Verification        │     │
│  │ Budget Split Enforcement         │     │
│  └─────────────────────────────────┘     │
└────────────────┬────────────────────────┘
                 │ createMission() / completeMission()
┌────────────────▼────────────────────────┐
│          MissionEscrow.sol               │
│  (323 lines, 14/14 tests ✅)            │
│  Individual mission lifecycle            │
│  Escrow lock/release/dispute             │
└──────────────────────────────────────────┘
```

**Modifier :** Le positioning passe de "AI agents as service" à "**Auditable verification topologies for AI-generated code.**"

### 4.2 `MASTER.md` — Section Smart Contracts

**Ajouter :** Spécification compl��te de `WorkflowEscrow.sol` :
- Interface publique (createWorkflow, advanceStage, disputeStage, expireStage)
- Events (WorkflowCreated, StageAdvanced, GatePassed, GateFailed, WorkflowCompleted, WorkflowDisputed)
- Modèle de composition avec MissionEscrow
- Budget split tables par tier (figées en V1)

**Ajouter :** Gate attestation flow :
- Off-chain: agent produit rapport → IPFS pin → signe (hash, score)
- On-chain: `submitGateAttestation(workflowId, gateIndex, reportHash, score, sig)`
- Dispute: `challengeGateAttestation(workflowId, gateIndex)` → freeze + arbitrage

### 4.3 `MASTER.md` — Section Quality & Trust

**Nouvelle section :** "Information Asymmetry by Design"
- Documenter que le reviewer NE REÇOIT PAS l'issue originale
- Documenter les input sets par role :
  - **Coder**: issue + repo context + constraints
  - **Reviewer**: code output + tests + interface spec (PAS l'issue)
  - **Security Auditor** (V2): code output + dependency graph + known CVE patterns (PAS l'issue NI la review)

### 4.4 `MASTER.md` — Section Business Model

**Modifier :** Pricing n'est plus "par agent" mais "par tier de vérification" :
- Bronze: base fee (infra cost + margin)
- Silver: base fee × 2.5 (le reviewer coûte, mais la valeur est la confiance)
- Gold: base fee × 5 (2 reviewers parallèles + merge gate)
- Platinum (V2): custom pricing

**Ajouter :** Flywheel data section — comment les données de `(issue_type, tier, outcome)` alimentent les recommandations et SLA.

### 4.5 Nouveau fichier : `WORKFLOW_SPEC.md`

Fichier dédié contenant :
- Les 3 topologies supportées avec diagrammes ASCII complets
- Le state machine complet de chaque workflow (states + transitions)
- Le modèle de budget split avec exemples numériques
- La spécification des gates (types, thresholds par tier, dispute flow)
- Le test plan Foundry pour `WorkflowEscrow.sol`

---

## 5. Implementation Priority

### Phase 1 — Bronze: Linear Single-Agent (Semaine 1-2)

**Objectif :** Shipper le cas le plus simple pour valider le pattern meta-client.

```
Scope:
├── WorkflowEscrow.sol — createWorkflow() pour tier BRONZE uniquement
├── 1 stage (CODER), 1 gate (AUTO_LINT)
├── Gate: vérifie que artifactHash est non-null + lint score off-chain > threshold
├── Budget split: 90% coder / 10% platform
├── Tests Foundry: 6-8 tests (create, advance, expire, dispute)
└── Intégration: WorkflowEscrow calls MissionEscrow.createMission()
```

**Critère de succès :** Les 14 tests MissionEscrow restent verts + les 6-8 nouveaux tests WorkflowEscrow sont verts. Le flow end-to-end fonctionne : client crée workflow → agent claim → agent submit → gate check → payout.

**Pourquoi Bronze first :** C'est un wrapper minimal autour de MissionEscrow. Si le pattern meta-client a des friction points, on les découvre sur le cas simple. De plus, Bronze est le tier avec le plus de volume attendu (petites issues, $5-50).

### Phase 2 — Silver: Linear Two-Agent (Semaine 3-4)

**Objectif :** Introduire le deuxième agent (reviewer) et l'attestation off-chain.

```
Scope:
├── WorkflowEscrow.sol — extend pour tier SILVER
├── 2 stages (CODER → REVIEWER), 2 gates (lint + attestation)
├── Gate attestation: submitGateAttestation() avec sig verification
├── Stage transition logic: stage N complete → gate N check → stage N+1 start
├── Budget split: 65% coder / 25% reviewer / 10% platform
├── Tests Foundry: 8-10 tests additionnels (attestation, sig verify, stage transition, gate fail)
├── IPFS integration: off-chain rapport pinning + hash verification
└── Information asymmetry: spec du payload que le reviewer reçoit vs ne reçoit pas
```

**Critère de succès :** Un workflow Silver complète end-to-end avec 2 agents différents. Le reviewer signe une attestation valide. Le client peut challenger l'attestation et freeze le payout.

### Phase 3 — Gold: Parallel Reviews (Semaine 5-7)

**Objectif :** Le produit différenciant. Fan-out parallèle + merge gate.

```
Scope:
├── WorkflowEscrow.sol — extend pour tier GOLD
├── 3-4 stages (CODER → [REVIEWER_A ∥ REVIEWER_B] → merge)
├── parallelGroup logic: stages avec même group démarrent simultanément
├── Merge gate: requiert attestations de TOUS les agents du parallel group
├── Consensus scoring: average des scores, ou minimum, ou weighted (TBD)
├── Conflict resolution: si reviewer A dit pass et B dit fail → ???
├── Budget split: 50% coder / 20% reviewer A / 20% reviewer B / 10% platform
├── Tests Foundry: 10-12 tests additionnels (parallel start, partial complete, 
│   consensus, conflict, timeout d'un reviewer parallèle)
└── Dashboard: visualisation du workflow state en temps réel
```

**Critère de succès :** Un workflow Gold avec 2 reviewers parallèles complète. Le cas de conflit (1 pass, 1 fail) a un resolution path clair.

**Open question Phase 3 :** Que faire quand les reviewers ne sont pas d'accord ? Options :
- **(A)** Fail-safe : si un reviewer fail → le workflow fail → client review
- **(B)** Majority : 2/2 ou 2/3 → pass (mais on n'a que 2 reviewers en Gold)
- **(C)** Escalation : conflit → stage supplémentaire "tiebreaker" (coûte plus)

**Recommandation :** **(A) pour V1.** Fail-safe protège le client. C'est conservateur mais aligné avec le positioning "confiance." On track les conflits — si le taux est > 20%, c'est un signal que soit les reviewers sont mauvais, soit l'issue est ambiguë, ce qui alimente le flywheel data.

### Phase 4 — Infrastructure & Data (Semaine 8-10)

```
Scope:
├── Event indexing: indexer tous les WorkflowEscrow events pour analytics
├── Tier recommendation engine (v0): règles simples basées sur issue size/complexity
├── Agent matching: quel agent assigner à quel stage (round-robin V1, reputation V2)
├── Monitoring: dashboard ops — workflows in progress, gate pass rates, dispute rates
└── Load testing: simuler 100 workflows concurrents, mesurer gas + latency
```

---

## 6. Next Cycle Focus

### Question prioritaire : **Le mécanisme de dispute multi-stage**

Le cycle zs a résolu l'orchestration (comment les stages s'enchaînent) et les gates (comment la qualité est attestée). Mais le **dispute flow** dans un workflow multi-agent est le problème le plus dur restant :

**Scénarios non résolus :**

1. **Le client dispute le livrable final.** Le coder dit "mon code était bon, c'est le reviewer qui a mal attesté." Le reviewer dit "le code avait un bug subtil que mes tests n'ont pas couvert." → Qui perd son escrow ? Les deux ? Seulement le reviewer ?

2. **Un agent mid-pipeline disparaît.** Le coder a livré et a été payé (stage 1 complete). Le reviewer (stage 2) ne livre jamais. → Le client a payé le coder pour un livrable non-reviewé. Doit-on clawback le paiement du coder ?

3. **Gate failure cascade.** Le lint gate fail → le coder doit re-soumettre. Combien de re-soumissions avant auto-fail du workflow ? (Proposition : 3 max, configurable par tier.)

4. **Dispute sur l'attestation elle-même.** Le client challenge l'attestation du reviewer ("ce rapport de review est vide, l'agent a rubber-stamped"). Comment prouver on-chain que le rapport off-chain est substantif ?

**Deliverable du prochain cycle :** Un **dispute resolution state machine** complet couvrant ces 4 scénarios, avec pour chaque cas : (a) qui peut initier la dispute, (b) quelle est la preuve requise, (c) quel est le flow d'arbitrage, (d) comment les funds sont redistribués, (e) comment les reputations sont affectées.

---

## 7. Maturity Score

### Score : **6.5 / 10**

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Positioning & Moat** | 8/10 | L'insight "topologie de vérification" est solide et différenciant. Besoin de valider par le marché. |
| **Smart Contract Architecture** | 7/10 | Le pattern meta-client est clean. WorkflowEscrow spec est crédible. Pas encore implémenté. |
| **Quality Gate Design** | 6/10 | Off-chain attestation + on-chain commitment est sain. L'information asymmetry est un bon insight mais pas encore spécifié en détail (quels inputs exactement par rôle ?). |
| **Dispute Resolution** | 3/10 | C'est le trou béant. On a identifié les scénarios mais zéro solution concrète. Bloquant pour Gold tier. |
| **Tier Pricing** | 5/10 | Les splits sont raisonnables mais arbitraires. Aucune donnée de marché pour valider. Need beta testing. |
| **Agent Independence** | 6/10 | L'insight est là, la solution V1 (information asymmetry) est décrite, mais le risque de rubber-stamping n'est pas quantifié ni mesuré. |
| **Implementation Readiness** | 7/10 | MissionEscrow existe et est testé. Le plan Phase 1-4 est concret et séquencé. On peut commencer à builder demain. |
| **Data Flywheel** | 4/10 | L'idée est articulée mais zéro infrastructure pour la réaliser. Pas d'event indexing, pas d'analytics, pas de feedback loop. |

**Pourquoi 6.5 et pas 7 :** Le dispute resolution à 3/10 est un risque systémique. On peut builder et shipper Bronze (pas de dispute multi-agent — c'est juste MissionEscrow wrappé). On peut builder Silver (dispute simple entre coder et reviewer — le client tranche). Mais Gold — le produit différenciant — est **bloqué** tant que le dispute multi-stage n'est pas résolu. Le prochain cycle doit faire passer ce score de 3 à au moins 6 pour débloquer la roadmap.

**Verdict :** On est prêt à **builder Phase 1 (Bronze) et Phase 2 (Silver) immédiatement.** Phase 3 (Gold) nécessite un cycle de design supplémentaire sur les disputes. L'insight stratégique est mature. L'implémentation tactique est à moitié là.