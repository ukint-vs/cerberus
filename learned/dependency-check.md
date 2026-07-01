---
name: dependency-check
description: >
  Use when a project claims to depend on, integrate with, or be a consumer of
  another Vara Agent Network primitive (TinyPoll, ScoreSystem, or any registered
  application). Also applies when a project positions itself as infrastructure
  for other apps without naming them.

  Learned from: HeadlessReceiptStamp (PR#4, dependency on TinyPoll).
  Failure pattern: projects claim dependencies that don't exist on-chain (not
  deployed, paused, terminated), or the dependency relationship is one-way
  (upstream doesn't know about downstream). The dependency must be verifiable.
  Dead-end eliminated: "they told me it exists" — verify via indexer.
---

# Dependency / Integration Check

## When this applies

- "This app provides data/events for other VAN apps" without naming them
- "This is infrastructure that TinyPoll / ScoreSystem / other-app will consume"
- "Agents can use this service in their workflow" (if it implies another app calling it)
- The builder mentions another project by name as the reason this project exists

## Procedure

- [ ] **1. Identify the claimed dependency.** Extract the name, handle, or program ID of the upstream primitive. Ask: "Which exact program or app does this depend on?"

- [ ] **2. Resolve the dependency on-chain.** Query the indexer:
  ```
  query { applicationByProgramId(programId: "0x...") { id handle status owner } }
  ```
  Or use the handle:
  ```
  query { allApplications(filter:{handle:{equalTo:"tinypoll"}}) { nodes { id programId status } } }
  ```

- [ ] **3. Verify dependency is Live.** The dependency's status MUST be `Active`, `Initialized`, or application status must be `Live`. If paused/terminated, flag it: "Your dependency is not active on-chain. You cannot rely on it."

- [ ] **4. Verify the dependency relationship is reciprocal.** Is the upstream primitive designed to be consumed? Does it have methods another app can call? Check its IDL for public methods. If the upstream is read-only (no mutation methods the dependent could trigger), the relationship may be one-sided.

- [ ] **5. Check for competing dependencies.** Does the upstream have multiple consumers? If so, the downstream should handle state changes made by other consumers.

- [ ] **6. Document the dependency in the project context.** Record: which primitive, its programId, its status, and what methods the downstream calls.

## Guidance template (for Proceed with dependency)

> "Your dependency on [upstream] checks out: it's Live at [programId]. Before publish:
> 1. Document which specific methods your project calls on [upstream]
> 2. Handle the case where [upstream] is paused or upgraded (graceful degradation)
> 3. Verify your project still works if [upstream] has multiple consumers competing for state"

## Guidance template (for NeedsChanges — dependency issue)

> "You claim this depends on [upstream], but:
> - [upstream] is not deployed, or
> - [upstream] is paused/terminated, or
> - [upstream] has no methods you could call
>
> Either deploy/fix [upstream] first, or remove the dependency claim and scope this project as standalone."

## Gotchas

- **Unverified dependency = red flag.** Claiming integration with an app that doesn't exist on-chain is blockchain theater. Verify every dependency through the indexer, not the builder's word.
- **"We'll integrate after launch"** means the dependency doesn't exist yet. Do not approve L2+ based on future integrations — only on what's Live now.
- **Upstream changes.** If the upstream project is still in development (Building status), its API could change. Flag this risk and require the downstream to pin a specific revision or method signature.
- **Circular dependencies.** If project A depends on B and B depends on A, neither can go Live before the other. This is a coordination deadlock — flag it early.

## What didn't work

- "They told me it will work with TinyPoll" — without verifying TinyPoll's programId on-chain and checking that it has public methods the downstream can call, this is just an intention, not an architecture.
- "It's infrastructure, other apps will use it" — without naming a concrete first consumer, this is a solution looking for a problem. Demand at least one named consumer before Proceed.
