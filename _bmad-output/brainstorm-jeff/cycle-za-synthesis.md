

# Cycle za — Synthesis & Decisions

---

## 1. Décisions Retenues

### 1.1 Le Budget achète un niveau de confiance, pas du compute

**Validé.** C'est le positionnement produit le plus différenciant du projet. Le marché est saturé de "hire an AI agent" ; personne ne vend encore du **verifiable quality assurance as a function of budget**. Ça parle directement au buyer enterprise qui a un procurement process et qui justifie la dépense par la réduction du rework.

**Justification chiffrée :** Si le "30% rework tax" existe réellement (chiffre cohérent avec les études Stripe/McKinsey sur le coût de la mauvaise qualité logicielle), un workflow à 3 stages qui coûte 40% de plus mais élimine 80% du rework est NPV-positif dès la première mission.

### 1.2 Pipeline DAG contraint (pas un DAG arbitraire)

**Validé.** Un DAG arbitraire en V1 est un piège mortel :
- Gas imprévisible pour la traversée on-chain
- Surface d'attaque combinatoire sur les quality gates
- UX incompréhensible pour le client qui poste une issue

Les **3 patterns retenus** (Sequential, Parallel Fan-out, Conditional Branch) couvrent >95% des cas réels. On pourra ouvrir le DAG en V2 si la demande existe.

**Guard-rail critique :** Max 6 stages par workflow. Au-delà, la valeur marginale d'un stage supplémentaire est négative (latence, coût, complexité de dispute).

### 1.3 Workflow comme entité intermédiaire entre Client et Missions

**Validé.** L'architecture à 3 couches est saine :

```
Client → Workflow (orchestration) → Mission[] (exécution)
                                  → QualityGate[] (validation)
```

Le Workflow n'a **pas** besoin d'être un smart contract séparé. Il peut être un `struct` au sein d'un `WorkflowEscrow.sol` qui wraps le `MissionEscrow` existant. Ça préserve la composabilité :

```
WorkflowEscrow.sol
├── createWorkflow(stages[], budgetSplit[], qualityGateConfigs[])
├── advanceStage(workflowId, stageOutput, proof)
├── failStage(workflowId, reason) → conditional branch
└── inherits/composes MissionEscrow pour chaque stage
```

### 1.4 Les 14 tests Foundry existants comme base de non-régression

**Validé.** Le `MissionEscrow.sol` à 323 lignes avec 14/14 tests verts est le socle. Toute extension (WorkflowEscrow) doit **composer** avec, pas le modifier. Pattern : `WorkflowEscrow` appelle `MissionEscrow.createMission()` pour chaque stage, agissant comme un meta-client.

---

## 2. Décisions Rejetées

### 2.1 ❌ Quality Gates entièrement on-chain

**Rejeté.** Le cycle propose implicitement que les QG vivent on-chain avec pass/fail. En réalité :

- **Le jugement de qualité est subjectif** — un smart contract ne peut pas évaluer si un code review est pertinent
- **Le coût gas est prohibitif** — stocker les outputs de review on-chain est absurde
- **L'oracle problem** — qui pousse le pass/fail ? Si c'est l'agent reviewer, il est juge et partie

**Décision retenue à la place :** Quality Gates = **attestation off-chain avec commitment on-chain**

```
Off-chain: Agent reviewer produit un rapport + score
On-chain:  Hash(rapport) + score + signature agent → QualityGateAttestation
Dispute:   Le client peut challenger l'attestation → arbitrage (V2: Kleros/UMA)
```

Le smart contract ne vérifie que : (a) l'attestation existe, (b) elle est signée par un agent autorisé pour ce stage, (c) le score dépasse le threshold configuré.

### 2.2 ❌ Escrow partiel par stage avec release automatique

**Rejeté partiellement.** L'idée de splitter le budget entre stages est bonne, mais le **release automatique** sur pass du QG est dangereux :

- Collusion reviewer + coder : le reviewer auto-passe, les deux sont payés
- Pas de recours client si le résultat final est mauvais malgré des QG passés

**Décision retenue à la place :** **Escrow progressif avec client veto window**

```
Stage N QG pass → Funds pour Stage N unlocked (pending)
                → Client a 24h pour veto
                → Si pas de veto : release
                → Si veto : freeze + dispute
Final Stage QG pass → Même flow, mais sur le total restant
```

Le client ne peut pas veto infiniment — après 2 vetos sans justification valide (arbitrage), il perd son droit de veto et les fonds sont releasés. Ça protège les agents contre les clients abusifs.

### 2.3 ❌ Budget tiers définis statiquement dans le contrat

**Rejeté.** Hardcoder "Bronze = 1 stage, Silver = 3 stages, Gold = 5 stages" dans le smart contract est une erreur de design :

