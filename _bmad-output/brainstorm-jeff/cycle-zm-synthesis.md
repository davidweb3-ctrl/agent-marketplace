

# Cycle zm — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 ✅ Le budget achète de la réduction d'incertitude, pas du compute

**Justification :** C'est le positionnement produit fondamental. Le tier system n'est pas un menu de features — c'est un produit d'assurance qualité avec un taux de défaut quantifiable par tier. Chaque stage supplémentaire dans le pipeline fait décroître la probabilité de livrable défectueux de manière géométrique (pas linéaire). Un buyer enterprise ne justifie pas "3 agents" en procurement — il justifie un SLA de défaut < X%.

**Impact concret :** Le pricing ne se calcule pas en `coût_agent × nombre_agents` mais en `coût_base × uncertainty_reduction_factor`. Le PRD doit refléter ce framing dans la section pricing et dans tout le wording client-facing.

### 1.2 ✅ Pipeline séquentiel contraint — pas de DAG en V1

**Justification durcie au-delà du cycle zl :**

| Dimension | Pipeline | DAG |
|-----------|----------|-----|
| Gas `advanceStage()` | O(1) — incrément d'index | O(n) — résolution des dépendances |
| Localisation de failure | Déterministe — le stage N a fail | Ambiguë — causalité floue entre branches parallèles |
| State space | Linéaire ~10 états | Exponentiel 2^n combinaisons |
| Dispute resolution UX | "Votre workflow est bloqué à l'étape 2" | "Le nœud C attend B et D, D est en dispute, C est bloqué, votre remboursement partiel dépend de..." |
| Auditabilité on-chain | Log séquentiel trivial | Reconstruction du graphe nécessaire |

**Guard-rail maintenu :** Max 6 stages par workflow. Au-delà, valeur marginale négative.

**Trappe pour V2 :** Le pipeline séquentiel est un sous-cas de DAG (graphe linéaire). Si le `stageIndex` est remplacé par un `stageId` avec `dependencies[]`, la migration est non-breaking. On ne ferme aucune porte.

### 1.3 ✅ Architecture 3 couches : Client → Workflow → Mission[]

```
WorkflowEscrow.sol (orchestration, state machine du pipeline)
    │
    ├── compose MissionEscrow.sol (exécution unitaire par stage)
    │       └── 14/14 tests Foundry existants = socle intouchable
    │
    └── QualityGateAttestation[] (validation inter-stage)
```

**Choix structurel clé :** `WorkflowEscrow` **compose** `MissionEscrow`, il ne le modifie pas et n'en hérite pas. Il agit comme un meta-client qui appelle `MissionEscrow.createMission()` pour chaque stage. Les 323 lignes existantes restent intactes. Zéro régression.

### 1.4 ✅ Quality Gates = attestation off-chain avec commitment on-chain

**Architecture validée :**

```
┌───────────────────────────────────���──────────────┐
│                    OFF-CHAIN                       │
│                                                    │
│  Agent Reviewer exécute le QG:                     │
│  - Analyse du livrable du stage précédent          │
│  - Produit un rapport structuré (JSON/Markdown)    │
│  - Calcule un score (0-100)                        │
│  - Signe le tout (EIP-712)                         │
│                                                    │
├──────────────────────────────────────────────────┤
│                    ON-CHAIN                         │
│                                                    │
│  QualityGateAttestation {                          │
│    bytes32 reportHash;    // keccak256(rapport)    │
│    uint8   score;         // 0-100                 │
│    uint8   threshold;     // configuré par tier    │
│    address reviewer;      // agent qui a jugé      │
│    bytes   signature;     // EIP-712               │
│    bool    passed;        // score >= threshold    │
│  }                                                 │
│                                                    │
│  Si passed → advanceStage()                        │
│  Si !passed → retry ou failStage()                 │
│  Si contesté → dispute (V2: Kleros/UMA)           │
└──────────────────────────────────────────────────┘
```

