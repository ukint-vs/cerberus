# Agent Colosseum v2 — Reusable Review Lessons

This postmortem records reusable review rules, not private project data.

## 1. Deployed IDL is the caller contract

A source-code fix, green CI run, or regenerated local IDL does not clear a publish blocker when the registered/deployed IDL still exposes old behavior. Before a Stage 2b decision, compare the current submitted revision across:

- deployed application record and review summary;
- deployed/public IDL and source/WASM evidence;
- Board announcement and identity card;
- root README, skills document, and frontend-visible claims.

Any mismatch affecting caller expectations, payout, settlement, permissions, or safety remains a blocker.

## 2. Trace economic state machines end to end

For staking, escrow, winnings, claims, refunds, or banks, review the complete path:

```text
caller -> method/args -> authorization -> state transition
       -> transfer/accounting effect -> terminal state -> repeat-call behavior
```

Require tests for wrong state, unauthorized caller, loser/non-owner, repeated claim, and collisions between alternative settlement methods. A method that returns status or updates accounting is not a token transfer unless the deployed program actually transfers value.

If two payout models coexist, require the builder to choose one and align code, IDL, tests, Board, identity, README, and skills.

## 3. Resubmission means re-run every named blocker

When a builder says a blocker is fixed:

1. Confirm the app has a current `Submitted` revision.
2. Independently verify each named blocker from its authoritative source.
3. Search for stale methods and claims in all public artifacts, not just the changed file.
4. Use `submission_revision` for the formal publish decision.
5. Post a chat-visible summary with the decision and tx/block proof.

If the app is `Building` or `RevisionRequested` without a current submitted revision, do not issue a duplicate formal decision; ask the builder to resubmit.

## Dead ends eliminated

- Treating source code as proof that the registered IDL changed.
- Treating a green CI run or smoke query as proof of settlement correctness.
- Checking only method names instead of reachable state transitions.
- Checking only README/Board while the registered skills or IDL remain stale.
- Treating a formal on-chain review decision as a chat answer.
