# Gaps & Action Plan — Post Multi-LLM Brainstorm
> Sources: Grok 4 (sécurité) + Mistral Large (GTM/org) + Claude Opus 4.6 (stratégie)
> Date: 2026-02-28

## 🔴 CRITIQUES — À documenter avant Sprint 1

### GAP-01 — MEV / Front-running sur MissionEscrow
**Source:** Grok 4
**Problème:** Pas de commit-reveal sur les bids, pas de MEV protection (Flashbots/MEV-Share). Un bot peut front-run les accepts de mission.
**Action:** Ajouter commit-reveal scheme dans MissionEscrow spec + note "V1 mitigation: private RPC via Alchemy MEV protection"

### GAP-02 — Responsabilité légale outputs agents
**Source:** Opus + Grok
**Problème:** Quand un agent IA délivre un conseil foireux via le marketplace, qui est responsable? Zéro jurisprudence, pas dans les ToS.
**Action:** Ajouter clause "Platform is not liable for agent outputs" dans ToS spec + disclaimer obligatoire sur chaque agent card

### GAP-03 — Rate limits LLM providers (supply-side risk)
**Source:** Opus
**Problème:** Si 80% des agents wrappent OpenAI et qu'OpenAI change ses ToS (interdiction resale), supply-side mort overnight.
**Action:** Ajouter dans risk register + exiger que les agents déclarent leurs LLM providers → diversification incentivée (badge "multi-model")

### GAP-04 — Runbooks de crise manquants
**Source:** Opus + Grok
**Problèmes non couverts:**
- Exploit smart contract → que fait-on dans les 30 premières minutes?
- Insurance pool drainé → plan de recharge treasury?
- Indexer down 48h → fallback read-only mode?
- Multisig key lost → procédure de récupération?
- Token crash -90% → communication plan?
**Action:** Créer `incident-runbooks.md` avec les 5 scénarios

### GAP-05 — MiCA/CASP Compliance (EU)
**Source:** Opus
**Problème:** Stripe→USDC bridge potentiellement = service de paiement régulé EU. Licence PSAN (France) / CASP (MiCA) possible.
**Action:** Ajouter à compliance checklist + mentionner dans legal budget

### GAP-06 — Insurance Pool Game-Theory
**Source:** Opus
**Problème:** Disputes coordinées provider+client complices → drain systématique du 5% insurance fund.
**Action:** Ajouter dans smart-contracts-spec: rate limiting des disputes par wallet pair + sybil detection dans ReputationOracle

### GAP-07 — Bus Factor = 1
**Source:** Opus + Mistral
**Problème:** Dev + ops + security + product = probablement même personne. 2 semaines maladie = projet mort.
**Action:** Documenter qui peut faire quoi → définir minimum 2 personnes avec accès aux clés critiques (multisig) et aux runbooks

### GAP-08 — Cold Start Supply (providers)
**Source:** Mistral
**Problème:** Aucun provider ne stakera 1000 AGNT sur un marché vide. Le Genesis program est flou.
**Action:** Préciser dans GTM: 50 premiers providers reçoivent les 1000 AGNT de stake remboursés à 100% (Genesis airdrop) + garantie 5 missions/mois les 3 premiers mois via treasury

### GAP-09 — Benchmarks agents obligatoires
**Source:** Opus
**Problème:** Race to bottom si n'importe quel wrapper GPT-4 peut se lister. Pas de curation = discovery inutilisable.
**Action:** Ajouter à agent onboarding: score minimum sur benchmark public (ex: METR, BenchmarkAI) requis pour listing. Delisting auto si dispute rate >15%.

### GAP-10 — Incident Response 3h du matin
**Source:** Opus + Grok
**Problème:** Pas de on-call, pas de PagerDuty, pas d'escalade.
**Action:** Ajouter dans infra-spec: Grafana → alert → Telegram (critique) avec runbook lié. Définir qui répond et en combien de temps.

## 🟡 IMPORTANTS — À intégrer avant mainnet

### GAP-11 — Concurrent centralisé (kill scenario)
**Source:** Opus
**Mitigation:** Moat = réputation on-chain accumulée (impossible à copier en overnight) + réseau d'agents interdépendants (V1.5)

### GAP-12 — Acquisition clients = zéro stratégie concrète
**Source:** Mistral
**Action:** VS Code plugin (V1.5), bounty 500 AGNT premiers clients, partenariats RunPod/Lambda Labs pour GPU providers

### GAP-13 — Question existentielle blockchain
**Source:** Opus
**"Retire la blockchain, le produit tient encore?"**
Réponse: **OUI** — la marketplace tient sans blockchain. La blockchain ajoute: réputation immutable, escrow trustless, token incentives.
→ Ship fiat-first MVP V1 pour valider le marché AVANT de pousser le crypto narrative.

## ✅ Déjà Couverts (rappel)

- UUPS timelock + multisig 3/5 ✅
- Indexer getLogs backfill + reorg ✅
- OFAC async + cache ✅
- KYC $1K threshold ✅
- Fiat holdback 7j ✅
- Webhook spec ✅
- Error codes ✅
- V1 scope locked ✅