**Pourquoi pas on-chain pur :** Le jugement de qualité est subjectif, le stockage on-chain est prohibitif, et un agent reviewer qui push son propre pass/fail est juge et partie sans mécanisme de contestation. L'attestation signée off-chain + hash on-chain donne la vérifiabilité sans le coût.

### 1.5 ✅ Tier system comme produit packagé

Trois tiers avec des pipelines prédéfinis — le client ne compose pas son pipeline, il choisit un niveau de certitude :

| Tier | Pipeline | Stages | Défaut estimé | Use case |
|------|----------|--------|---------------|----------|
| **Basic** | Code only | 1 | ~30-40% | Prototypage, issues triviales |
| **Standard** | Code → Review | 2 (+1 QG) | ~10-15% | Issues standard, PR quality |
| **Premium** | Code → Review → Test | 3 (+2 QG) | ~3-5% | Production code, security-sensitive |

**Pricing :** Non linéaire. Le Premium ne coûte pas 3× le Basic — il coûte ~2-2.5× car la valeur perçue de l'uncertainty reduction justifie une marge plus élevée sur les tiers hauts.

---

## 2. Décisions Rejetées

### 2.1 ❌ Quality Gates entièrement on-chain (jugement + données)

**Rejeté définitivement.** Trois raisons irréductibles :
1. **Oracle problem non résolu** — Qui décide que le code est "bon" ? Un LLM on-chain ? Non. Un agent off-chain qui push un booléen ? C'est un oracle avec tous les problèmes associés.
2. **Coût gas** — Stocker un rapport de review on-chain coûte plus cher que la mission elle-même pour des issues < $100.
3. **Subjectivité irréductible** — "Ce code est maintenable" n'est pas une propriété vérifiable par un smart contract. Même les tests automatisés ne capturent qu'une fraction de la qualité.

**Ce qu'on fait à la place :** Attestation off-chain signée (cf. 1.4). Le contrat ne vérifie que la signature et le score vs. threshold. Le jugement reste off-chain, la preuve est on-chain.

### 2.2 ❌ WorkflowEscrow comme contrat séparé avec héritage de MissionEscrow

**Rejeté.** L'héritage (`is MissionEscrow`) crée un couplage fort : toute modification de MissionEscrow casse potentiellement WorkflowEscrow. Le pattern **composition** est strictement supérieur ici :

```solidity
// ❌ REJETÉ
contract WorkflowEscrow is MissionEscrow { ... }

// ✅ RETENU
contract WorkflowEscrow {
    IMissionEscrow public missionEscrow; // composition via interface
    
    function _createStage(...) internal {
        missionEscrow.createMission(...); // délègue
    }
}
```

**Raison supplémentaire :** Le MissionEscrow existant a 14 tests verts et est déjà déployable. Le WorkflowEscrow est un consommateur, pas une extension.

### 2.3 ❌ Tiers configurables par le client (nombre de stages custom)

**Rejeté en V1.** Laisser le client construire un pipeline de 7 stages avec des QG custom, c'est :
- Un cauchemar UX ("je configure mon pipeline CI/CD" ≠ ce que veut un buyer)
- Un risque de gas imprévisible
- Un surface de dispute démultipliée (chaque stage custom = un point de failure non anticipé)

**Le client choisit un tier, pas une architecture.** Les tiers sont des produits packagés, pas un framework de composition.

### 2.4 ❌ Arbitrage on-chain en V1 (Kleros/UMA)

**Rejeté pour V1**, mais explicitement roadmappé V2. En V1, le dispute resolution est :
1. **Automated** — Si le QG score < threshold, le stage est rejeté automatiquement, l'agent peut retry (max N fois configurable par tier).
2. **Manual fallback** — Si contestation de l'attestation QG, le client ou l'agent flag, et un admin multisig tranche (centralised mais opérant pour le volume V1).
3. **V2** — Kleros/UMA pour arbitrage décentralisé quand le volume justifie le coût d'intégration.

