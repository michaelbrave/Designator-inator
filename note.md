# Carry-Forward Note

## Current State

- Repo rename is complete:
  - repo/product name: `Designator-inator`
  - Elixir namespace: `DesignatorInator`
  - OTP app: `:designator_inator`
  - CLI/escript: `designator-inator`
  - default config paths: `~/.designator_inator/...`
- Milestone 2 is complete and verified.
- Milestone 3 core pod packaging is largely implemented; CLI `run/list/stop/models`, chat loop, and MCP `serve` stdio wiring are now wired and their targeted tests pass.
- Fully implemented and verified so far:
  - `DesignatorInator.ModelInventory`
  - `DesignatorInator.Providers.LlamaCpp`
  - `DesignatorInator.ModelManager`
  - `DesignatorInator.Memory`
  - `DesignatorInator.ToolCallParser`
  - `DesignatorInator.ReActLoop`
  - `DesignatorInator.Pod.Manifest`
  - `DesignatorInator.Pod.Config`
  - `DesignatorInator.Pod`
  - `DesignatorInator.PodSupervisor`
  - `DesignatorInator.ToolRegistry`
  - `DesignatorInator.MCPGateway`
  - `DesignatorInator.CLI.cmd_serve/2` stdio wiring
  - `DesignatorInator.MCP.Transport.SSE` auth + POST dispatch + response routing
- Milestone 3 is complete: assistant pod packaging, CLI run/list/stop/models, and the end-to-end `designator-inator run ./examples/assistant/` path are verified.
- Milestone 4 is complete, verified, and audited.
- Milestone 5 is complete, verified, and audited.
- Milestone 6 is complete: pods register/deregister exposed tools via ToolRegistry, the orchestrator example exposes namespaced pod tools through `internal_tools: ["pods"]`, ReActLoop executes tool calls in parallel, and orchestration persistence/recovery now work through persisted conversation history.
- Milestone 7 is complete: SwarmRegistry now handles `:pg`-based pod discovery, node connect, node monitoring, node-info aggregation, and model-aware pod selection.
- Current full test suite passes: 145 tests, 0 failures.
- First version of the project is now complete; next work is user-directed follow-up.

## Toolchain / Environment

- Standardized toolchain for this repo:
  - Erlang `28.0.2`
  - Elixir `1.19.5-otp-28`
- `.tool-versions` is checked in.
- `designator_inator/mix.exs` now targets `elixir: "~> 1.19"`.
- In this Codex environment, `mix` may still be unavailable even if it works in the user's shell. If that happens, ask the user to run the targeted test and paste the result.

## What Was Implemented

### ModelInventory

Implemented in:
- [`designator_inator/lib/designator_inator/model_inventory.ex`](./designator_inator/lib/designator_inator/model_inventory.ex)

Implemented functions:
- `scan_directory/1`
- `parse_gguf_filename/1`
- `parse_quantization/1`
- `init/1`
- `handle_call(:list, ...)`
- `handle_call({:get, ...}, ...)`
- `handle_call(:rescan, ...)`

Important details:
- `FP16` is normalized to `:f16`
- `rescan/0` preserves the last known catalog if a rescan fails
- unparseable files are skipped rather than crashing the scan

Verified passing:
- [`designator_inator/test/designator_inator/model_inventory_test.exs`](./designator_inator/test/designator_inator/model_inventory_test.exs)

Latest result:
```text
13 tests, 0 failures
```

### Providers.LlamaCpp

Implemented in:
- [`designator_inator/lib/designator_inator/providers/llama_cpp.ex`](./designator_inator/lib/designator_inator/providers/llama_cpp.ex)

Implemented functions/callbacks:
- `complete/2`
- `messages_to_openai/1`
- `health_check/1`
- `init/1`
- `handle_call(:await_ready, ...)`
- `handle_call(:stop, ...)`
- `handle_info(:health_check, ...)`
- `handle_info({port, {:exit_status, code}}, ...)`
- supporting helpers for request building, response extraction, process killing, and config-driven test seams

Important details:
- uses app-configured seams for HTTP client, Port opener, and kill command runner so unit tests do not require a real `llama-server`
- converts tool calls into OpenAI-compatible `tool_calls`
- supports readiness waiters and graceful shutdown flow

Verified passing:
- [`designator_inator/test/designator_inator/providers/llama_cpp_test.exs`](./designator_inator/test/designator_inator/providers/llama_cpp_test.exs)

Latest result:
```text
7 tests, 0 failures
```

### ModelManager

Implemented in:
- [`designator_inator/lib/designator_inator/model_manager.ex`](./designator_inator/lib/designator_inator/model_manager.ex)