- Les tiers changent avec le marché
- Différents types d'issues ont différents besoins (un bug fix n'a pas besoin de security audit)
- Ça couple la logique business au contrat immutable

**Décision retenue à la place :** Les tiers sont des **Workflow Templates** stockés off-chain (YAML), et le smart contract ne connaît que `stages[]` et `budgetSplit[]`. Le GitHub Bot traduit "budget = $50" en "template = standard-review" côté off-chain, puis appelle `createWorkflow()` avec les params concrets.

```yaml
# workflow-templates/standard-review.yaml
name: "Standard Review"
min_budget_usdc: 30
max_budget_usdc: 100
stages:
  - role: coder
    budget_pct: 60
    quality_gate:
      type: automated_tests
      threshold: 0.8
  - role: reviewer  
    budget_pct: 25
    quality_gate:
      type: llm_review_score
      threshold: 7.0
  - role: integration_check
    budget_pct: 15
    quality_gate:
      type: ci_green
      threshold: 1.0
```

---

## 3. Nouveaux Insights

### 3.1 🆕 Le Workflow crée un marché d'agents spécialisés par rôle

Insight non présent dans les cycles précédents : en introduisant des **stages typés** (coder, reviewer, security auditor, optimizer), on crée de facto des **sous-marchés** avec des dynamiques différentes :

| Rôle | Supply attendu | Pricing power | Cold-start difficulty |
|------|---------------|---------------|----------------------|
| Coder | Élevé (tout le monde veut coder) | Faible | Faible |
| Reviewer | Moyen | Moyen | Moyen |
| Security Auditor | Faible | Élevé | Élevé |
| Optimizer | Faible | Élevé | Élevé |

**Implication produit :** Il faut un **mécanisme d'incitation asymétrique** pour bootstrapper les rôles rares. Options :
- Bonus pool pour les premiers security auditors qui s'inscrivent
- Le reviewer touche un % si la mission finale est acceptée (skin in the game)
- Reputation multiplier pour les rôles rares (plus de visibilité dans le marketplace)

**Implication technique :** Le système de matching (`matchAgent()`) doit intégrer le rôle comme dimension primaire, pas juste le skill/reputation score.

### 3.2 🆕 Le conditional branch crée un problème de liveness

Si un QG échoue et qu'on route vers un "rework agent", que se passe-t-il si aucun rework agent n'est disponible ? Le workflow est stuck. C'est un **liveness problem** classique en systèmes distribués.

**Solutions concrètes :**
1. **Timeout par stage** : si le rework agent ne claim pas en 2h, le workflow abort et le client est remboursé (moins les stages déjà complétés)
2. **Fallback to original agent** : l'agent initial peut re-soumettre après correction, mais avec un malus reputation
3. **Escalation** : après 2 échecs du même stage, le client peut choisir "accept as-is" (release partiel) ou "abort" (refund partiel)

```solidity
// Pseudo-code pour le timeout
modifier stageNotExpired(uint256 workflowId, uint8 stageIdx) {
    Stage storage s = workflows[workflowId].stages[stageIdx];
    require(
        block.timestamp <= s.startedAt + s.timeoutSeconds,
        "Stage expired"
    );
    _;
}

function expireStage(uint256 workflowId, uint8 stageIdx) external {
    Stage storage s = workflows[workflowId].stages[stageIdx];
    require(block.timestamp > s.startedAt + s.timeoutSeconds, "Not expired");
    // Refund unspent budget to client
    // Release earned funds to completed stages
    _abortWorkflow(workflowId, stageIdx);
}
```

### 3.3 🆕 Les Quality Gates sont le vrai moat, pas l'escrow

L'escrow USDC est commoditisable — n'importe qui peut forker `MissionEscrow.sol`. Ce qui est **non-forkable** c'est :
- La bibliothèque de QG templates testés en production
- Les données de corrélation "quel type de QG réduit le plus le rework pour quel type d'issue"
- Le réseau d'agents spécialisés dans la review/audit avec un track record vérifié

**Action :** Investir dans les QG comme produit en soi. Chaque QG devrait avoir :
- Un score de fiabilité (combien de fois un QG pass a résulté en client satisfaction)
- Des métriques de false positive / false negative
- Un versioning (QG v1.2 est meilleur que v1.1 pour les issues type "refactoring")

### 3.4 🆕 Le split budgétaire crée un problème de pricing circulaire

Pour définir `budgetSplit[]`, il faut connaître le coût de chaque rôle. Mais le coût de chaque rôle dépend du marché, qui dépend de l'offre et de la demande, qui dépend du nombre de workflows actifs. C'est circulaire.

**Solution pragmatique V1 :** Le template YAML définit des `budget_pct` par défaut, mais le système de matching fait un **reverse auction par stage** :

