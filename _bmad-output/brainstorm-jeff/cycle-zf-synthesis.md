

# Cycle zf — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ Le Workflow Engine est une State Machine Financière, pas un orchestrateur générique

**Justification :** C'est l'insight le plus structurant du cycle. Chaque transition d'état (`advanceStage`, `failStage`, `disputeStage`) a un impact monétaire direct. Cela signifie que le contrat on-chain ne gère pas de logique métier — il gère des **flux USDC conditionnels**. Le Plan Compiler off-chain prend toutes les décisions de routing, matching, qualité. Le contrat on-chain ne fait qu'appliquer les conséquences financières de ces décisions.

**Implication concrète :** Le `WorkflowEscrow.sol` n'a besoin que de 5 fonctions publiques :
- `createWorkflow()` — lock le budget total, enregistre le split par stage
- `advanceStage()` — release le paiement du stage N, lock celui du stage N+1
- `failStage()` — déclenche le refund partiel ou le re-routing selon la config
- `disputeStage()` — freeze les fonds, ouvre une fenêtre d'arbitrage
- `cancelWorkflow()` — refund des stages non-démarrés

### 1.2 ✅ Architecture Deux-Couches (Off-chain Compiler + On-chain Escrow)

**Justification :** La séparation est nette et non-ambiguë. Le Compiler est un service backend Node/Python classique. L'Escrow est un contrat Solidity minimaliste. La communication entre les deux se fait via un `planHash` ��� le Compiler génère un plan, le hache, le soumet on-chain. Le contrat stocke le hash et les splits, pas le plan lui-même.

**Validé sans modification.** C'est l'architecture de référence pour l'implémentation.

### 1.3 ✅ Composition avec MissionEscrow existant (pattern meta-client)

**Justification :** Le `WorkflowEscrow` agit comme un client programmatique du `MissionEscrow`. Pour chaque stage, il appelle `MissionEscrow.createMission()` avec le budget alloué et l'agent sélectionné. Les 14 tests existants restent verts. Zéro modification du contrat existant.

**Pattern validé :**
```solidity
contract WorkflowEscrow {
    MissionEscrow public missionEscrow; // composition, pas héritage

    function advanceStage(uint workflowId) external {
        Stage storage s = workflows[workflowId].stages[currentStage];
        // Crée une mission via le contrat existant
        missionEscrow.createMission(s.agent, s.budget, s.deadline);
    }
}
```

### 1.4 ✅ Quality Gates = Attestation off-chain + Commitment on-chain

**Justification :** Le jugement de qualité est intrinsèquement subjectif. Le contrat ne peut pas évaluer du code. La solution est un pattern commit-reveal allégé :

1. L'agent reviewer produit un rapport + score off-chain
2. Le hash du rapport + le score + la signature du reviewer sont soumis on-chain
3. Le contrat applique un seuil (score ≥ threshold → `advanceStage`, sinon → `failStage`)
4. Le client a une fenêtre de dispute pour challenger l'attestation

**Guard-rail :** Le seuil est défini **par le Tier Preset**, pas par le client (évite le gaming).

### 1.5 ✅ Max 6 stages par workflow

**Justification :** Validé aux cycles précédents et renforcé ici. Au-delà de 6 stages, le coût de coordination (gas, latence, surface de dispute) dépasse la valeur marginale. Les Tier Presets sont calibrés dans cette enveloppe :

| Tier | Stages | Budget Range | Quality Gates |
|------|--------|-------------|---------------|
| Bronze | 1 | $5–50 | Aucun (auto-accept) |
| Silver | 2–3 | $50–500 | 1 QG automated (tests pass) |
| Gold | 3–4 | $500–5000 | 1–2 QG (automated + peer review) |
| Platinum | 4–6 | $5000+ | 2–3 QG (automated + peer + client approval) |

### 1.6 ✅ Lazy Agent Matching (per-stage, pas upfront)

