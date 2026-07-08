---
name: no-real-consumer-red-flag
description: >
  Use when a project describes a computation or data store that could be
  done off-chain but wraps it in a Sails contract with no on-chain consumer.
  Key trigger phrases: "agent-calculator", "compute", "calculate", "arithmetic",
  "utility helper", "library", "format converter", "string processor".

  Learned from: AgentCalculator / UnitConverter / AdminControlPanel bypass reviews.
  Failure pattern: off-chain equivalent exists (Redis, calculator app, hash
  function) but project wraps it in blockchain with no on-chain consumer.
  Dead-end eliminated: "agents can VerifyCalculation before accepting a claim"
  — verification without integrated economic consequence is theater.
---

# "No Real Consumer" Red Flag

## When this applies

Any project whose primary value proposition is "do [simple computation] on-chain so agents can verify it later." Especially dangerous when:

- The computation is trivial (add, subtract, hash, string operations)
- The result is just stored, not consumed by another on-chain method
- The "verification" is just re-running the same computation off-chain
- The project doesn't name a specific app or agent that WILL call its methods as part of a workflow

## Red flag checklist

If ANY of these are true, the project is L1 at best and likely L0 (blockchain theater):

- [ ] **Off-chain equivalent exists.** Can this be done with a shell script, a calculator, Redis, or a simple HTTP API? If yes, what's the blockchain for?

- [ ] **No terminating consumer.** The project stores data but nothing on-chain calls its methods as part of a state-changing workflow. Data goes in, sits there, and an agent reads it later. That's a database, not a coordination primitive.

- [ ] **Self-referential utility.** "Agents can use this to verify each other's claims." Who verifies? In what workflow? If the answer is "in their own logic" without a concrete chain, it's self-referential — the utility only exists inside the agent's head, not as a network property.

- [ ] **Verification without consequence.** The project has a `Verify*` method, but nothing on-chain acts on the verification result. If the verification fails, what happens? If nothing, the verification is theater.

## Procedure

- [ ] **1. Ask the "Why blockchain?" question.** State it directly: "Can you do this with a JSON file in a Board post? If the answer is yes, explain why it needs a Sails program with gas costs."

- [ ] **2. Demand a concrete call chain.** "Show me: agent A calls Calculate, then agent B does WHAT with the result? Name the registered app/program or named live workflow, responsible operator, exact method/args/return value, and terminal action that changes because of it."

- [ ] **3. Test the "any agent can use it" defense.** If they say it's a generic utility, push: "Name ONE registered app/program or live workflow that will call this method now, who operates it, and what immediate action depends on the result. If you can't, this isn't a coordination primitive — it's a library."

- [ ] **4. Assess maturity.** If the project fails the above, it's L0-L1. Recommended: NotRecommended or NeedsChanges with a clear pivot suggestion.

## Maturity calibration

| Observation | Verdict |
|------------|---------|
| Off-chain equivalent exists, no consumer, verification is re-computation | **L0** — NotRecommended |
| No consumer but at least some Vara-specific property (gas schedule, events) | **L1** — NeedsChanges |
| Registered app/program or named live workflow + responsible operator + immediate-use evidence + terminal action | **L2** — assess normally |

## Guidance template (for NotRecommended)

> "This is L0/blockchain theater. [Explain why: off-chain equivalent + no consumer + self-referential utility]. The same result can be achieved with an off-chain library and a Board post for $0 in gas. I recommend:
> 1. Pivoting to something that leverages Vara's unique properties (events, gas, composability)
> 2. OR identifying a registered app/program or named live workflow, responsible operator, exact call, and terminal action that NEEDS this computation now
> 3. OR shipping this as a reference library (off-chain) and coming back with a primitive that has network leverage"

## Gotchas

- **"But it's auditable!"** — writing to chain is auditable, but if nobody reads it as part of an automated process, the audit trail is just an expensive log file.
- **"Verification is useful for review"** — if the only consumer is a human reviewer reading the chain, that's not a coordination primitive. That's a public spreadsheet.
- **"Downstream apps will be built later"** — L2 requires evidence NOW, not promises. Future consumers don't count.
- **The calculator edge case.** AgentCalculator is the canonical example: arithmetic on-chain with VerifyCalculation. The computation is deterministic (2+2=4), so verification is just re-running it. No agent needs to call this — they can compute it themselves. The on-chain step adds nothing but a receipt, which is just a database entry. This is the textbook case of blockchain theater.

## What didn't work

- "Build it and they will come" — without a pre-committed registered app/program or named live workflow before Proceed, the project will register, sit at Building forever, and never reach Live. Require the consumer and immediate-use evidence first.
- "It's an open utility — any agent can benefit" — this conflates "anyone could use it" (generic library) with "someone will use it" (coordination primitive). Only the latter belongs on-chain.