```
1. Client poste issue avec budget = $80
2. Template "standard-review" → 3 stages (60/25/15%)
3. Stage 1 (coder): budget = $48 → agents bid
4. Si aucun bid en dessous de $48 → soit augmenter le %, soit réduire le nombre de stages
5. Surplus redistributé aux stages suivantes ou remboursé
```

---

## 4. PRD Changes Required

### 4.1 `MASTER.md` — Section "Smart Contract Architecture"

**Ajouter :** `WorkflowEscrow.sol` comme nouveau contrat qui compose `MissionEscrow.sol`

```markdown
### Contract Hierarchy
- `MissionEscrow.sol` — Atomic mission escrow (unchanged)
- `WorkflowEscrow.sol` — Multi-stage pipeline orchestrator
  - Creates N MissionEscrow instances per workflow
  - Manages stage transitions and quality gate attestations
  - Handles partial refunds on abort
  - Client veto window (24h default, configurable)
```

### 4.2 `MASTER.md` — Nouvelle section "Workflow Templates"

**Ajouter :** Spec complète des templates YAML avec les 3 patterns supportés, les constraints (max 6 stages, timeout par stage), et le mécanisme de fallback.

### 4.3 `MASTER.md` — Section "Agent Roles"

**Ajouter :** Taxonomie des rôles (coder, reviewer, security_auditor, optimizer, tester) avec les requirements de chaque rôle et le mécanisme d'incitation asymétrique pour les rôles rares.

### 4.4 `MASTER.md` — Section "Quality Gates"

**Réécrire complètement.** Passer de "QG = on-chain pass/fail" à "QG = off-chain attestation + on-chain commitment + client veto window + dispute escalation".

### 4.5 `MASTER.md` — Section "Fee Structure"

**Mettre à jour :** Le fee model change avec les workflows multi-stages :

```
Platform fee = 5% du budget total (pas par stage, sinon ça s'accumule)
Agent fee = bid price par stage
QG attestation fee = inclus dans le budget du reviewer stage (pas un fee séparé)
Gas sponsoring = Platform paie le gas pour les transitions de stage (UX)
```

### 4.6 GitHub Issues à créer

| Issue # | Titre | Priority |
|---------|-------|----------|
| #21 | `WorkflowEscrow.sol` — Multi-stage pipeline contract | P0 |
| #22 | Workflow Templates YAML spec + parser | P0 |
| #23 | Quality Gate attestation model (off-chain + on-chain commitment) | P0 |
| #24 | Stage timeout + abort + partial refund logic | P1 |
| #25 | Client veto window mechanism | P1 |
| #26 | Agent role taxonomy + role-based matching | P1 |
| #27 | Reverse auction per stage | P2 |
| #28 | QG reliability scoring (data pipeline) | P2 |

---

## 5. Implementation Priority

### Phase 1 — Foundation (Semaines 1-2) — Ne pas casser ce qui marche

```
┌────────────────────────────────────────────┐
│ 1. WorkflowEscrow.sol                      │
│    - createWorkflow(stages[], splits[])     │
│    - advanceStage() avec QG hash check     │
│    - abortWorkflow() avec partial refund   │
│    - Compose MissionEscrow, don't modify   │
│                                            │
│ 2. Foundry tests pour WorkflowEscrow       │
│    - Happy path: 3 stages, all pass        │
│    - Stage fail → conditional branch       │
│    - Stage timeout → abort + refund        │
│    - Client veto → freeze                  │
│    - Target: 20+ tests verts               │
│                                            │
│ 3. Workflow Template parser (Python)        │
│    - YAML → createWorkflow() calldata      │
│    - Validation: max stages, budget sanity │
└────────────────────────────────────────────┘
```

**Pourquoi cet ordre :** Le contrat est le risque #1 (immutable une fois déployé). Les tests sont la preuve que le contrat est correct. Le parser est le bridge entre UX et contrat.

### Phase 2 — Integration (Semaines 3-4) — Le bot GitHub orchestre

```
┌────────────────────────────────────────────┐
│ 4. GitHub Bot v2                           │
│    - Issue label → template selection      │
│    - `/budget $80` command → workflow      │
│    - Stage progress comments on issue      │
│    - QG results displayed inline           │
│                                            │
│ 5. Agent SDK v2                            │
│    - GET /workflow/{id}/my-stage           │
│    - POST /stage/{id}/submit (with proof)  │
│    - Webhook: stage_assigned, stage_failed │
│                                            │
│ 6. QG Attestation service                  │
│    - Off-chain review execution            │
│    - Hash commitment to chain              │
│    - Signature verification                │
└────────────────────────────────────────────┘
```

### Phase 3 — Hardening (Semaines 5-6) — Production readiness

```
┌────────────────────────────────────────────┐
│ 7. Client veto window UI/UX               │
│ 8. Stage timeout watchdog service          │
│ 9. Partial refund accounting               │
│ 10. Slither + manual audit                 │
│ 11. Sepolia deployment + E2E test          │
│ 12. 3 real issues processed end-to-end     │
└──��─────────────────────────────────────────┘
```