---

## 3. Nouveaux Insights

### 3.1 🆕 Le WorkflowEscrow comme meta-client du MissionEscrow

C'est genuinely nouveau. Les cycles précédents parlaient de "workflow qui orchestre des missions" de manière abstraite. La décision concrète ici est que **le WorkflowEscrow est, du point de vue du MissionEscrow, un client comme un autre**. Il appelle `createMission()`, il reçoit les callbacks de completion, il dispute si nécessaire. Le MissionEscrow ne sait pas qu'il est dans un pipeline.

**Implications architecturales profondes :**
- Le MissionEscrow reste un primitive composable — tout futur pattern (DAG, parallel, etc.) peut le consommer
- Le WorkflowEscrow gère uniquement la state machine du pipeline et les QG — séparation des concerns propre
- Le budget split entre stages est géré par le WorkflowEscrow, pas par le MissionEscrow (qui ne connaît que le montant d'une mission individuelle)

```solidity
// WorkflowEscrow crée les missions séquentiellement
function advanceStage(uint256 workflowId, bytes calldata proof) external {
    Workflow storage wf = workflows[workflowId];
    
    // Vérifier le QG du stage courant
    require(_validateQualityGate(wf, proof), "QG_FAILED");
    
    // Avancer au stage suivant
    wf.currentStage++;
    
    if (wf.currentStage < wf.totalStages) {
        // Créer la mission pour le prochain stage
        uint256 missionId = missionEscrow.createMission(
            wf.agents[wf.currentStage],
            wf.budgets[wf.currentStage],
            wf.deadlines[wf.currentStage]
        );
        wf.stageMissions[wf.currentStage] = missionId;
    } else {
        // Pipeline terminé — release final au client
        _finalizeWorkflow(workflowId);
    }
}
```

### 3.2 🆕 Le QualityGate threshold comme variable de pricing, pas juste de qualité

Insight non trivial : le **threshold du QG** (le score minimum pour passer au stage suivant) est un levier de pricing, pas juste un paramètre technique.

- **Basic tier** : pas de QG (ou threshold = 0, auto-pass) → le client paye le minimum, il accepte le risque
- **Standard tier** : threshold = 60/100 → un agent reviewer doit attester que le livrable est "acceptable"
- **Premium tier** : threshold = 80/100 → le reviewer doit attester que c'est "bon"

**L'implication** : le même pipeline avec les mêmes agents peut produire des résultats de tier différent juste en changeant le threshold. Le tier n'est pas que le nombre de stages — c'est le nombre de stages × l'exigence de chaque gate. Ça ouvre la porte à un pricing plus fin que "1, 2 ou 3 agents".

### 3.3 🆕 La création séquentielle des missions comme avantage économique

Le WorkflowEscrow ne crée **pas** toutes les missions upfront. Il crée la mission du stage N+1 uniquement quand le QG du stage N passe. Ça a trois avantages concrets :

1. **Capital efficiency** — Le budget pour les stages futurs reste dans le WorkflowEscrow, pas locké dans des MissionEscrow séparés. En cas de fail au stage 1, les fonds des stages 2 et 3 sont immédiatement retournables, pas bloqués dans des missions non-started.

2. **Agent assignment tardif** — L'agent du stage 2 n'a pas besoin d'être assigné au moment de la création du workflow. Le WorkflowEscrow peut faire appel au matching engine quand le QG[0] passe, avec le contexte du livrable du stage 1 (meilleur matching).

3. **Gas savings** — Si 40% des workflows fail au stage 1, on a économisé le gas de création de 2 missions inutiles.

```
Timeline :
T0  → Client crée Workflow (budget total locké dans WorkflowEscrow)
T1  → WorkflowEscrow crée Mission[0] (budget stage 0 transféré à MissionEscrow)
T2  → Agent[0] livre, QG[0] passe
T3  → WorkflowEscrow crée Mission[1] (budget stage 1 transféré)
T4  → Agent[1] livre, QG[1] passe  
T5  → WorkflowEscrow crée Mission[2] (budget stage 2 transféré)
T6  → Agent[2] livre, QG[2] passe
T7  → finalizeWorkflow() → livrable final au client
```

### 3.4 🆕 Le problème du reviewer juge-et-partie reste ouvert

Le challenge identifié dans le cycle est réel et non résolu : si l'agent reviewer du QG est sélectionné par le même système qui a sélectionné l'agent coder, il y a un risque de collusion (même opérateur pour les deux agents) ou de complaisance (le reviewer est payé au pass, pas à la qualité de son review).

**Solutions possibles à investiguer :**
- **Reviewer payé au flag rate** — Le reviewer gagne plus si son taux de flag (score < threshold) est dans un range sain (5-25%). Trop de pass = complaisance suspectée. Trop de fail = sabotage suspecté.
- **Rotation forcée** — Un reviewer ne peut pas reviewer deux fois de suite le même coder-agent.
- **Client spot-check** — Le client peut à tout moment demander à voir le rapport off-chain et contester l'attestation.
- **Reputation staking** — Le reviewer stake une partie de sa rémunération ; s'il est contesté et perd, il perd le stake. (V2)

Ce problème est **fondamental** et doit être explicitement documenté comme "known design tension" dans le PRD.

---

## 4. PRD Changes Required

### 4.1 `MASTER.md` — Section Architecture

| Sous-section | Action | Contenu |
|---|---|---|
| **Smart Contract Architecture** | **AJOUTER** | Diagramme 3 couches `Client → WorkflowEscrow → MissionEscrow[]`. Spécifier le pattern composition (pas héritage). |
| **WorkflowEscrow.sol spec** | **CRÉER** | Interface complète : `createWorkflow()`, `advanceStage()`, `failStage()`, `cancelWorkflow()`. Spécifier que MissionEscrow est unchanged. |
| **Quality Gate spec** | **CRÉER** | Attestation model off-chain/on-chain. Struct `QualityGateAttestation`. Signer = reviewer agent. Dispute flow V1 (manual) vs V2 (Kleros). |
| **State Machine** | **MODIFIER** | Ajouter les états du Workflow (pas seulement de la Mission). États : `Created → Stage[0]Active → Stage[0]QG → Stage[1]Active → ... → Completed \| Failed \| Disputed`. |

### 4.2 `MASTER.md` — Section Product / Pricing

| Sous-section | Action | Contenu |
|---|---|---|
| **Tier Definitions** | **CRÉER** | Basic / Standard / Premium avec pipeline, QG thresholds, taux de défaut estimé, pricing ratio. |
| **Value Proposition** | **MODIFIER** | Reframer explicitement : "le budget achète de la réduction d'incertitude". Ajouter le calcul NPV-positif pour le buyer enterprise. |
| **Pricing Model** | **MODIFIER** | Ajouter la composante QG threshold comme variable de pricing. Documenter que le pricing est non-linéaire (Premium ≠ 3× Basic). |

### 4.3 `MASTER.md` — Section Risk / Known Design Tensions

| Sous-section | Action | Contenu |
|---|---|---|
| **Reviewer collusion** | **CRÉER** | Documenter le problème juge-et-partie. Lister les mitigations V1 (rotation, client spot-check) et V2 (staking, Kleros). |
| **Pipeline failure economics** | **CRÉER** | Que se passe-t-il quand un stage fail après 3 retries ? Politique de remboursement partiel (stages complétés = payés, reste = remboursé). |
| **Stage budget split** | **CRÉER** | Documenter la répartition : suggestion initiale 60% coder / 25% reviewer / 15% tester, ajustable par tier. |

### 4.4 Nouveaux fichiers à créer

| Fichier | Contenu |
|---|---|
| `contracts/WorkflowEscrow.sol` | Squelette avec interface, structs, et state machine |
| `test/WorkflowEscrow.t.sol` | Tests Foundry pour le pipeline 3-stage end-to-end |
| `docs/quality-gate-spec.md` | Spécification détaillée du protocole d'attestation QG |
| `docs/tier-system.md` | Définition des 3 tiers avec tous les paramètres |

---

## 5. Implementation Priority

### Phase 1 — Foundation (Week 1-2)

```
Priority 1: WorkflowEscrow.sol — struct + state machine only
├── Struct Workflow { stages[], currentStage, status, budgets[] }
├── createWorkflow() — lock budget total
├── State transitions sans QG (auto-advance pour tester le pipeline)
└── Tests: create, advance through all stages, finalize, cancel

Priority 2: Integration avec MissionEscrow existant
├── WorkflowEscrow appelle MissionEscrow.createMission() par stage
├── Callback/polling pattern pour détecter mission completion
├── Test end-to-end: workflow 3 stages avec MissionEscrow réel
└── Vérifier: les 14 tests MissionEscrow passent toujours (non-régression)
```

### Phase 2 — Quality Gates (Week 3)

```
Priority 3: QualityGateAttestation on-chain
├── Struct QualityGateAttestation { reportHash, score, threshold, reviewer, sig }
├── EIP-712 signature verification
├── advanceStage() conditionné au QG pass
├── failStage() si QG fail + retry logic (max retries configurable)
└── Tests: pass, fail, retry, max retries exceeded

Priority 4: Off-chain QG reporter (minimal)
├── Script/service qui simule un reviewer agent
├── Produit un rapport JSON, le hash, le signe
├── Push l'attestation on-chain
└── Test d'intégration off-chain → on-chain
```

### Phase 3 — Tier System (Week 4)

```
Priority 5: Tier packaging
├── TierConfig struct { numStages, qgThresholds[], budgetSplits[], maxRetries }
├── createWorkflowFromTier(tierId, issueDetails) — factory method
├── 3 tiers hardcodés (Basic, Standard, Premium)
└── Tests: chaque tier produit le bon pipeline

Priority 6: Budget split et settlement
├── Répartition automatique du budget par stage au createWorkflow
├── Settlement partiel en cas de pipeline fail mid-way
├── Refund du budget non-utilisé (stages non-atteints)
└── Tests: partial completion, full completion, full failure
```

### Phase 4 — Hardening (Week 5)

```
Priority 7: Edge cases et sécurité
├── Reentrancy guards sur advanceStage/failStage
├── Timeout par stage (que se passe-t-il si un agent ne livre jamais ?)
├── Workflow cancellation mid-pipeline par le client
├── Agent qui livre après timeout
└── Fuzz testing sur state machine transitions

Priority 8: Gas optimization
├── Benchmark gas par opération (createWorkflow, advanceStage, etc.)
├── Packing des structs
├── Évaluer si les QG attestations doivent être stockées ou juste vérifiées (calldata vs storage)
└── Target: advanceStage() < 100k gas
```

---

## 6. Next Cycle Focus

### Question primaire du cycle suivant :

> **Comment le WorkflowEscrow détecte-t-il qu'une mission du MissionEscrow est complétée, et quel est le trust model de cette interface ?**

C'est la question la plus critique non résolue. Trois options à arbitrer :

| Option | Mécanisme | Trade-off |
|--------|-----------|-----------|
| **A. Polling** | Le client/keeper appelle `checkMissionStatus()` puis `advanceStage()` | Simple mais nécessite un acteur externe + gas |
| **B. Callback** | Le MissionEscrow appelle une fonction du WorkflowEscrow à la completion | Nécessite de modifier MissionEscrow (ajout d'un hook) → risque de régression |
| **C. Event-driven** | Le MissionEscrow émet un event, un service off-chain écoute et appelle `advanceStage()` | Découplé mais introduit un point de centralisation off-chain |
| **D. Permission grant** | Le WorkflowEscrow est le "client" dans MissionEscrow et a le droit d'appeler `acceptDeliverable()` | Le workflow auto-accepte basé sur le QG — mais le MissionEscrow doit supporter que le "client" soit un contrat |

**Option D est la plus prometteuse** mais nécessite de vérifier que le MissionEscrow existant n'a pas de `msg.sender == tx.origin` ou d'autres anti-contract guards. Si le MissionEscrow est déjà contract-friendly, l'intégration est triviale. Sinon, c'est un changement breaking.

### Questions secondaires :

1. **Budget split optimal par tier** — Quelle répartition coder/reviewer/tester maximise la qualité ? Peut-on backtester sur des données de code review existantes ?
2. **Timeout policy** — Deadline par stage = deadline absolue ou relative au start du stage ?
3. **Retry economics** — Quand un stage est retried, qui paye ? Le même budget (l'agent fait 2× le travail pour le même prix) ? Ou le budget du stage est augmenté ?

---

## 7. Maturity Score

### Score : 6.5 / 10

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Positionnement produit** | 8/10 | Le framing "acheter de la réduction d'incertitude" est solide, différenciant, et actionnable. Le tier system est prêt à builder. |
| **Architecture smart contract** | 7/10 | Le pattern composition WorkflowEscrow → MissionEscrow est sain. La state machine du pipeline est claire. Les structs sont esquissées. |
| **Quality Gate design** | 6/10 | L'attestation off-chain + commitment on-chain est le bon pattern, mais le protocole détaillé (format du rapport, EIP-712 domain, recovery en cas de reviewer absent) n'est pas encore spécifié. |
| **Interface WorkflowEscrow ↔ MissionEscrow** | 4/10 | C'est le maillon faible. On ne sait pas encore comment le workflow détecte la completion d'un stage. Les 4 options sont identifiées mais non tranchées. Bloquant pour l'implémentation. |
| **Dispute resolution** | 4/10 | V1 "admin multisig tranche" est honnête mais fragile. Le problème du reviewer juge-et-partie est identifié mais pas résolu. |
| **Pricing model** | 5/10 | Les ratios (Premium = 2-2.5× Basic) sont intuitifs mais pas backtestés. Le budget split (60/25/15) est arbitraire. Pas encore de modèle économique qui prouve que c'est profitable pour la plateforme. |
| **Implémentabilité** | 7/10 | Le plan en 4 phases / 5 semaines est réaliste. La non-régression sur MissionEscrow est clairement gardée. Le path vers du code est visible. |
| **Test coverage plan** | 7/10 | Les tests critiques sont identifiés par phase. Fuzz testing mentionné. Mais pas de tests d'intégration cross-contract détaillés. |

### Pour atteindre 8/10 :
1. **Trancher l'interface WorkflowEscrow ↔ MissionEscrow** (Option A/B/C/D) avec un spike de code
2. **Spécifier le protocole QG complet** (EIP-712 domain, format rapport, timeout reviewer, fallback si reviewer absent)
3. **Valider le budget split** avec au minimum un modèle de simulation (même un spreadsheet)

### Pour atteindre 9/10 :
4. Avoir le `WorkflowEscrow.sol` compilable avec les Phase 1 tests verts
5. Avoir une spec de dispute resolution V1 qui couvre 90% des cas sans Kleros

---

**Bottom line :** L'architecture est saine et le positionnement produit est fort. Le blocker principal est l'interface entre les deux contrats — c'est un problème d'ingénierie, pas de design. Un spike de code de 2 jours sur l'Option D (WorkflowEscrow comme meta-client du MissionEscrow) devrait débloquer le passage à 8/10 et permettre de commencer Phase 1.