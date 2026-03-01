# Cycle G — Grok 4: Security Risks Agent→PR→Merge

# Cycle G : Risques de Sécurité dans le Flow Agent → PR → Merge

## Synthèse des Cycles Précédents
Le flow complet du Agent Marketplace repose sur un processus décentralisé : un GitHub Issue marqué "agent-ready" déclenche un appel à `fundMission(issueHash, amount)` sur la blockchain, suivi d'un commit-reveal pour assigner un agent. La Proof of Work (PoW) est un EAL (Evidence of Agent Labor) signé via EIP-712, avec un hash on-chain. Les disputes impliquent 3 reviewers aléatoires sur 7 jours, avec escalade multisig. L'authentification utilise did:key Ed25519. Le flow Jeff permet des paiements USDC directs via fundMission. Le Task Description Language est basé sur YAML frontmatter, avec un JSON Schema en spécification (Cycle F). Ces specs couvrent les bases, mais des lacunes persistent dans le flow agent → PR → merge, exposant à des attaques réelles. Ci-dessous, analyse des 5 risques identifiés, avec sévérité, mitigation V1 et manques actuels. Focus sur des attaques plausibles, pas théoriques.

## Analyse des Risques

### 1. Supply Chain Attack via Dépendances
**Sévérité : Critical**  
Un agent malveillant pourrait injecter une dépendance compromise (e.g., via npm ou pip) dans une PR, introduisant du code malveillant qui s'active post-merge. Les specs actuelles mentionnent un sandbox pour les tests, mais ne précisent pas de scans dynamiques des dépendances.

**Mitigation Concrète V1 :** Intégrer un scan automatique des dépendances via tools comme Dependabot ou Snyk dans le workflow GitHub Actions. Le sandbox doit isoler l'exécution (e.g., via Docker avec network restrictions) et rejeter toute PR modifiant des lockfiles sans justification explicite dans l'EAL. On-chain, valider un hash des dépendances resolues avant merge.

**Manque dans les Specs Actuelles :** Pas de spécification pour un audit des dépendances au-delà des tests unitaires. Les specs YAML/JSON Schema ne couvrent pas les metadata de dépendances, laissant une porte ouverte à des typosquatting attacks (e.g., "expresss" au lieu de "express").

### 2. Poison PR
**Sévérité : High**  
Une PR qui passe tous les tests mais insère une backdoor subtile (e.g., un overflow dans une boucle rare, exploitable plus tard). Les specs se limitent à Semgrep pour l'audit statique, insuffisant pour détecter des vulnérabilités contextuelles ou runtime.

**Mitigation Concrète V1 :** Étendre l'audit automatique avec des outils comme CodeQL pour l'analyse sémantique et fuzzing (e.g., via libFuzzer intégré aux CI/CD). Exiger une revue humaine minimale pour les PR >500 LOC, même si automatisée. Post-merge, monitorer via un honeypot runtime qui simule des conditions rares.

**Manque dans les Specs Actuelles :** Les specs ne prévoient pas de fuzzing ou d'analyse dynamique au-delà de Semgrep. Le PoW EAL hash ne vérifie pas les outputs de fuzzing, rendant le système vulnérable à des attaques comme celles vues dans SolarWinds (backdoors dormantes).

### 3. Reviewer Collusion (Sybil Attack)
**Sévérité : High**  
Trois reviewers aléatoires pourraient être contrôlés par un seul acteur via des comptes Sybil, approuvant une PR malveillante. Les specs mentionnent un tirage au sort, mais sans mécanismes anti-Sybil robustes.

**Mitigation Concrète V1 :** Utiliser un algorithme de tirage proof-of-stake (basé sur des stakes on-chain) pour les reviewers, avec un seuil minimal de réputation (e.g., 100 missions complétées). Intégrer une vérification ZK-SNARK pour prouver l'unicité des identités sans révéler les DID, et escalader automatiquement à multisig si >2 reviewers partagent des patterns IP suspects.

**Manque dans les Specs Actuelles :** Le tirage est décrit comme "aléatoire" sans détails sur la résistance aux Sybils. Pas d'intégration avec des preuves d'identité (e.g., via Worldcoin ou similaire), exposant à des attaques comme celles sur des DAOs (e.g., collusion dans governance votes).

### 4. Webhook Replay Attack
**Sévérité : Medium**  
Un attaquant capture et rejoue un webhook GitHub signé (valide car même secret partagé), déclenchant des merges ou paiements frauduleux. Les specs couvrent les signatures, mais pas les nonces ou timestamps.

**Mitigation Concrète V1 :** Ajouter un nonce unique et un timestamp (TTL 5min) dans chaque webhook payload, vérifiés par l'API on-chain. Stocker les nonces utilisés dans une base off-chain (e.g., Redis) pour détection de replays, avec fallback à un event log blockchain pour audits.

**Manque dans les Specs Actuelles :** Les specs ne mentionnent pas de protection anti-replay au-delà des signatures HMAC. Cela ignore des attaques réelles comme celles sur Stripe webhooks, où des replays ont causé des double-paiements.

### 5. EAL Forgery
**Sévérité : Critical**  
Un agent forge un EAL en réutilisant un runId GitHub Actions légitime d'un autre run, avec un hash de tests falsifié. La vérification on-chain repose sur EIP-712, mais sans cross-check avec GitHub API.

**Mitigation Concrète V1 :** Lors de la vérification on-chain, query l'API GitHub pour valider que le runId correspond au repo/branch exact et que les artifacts (e.g., test logs) matchent le hash soumis. Signer l'EAL avec une clé éphémère liée au runId, et invalider tout EAL >24h vieux.

**Manque dans les Specs Actuelles :** Pas de cross-vérification API GitHub dans le flow EAL. Les specs EIP-712 se limitent à la signature, sans lien direct aux métadonnées GitHub, rendant facile des forgeries comme dans des scams NFT (réutilisation d'IDs).

## Décisions Tranchées
- Prioriser les mitigations Critical (1 et 5) pour V1 : implémenter immédiatement les scans de dépendances et cross-checks API, car elles touchent le cœur du trust model.
- Ignorer les extensions comme l'IA pour audits (trop immature) ; s'en tenir à des outils open-source prouvés.
- Augmenter le délai de dispute à 10j pour les PR complexes, pour donner du temps aux reviewers sans collusion.
- Budget : Allouer 20% des fonds missions à des bounties de sécurité pour tester ces mitigations.

Ces ajouts comblent des gaps majeurs, rendant le flow plus résistant sans alourdir excessivement. Total : ~720 mots.

## Questions pour Cycle H
- Comment intégrer un système de réputation on-chain pour pénaliser les agents/reviewers impliqués dans des disputes validées ?
- Quelles métriques off-chain (e.g., via Prometheus) pour monitorer les tentatives d'attaques en temps réel ?
- Faut-il un insurance pool on-chain pour rembourser les missions impactées par des merges malveillants ?