### Critical Path

```
WorkflowEscrow.sol → Tests verts → Template parser → Bot v2 → E2E on Sepolia
       ↑                                                            ↑
   BLOQUANT pour tout                                    BLOQUANT pour launch
```

---

## 6. Next Cycle Focus

### La question la plus importante : **Comment évaluer objectivement la qualité d'un Quality Gate ?**

C'est le **meta-problem** : on construit un système où des agents jugent d'autres agents. Mais qui juge les juges ?

Sous-questions concrètes à traiter au cycle zb :

1. **QG scoring model** : Comment mesurer la fiabilité d'un reviewer agent ? Corrélation entre ses "pass" et la satisfaction client finale ? Ça nécessite des données qu'on n'a pas encore.

2. **Collusion detection** : Si Agent A (coder) et Agent B (reviewer) sont opérés par la même entité, ils peuvent collude pour pass systématiquement. Comment détecter/prévenir ça ? Options : agent reputation graph, randomized reviewer assignment, mandatory diversity (reviewer ≠ même operator que coder).

3. **QG standardization** : Est-ce qu'un "score de 7/10 en code review" veut dire la même chose pour deux reviewers différents ? Probablement pas. Comment normaliser ?

4. **Le cas dégénéré** : Que se passe-t-il quand le reviewer est meilleur que le coder ? Il finit par réécrire le code au lieu de le reviewer. Le rôle de reviewer doit-il avoir un scope constraint explicite ?

5. **Automated QG vs Human-in-the-loop QG** : Pour V1, est-ce qu'on supporte les deux ? Les automated QG (CI pass, test coverage > 80%) sont objectifs mais limités. Les human/LLM QG sont plus riches mais subjectifs.

**Proposition pour cycle zb :** Designer un **QG Framework** avec 3 types :
- **Deterministic** : CI green, tests pass, linter clean → Binary, on-chain verifiable
- **Heuristic** : LLM review score, complexity metrics → Numeric, off-chain with commitment
- **Human** : Client or designated reviewer approval → Binary, off-chain with signature

Chaque workflow template déclare quel type de QG par stage. Le contrat ne change pas — il vérifie juste attestation + signature + threshold.

---

## 7. Maturity Score

### Score global : **7.5 / 10**

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Smart Contract (MissionEscrow)** | 9/10 | 14/14 tests, code reviewé, déployable sur Sepolia |
| **Smart Contract (WorkflowEscrow)** | 3/10 | Concept validé, structures identifiées, **aucun code écrit** |
| **Off-chain (Bot + Agent SDK)** | 7/10 | Walking skeleton fonctionnel, mais pas de workflow support |
| **Architecture Design** | 8/10 | Patterns clairs, risques identifiés, décisions justifiées |
| **Quality Gate Design** | 5/10 | Direction claire (off-chain + commitment), mais QG framework pas encore spécé |
| **Economic Model** | 6/10 | Budget split + reverse auction identifiés, mais pas modélisé (simulations absentes) |
| **Production Readiness** | 4/10 | Pas de monitoring, pas de incident response, pas de rate limiting |
| **Security** | 6/10 | Slither dans CI, OFAC/anti-Sybil identifiés, mais collusion pas traitée |

### Justification du 7.5

On est passé de **spec théorique** (cycles a-s, ~74/100) à **code fonctionnel + tests verts** (cycles T-Y, ~95/100 pour l'escrow atomique). Le cycle za introduit le **workflow layer** qui est le vrai produit — et sur ce layer, on est à ~40% de maturité.

Le 7.5 reflète : **fondations solides, mais le feature qui fait le produit (tiered workflows) n'existe pas encore en code.**

### Prêt à builder ?

**Oui, mais sous contrainte :**
- ✅ On peut commencer `WorkflowEscrow.sol` immédiatement — le design est assez clair
- ✅ Les templates YAML sont implémentables en parallèle
- ⚠️ Le QG framework doit être spécé au cycle zb AVANT de coder le QG attestation service
- ⚠️ Le economic model (reverse auction per stage) nécessite une simulation avant implémentation — sinon risque de pricing dysfonctionnel
- ❌ Ne PAS déployer sur mainnet avant d'avoir résolu le problème de collusion reviewer/coder

### Gate pour passer à 9/10

```
□ WorkflowEscrow.sol avec 20+ tests verts
□ 3 workflow templates en YAML validés
□ QG Framework spécé (cycle zb)
□ 1 E2E workflow exécuté sur Sepolia (3 stages, vrais agents)
□ Collusion mitigation strategy implémentée (au minimum: random reviewer assignment)
□ Economic simulation: 100 workflows simulés avec pricing dynamique
```