Implemented functions/callbacks:
- `estimate_vram_mb/1`
- `lru_model/1`
- `init/1`
- `handle_call({:load_model, ...}, ...)`
- `handle_call({:complete, ...}, ...)`
- `handle_call({:unload_model, ...}, ...)`
- `handle_call(:available_vram_mb, ...)`
- `handle_call(:node_info, ...)`
- supporting helpers for model loading, budget enforcement, LRU eviction, node-info refresh, local-failure fallback routing, and provider seams

Important details:
- local-vs-cloud provider routing via `provider_for/1`
- local failure supports auto-fallback to configured cloud model
- added app-configured provider seams for testing:
  - `:model_manager_llama_provider`
  - `:model_manager_openai_provider`
  - `:model_manager_anthropic_provider`
- keeps HTDP template comments preserved in `# Was:` blocks

Verified passing:
- [`designator_inator/test/designator_inator/model_manager_test.exs`](./designator_inator/test/designator_inator/model_manager_test.exs)

Latest result:
```text
10 tests, 0 failures
```

Cross-check run:
```text
model_inventory + llama_cpp + model_manager: 30 tests, 0 failures
```

### Milestone 1 Integration (real GGUF + compiled llama-server)

Environment used:
- GGUF directory: `/media/mike/storage/models/lmstudio/lmstudio-community/gemma-3-4b-it-GGUF`
- model: `gemma-3-4b-it-Q4_K_M`
- llama.cpp source: `https://github.com/ggml-org/llama.cpp`
- compiled binary: `/home/mike/projects/llama.cpp/build/bin/llama-server`

Issue found and fixed:
- `Providers.LlamaCpp.await_ready/1` had a hardcoded `15_000ms` timeout.
- Real model load exceeded that startup window and caused `ModelManager.load_model/1` to timeout.
- Fix applied: `await_ready/1` now reads timeout from app config key `:llama_ready_timeout_ms` (default still `15_000`).

Integration result:
```text
load_model: :ok
complete: {:ok, "INTEGRATION_OK\n"}
unload_model: :ok
```

## Earlier Test / Boot Fixes Already In Place

### Test repo config

Updated [`designator_inator/config/test.exs`](./designator_inator/config/test.exs):
- switched test DB from SQLite `:memory:` to file-backed DB
- set `pool_size: 1`

Reason:
- `:memory:` lost migration state across Mix alias/test process boundaries
- current `ecto_sqlite3` requires `pool_size: 1` for in-memory DB anyway

### Test helper

Updated [`designator_inator/test/test_helper.exs`](./designator_inator/test/test_helper.exs):
- explicitly starts `DesignatorInator.Memory.Repo`

### Test application boot

Updated [`designator_inator/mix.exs`](./designator_inator/mix.exs):
- in `:test`, do not start `DesignatorInator.Application`

Reason:
- unfinished supervisors/stubs were crashing test startup

### Fixture helper fix

Updated [`designator_inator/test/support/fixtures.ex`](./designator_inator/test/support/fixtures.ex):
- removed invalid `on_exit/1` call from helper module `tmp_dir/1`

## Important Context For Next Session

- Follow [`agents.md`](./agents.md) strictly:
  - keep HTDP scaffolding comments
  - do not remove docs
  - implement one module at a time
  - update `plan.md` after meaningful progress
- Unit-test-by-module is still the right workflow.
- Do not try to boot the whole application yet.
- Milestone 1 integration has been run successfully against a real local GGUF with compiled `llama-server`.

## Recommended Next Step

Milestone 2 is complete. Milestone 3 is largely done. Next up is the remaining Milestone 4 work:
- `MCPGateway.handle_call/3` for `tools/list` and `tools/call`
- `CLI.cmd_serve/2`
- SSE transport + token auth
- multi-pod routing in the gateway

Note on test status:
- The full `mix test` suite is expected to stay partially red until later milestones are implemented.
- For now, validate the milestone-specific MCP tests and the module(s) you are actively changing.

Keep these targeted tests green while moving forward:

```bash
cd /home/mike/projects/Designator-inator/designator_inator
mix test test/designator_inator/mcp/protocol_test.exs \
         test/designator_inator/mcp/transport_stdio_test.exs
```

Then continue adding Milestone 4 tests module-by-module before implementing each stub.

## Known Warnings

- OTP `28.0` emits a regex recompilation warning at runtime.
- This is not a blocker.
- Upgrading from `28.0.2` to a later `28.x` should remove it, but it is not urgent.

## Post-Review Fixes (2026-04-02)

