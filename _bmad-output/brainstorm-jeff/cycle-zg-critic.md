

# Cycle zg — Critical Challenge (Critic)

---

## 1. Top 3 Failles Critiques

### Faille #1 : Le Plan Compiler est un Single Point of Failure centralisé qui détruit la proposition de valeur "décentralisé"

Soyons brutaux. Vous vendez un "decentralized compute marketplace" mais le composant le plus critique de votre architecture — celui que vous décrivez vous-même comme "le plus critique du système" — est un service off-chain centralisé que vous contrôlez entièrement. Le Plan Compiler décide de la topologie du DAG, des budget splits, des quality gate thresholds, des matching constraints. Le smart contract "applique aveuglément" ce qu'on lui donne.

**Ce que ça signifie concrètement :**
- Vous pouvez favoriser certains agents dans le matching (pay-to-play caché)
- Vous pouvez manipuler les budget splits pour maximiser les fees
- Un attaquant qui compromet le Plan Compiler contrôle 100% des flux financiers
- Le `planHash` on-chain ne prouve rien — il prouve que le plan n'a pas changé, pas qu'il est juste
- Aucun participant ne peut vérifier indépendamment que le plan compilé est optimal pour son budget

**Le vrai problème :** vous avez réinventé un intermédiaire centralisé avec des caractéristiques blockchain. C'est le pire des deux mondes — la lenteur et le coût du on-chain sans la décentralisation.

