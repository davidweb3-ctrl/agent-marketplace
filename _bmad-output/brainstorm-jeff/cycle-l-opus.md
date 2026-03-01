# Cycle L — Opus: 4 Gaps Résolus (specs V1 minimales)

## Gap 1: DAG → blockedBy liste plate

**Décision:** V1 = liste `blocked_by UUID[]` en DB, pas de moteur DAG complet.

```sql
ALTER TABLE missions ADD COLUMN blocked_by UUID[] DEFAULT '{}';
```

- Mission créée avec bloqueurs non-COMPLETED → status `BLOCKED`
- Sur `completeMission()` → chercher dépendants → débloquer automatiquement si tous bloqueurs complétés
- V1.5: détection cycles, DAG visualization

## Gap 2: EAL Forgery → mission-binding artifact

**Décision:** Le run GitHub Actions DOIT publier un artifact `mission-binding.json` contenant le `missionId`.

```json
{ "missionId": "xxx", "agentDid": "did:key:...", "timestamp": "..." }
```

`verify-service` vérifie:
1. repo = agent enregistré
2. event = `workflow_dispatch`
3. artifact `mission-binding.json` présent avec `missionId` correct
4. run créé APRÈS `mission.claimedAt`

V1.5: OIDC token GitHub Actions (plus élégant)

## Gap 3: SDK minimal `@agent-marketplace/sdk`

```typescript
export function createAgent(config: { privateKey: string; marketplaceUrl: string; mode: 'github-actions' | 'self-hosted' })
// Fournit: handleTask(), emit(), complete(), buildEAL()
// Signe EAL avec ed25519 (did:key)
// Mode self-hosted: polling loop toutes les 30s
// Mode github-actions: écrit mission-binding.json au démarrage
```

V1.5: WebSocket, SDK Python, retry/resume

## Gap 4: Docker trust → rebuild cron + cosign + notify

- Agent = cron GitHub Actions tous les 2 mois (avant deadline 90j)
- Signe image avec cosign (Sigstore OIDC)
- Notifie marketplace via `POST /agents/images` avec digest SHA256
- Marketplace vérifie signature + stocke dans `agent_images` table
- Providers notifiés par webhook à chaque nouvelle image
- Image stale > 90j → missions bloquées (hard block)

## Questions Cycle M

1. `blocked_by` : que se passe-t-il si une mission bloquante est CANCELLED (pas COMPLETED) ?
2. L'artifact `mission-binding.json` peut être falsifié après coup. Est-ce que le timestamp GitHub du run est la vraie source de vérité ?
3. Qui publie `@agent-marketplace/sdk` sur npm ? Même org GitHub que les contrats ?
4. Si un provider ignore le cron rebuild et que son image expire, ses missions en cours sont-elles bloquées ou seulement les nouvelles ?
