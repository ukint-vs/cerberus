---
name: voting-archtype
description: >
  Use when evaluating ANY project that collects votes, scores, ratings, polls,
  or rankings from multiple actors. Covers ScoreSystem, TinyPoll, and
  reputation/rating primitives. Automatically load this skill whenever the
  project idea contains "vote", "poll", "score", "rating", "reputation",
  "review", "rank", "consensus", or "survey".

  Learned from: ScoreSystem (PR#2, L2) and TinyPoll (PR#3, L2).
  Failure pattern: voting primitives without economic slashing stall at L1/L2
  because voters have no skin in the game. Named consumer is often missing.
  Dead-end eliminated: "just storing votes on-chain" is not sufficient for L2.
---

# Voting / Scoring / Polling Archetype

## When this applies

The project describes itself as any of: voting system, score system, poll, reputation tracker, rating engine, ranking primitive, consensus mechanism, survey tool, or any primitive where actors submit votes/scores about something.

## Pattern recognition checklist

Evaluate in order:

- [ ] **1. What's being voted on?** On-chain state? Off-chain content (via hash)? Another agent's reputation? If off-chain, is there a `Verify*` method for submitted evidence?

- [ ] **2. Named consumer.** Who reads the result? "Any agent can query it" is not a named consumer. Require at least one concrete caller: another app, a reviewer agent, a Board posting script. If they can't name one, it's L1.

- [ ] **3. Evidence protocol.** Every vote/score that stores a `*Hash` or `*Proof` field MUST have a corresponding `Verify*`/`Validate*` method. A hash without a verifier is decorative data — red flag.

- [ ] **4. Anti-sybil / anti-gaming.** At L2+: how does the system prevent one actor from voting 1000 times? Is there a per-actor constraint? A minimum stake? If the answer is "agents are honest", push for at least a rate-limit mechanism.

- [ ] **5. Economic weight (L3 gate).** Voting/scoring without slashing is L2 at best. L3 requires: fees per vote, stake per voter, or slashing for malicious votes. If they claim L3 but have none of these, push back — it's L2.

- [ ] **6. Outcome enforcement.** For polls with a close mechanism: what happens after the poll closes? Who enforces the outcome? If the poll result is just stored data with no automatic action, flag it — terminal composability is missing.

## Maturity calibration

| Observation | Maturity |
|------------|----------|
| Stores votes, exposes queries, no consumer named | **L1** — NeedsChanges |
| Named consumer + evidence protocol + per-actor constraint | **L2** — Proceed |
| L2 + fees/stake/slashing for voters | **L3** — auto-publish candidate |
| L3 + multiple independent consumers + governance | **L4** — escalate to Foundation |

## Guidance template (for Proceed)

> "Your primitive is L2: it has [evidence protocol / named consumer]. Before submitting for publish, make sure your README documents:
> 1. The exact `Verify*` call for each stored hash
> 2. Who the first consumer is and what action they perform on the result
> 3. How the system prevents a single actor from dominating votes/scores"

## Guidance template (for NeedsChanges)

> "This is currently L1 (data silo). To reach L2, you need:
> 1. A named consumer — which app or agent reads the result and acts on it?
> 2. An evidence protocol — for every stored hash, add a `Verify*` method
> 3. A per-actor constraint — what stops one agent from voting 1000 times?
>
> Show me a concrete call chain: agent A → your method → downstream action."

## Gotchas

- **"Any agent can use it"** is valid only if you can trace a full method call chain from query to termination. Demand one.
- **`*Hash` without `Verify*`** is a blockchain-theater red flag — the hash is decorative without its verifier.
- **Voting ≠ reputation.** A poll that stores one-vote-per-actor is L2. A reputation system that aggregates scores over time is harder — it needs identity continuity and anti-sybil measures for L3.
- **Off-chain votes hashed on-chain** need the verifier to accept the off-chain data payload, not just check a hash against a pre-image — otherwise it's still decorative.

## What didn't work

- "Store everything on-chain and let agents query it" — this is just a smart contract acting as a database. Without a consumer that *acts* on the query result (terminating composability), it's L1 at best. Redis could do the same job.
- "The on-chain record is the proof" — the record IS the data. Proof requires a verifiable relationship between the record and some claim. If there's nothing to verify, there's no evidence protocol.
