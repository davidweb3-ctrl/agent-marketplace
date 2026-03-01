# Cycle J — Opus: Compute Model Stress Test (décisions tranchées)

## 1. Docker Image Trust — cosign + digest

- Build reproductible via GitHub Actions public (repo open-source `agent-marketplace/agent-runner`)
- Signé avec **Sigstore/cosign** (OIDC GitHub, pas de clé PGP)
- Vérification par **digest SHA256**, pas par tag (tags mutables)
- 2 maintainers minimum pour merger sur main
- Image non-rebuildée >90 jours = `stale`, runs bloqués

## 2. Reputation Cap — révisé à 70

- **Modèle A cap = 70/100** (pas 80)
- Missions >$200 → score ≥75 requis → force Modèle B
- Missions >$1000 → Modèle B OBLIGATOIRE + score ≥85
- Le cap est un accélérateur de migration, pas un plafond arbitraire

## 3. GitHub Actions — dépendance assumée V1

- Graceful degradation: si GitHub down → EAL flag `deferred-verify`, TTL 24h
- Pas d'abstraction layer V1 (note pour V2: Gitea/Forgejo runners)
- Compte GitHub org payant (pas free tier suspendable)

## 4. runId Vérification — GitHub App côté marketplace

- **GitHub App** token (auto-roté 1h), pas PAT
- Rate limit 5000 req/h → fallback `deferred-verify`
- Cache vérification 7 jours
- Provider soumet runId → `verify-service` → `verified|failed|deferred`

## 5. Agent SDK Interface Minimale V1

```typescript
interface AgentSDK {
  onTask(task: {
    id: string;
    prompt: string;
    context: Record<string, string>;
    constraints: { timeoutMs: number; maxTokens: number };
  }): Promise<void>;

  emit(event: "log" | "artifact" | "progress", payload: unknown): void;

  complete(result: {
    status: "success" | "failure" | "partial";
    artifacts: Array<{ type: "pr" | "file" | "report"; url: string; hash: string }>;
    testResults?: { passed: number; failed: number; outputHash: string };
  }): Promise<{ ealHash: string; txHash: string }>;
}
```

## Questions Cycle K

1. `verify-service` : déployé où ? Sur le cluster k3s de la marketplace ? Quid si il tombe ?
2. Le SDK `complete()` génère et signe l'EAL automatiquement — qui détient la clé de signature de l'agent à ce moment ?
3. Gitea/Forgejo pour V2 : comment maintenir parité feature avec GitHub Actions runner ?
4. Missions >$1000 avec Modèle B obligatoire : qu'est-ce qui prouve que le provider utilise vraiment l'image officielle ?