**Justification :** Matcher tous les agents à la création du workflow est du gaspillage. Un workflow Gold de 4 stages prend potentiellement 48h. La disponibilité et la réputation des agents changent entre le stage 1 et le stage 4. Le matching se fait au moment de l'`advanceStage`, pas au `createWorkflow`.

**Implication :** Le `createWorkflow` on-chain ne stocke **pas** d'adresses d'agents. Il stocke uniquement les `agentRequirements[]` par stage (hashé). Le Compiler résout l'agent au moment de la transition.

---

## 2. Décisions Rejetées

### 2.1 ❌ WorkflowEscrow comme contrat séparé qui hérite de MissionEscrow

**Rejeté. Composition, pas héritage.** L'héritage couplerait les deux contrats et rendrait impossible l'upgrade indépendante. Le `MissionEscrow` est un contrat déployé et testé. Le `WorkflowEscrow` le référence par adresse, pas par héritage.

**Risque évité :** Un bug dans `WorkflowEscrow` ne peut pas affecter les missions créées directement via `MissionEscrow`.

### 2.2 ❌ Gestion automatisée des échecs de stage intermédiaire avec re-routing on-chain

**Rejeté.** Le cycle propose implicitement que `failStage` puisse déclencher un re-routing automatique (réassigner à un autre agent). Mais le re-routing implique un nouveau matching, donc une décision off-chain. Le contrat ne doit pas essayer de résoudre un nouvel agent.

**Décision retenue :** `failStage` a exactement 2 issues :
1. **Retry** — Le Compiler off-chain sélectionne un nouvel agent, appelle `retryStage(workflowId, stageId, newAgent)` on-chain. Les fonds du stage restent lockés.
2. **Abort** — Refund de tous les stages non-complétés au client. Les stages déjà complétés et payés sont irréversibles.

Pas de logique conditionnelle complexe on-chain. Le contrat expose les primitives, le Compiler orchestre.

### 2.3 ❌ Disputes résolues on-chain en V1

**Rejeté.** L'arbitrage décentralisé (Kleros, UMA) est un gouffre de complexité en V1. En V1, la dispute fonctionne ainsi :

1. Le client appelle `disputeStage()` → les fonds du stage sont freezés
2. Un **admin multisig** (équipe Agent Marketplace) tranche manuellement
3. L'admin appelle `resolveDispute(workflowId, stageId, ruling)` → release ou refund

**V2 :** Migration vers un oracle d'arbitrage décentralisé. Le contrat V1 est déjà designé avec un `disputeResolver` abstrait (adresse configurable) pour faciliter cette migration.

### 2.4 ❌ Budget splits dynamiques recalculés en cours de workflow

**Rejeté.** Le budget split est fixé à la création du workflow et inscrit on-chain. Permettre la modification en cours de route (ex: "le stage 2 a coûté moins cher, réallouons au stage 3") crée une surface d'attaque énorme et une complexité de gestion disproportionnée.

**Règle :** Si un stage coûte moins que son allocation, le surplus est refunded au client à la fin du workflow, pas réalloué.

### 2.5 ❌ Tier Presets personnalisables par le client

**Rejeté.** Les Tiers sont des presets figés par la plateforme. Permettre au client de customiser le nombre de stages, les seuils de QG, ou les splits budgétaires reviendrait à exposer un DSL de workflow arbitraire — exactement le pattern d'over-engineering qu'on a tué au cycle ze.

Le client choisit un Tier. Le Compiler génère un plan conforme. Point.

**Exception admise :** Le client peut optionnellement ajouter un stage de "Client Review" en fin de workflow Gold/Platinum (opt-in, pas opt-out). C'est le seul degré de liberté.

---

## 3. Nouveaux Insights

### 3.1 🆕 Le planHash comme mécanisme de non-répudiation

Insight nouveau de ce cycle : le hash du plan off-chain soumis on-chain n'est pas juste un mécanisme d'intégrité — c'est un **mécanisme de non-répudiation**. Si un litige survient, le plan off-chain stocké en base de données peut être vérifié contre le hash on-chain. Ni le client, ni la plateforme, ni l'agent ne peuvent prétendre que le plan était différent de ce qui a été committé.

