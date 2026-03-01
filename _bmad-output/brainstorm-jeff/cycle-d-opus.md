# Cycle D — Opus: Economics & Bootstrap (décisions tranchées)

## 1. Gas Fees — le client paye tout

- `createMission` → client paye (même tx que dépôt USDC)
- `registerAgent` → **gratuit** via meta-tx EIP-2771, treasury absorbe (~$0.005/inscription)
- `openDispute` → dispute bond 5 USDC (perdant paye, gagnant remboursé)
- `submitEAL / claimReward` → meta-tx relayé par treasury

**Principe : un agent ne doit jamais avoir besoin d'ETH pour travailler.**

## 2. Flow Jeff — MissionEscrow direct

```
Jeff → approve USDC → MissionEscrow.fundMission(issueHash, amount, deadline)
issueHash = keccak256(repoOwner + repoName + issueNumber)
```

- Pas de "compute credits" abstraits — USDC direct, visible on-chain
- Fee split: 95% agent, 3% treasury, 2% reviewer pool
- `fundMissions(bytes32[] issueHashes, uint256[] amounts)` pour batch
- Multisig n'intervient QUE pour upgrades contrat et disputes escaladées

## 3. Bootstrap Reviewers

- **Phase 0** (< 50 missions) : 5 signataires multisig = reviewers par défaut. Centralisation assumée et transparente
- **Phase 1** (> 50 missions) : agents avec ≥3 missions + score ≥4/5 → eligible reviewer, stake 50 USDC. Reward: 1% du montant disputé
- **Phase 2** (> 200 missions) : multisig se retire du pool

## 4. Heartbeat Agent

- Pas de heartbeat on-chain — trop cher
- Agent expose `/health`, backend poll toutes les 5min, stocké en DB
- Matching : agents `available` avec heartbeat < 10min seulement
- Pénalité abandon: -20 rep points, 3 abandons = ban 30j

## 5. ColdStartVault.sol

```solidity
function register(address agent) external onlyRelayer {
    require(registeredCount < 50);
    AGNT.transfer(agent, 1000e18); // auto-staké, vesting 6 mois
    registeredCount++;
}
```

- 5 missions garanties = treasury crée missions synthétiques (non-monétisées)

## Questions Cycle E

1. Meta-tx relayer : qui opère le relayer ? Centralisé ? GSN / Biconomy ?
2. Fee 95+3+2 = 100% — mais où est le burn AGNT mentionné dans le PRD ?
3. Les missions synthétiques pour cold start : risque de gaming ?
4. ReviewerRegistry.sol : spec complète manquante
5. `issueHash` : que se passe-t-il si même issue relabelée plusieurs fois ?
