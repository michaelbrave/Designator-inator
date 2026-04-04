# Future Features

Ideas and improvements that didn't make the current cut. Open a PR or issue to pick one up.

---

## Hot-reload model and config without pod restart

**Problem:** Right now, changing a pod's `config.yaml` (e.g. swapping the primary model,
adjusting temperature, enabling a fallback provider) requires stopping and restarting the
pod. This is disruptive — the conversation session is interrupted and any in-flight
requests are dropped.

**What already works:** `soul.md` hot-reloads automatically via the `:fs` file watcher.
The same mechanism could be extended.

**Proposed approach:**

1. Extend the `:fs` watcher in `Pod.init/1` to also watch `config.yaml`.
2. On `{:file_event, _, {path, _}}` where path ends in `config.yaml`, call
   `Pod.Config.load/1` to re-parse and diff against the current config.
3. Apply changes that are safe to apply in-place:
   - Inference params (`temperature`, `max_tokens`, `max_history`) — just update
     the GenServer state; next request picks them up.
   - Provider API key env vars — re-resolve on next request anyway.
   - Fallback model and fallback mode — update state; no restart needed.
4. For changes that require a model swap (different `primary` model):
   - Finish any in-flight request first.
   - Call `ModelManager.load_model/1` for the new model (pre-warms it).
   - Update pod state to point at the new model.
   - Optionally call `ModelManager.unload_model/1` for the old one if no other
     pod is using it.
5. Expose a CLI command: `designator-inator reload <pod-name>` that triggers the
   same config reload path on demand, without waiting for a file change.

**Why it matters:** Makes iterating on model selection much faster, especially when
testing which quantization fits in available VRAM. Also enables runtime model swaps
driven by the orchestrator (e.g. "use the cheap model for drafting, promote to the
big model for final review").

**Files to touch:**
- `lib/designator_inator/pod.ex` — extend `handle_info {:file_event, ...}`
- `lib/designator_inator/cli.ex` — add `cmd_reload/1`
- `lib/designator_inator/pod/config.ex` — add `diff/2` helper (optional, makes
  it easier to decide what changed)

---

## OpenRouter support as fallback (done — 2026-04-03)

Added in `Providers.OpenRouter`. Model IDs use `openrouter/<provider>/<model>` prefix.
Set `OPENROUTER_API_KEY` or configure `api_key_env` in `config.yaml`:

```yaml
model:
  primary: mistral-7b-instruct-Q4_K_M
  fallback: openrouter/meta-llama/llama-3.1-8b-instruct
  fallback_mode: auto
  providers:
    openrouter:
      api_key_env: OPENROUTER_API_KEY
```
