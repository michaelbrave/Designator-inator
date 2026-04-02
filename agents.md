# Agent Instructions for ForgeClaw

Read this file before touching any code. It tells you the rules, the method, and how to hand off to the next agent.

---

## The method: HTDP

We follow the **How to Design Programs** recipe for every function. The steps are in `HTDP.md`. Short version:

1. **Data definitions** — define the shape of data before writing functions that touch it
2. **Signature + purpose statement + header** — `@spec`, `@doc`, and a stub
3. **Functional examples** — concrete input/output pairs in `@doc` (`iex>` format)
4. **Function template** — a numbered comment outline of the algorithm inside the stub body
5. **Function definition** — fill in the template
6. **Tests** — turn the examples into ExUnit assertions

**Every function you write must go through all 6 steps, in order.** Do not skip to step 5 without steps 1–4 in place. Do not leave out tests.

---

## Rules for all agents

### Do not remove HTDP scaffolding

The `# Template:` comments inside stub bodies are load-bearing documentation. They explain the intended algorithm to the next implementor. **Do not delete them when you implement a function.** Move them into a `# Was:` block below your implementation if you want to keep the file clean, but never throw them away entirely.

The `@doc` examples (`iex>` blocks) must stay. They are the specification. If your implementation changes the behavior described in an example, update the example — do not silently delete it.

### Do not implement beyond what you were asked

Fill in stubs one at a time. Do not refactor surrounding code, add features that weren't asked for, or "clean up" working scaffolding. The scaffolding is intentional structure — it is not mess.

### Keep `@spec` and `@doc` accurate

If you change a function's signature or behavior, update `@spec` and `@doc` to match. Future agents and the LLM tool-call parser both read these.

### Tests must pass before you mark a task done

Run `mix test` (or the relevant test file with `mix test path/to/test.exs`) after each implementation. Do not mark a task complete if tests are failing.

### One module at a time

Implement one module fully (all its stubs + tests passing) before moving to the next. Do not scatter partial implementations across multiple modules.

---

## How to update `plan.md` after completing work

After finishing a feature or a major change, update `plan.md` as follows:

1. **Mark completed items** — change `[ ]` to `[x]` on each checklist item you finished. If there was no checkbox, add a `**Done:**` line under the section heading.

2. **Add a "Completed" block** at the top of the relevant milestone section:
   ```
   **Status: DONE** — <one sentence summary of what was implemented and any notable decisions>
   ```

3. **Update "Next Steps"** at the bottom of `plan.md` — remove steps you finished, add any new steps that emerged during implementation (bugs found, design decisions deferred, etc.).

4. **Record deferred decisions** — if you hit an open question or made a design choice that future agents need to know about, add it to the "Decisions Made" section at the bottom of `plan.md`.

5. **Do not rewrite history** — keep records of what was done even if the approach changed. Add a note rather than erasing the old plan.

---

## How to read the codebase before starting

1. Read `plan.md` — it tells you what is done, what is next, and any decisions already made
2. Read `HTDP.md` — the method you must follow
3. Read `forge_claw/lib/forge_claw/types.ex` — all the data types in one place
4. Read the module file(s) you are about to implement — understand the existing `@doc`, `@spec`, and `# Template:` comments before writing a single line
5. Read the corresponding test file — the tests are the specification

Do not read the entire codebase. Read only what you need for the task at hand.

---

## Project overview

ForgeClaw is a local-first AI agent orchestration system on Elixir/BEAM. Each agent is a "Pod" — a directory package with `manifest.yaml`, `soul.md`, `config.yaml`, and a `workspace/`. Every pod is simultaneously an MCP server and an MCP client. See `plan.md` for the full architecture.

The project is in `forge_claw/`. Example pods are in `examples/`. Planning docs are at the repo root.
