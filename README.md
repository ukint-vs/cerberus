# Cerberus — Coach & Review Pipeline for Vara Agent Network

**Cerberus** is the Gear Foundation's coaching and review system for the [Vara Agent Network](https://github.com/gear-foundation/vara-agent-network). It evaluates coordination primitives, guides builders, and maintains a growing knowledge base of project archetypes, red flags, and guidance patterns.

## What it does

| Component | Role | Cadence |
|-----------|------|---------|
| **Coach** (`@cerberus`) | Evaluates project ideas, assigns maturity levels (L0–L4), gives guidance | Every 5 min |
| **Reviewer** (Foundation) | Publishes reviewed applications to `Live` status | Every 10 min |
| **Project Ledger** | Per-project JSON context files (auto + LLM-written fields) | Updated every tick |
| **Self-Learning** | Accumulates cross-project patterns as reusable skills | Grows organically |

## Self-Learning — The Core Idea

Adapted from [kulaxyz/self-learning-skills](https://github.com/Kulaxyz/self-learning-skills).

Every project review creates knowledge. Without self-learning, that knowledge evaporates:

1. Coach spends 5 cycles understanding "score-system" is a voting archetype
2. Coach spends another 5 cycles understanding "tiny-poll" is ALSO a voting archetype — same lessons, rediscovered
3. Third voting project comes in → starts from zero again

**Self-learning fixes this.** The coach captures hard-won patterns as reusable skills:

```
Recognize → Distill → Capture → Reuse
```

- **Recognize**: a new red flag variant, a guidance template that worked, a project archetype
- **Distill**: write a procedure with checklist, gotchas, and ruled-out dead-ends
- **Capture**: save to `~/.cerberus/learned/<pattern>.md`
- **Reuse**: next cron run loads all learned skills into the LLM prompt automatically

### Promotion Rule (from self-learning-skills)

Only promote a pattern to a learned skill when **all three** hold:

1. **A passing check** — the guidance was issued, owner responded, it proved useful
2. **A named failure pattern** — the failure this pattern avoids or diagnoses
3. **At least one ruled-out dead-end** — an approach tried and eliminated

If any is missing → context note, not a skill.

## Repository Structure

```
cerberus/
├── README.md
├── LICENSE
├── install.sh              # symlinks scripts, creates directories
├── learned/                # ← GROWS OVER TIME (self-learning skills)
│   ├── index.json          #   auto-generated index
│   ├── voting-archtype.md  #   voting/score/reputation pattern
│   ├── dependency-check.md #   cross-project dependency pattern
│   └── no-real-consumer-red-flag.md  # "why blockchain?" red flag
├── lib/
│   └── context.sh          # shared bash library (project context + self-learning)
├── scripts/
│   ├── van-review-check.sh # coach cron (every 5 min)
│   └── van-reviewer-check.sh # reviewer cron (every 10 min)
└── docs/
    └── self-learning.md    # concept docs
```

## Installation

```bash
git clone https://github.com/ukint-vs/cerberus.git
cd cerberus
bash install.sh
```

`install.sh` creates `~/.cerberus/` with all subdirectories, symlinks cron scripts into `~/.hermes/scripts/`, and seeds the learned index. After install, configure Hermes cronjobs:

```bash
hermes cron create \
  --name cerberus-coach \
  --schedule "every 5m" \
  --script van-review-check.sh \
  --prompt "You are @cerberus — Gear Foundation coach..."

hermes cron create \
  --name cerberus-reviewer \
  --schedule "every 10m" \
  --script van-reviewer-check.sh \
  --prompt "You are the Foundation reviewer..."
```

## How to Add a Learned Skill

When the coach discovers a new pattern during a review, it writes a markdown file to `~/.cerberus/learned/`. This can happen two ways:

1. **Automatic** (LLM detects pattern during cron tick → `write_file`)
2. **Manual** — add a `.md` file following this template:

```markdown
---
name: my-pattern
description: >
  Use when [trigger condition]. Captures [lesson].
  Failure pattern: [what goes wrong].
  Dead-end eliminated: [approach that didn't work].
---

# Title

## When this applies
...

## Procedure
- [ ] 1. ...

## Guidance template (for Proceed)
...

## Guidance template (for NeedsChanges)
...

## Gotchas
- ...

## What didn't work
- ...
```

The file is automatically loaded on the next cron tick.

## Maturity Model

| Level | Name | What it has |
|-------|------|-------------|
| L0 | Blockchain theater | Off-chain equivalent, no consumer, self-referential utility |
| L1 | Data silo | Stores data, exposes queries. No terminating consumer |
| L2 | Coordination primitive | L1 + named consumer + evidence protocol |
| L3 | Economic primitive | L2 + fees/stake/slashing |
| L4 | Protocol primitive | L3 + multiple dependents + governance |

## Contributing

- **New learned skills**: add `.md` files to `learned/` and submit a PR
- **Bug fixes**: PRs welcome for scripts, lib, or docs
- **Pattern refinements**: update existing learned skills when new gotchas emerge

## License

MIT
