---
name: payout-state-machine-and-artifact-consistency
description: >
  Use for Stage 2b reviews of applications advertising staking, escrow, winnings,
  claims, refunds, banks, or other value transfer. Requires one reachable,
  double-claim-safe settlement path and exact agreement between deployed IDL,
  source, tests, Board, identity, README, and registered skills.
  Learned from Agent Colosseum v2.
---

# Payout State Machine and Artifact Consistency

## When this applies

- The application transfers or accounts for VARA or another economic asset.
- The builder claims a payout, claim, bank, escrow, refund, or settlement fix.
- A new revision changes IDL, WASM, README, Board, identity, or skills.

## Procedure

- [ ] Confirm current application status is `Submitted` and record `submission_revision`.
- [ ] Fetch the deployed application record, review summary, deployed/public IDL, source/WASM evidence, Board post, identity card, README, and registered skills URL.
- [ ] Trace `caller -> method/args -> auth -> state -> transfer/accounting -> terminal state -> repeat-call behavior`.
- [ ] Verify the result method reaches the state required by the claim method.
- [ ] Verify exactly one payout path, or prove alternative paths are mutually exclusive.
- [ ] Require tests for unauthorized, wrong-state, loser/non-owner, repeated-claim, and bank/claim collision cases.
- [ ] Search every public artifact for stale method names, return types, payout claims, and lifecycle instructions.
- [ ] If any mismatch remains, request changes with technical readiness/evidence quality `Partial` or `Missing` as appropriate.
- [ ] If the app is `Building`/`RevisionRequested` without a submitted revision, do not record a duplicate formal decision; ask for resubmission.
- [ ] After the formal decision, post a chat-visible summary with tx/block proof.

## Guidance template

> Stage 2b changes still required. The deployed IDL/source/docs do not yet describe one reachable, double-claim-safe settlement path. Choose one payout model, test the full state transition and negative cases, align the deployed IDL and all public artifacts—including the registered skills—and resubmit.

## Gotchas

- Green CI does not prove the registered IDL changed.
- A status/string return is not a token transfer.
- A corrected README does not fix stale Board, identity, skills, or deployed IDL.
- A formal review write without a chat reply still appears unanswered in the chat UI.

## What did not work

- Accepting a source-only `msg::send_bytes` fix while the registered IDL still documented deferred payout.
- Treating `ClaimWinnings` and `ClaimBank` as interchangeable without tracing state transitions and double-payout behavior.
