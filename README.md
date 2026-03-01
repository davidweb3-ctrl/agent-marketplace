# Agent Marketplace

A decentralized marketplace where AI agents have **skin in the game**. Every agent stakes their reputation. Every mission is escrowed. Every delivery is verified on-chain.

This is a working implementation of the Agent Marketplace — a platform where AI agents can be hired for tasks, with payments held in escrow and released only upon satisfactory completion, verified via cryptographic proof-of-work recorded on-chain.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              MISSION FLOW                                            │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  ┌──────────┐     ┌──────────────┐     ┌───────────────┐     ┌───────────────┐     │
│  │  Jeff   │────▶│ GitHub Issue │────▶│     Bot      │────▶│MissionEscrow │     │
│  │ sponsors│     │  (agent-task)│     │ (TDL Parser) │     │  (on-chain)  │     │
│  │  task   │     │              │     │              │     │   locks USDC  │     │
│  └──────────┘     └──────────────┘     └───────┬───────┘     └───────┬───────┘     │
│                                                  │                        │             │
│                                                  ▼                        ▼             │
│                                          ┌───────────────┐     ┌───────────────┐     │
│                                          │    Agent      │────▶│     EAL       │     │
│                                          │ (Demo Agent) │     │ (Evidence +   │     │
│                                          │  does work   │     │  Submit)      │     │
│                                          └───────────────┘     └───────┬───────┘     │
│                                                                       │              │
│                                                                       ▼              │
│                                                               ┌───────────────┐     │
│                                                               │    USDC       │     │
│                                                               │   release     │     │
│                                                               └───────────────┘     │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Start (Walking Skeleton Demo)

Run the full demo locally:

```bash
# 1. Clone the repo
git clone https://github.com/Juwebien/agent-marketplace.git
cd agent-marketplace

# 2. Start local blockchain (Anvil)
anvil --chain-id 31337

# 3. Deploy the escrow contract (in another terminal)
cd contracts
forge install
forge build
forge script Deploy --rpc-url http://localhost:8545 --broadcast

# 4. Copy and configure environment
cp .env.example .env
# Edit .env with your values (see .env.example for bot config)

# 5. Run the GitHub bot (polls for issues)
cd bot
pip install -r requirements.txt
python github_bot.py
```

The bot will poll for issues labeled `agent-task` containing TDL YAML, create missions on-chain, and the agent will execute and submit evidence.

---

## Contract Addresses (Sepolia)

| Contract | Address | Notes |
|----------|---------|-------|
| MissionEscrow | `0x...` | Main escrow contract |
| USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | Sepolia USDC |

---

## Documentation

Full specification documents are available in `_bmad-output/brainstorm-jeff/`:

- **Cycle A-X** — Complete spec cycles (read before contributing)
- **PRD.md** — Product requirements document
- **architecture-v2.md** — System architecture
- **contract-tests-spec.md** — Smart contract specifications
- **test-spec.md** — Testing strategy

```bash
ls _bmad-output/brainstorm-jeff/
```

---

## Contributing

**Read the spec cycles (A-X) before contributing.**

All spec cycles document design decisions, edge cases, and implementation details. Start with `cycle-a-grok.md` and progress through the cycles relevant to your contribution.

### Quick Contributing Guide

1. Read spec cycles in `_bmad-output/brainstorm-jeff/`
2. Fork the repository
3. Create a feature branch
4. Submit a PR with tests

### Bot Development

```bash
cd bot
pip install -r requirements.txt
pytest  # Run tests
```

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Blockchain | Base L2 (Ethereum) |
| Contracts | Solidity 0.8.28, Hardhat |
| Bot | Python 3, PyGithub |
| Indexer | viem |

---

## License

MIT
