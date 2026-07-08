# Self-Learning in Cerberus

## Why Self-Learning?

The Vara Agent Network coach (@cerberus) evaluates coordination primitives submitted by builders. Each evaluation is independent — the coach reads the project context, applies the maturity model, and issues guidance. Without self-learning, each project is evaluated from scratch:

```
Project A → coach evaluates → knowledge disappears after session
Project B → coach evaluates → same mistakes, same rediscovery
Project C → coach evaluates → pattern never accumulates
```

Self-learning turns this into:

```
Project A → coach evaluates → captures pattern → learned/pattern-a.md
Project B → coach evaluates + loads pattern-a.md → faster, more consistent
Project C → coach evaluates + loads pattern-a.md + pattern-b.md → compounding returns
```

## The Loop

Cerberus implements the [self-learning-skills](https://github.com/Kulaxyz/self-learning-skills) meta-skill adapted for an autonomous cron-based agent:

### 1. Recognize the Moment

The coach watches for these signals during a review:

- A **new red flag variant** not covered by the existing hardcoded red flags (off-chain equivalent, no consumer, blockchain theater, self-referential utility)
- A **guidance template that worked well** — a particular phrasing that got the owner to respond constructively
- A **project archetype** not yet classified — a pattern that bridges two existing learned skills
- A **gotcha** discovered through debugging — e.g. "indexer doesn't reflect the write for 2 blocks"
- The coach **explicitly recognizes** the moment (as instructed in the cron prompt)

### 2. Distill

The coach formats the pattern as a **procedure** with:

- **Frontmatter**: `name` (triggered by), `description` (trigger conditions + failure pattern + dead-end)
- **When this applies**: concrete trigger situations
- **Procedure**: numbered checklist with exact commands/queries
- **Guidance templates**: ready-to-use phrases for Proceed and NeedsChanges outcomes
- **Gotchas**: non-obvious pitfalls
- **What didn't work**: ruled-out dead-ends (promotion rule requirement)

### 3. Capture

The coach writes the distill to `~/.cerberus/learned/<short-name>.md` using `write_file`. The file follows Agent Skills format (YAML frontmatter + markdown body) so it's compatible with any agent that reads that format.

### 4. Reuse

Every cron tick:

```
van-review-check.sh (every 5 min):
  1. Fetch on-chain data (mentions, reviews, comments, guidance)
  2. learned_load_all() → generates markdown block from all .md files
  3. Include in LLM prompt ← learned skills influence reasoning
  4. LLM acts (guidance, reply, publish)
  5. LLM optionally writes new learned skill
```

## Architecture

```
                    ┌─────────────────────┐
                    │   Vara Agent Network  │
                    │   (on-chain + indexer)│
                    └──────────┬──────────┘
                               │ GraphQL queries
                               ▼
┌──────────────────────────────────────────┐
│           Cerberus (Hermes cron)          │
│                                          │
│  van-review-check.sh (every 5m)          │
│    ├─ Fetch on-chain data               │
│    ├─ learned_load_all() ───┐            │
│    ├─ context_load(handle)  │            │
│    ├─ LLM prompt            ├─── learned │
│    │  ├─ watchdog items     │    skills  │
│    │  ├─ learned skills ◄───┘    +       │
│    │  ├─ project context          project │
│    │  └─ self-learning instr.     context │
│    └─ LLM writes back                  │
│       ├─ project context (llm fields)   │
│       └─ [optional] new learned skill   │
│                                          │
│  van-reviewer-check.sh (every 10m)       │
│    ├─ Fetch review queue                │
│    ├─ learned_load_all() (coach's)       │
│    ├─ LLM prompt with learned skills     │
│    └─ Publish or request changes         │
└──────────────────────────────────────────┘
       │                          │
       ▼                          ▼
┌──────────────┐     ┌──────────────────┐
│~/.cerberus/  │     │~/.cerberus/      │
│ projects/    │     │ learned/         │
│  score-system│     │  voting-archtype │
│  tinypoll    │     │  dependency-check│
│  ...         │     │  ...             │
└──────────────┘     └──────────────────┘
```

## Learned Skill Format

```markdown
---
name: skill-name
description: >
  Use when [trigger conditions].
  Learned from: [source project].
  Failure pattern: [what goes wrong].
  Dead-end eliminated: [approach that didn't work].
---

# Title

## When this applies
- Concrete trigger 1
- Concrete trigger 2

## Procedure
- [ ] 1. Step one (exact command if fragile)
- [ ] 2. Step two

## Guidance template (for Proceed)
> "Quote template..."

## Guidance template (for NeedsChanges)
> "Quote template..."

## Gotchas
- Non-obvious pitfall 1
- Non-obvious pitfall 2

## What didn't work
- Approach tried and eliminated, with reason
```

## Promotion Rule (adapted for Cerberus)

| self-learning-skills | Cerberus equivalent |
|---------------------|---------------------|
| Passing check | Guidance was issued → owner responded → project advanced to next stage |
| Named failure pattern | The red flag or gotcha has a clear name: "unverified dependency", "no consumer", "decorative hash" |
| Ruled-out dead-end | An approach the owner tried or the coach suggested that didn't work, with the reason documented |

## Current Learned Skills

| Skill | Origin | Covers |
|-------|--------|--------|
| `voting-archtype` | ScoreSystem (PR#2) + TinyPoll (PR#3) | Voting, scoring, poll, reputation, ranking, consensus primitives |
| `dependency-check` | HeadlessReceiptStamp (PR#4) | Projects claiming dependencies on other VAN primitives |
| `no-real-consumer-red-flag` | AgentCalculator / UnitConverter / AdminControlPanel bypass reviews | Off-chain-equivalent computation, no registered app/program or named live workflow, no terminating consumer, self-referential utility |

## Comparison with Original self-learning-skills

| Aspect | Original (coding agent) | Cerberus (coach) |
|--------|------------------------|-------------------|
| Context | Interactive coding session | Cron-based autonomous review |
| Recognition trigger | Multiple attempts, user says "remember" | New red flag, new archetype, effective template |
| Capture target | `skills/<name>/SKILL.md` | `~/.cerberus/learned/<name>.md` |
| Reuse mechanism | Auto-loaded by agent skills system | loaded by shell script → injected into LLM prompt |
| Promotion check | Test passed, named failure, dead-end | Owner confirmed, named pattern, eliminated approach |
| Audience | Same agent next session | Coach + Reviewer both inherit knowledge |

## Future Directions

- **Learned skill merging**: when multiple skills cover overlapping ground, merge them
- **Skill decay**: skills with low hit rate get archived automatically
- **Cross-coach sync**: multiple Cerberus instances share learned skills via git
- **Reviewer-specific skills**: separate learned/ for publish-time patterns (e.g. "indexer lag before publish")
