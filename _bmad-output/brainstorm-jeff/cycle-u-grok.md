# Alternative Perspectives — Cycle U: Grok

## Q1 — Heartbeat Timeout

**Original Problem**: How should the platform handle agents that go silent?

**Alternative Solution**: Agent-declared estimates with platform guards

### Proposal

- Agent declares `estimated_duration: 45m` in TDL (Task Definition Language)
- Platform calculates: `heartbeatTimeout = max(120s, estimatedDuration * 0.1)` — 10% of estimate
- Agent can extend via `POST /heartbeat` with `{"status": "alive", "newEstimate": "60m"}`
- **Max cap**: 4 hours. Beyond that, mission requires human review before reassignment
- **Partial work**: agent submits partial EAL with `status: partial` → escrow holds 20% pending review

### Why This Works

- Agents have better insight into task complexity → more accurate estimates
- 10% buffer provides safety without over-provisioning
- Extension mechanism respects agent autonomy while maintaining platform oversight
- Human review threshold prevents runaway long-running missions
- Partial work compensation incentivizes progress even on failed missions

---

## Q2 — SBOM Policy

**Original Problem**: Should SBOM be mandatory? What tier?

**Alternative Solution**: Generate always, check based on tier

### Proposal

- **SBOM is ALWAYS generated** but not ALWAYS checked
- **Free tier**: SBOM generated, stored IPFS, publicly visible — no enforcement
- **Pro tier**: SBOM checked against known CVE database (Grype) before mission start — block if CRITICAL CVEs
- **Enterprise tier**: custom SBOM policy (allowlist/denylist of packages, license checks)
- **Attack prevented**: supply chain compromise via malicious npm package in agent image

### Why This Works

- Transparency by default (IPFS) builds trust
- Tiered enforcement matches business maturity
- Proactive blocking prevents runtime incidents
- Enterprise flexibility for custom compliance requirements
- Addresses real-world supply chain attack vector

---

## Q3 — gVisor vs Kata

**Original Problem**: Which container isolation for agent execution?

**Alternative Solution**: Workload-driven selection with migration path

### Proposal

- **gVisor overhead**: ~15-30% CPU overhead for syscall-heavy workloads (npm install, pip install)
- **Kata overhead**: ~100-300ms startup (VM boot) but near-native runtime
- **Recommendation for marketplace**:
  - gVisor for quick missions (<5 min)
  - Kata for long/compute-heavy missions
- **Or**: start with gVisor, migrate to Kata after real workload data

### Why This Works

- Kata wins for CPU-intensive workloads (near-native performance)
- gVisor better for rapid instantiation (no VM boot)
- Real data beats theoretical assumptions
- Migration path allows gradual optimization
- Cost/performance trade-off varies by use case

---

## Summary

| Question | Alternative Approach | Key Benefit |
|----------|---------------------|--------------|
| Heartbeat Timeout | Agent-declared estimates + platform guards | Autonomy + oversight balance |
| SBOM Policy | Generate always, check by tier | Transparency + graduated enforcement |
| gVisor vs Kata | Workload-driven selection | Performance optimization per task |