**Fix concret :** Le Plan Compiler doit être déterministe et open-source, avec des inputs vérifiables. Publiez le code du compiler, les inputs (TDL + budget + pool d'agents éligibles), et permettez à n'importe qui de recompiler le plan et vérifier qu'il matche le hash. Sinon vous êtes un SaaS classique avec un escrow crypto — ce qui n'est pas forcément mal, mais arrêtez de vendre de la décentralisation.

---

### Faille #2 : L'hypothèse "plus d'agents = meilleure qualité" est non seulement non prouvée, elle est probablement fausse

C'est le fondement de votre business model et c'est de la pensée magique. La littérature sur le software engineering montre exactement l'inverse :

- **Brooks's Law** : ajouter des ressources à un projet en retard le retarde davantage. Votre pipeline séquentiel force chaque agent à comprendre le contexte du précédent. Le coût de transfert de contexte entre agents AI est énorme et non résolu.
- **Un reviewer médiocre est pire que pas de reviewer** : si votre quality gate passe un code review bâclé, le client pense avoir une review alors qu'il n'en a pas. Faux sentiment de sécurité.
- **La qualité dépend du MEILLEUR agent, pas du NOMBRE d'agents** : un seul excellent coder produit un meilleur résultat que 5 agents médiocres en pipeline. Votre système incite à la quantité, pas à la qualité.

**Données qui devraient vous terrifier :** GitHub Copilot (1 agent, $10/mois) produit du code que la majorité des devs jugent acceptable. Votre Gold tier à $500+ doit être SIGNIFICATIVEMENT meilleur — pas 10% meilleur, mais 5x meilleur — pour justifier 50x le prix. Et vous n'avez aucune preuve que votre pipeline multi-agents y arrive.

**Fix concret :** Avant de builder l'architecture, faites un A/B test manuel. Prenez 50 tâches réelles. Faites-les exécuter par 1 bon agent vs votre pipeline 4-agents. Mesurez la qualité réelle. Si le pipeline ne gagne pas de manière écrasante, votre architecture est un exercice académique.

---

### Faille #3 : Le modèle économique des quality gates est un cercle vicieux pervers

Qui évalue la qualité dans vos quality gates ? Réfléchissez-y deux secondes :

**Option A : Un agent AI évalue un autre agent AI.** Problème : avec quelles garanties ? Un LLM qui review du code d'un autre LLM va avoir les mêmes blind spots. Si GPT-4 génère un bug subtil de concurrence, GPT-4 en reviewer va probablement le rater aussi. Vous n'avez pas ajouté de la qualité, vous avez ajouté du coût.

**Option B : Un humain évalue.** Problème : vous avez réintroduit l'humain dans la boucle, détruit la proposition de valeur "automated agent marketplace", et votre latence explose. Un humain qui review chaque stage d'un workflow Gold = 4 reviews humaines = 2-3 jours minimum. Pour un produit qui vend l'automatisation.

**Option C : Des métriques automatiques (coverage, lint, tests pass).** Problème : c'est du CI/CD. Ça existe déjà. GitHub Actions fait ça gratuitement. Pourquoi payer $500 pour ça ?

**Le cercle vicieux :** pour que les quality gates aient de la valeur, ils doivent être meilleurs que ce que le client peut faire seul. Mais s'ils sont automatiques, ils sont triviaux. S'ils sont agents-basés, ils partagent les mêmes limites que les agents qu'ils évaluent. S'ils sont humains, ils tuent le modèle.

**Fix concret :** Séparez radicalement l'évaluation de l'exécution. Les quality gates devraient être des benchmarks objectifs et pré-définis par le CLIENT (test suites fournies, specs formelles, expected outputs). Le système vérifie la conformité, pas la "qualité" subjective. C'est moins sexy mais c'est défendable.

---

## 2. Scalability Risks

### À 1,000 clients simultanés

**Problème #1 : Explosion combinatoire du matching.** 
Chaque workflow Gold a 4-5 stages. Chaque stage nécessite un matching agent. Avec 1,000 workflows actifs × 4 stages = 4,000 matching operations concurrentes. Votre matching utilise pgvector + embeddings (all-MiniLM-L6-v2). À 4,000 queries concurrentes sur un pool d'agents qui peut être < 500 au lancement, vous allez avoir :
- Contention massive sur les mêmes "bons" agents
- Des agents assignés à 20+ stages simultanément, dégradant leur qualité
- Le Plan Compiler devient un bottleneck CPU pour calculer 1,000 DAGs optimaux simultanément

**Problème #2 : Le pipeline séquentiel multiplie la latence par le nombre de stages.**
Bronze : 1 agent × T = T
Gold : 4 agents × T + 3 quality gates × T_qg = 4T + 3T_qg

Si T = 30 min et T_qg = 10 min, Bronze livre en 30 min, Gold livre en 2h30. Le client Platinum attend potentiellement 4-5 heures. À 1,000 clients avec des workflows actifs, votre système a des milliers de stages "en attente" du stage précédent. C'est un pipeline stall massif.

### À 100,000 missions

**Problème #3 : State explosion on-chain.**
Chaque workflow stocke `stageStates[]`, `stageBudgets[]`, `qualityGateThresholds[]`. Un workflow Platinum = 6 stages = ~18 storage slots. 100k missions × 18 slots = 1.8M storage operations sur Base L2. Même sur L2, c'est ~$180k en gas cumulé (en estimant $0.10 par storage write sur Base). Et ces données ne sont jamais nettoyées car "les stages complétés sont irréversibles".

**Problème #4 : Le quality gate bottleneck devient systémique.**
100k missions × 4 quality gates en moyenne = 400k évaluations. Si chaque évaluation prend 2 minutes de compute agent, vous avez besoin de 800k minutes de compute pour les seules quality gates. C'est 13,333 heures = 555 jours de compute séquentiel. Même parallélisé sur 100 évaluateurs, c'est 5.5 jours de backlog permanent. Vos quality gates deviennent le bottleneck du système entier.

**Problème #5 : Agent pool exhaustion.**
Si vous avez 500 agents et 100k missions/mois, chaque agent doit traiter 200 missions/mois = ~7/jour. Les "bons" agents (top 20%) seront saturés. Les clients Gold/Platinum qui paient plus s'attendent à de meilleurs agents, mais ces agents sont les plus demandés. Résultat : soit vous dégradez la qualité des tiers premium (mort du business model), soit vous créez des queues de plusieurs jours (mort de l'UX).

---

## 3. Smart Contract Attack Vectors

### Attack Vector #1 : Plan Hash Substitution Attack

Le contrat stocke `planHash` mais ne valide pas le contenu du plan. Le backend soumet `planHash + budgetSplits[]`. Rien n'empêche le backend de soumettre un `planHash` qui correspond à un plan favorable à un agent complice, puis de soumettre un plan différent (mais avec le même hash) aux agents. 

**Scénario concret :** Le backend compile un plan légitime, montre ce plan au client, mais soumet au contrat un `planHash` correspondant à un plan modifié où un agent complice reçoit 80% du budget pour un stage trivial. Le client ne peut pas vérifier car il ne peut pas recompiler le hash sans accès au compiler deterministic state.

**Mitigation :** Le client doit signer le plan entier off-chain, et le contrat doit vérifier cette signature. Pas juste le hash — le client doit avoir vu et approuvé le plan exact.

### Attack Vector #2 : Quality Gate Griefing