**Implication architecturale :** Le plan off-chain doit être **signé par le client** avant soumission on-chain. La signature est vérifiée dans `createWorkflow()`. Cela ajoute une étape UX (le client signe via son wallet) mais rend le plan légalement opposable.

```solidity
function createWorkflow(
    bytes32 planHash,
    uint[] calldata budgetSplits,
    bytes calldata clientSignature  // EIP-712 signature du plan
) external {
    require(
        _verifySignature(planHash, budgetSplits, clientSignature, msg.sender),
        "Invalid client signature"
    );
    // ...
}
```

### 3.2 🆕 Le problème du "stage boundary payment" est le vrai défi technique

Le cycle identifie correctement le problème mais ne le résout pas complètement : **que se passe-t-il entre deux stages ?** Quand `advanceStage` est appelé :

1. Le paiement du stage N doit être **released** à l'agent N
2. Le budget du stage N+1 doit être **locked** pour l'agent N+1
3. L'agent N+1 doit être **matché** (off-chain, lazy)
4. L'output du stage N doit être **passé** comme input du stage N+1

La séquence exacte est :
```
advanceStage(workflowId, stageOutput, qgAttestation)
  ├── 1. Vérifier QG attestation (hash + score + sig)
  ├── 2. Vérifier score ≥ threshold du Tier
  ├── 3. Release paiement stage N via MissionEscrow.completeMission()
  ├── 4. Émettre événement StageCompleted(workflowId, stageId, outputHash)
  └── 5. Marquer stage N+1 comme READY (pas ACTIVE — le matching n'a pas eu lieu)

// Ensuite, off-chain :
  ├── 6. Plan Compiler matche un agent pour stage N+1
  ├── 7. Agent accepte
  └── 8. Compiler appelle startStage(workflowId, stageId, agentAddress)
              └── MissionEscrow.createMission(agent, budget, deadline)
```

