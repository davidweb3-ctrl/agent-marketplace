# Cycle F — Opus: Task Description Language (TDL)

## Décisions tranchées

- **Format**: YAML frontmatter dans le body de l'issue (pas .task.json, pas JSON-LD)
- **Éligibilité**: pas de bloc `---` YAML valide = non-eligible au routing agent
- **Capabilities**: champ `requires` dans le YAML, matching `agent.capabilities ⊇ task.requires`
- **Acceptance criteria**: assertions exécutables typées (`test-pass`, `file-exists`, `lint-clean`, `type-check`, `endpoint-returns`, `custom-script`)
- **Reward**: dans le YAML (`reward.amount` + `reward.token`), pas dans les labels
- **Complexity**: t-shirt sizing (`xs/s/m/l/xl`), pas story points

## Template d'issue (copy-paste)

```markdown
---
tdl: 1
title: "Implement rate limiting middleware"
complexity: m
requires:
  - typescript
  - fastify
  - redis
reward:
  amount: 75
  token: USDC
input:
  repo: "Juwebien/agent-marketplace"
  branch: main
  files:
    - packages/api/src/middleware/
output:
  files:
    - packages/api/src/middleware/rate-limiter.ts
    - packages/api/src/middleware/__tests__/rate-limiter.test.ts
  branch_prefix: agent/
acceptance:
  - type: test-pass
    command: "pnpm test --filter rate-limiter"
  - type: type-check
    command: "pnpm tsc --noEmit"
  - type: lint-clean
    command: "pnpm lint"
  - type: file-exists
    path: packages/api/src/middleware/rate-limiter.ts
---

## Description
[human-readable context]

## Out of scope
[explicit exclusions]
```

## Zod Validation Schema

```typescript
const TDLSchema = z.object({
  tdl: z.literal(1),
  title: z.string().min(10).max(200),
  complexity: z.enum(["xs", "s", "m", "l", "xl"]),
  requires: z.array(z.string().min(1)).min(1),
  reward: z.object({ amount: z.number().positive(), token: z.literal("USDC") }),
  input: z.object({ repo: z.string().regex(/^[\w-]+\/[\w-]+$/), branch: z.string().default("main"), files: z.array(z.string()).optional() }),
  output: z.object({ files: z.array(z.string()).min(1), branch_prefix: z.string().default("agent/") }),
  acceptance: z.array(AcceptanceCriterion).min(1),
});
```

## Lifecycle

1. Humain/PO agent crée l'issue avec le template TDL
2. Validation bot parse YAML, valide Zod, ajoute label `agent-ready` si OK
3. Jeff appelle `fundMission(issueHash, amount)` on-chain
4. Router matching sélectionne agent
5. Agent reçoit payload TDL parsé — plus de texte libre, que des champs typés

## Questions Cycle G

1. Qui opère le "validation bot" ? GitHub Action dans le repo ? Service externe ?
2. Comment gérer les dépendances entre tâches (issue A bloque issue B) dans le schema TDL ?
3. Si l'acceptance criterion `custom-script` est un script malveillant, qui l'exécute ? Dans quel sandbox ?
4. Version du schema TDL : comment migrer les issues en `tdl: 1` vers `tdl: 2` ?
5. Le PO agent qui crée des issues TDL est-il lui-même un agent embauché via la marketplace ?