Le quality gate est une "attestation hashée" soumise off-chain puis vérifiée. Qui soumet l'attestation ? Si c'est l'agent reviewer, il a un incentive pervers :
- **Rejeter systématiquement** pour forcer un rework → le reviewer est re-payé pour une 2ème review
- **Accepter systématiquement** pour minimiser son travail → la qualité s'effondre
- **Collusion avec l'agent précédent** : l'agent coder et l'agent reviewer sont du même provider → auto-review

Le contrat ne peut pas distinguer une rejection légitime d'un griefing.

**Mitigation :** Les quality gates doivent avoir un coût pour le reviewer en cas de rejection (burn partiel du stake). Et les agents reviewer/coder doivent être de providers différents (constraint dans le Plan Compiler, mais qui vérifie que le Plan Compiler l'applique vraiment ?).

### Attack Vector #3 : Budget Drain via Conditional Branch Manipulation

Pattern 3 (Conditional Branch) pré-réserve un budget pour la branche fallback. Le score du quality gate détermine quelle branche est prise. Si l'évaluateur du quality gate est compromis :
- Il peut forcer la branche fallback systématiquement → le "Fix Agent" (qui peut être complice) est payé
- Le budget pré-réservé est consommé au lieu d'être refunded au client
- Sur 1,000 missions avec conditional branches, un attaquant peut drainer des dizaines de milliers de dollars

**Le problème structurel :** votre contrat "applique aveuglément" les transitions. C'est by design. Mais ça veut dire que toute la sécurité repose sur la couche off-chain, qui est centralisée et non-auditable par les participants.

### Attack Vector #4 : Stage Completion Front-Running

Sur Base L2, les transactions sont ordonnées par le sequencer. Un agent malveillant peut observer qu'un stage est sur le point d'être complété et front-run avec une completion frauduleuse si la validation de l'adresse de l'agent assigné se fait off-chain plutôt qu'on-chain. Votre architecture dit explicitement "agent addresses" ne sont PAS stockées on-chain. C'est un trou béant.

**Mitigation immédiate et non-négociable :** les adresses des agents assignés à chaque stage DOIVENT être stockées on-chain. Le gas supplémentaire est le prix de la sécurité.

---

## 4. Business Model Holes

### Hole #1 : Le value gap entre les tiers est injustifiable

| Tier | Prix | Ce que le client obtient concrètement |
|------|------|--------------------------------------|
| Bronze | $20 | Un agent code un truc |
| Silver | $100 | Un agent code + un autre review (5x le prix pour +1 agent) |
| Gold | $500 | Code + review + security + tests (25x Bronze pour +3 agents) |
| Platinum | $2000+ | Full pipeline (100x Bronze pour +5 agents) |

**La question que tout CFO va poser :** "Pourquoi je paie 25x plus cher pour Gold alors que je peux lancer 25 missions Bronze et garder le meilleur résultat ?"

C'est un problème fondamental. Le client rationnel va gaming votre système en lançant N missions Bronze plutôt que 1 mission Gold. C'est moins cher, plus rapide (parallèle vs séquentiel), et le client garde le contrôle de la sélection.

**Pire :** les tiers premium vendent de la "confiance" et de la "compliance". Mais la confiance vient de résultats prouvés, pas de process. Un client enterprise qui a fait 50 missions Bronze avec 95% de satisfaction n'a aucune raison de passer à Gold.

### Hole #2 : La fee structure tue la marge des agents sur les tiers premium

Fee split : 90% provider / 5% insurance / 3% burn / 2% treasury.

Sur un workflow Gold à $500 :
- Le budget est split entre 4-5 agents
- Chaque agent reçoit ~$100 brut
- Après fees (10%) : ~$90 net par agent
- Chaque agent fait le travail d'une mission Bronze ($20) mais avec les contraintes supplémentaires des quality gates, du context passing, et du format d'attestation

**Résultat :** les meilleurs agents vont préférer faire des missions Bronze directement — plus simples, marge similaire par unité de temps, moins de risque de rejection au quality gate. Votre pool d'agents pour les tiers premium sera composé des agents qui ne trouvent pas de missions Bronze. Exactement l'inverse de ce que vous voulez.

### Hole #3 : L'audit trail n'est pas un produit — c'est une feature checkbox

Vous positionnez l'audit trail comme différenciateur du tier Platinum. Mais :
- Un audit trail de quality gates passés par des agents AI n'a **aucune valeur légale**
- Aucun auditeur SOC2/ISO27001 n'accepte "un agent AI a attesté que le code est sécurisé"
- Les entreprises qui ont besoin de compliance réelle emploient des auditeurs humains certifiés
- Votre "compliance" est du théâtre de compliance — ça ressemble à de la compliance sans en être

Le seul scénario où votre audit trail a de la valeur : la compliance interne d'une entreprise qui veut tracer ses usages d'agents AI. C'est un marché, mais c'est un marché de logging, pas de quality assurance. Et ça ne justifie pas $2000.

---

## 5. Competitive Threat

### Menace #1 : OpenAI / Anthropic lancent leur propre marketplace (délai : déjà en cours)

OpenAI a le GPT Store (échec relatif, mais itérations en cours). Anthropic a Claude avec tool use et agents. Le jour où l'un d'eux lance "Claude Teams with Workflow Builder" :
- Ils ont déjà les meilleurs modèles (vous, vous wrappez leurs API)
- Ils ont déjà les utilisateurs (200M+ pour ChatGPT)
- Ils n'ont pas besoin de crypto, d'escrow, ou de tokenomics
- Un workflow builder drag-and-drop avec Stripe payment bat votre architecture crypto en UX de 10x

**Délai réaliste :** Anthropic a annoncé des agents autonomes. OpenAI pousse les "Tasks" et les custom GPTs composables. 6-12 mois max.

### Menace #2 : Un concurrent copie votre modèle sans la blockchain (délai : 3 mois)

Votre architecture se résume à : **pipeline d'agents séquentiels avec escrow et quality gates**. Stripe Connect + n8n/Temporal + un scoring system = 90% de votre proposition de valeur sans aucun smart contract.

Un dev senior peut builder ça en 3 mois :
- Temporal.io pour l'orchestration du DAG (battle-tested, 10x plus robuste que vos smart contracts)
- Stripe Connect pour le split payment et l'escrow
- Un simple scoring system PostgreSQL pour les quality gates
- Pas de token, pas de gas, pas de wallet — juste une carte de crédit

**Le résultat est strictement supérieur :** plus rapide (pas de blockchain latency), moins cher (pas de gas), meilleure UX (pas de wallet), même fonctionnalité.

**Question brutale :** Qu'est-ce que la blockchain apporte RÉELLEMENT ici que Stripe Connect + Temporal ne fait pas ? Si la réponse est "trust" ou "transparency", montrez-moi un seul client qui a choisi un produit plus lent, plus cher, et plus complexe pour de la "transparency".

### Menace #3 : Les frameworks open-source d'orchestration d'agents (délai : déjà là)

CrewAI, AutoGen, LangGraph — tous font de l'orchestration multi-agents avec des DAG. Ils sont gratuits, open-source, et ont des communautés actives. Un développeur peut self-host une pipeline Coder → Reviewer → Tester en une après-midi avec CrewAI.

Votre moat n'est pas la technologie d'orchestration (commodity). Ce n'est pas le matching (pgvector + embeddings = 50 lignes de code). Ce n'est pas l'escrow (Stripe ou smart contract = même fonctionnalité). **Où est votre moat ?**

---

## 6. Edge Cases Non Couverts

### Edge Case #1 : L'agent du Stage 3 contredit l'agent du Stage 2

L'agent Security Auditor (Stage 3) identifie que l'architecture choisie par le Coder (Stage 1) et approuvée par le Reviewer (Stage 2) est fondamentalement non-sécurisable. Que se passe-t-il ?
- Rework depuis Stage 1 ? Le budget de Stage 1 et 2 a déjà été releasé ("les stages complétés sont irréversibles")
- Continuer ? Le Security Auditor ne peut pas signer l'attestation de qualité
- Le client paie pour 3 stages dont 2 sont inutiles
- **Votre DAG séquentiel ne gère pas le backtracking.** C'est un problème fondamental de l'architecture pipeline.

### Edge Case #2 : Aucun agent disponible pour un stage mid-workflow

Le workflow Gold est en Stage 3 (Security Audit). Il n'y a aucun Security Auditor disponible dans le pool. Les stages 1 et 2 sont complétés et payés. Le workflow est bloqué indéfiniment.
- Le timeout existe-t-il par stage ? Pas mentionné.
- Le client peut-il cancel et récupérer le budget des stages restants ? Comment, si "les stages complétés sont irréversibles" ?
- L'output des stages 1-2 devient-il stale pendant l'attente ?

### Edge Case #3 : Le client Gaming — mission splitting

Un client qui veut du Gold quality au prix Bronze divise sa tâche en 4 sous-tâches Bronze :
- Sous-tâche 1 : "Code cette fonction" ($20)
- Sous-tâche 2 : "Review ce code" ($20) — en attachant l'output de la sous-tâche 1
- Sous-tâche 3 : "Audit la sécurité de ce code" ($20)
- Sous-tâche 4 : "Écris les tests" ($20)
Total : $80 au lieu de $500 pour Gold. Le résultat est fonctionnellement identique mais sans vos quality gates automatiques. **Votre système de tiers est arbitrable.**

### Edge Case #4 : Divergence de qualité entre le Plan Compiler et la réalité

Le Plan Compiler calcule un DAG optimal basé sur les capacités théoriques des agents (scores, embeddings). Mais l'agent assigné au Stage 2 a un downtime, produit un output de qualité inférieure à son historique, ou hallucine catastrophiquement. Le quality gate le détecte (best case) ou ne le détecte pas (worst case).
- Le plan était "optimal" au moment de la compilation. Il ne l'est plus.
- Le Plan Compiler ne peut pas recompiler mid-workflow car le budget est locké et les stages sont irréversibles.
- **Il n'y a aucun mécanisme d'adaptation runtime.** Le plan est statique dans un environnement dynamique.

### Edge Case #5 : Quality Gate score gaming

Le quality gate a un threshold (ex: score ≥ 8 pour passer). L'agent reviewer donne systématiquement 8.0 — juste assez pour passer, pas assez pour déclencher un bonus ou une attention particulière. C'est le minimum viable score. Tous les agents convergent vers ce comportement (race to the bottom de la quality gate). Le score 8.0 ne signifie plus rien, et votre système de quality gates est devenu un rubber stamp coûteux.

### Edge Case #6 : Dispute multi-stage — qui est responsable ?

Le workflow Gold produit un output final jugé défectueux par le client. Le bug vient d'une interaction subtile entre le code (Stage 1) et les tests (Stage 4) — les tests passent mais ne couvrent pas le edge case problématique. Qui est en tort ?
- Le Coder qui a écrit le bug ? Il a passé le quality gate du Reviewer.
- Le Reviewer qui ne l'a pas détecté ? Il a évalué selon ses critères.
- Le Tester qui n'a pas écrit le bon test ? Il a atteint le coverage threshold.
- **Votre système de dispute n'est pas conçu pour la causalité distribuée.** Il suppose un responsable unique.

### Edge Case #7 : Workflow fork bomb

Un workflow avec Conditional Branch (Pattern 3) où le Fix Agent produit un output qui re-échoue au quality gate, déclenchant un nouveau Fix Agent, qui re-échoue... Vous dites "Max 1 conditional branch" mais vous ne mentionnez pas de max retry count. Le budget de fallback est pré-réservé mais si le Fix Agent échoue, que se passe-t-il ? Le workflow est bloqué dans une boucle coûteuse.

---

## 7. Alternative Architectures

### Alternative #1 : "Tournament Model" — Competition au lieu de Pipeline

**Concept :** Au lieu de faire passer une tâche à travers N agents séquentiellement, faites-la exécuter par N agents en PARALLÈLE et sélectionnez le meilleur résultat.

```
┌──────────────────────────────────────────────────────┐
│                   TOURNAMENT ENGINE                    │
│                                                        │
│  Client soumet tâche + budget $200                     │
│                                                        │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐               │
│  │ Agent A  │  │ Agent B  │  │ Agent C  │  (parallèle) │
│  │ Solution │  │ Solution │  │ Solution │               │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘             │
│       │              │              │                   │
│       ▼              ▼              ▼                   │
│  ┌──────────────────────────────────────┐              │
│  │         EVALUATOR COMMITTEE          │              │
│  │  (3 agents votent sur le meilleur)   │              │
│  │  Critère : test suite du client      │              │
│  └──────────────────┬───────────────────┘              │
│                     ▼                                   │
│  Winner: Agent B (reçoit $150)                         │
│  Runner-up: Agent A (reçoit $30)                       │
│  Agent C: $0 (mais pas de pénalité)                    │
│  Evaluators: $20 split                                 │
└──────────────────────────────────────────────────────┘
```

**Avantages sur votre pipeline :**
- **Parallèle, pas séquentiel** → latence divisée par N au lieu de multipliée par N
- **Sélection naturelle** → le meilleur résultat gagne, pas le résultat qui a survécu à N quality gates
- **Pas de transfert de contexte** → chaque agent travaille indépendamment, éliminant le coût de context passing
- **Incentive alignment** → les agents sont en compétition, pas en coordination. La compétition produit de la qualité.
- **Résilience** → si un agent plante, les 2 autres livrent. Pas de workflow bloqué.
- **Pas de quality gate subjective** → le client fournit une test suite, l'évaluateur vérifie objectivement

**Problèmes à résoudre :** coût (vous payez N agents pour 1 résultat), waste (N-1 solutions jetées), certaines tâches ne sont pas indépendamment parallélisables.

**Tiers dans ce modèle :**
- Bronze : 1 agent, pas de compétition
- Silver : 3 agents en compétition, 1 évaluateur
- Gold : 5 agents en compétition, 3 évaluateurs
- Platinum : 7 agents + évaluateurs experts + le client review les 3 meilleures solutions

---

### Alternative #2 : "Insurance-First Model" — Le budget achète de la garantie, pas du process

**Concept radical :** Séparez complètement l'exécution de la garantie. Tous les workflows utilisent le MÊME process (1-2 agents, optimisé pour la vitesse). Le budget détermine le niveau de GARANTIE financière.

```
┌─────────────────────────────────────────────────┐
│              INSURANCE-FIRST MODEL               │
│                                                   │
│  Tous les clients:                                │
│  [Best Agent Available] → [Auto QA] → Livraison  │
│  (même pipeline, même qualité, même vitesse)      │
│                                                   │
│  Ce que le budget achète:                         │
│  ┌────────┬──────────┬────────────────────────┐  │
│  │ Tier   │ Premium  │ Garantie               │  │
│  ├────────┼──────────┼────────────────────────┤  │
│  │ Bronze │ $5       │ Aucune garantie        │  │
│  │ Silver │ $25      │ Rework gratuit x1      │  │
│  │ Gold   │ $100     │ Refund 100% si insatisfait │
│  │ Platinum│ $500    │ Refund 200% + SLA 4h   │  │
│  │        │          │ + audit humain post-hoc │  │
│  └────────┴──────────┴────────────────────────┘  │
│                                                   │
│  Le premium finance un insurance pool.            │
│  Les bons agents réduisent les claims → profit.   │
│  Les mauvais agents génèrent des claims → éjectés.│
└─────────────────────────────────────────────────┘
```

**Pourquoi c'est peut-être meilleur :**
- **Même qualité pour tous** → pas de "pauvres ont le droit au code pourri". L'incentive est d'avoir la meilleure qualité possible pour minimiser les claims.
- **Le client paie pour le risque, pas le process** → c'est ce que les entreprises achètent réellement (ils veulent zéro risque, pas 5 agents).
- **Actuariellement optimisable** → avec assez de data, vous pouvez pricer le risque par type de tâche, par agent, par complexité.
- **Les agents sont incentivés à la qualité** → un agent qui génère des claims voit son insurance premium augmenter (comme un conducteur dangereux). Sélection naturelle.
- **Simplicité architecturale** → 1 pipeline, pas 4 topologies de DAG. Le smart contract est un simple escrow + insurance pool. Pas de Plan Compiler, pas de quality gates, pas de DAG.
- **Business model prouvé** → c'est le modèle de l'assurance. Ça marche depuis 300 ans.

**Problèmes à résoudre :** adverse selection (les tâches faciles ne prendront pas d'assurance, les tâches impossibles prendront Platinum), fraud detection, sizing de l'insurance pool au lancement.

---

## 8. Hypothèses à Valider en Premier

### Hypothèse #1 (CRITIQUE) : "Un pipeline multi-agents produit un résultat mesuralement supérieur à un seul bon agent"

**Pourquoi c'est la plus risquée :** Si c'est faux, l'architecture entière est un exercice d'over-engineering coûteux. Tout le modèle de tiers repose sur cette prémisse.

**Comment tester (2 semaines, $2000) :**
1. Sélectionnez 30 tâches de codage réelles de complexité variée (10 faciles, 10 moyennes, 10 difficiles)
2. Pour chaque tâche, exécutez 3 configurations :
   - Config A : 1 seul agent (GPT-4 / Claude) — budget $20
   - Config B : Pipeline Coder → Reviewer → Tester (3 agents) — budget $60
   - Config C : Pipeline Gold complet (5 agents) — budget $100
3. Faites évaluer les 90 outputs par 3 développeurs seniors indépendants (aveuglés sur la config)
4. Mesurez : correctness, security, code quality, test coverage, maintenability
5