A code review pass found two spec deviations. Both are now fixed and all 32 Milestone 1 tests pass.

### Fix 1: `parse_quantization/1` unknown string case

**Problem:** `parse_quantization/1` ran `String.upcase(str)` and then returned `{:unknown, upper}`, silently uppercasing unrecognized quantization strings. The `# Template:` comment and the function's intent was to preserve the original string.

**Fix:** Changed `upper -> {:unknown, upper}` to `_ -> {:unknown, str}` so the original casing is preserved.

**File:** `designator_inator/lib/designator_inator/model_inventory.ex`

### Fix 2: Auto-fallback 3-consecutive-errors threshold

**Problem:** `ModelManager.handle_local_failure/5` triggered cloud fallback on the **first** local inference error in `:auto` mode. The spec in `plan.md` says fallback triggers after **3 consecutive** inference errors; load/capacity errors (`:model_not_found`, `:insufficient_vram`) are still immediate triggers.

**Fix:** `handle_local_failure` now tracks `new_errors = consecutive_errors + 1` and only calls the cloud provider when `new_errors >= 3` (for inference errors) or `reason in [:model_not_found, :insufficient_vram]` (immediate). The existing `consecutive_errors` state field was already present for this purpose.

**Test update:** Replaced the single "falls back to cloud in :auto mode when local inference fails" test with three targeted tests:
- `does not fall back on first or second consecutive inference error in :auto mode`
- `falls back to cloud after 3 consecutive inference errors in :auto mode`
- `falls back immediately to cloud on model load error in :auto mode`

**Files:** `designator_inator/lib/designator_inator/model_manager.ex`, `designator_inator/test/designator_inator/model_manager_test.exs`

## Files Changed In This Session

- [`plan.md`](./plan.md)
- [`note.md`](./note.md)
- [`designator_inator/lib/designator_inator/mcp/protocol.ex`](./designator_inator/lib/designator_inator/mcp/protocol.ex)
- [`designator_inator/lib/designator_inator/mcp/transport/stdio.ex`](./designator_inator/lib/designator_inator/mcp/transport/stdio.ex)
- [`designator_inator/test/designator_inator/mcp/transport_stdio_test.exs`](./designator_inator/test/designator_inator/mcp/transport_stdio_test.exs)

## Test Audit + Fixes (2026-04-02)

A full audit of all test files was performed to check for auto-pass patterns, skipped tests, mock abuse, and weak assertions. No critical issues (auto-pass, `@tag :skip`, hardcoded `:ok`) were found. Two issues were fixed and one coverage gap was filled.

### Fix 1: Broken assertion idiom in stdio transport test

**File:** `designator_inator/test/designator_inator/mcp/transport_stdio_test.exs:75`

**Problem:** `assert output =~ ~s("method":"initialize") == false` — due to Elixir's left-to-right evaluation of same-precedence comparison operators, this parses as `(output =~ ...) == false`. It worked correctly at runtime but reads as if it were asserting the *presence* of the pattern.

**Fix:** Changed to `refute output =~ ~s("method":"initialize")`.

### Fix 2: Weak `inputSchema` assertion in protocol test

**File:** `designator_inator/test/designator_inator/mcp/protocol_test.exs:103`

**Problem:** `assert is_map(mcp_tool["inputSchema"])` accepted any map, including `%{}`. The source correctly builds `%{"type" => "object", "properties" => ...}` but a broken implementation returning an empty map would have passed.

**Fix:** Replaced with `assert mcp_tool["inputSchema"]["type"] == "object"` and `assert is_map(mcp_tool["inputSchema"]["properties"])`.

### New test: `tools_to_mcp` parameter conversion

**File:** `designator_inator/test/designator_inator/mcp/protocol_test.exs`

**Problem:** The existing test only called `tools_to_mcp` with `parameters: %{}` (empty), leaving the entire parameter-to-JSON-Schema conversion path in `protocol.ex` (lines 196–230) untested. That code handles `:type`, `:description`, `:enum`, `:required`, and `:default` fields.

**Fix:** Added a second test case with real parameters that verifies type conversion, description, enum, and the `"required"` array in the output schema.

**Result:** MCP tests now 18 tests, 0 failures (was 17).

## Files Changed In This Session

- [`note.md`](./note.md)
- [`designator_inator/test/designator_inator/mcp/transport_stdio_test.exs`](./designator_inator/test/designator_inator/mcp/transport_stdio_test.exs)
- [`designator_inator/test/designator_inator/mcp/protocol_test.exs`](./designator_inator/test/designator_inator/mcp/protocol_test.exs)

## Milestone 4 & 5 Audit + Fixes (2026-04-03)