**Insight critique :** Il y a un **gap temporel** entre les étapes 5 et 8 où les fonds du stage N+1 sont lockés dans le `WorkflowEscrow` mais pas encore alloués via `MissionEscrow`. Ce gap est normal et sain (c'est le temps de matching). Mais il faut un **timeout** : si le matching échoue après X heures, le client peut reclaim les fonds non-alloués.

### 3.3 🆕 Les Tier Presets comme contrat social, pas technique

Les Tiers (Bronze/Silver/Gold/Platinum) ne sont pas des configurations techniques — ce sont des **contrats sociaux** entre la plateforme et le client. Le client paie un budget et obtient une **garantie de process** :

- **Bronze :** "Un agent va tenter de résoudre votre issue. Pas de garantie de qualité."
- **Silver :** "Deux agents travaillent dessus avec validation automatisée. Qualité minimum garantie."
- **Gold :** "Process structuré avec peer review. Qualité significative garantie."
- **Platinum :** "Process complet avec review experte et validation client. Qualité premium garantie."

**Implication :** Les Tier Presets doivent être documentés publiquement comme des SLA, pas cachés dans du code. Le client sait exactement ce qu'il achète.

### 3.4 🆕 Le WorkflowEscrow n'a PAS besoin de connaître les Tiers

Corollaire du 3.3 : le contrat on-chain est **tier-agnostic**. Il reçoit un array de stages avec des splits et des threshold. Qu'il s'agisse d'un workflow Bronze (1 stage) ou Platinum (6 stages) est indifférent pour le contrat. La logique de Tier vit **exclusivement** dans le Plan Compiler off-chain.

Cela simplifie massivement le contrat et élimine une source de couplage.

---

## 4. PRD Changes Required

### 4.1 Section à AJOUTER : "Workflow Engine Specification"

**Localisation :** Nouvelle section entre "Smart Contract Architecture" et "Agent Matching"

**Contenu requis :**

| Sous-section | Description | Statut |
|---|---|---|
| 4.1.1 WorkflowEscrow Interface | Les 5 fonctions publiques, leurs paramètres, les events émis | À rédiger |
| 4.1.2 Stage State Machine | Les 5 états (PENDING → READY → ACTIVE → COMPLETED / FAILED) et les transitions autorisées | À rédiger |
| 4.1.3 Budget Split Mechanics | Comment le budget total est décomposé, locké, released par stage | À rédiger |
| 4.1.4 QualityGate Attestation Schema | Format du hash, du score, de la signature, seuils par défaut | À rédiger |
| 4.1.5 Failure & Dispute Flows | Retry vs Abort, dispute freeze, admin resolution V1 | À rédiger |

### 4.2 Section à MODIFIER : "Smart Contract Architecture"

- Ajouter le diagramme de composition `WorkflowEscrow` → `MissionEscrow`
- Clarifier que `MissionEscrow` reste **intouché** et que `WorkflowEscrow` est un nouveau contrat
- Ajouter le `planHash` et la signature EIP-712 du client dans le flow de création

### 4.3 Section à MODIFIER : "Tier System"

- Remplacer toute mention de "Tier logic on-chain" par "Tier resolution off-chain"
- Ajouter le tableau des Tier Presets (stages, budget ranges, QG configs) du §1.5
- Documenter que les Tiers sont des SLA publics

### 4.4 Section à AJOUTER : "Stage Boundary Protocol"

**Contenu :** Le protocole exact entre deux stages (les 8 étapes du §3.2), incluant :
- Le gap temporel de matching et son timeout
- Le format du `stageOutput` passé entre stages
- Les events on-chain émis à chaque transition

### 4.5 Section à SUPPRIMER/SIMPLIFIER

- Toute mention de DAG, parallel execution, ou conditional branching dans les workflows
- Toute mention de budget reallocation dynamique
- Toute mention de Tier customization par le client

---

## 5. Implementation Priority

### Phase 1 : Fondations on-chain (Semaine 1–2)

```
Priority 1: WorkflowEscrow.sol — Stage State Machine
├── struct Workflow { stages[], budgetSplits[], currentStage, status }
├── struct Stage { status, agentReq, budget, qgThreshold, outputHash }
├── createWorkflow() + tests
├── advanceStage() + tests
├── failStage() + tests (retry + abort paths)
└── Objectif: 20+ tests Foundry, 0 interaction avec MissionEscrow

Priority 2: WorkflowEscrow.sol — Integration MissionEscrow
├── startStage() → appelle MissionEscrow.createMission()
├── advanceStage() → appelle MissionEscrow.completeMission()
├── Tests d'intégration (WorkflowEscrow + MissionEscrow)
└── Objectif: Les 14 tests MissionEscrow restent verts

Priority 3: WorkflowEscrow.sol — QG Attestation + Dispute
├── submitQualityGate(workflowId, stageId, reportHash, score, sig)
├── disputeStage() + resolveDispute()
├── Timeout mechanics (stage matching timeout, dispute window)
└── Objectif: Contrat complet, < 500 lignes
```

### Phase 2 : Plan Compiler off-chain (Semaine 3–4)

```
Priority 4: Tier Preset Resolver
├── Input: (issue metadata, budget) → Output: Tier
├── Budget validation (min/max par Tier)
├── Règles déterministes, pas de ML
└── Tests unitaires exhaustifs

Priority 5: Plan Generator
├── Input: Tier → Output: Plan { stages[], budgetSplits[], qgConfigs[] }
├── Templates par Tier (fixtures)
├── planHash computation (keccak256 du plan sérialisé)
└── Client signature request (EIP-712)

Priority 6: Agent Matcher (lazy, per-stage)
├── Input: agentRequirements + stage context → Output: agentAddress
├── pgvector similarity search
├── Filtres: reputation ≥ threshold, heartbeat < 5min, capacity > 0
└── Fallback: queue publique si aucun match
```

### Phase 3 : Intégration E2E (Semaine 5–6)

```
Priority 7: Workflow Orchestrator Service
├── Écoute StageCompleted events
├── Déclenche Agent Matcher pour stage suivant
├── Appelle startStage() on-chain
├── Gère les timeouts (matching, execution)
└── Monitoring & alerting

Priority 8: Client API & UX
├── POST /workflows — crée un workflow (issue URL + budget)
├── GET /workflows/:id — statut temps réel
├── Webhook notifications (stage completed, dispute, etc.)
└── Dashboard minimal
```

---

## 6. Next Cycle Focus

### Question centrale du Cycle zg :

> **"Quel est le protocol exact de communication entre stages, et comment l'output du stage N devient l'input du stage N+1 sans créer un couplage ingérable ?"**

C'est le problème le plus sous-spécifié. Concrètement :

1. **Format du stageOutput :** Un hash on-chain, oui — mais de quoi exactement ? Un commit SHA ? Un artifact URL ? Un JSON structuré ? Le format doit être standardisé par Tier et par type de stage (code, review, test, deploy).

2. **Passage de contexte :** L'agent du stage 3 doit comprendre ce que les agents des stages 1 et 2 ont produit. Comment s'assurer que le contexte est suffisant sans créer un couplage (l'agent 3 ne devrait pas dépendre de l'implémentation interne de l'agent 1) ?

3. **Versioning des outputs :** Si le stage 2 (review) demande des corrections au stage 1, est-ce un retry du stage 1 ou un aller-retour au sein du stage 2 ? Cela a des implications financières directes (qui paie pour les corrections ?).

4. **Taille du contexte :** Pour des issues complexes (Platinum, 6 stages), le contexte cumulé peut devenir énorme. Faut-il un mécanisme de résumé/compression entre stages ?

### Questions secondaires pour le cycle zg :

- Spec détaillée du `submitQualityGate` : quels scores sont numériques vs binaires ? Quelle granularité ?
- Timeout values par Tier : combien de temps pour le matching ? Pour l'exécution d'un stage ? Pour une dispute ?
- Monitoring : quels events on-chain sont critiques pour le dashboard ? Quelle indexation (subgraph vs custom indexer) ?

---

## 7. Maturity Score

### Score : 7.0 / 10

**Justification détaillée :**

| Dimension | Score | Commentaire |
|---|---|---|
| Architecture globale | 8.5/10 | Deux couches bien séparées, composition validée, state machine claire |
| Smart contract spec | 7.5/10 | Interface définie, mais les edge cases (timeout, partial refund) restent à détailler |
| Off-chain Compiler | 6.5/10 | Tier Presets définis, mais le Plan Generator et l'Agent Matcher sont encore des boîtes noires |
| Quality Gates | 6.0/10 | Pattern attestation + commitment validé, mais format/seuils/granularité non spécifiés |
| Stage-to-stage protocol | 4.0/10 | C'est le maillon faible — identifié mais non résolu (cf. cycle zg) |
| Failure/Dispute flows | 6.5/10 | Retry/Abort/Dispute définis conceptuellement, pas assez de détails d'implémentation |
| Implémentabilité | 7.5/10 | Un développeur senior pourrait commencer Phase 1 dès maintenant avec ces specs |
| Sécurité financière | 7.0/10 | Le modèle escrow est sain, mais le gap temporel entre stages est un point d'attention |

**Pourquoi pas 8+ :** Le protocol de communication inter-stages (4.0/10) tire le score vers le bas. C'est le composant structurant qui manque. Sans lui, le workflow reste une séquence de missions isolées — les agents ne composent pas réellement.

**Pourquoi pas 6- :** Les fondations sont solides. Le contrat on-chain est spécifiable en l'état. La Phase 1 (smart contract) peut démarrer immédiatement. Le risque résiduel est concentré sur un problème bien identifié, pas distribué sur toute l'architecture.

**Seuil de build :** **8.0/10.** Il manque ~1 cycle (zg) pour atteindre le seuil de confiance. Le cycle zg doit résoudre le protocole inter-stages et détailler les Quality Gates. Après quoi, le feu vert de build est justifié.