A full audit of milestone 4 (MCP Server Interface) and milestone 5 (Cloud Provider Integration) was performed. Three bugs were found and fixed.

### Fix 1: SSE transport silently dropped all gateway responses (critical)

**Files:**
- `designator_inator/lib/designator_inator/mcp_gateway.ex`
- `designator_inator/lib/designator_inator/mcp/transport/sse.ex`
- `designator_inator/test/designator_inator/mcp/transport_sse_test.exs`
- `designator_inator/test/designator_inator/mcp_gateway_test.exs`

**Problem:** Both clauses of `maybe_dispatch_to_gateway/2` in `sse.ex` called `MCPGateway.handle_request/1` but discarded the return value. The SSE stream (running in `stream_loop`) never received any responses. The architecture requires the POST handler to push the response back over the open SSE connection using the registered `send_fn`, but nothing did this.

The existing test only asserted the gateway was called, not that any response was sent back.

**Fix:**
- Added `MCPGateway.push_to_sse_connection/2` public API and its `handle_call({:push_to_sse, ...})` handler, which looks up the stored `send_fn` for a connection and calls it.
- Fixed the non-nil `maybe_dispatch_to_gateway/2` clause to call `push_to_sse_connection/2` with the response.
- Added `push_to_sse_connection/2` to the `GatewayStub` in the SSE test.
- Added two new tests: one in the SSE transport test verifying the push-back, one in the gateway test verifying `push_to_sse_connection/2` directly.

### Fix 2: `stream_loop` crashed on client disconnect instead of deregistering

**File:** `designator_inator/lib/designator_inator/mcp/transport/sse.ex`

**Problem:** All three `chunk/2` call sites used the irrefutable match `{:ok, conn} = chunk(...)`. When an SSE client disconnects, `chunk/2` returns `{:error, reason}`, which would crash the process and leave a stale entry in `MCPGateway.sse_connections` permanently.

**Fix:** Replaced the irrefutable matches with case expressions that call `gateway_module().deregister_sse_connection(connection_id)` on error, then return cleanly.

### Fix 3: Anthropic model IDs one generation behind (false-passing tests)

**Files:**
- `designator_inator/lib/designator_inator/providers/anthropic.ex`
- `designator_inator/test/designator_inator/providers/anthropic_test.exs`

**Problem:** `Providers.Anthropic.model_id/1` mapped `"claude-sonnet"` → `"claude-sonnet-4-5"` and `"claude-opus"` → `"claude-opus-4-5"`. The current latest is `4-6`. The tests passed because they asserted the outdated IDs rather than the correct ones.

**Fix:** Updated `model_id/1` to map to `"claude-sonnet-4-6"` and `"claude-opus-4-6"`. Updated test assertions to match. Haiku remains `"claude-haiku-4-5-20251001"` (no 4.6 version exists yet).

**Result:** 52 tests, 0 failures (was 49 — 3 new tests added).

## Recommended Next Step

Milestone 6 — Orchestration. Start from `plan.md` Milestone 6 section. Key work:
- `DesignatorInator.Orchestrator` — meta-agent that decomposes tasks and delegates to other pods
- `Pod.delegate/3` — pod-to-pod tool delegation via MCPGateway
- `DesignatorInator.SwarmRegistry` stubs need real implementations

Keep these targeted tests green while adding Milestone 6 coverage:

```bash
cd /home/mike/projects/Designator-inator/designator_inator
mix test test/designator_inator/mcp/ \
         test/designator_inator/mcp_gateway_test.exs \
         test/designator_inator/providers/ \
         test/designator_inator/model_manager_test.exs
```

## Files Changed In This Session (2026-04-03)

- [`plan.md`](./plan.md)
- [`note.md`](./note.md)
- [`designator_inator/lib/designator_inator/pod.ex`](./designator_inator/lib/designator_inator/pod.ex)
- [`designator_inator/lib/designator_inator/react_loop.ex`](./designator_inator/lib/designator_inator/react_loop.ex)
- [`designator_inator/test/designator_inator/pod_test.exs`](./designator_inator/test/designator_inator/pod_test.exs)
- [`designator_inator/test/designator_inator/react_loop_test.exs`](./designator_inator/test/designator_inator/react_loop_test.exs)
- [`examples/orchestrator/manifest.yaml`](./examples/orchestrator/manifest.yaml)
- [`examples/orchestrator/config.yaml`](./examples/orchestrator/config.yaml)
- [`examples/orchestrator/soul.md`](./examples/orchestrator/soul.md)
- [`examples/orchestrator/workspace/.keep`](./examples/orchestrator/workspace/.keep)
