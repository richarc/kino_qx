# Code Review: kino_qx 0.2.0 — Transpile + Submit Smart Cell

## Summary
- **Status**: Changes Requested
- **Issues Found**: 7 (2 BLOCKER, 3 WARNING, 2 SUGGESTION)

---

## BLOCKER

### 1. `transpile_cell.ex:154,184` — `Task.start_link` from a Kino.JS.Live process is unsound

`Task.start_link` links the task back to the cell process. If `do_connect/1` or `TranspilePipeline.run/1` raises (not just returns an error tuple), the exit signal propagates to the Kino-managed cell process, killing it silently. The existing `handle_info({:EXIT, _pid, _reason}, ctx)` clause at line 284 swallows exits without updating cell state — so a mid-flight crash produces a dead cell with no user-visible error.

The doc claims "Kino's Live cell process is its supervisor" but `Task.start_link/1` is a bare linked task, not supervised under a `Task.Supervisor`.

The link is also not needed for communication (results arrive via `send/2`). The minimum-viable fix is `Task.start/1` (unlinked). If keeping the link, the `{:EXIT, ...}` clause must surface an error state rather than silently returning `{:noreply, ctx}`.

### 2. `transpile_cell.ex:443` — `backend_known?/2` accepts any name before connect

```elixir
defp backend_known?(_ctx, ""), do: true      # empty string → true
# ...
defp backend_known?(ctx, name) do
  case ctx.assigns.backends_list do
    [] -> true            # no backends fetched → any name accepted
    list -> Enum.any?(list, fn b -> b.name == name end)
  end
end
```

Before connect, `backends_list` is `[]`, so any `update_backend` binary is accepted into `last_backend_name`. The module's Iron Law comment claims handle_event validates against the cached list — that invariant only holds post-connect. Low data-corruption risk (submit's `require_connected` catches it), but the stated invariant is false for pre-connect state. Change the empty-list branch to `false`, and document that the only valid pre-connect state is an empty string.

---

## WARNING

### 3. `transpile_pipeline.ex:121` — `stage/2` has a latent bare-`:ok` pass-through

```elixir
:ok -> :ok   # passes bare :ok into the `with` chain
```

No current pipeline stage returns bare `:ok` inside the `with` (only `close_session` does, and it sits outside), so this is latent. But the clause misleads: if a future stage did return `:ok`, the `with` binding `{:ok, value} <- stage(...)` would not match bare `:ok`. Remove the clause or add a comment.

### 4. `ibm_client.ex:389` — `cond` used for a single boolean

```elixir
options =
  cond do
    body != nil -> Keyword.put(base_options, :json, body)
    true -> base_options
  end
```

Idiomatic: `if body != nil, do: Keyword.put(...), else: base_options`. (Also flagged by credo.)

### 5. `transpile_cell.ex:527` — Access syntax on an atom-keyed map

```elixir
identity_email: ctx.assigns.identity && ctx.assigns.identity[:email],
```

`identity` is atom-keyed (via `Client.atomize/1`). Use `ctx.assigns.identity.email` for consistency with the rest of the module.

---

## SUGGESTION

### 6. `transpile_pipeline.ex` — config-inject pattern vs Mox

The `:ibm_client` / `:portal_client` override in opts is pragmatic. Main risk: `StubClients.Ibm` can silently drift from `IbmClient`'s real signatures. Adding a `@behaviour Kino.Qx.IbmClient` (with `@callback` declarations only) gives compile-time verification of the stub without adding Mox. The `__recorder__` key injected into the IBM config is benign but impurifies the config type — document it in `@type config`.

### 7. `transpile_cell.ex:368` — task captures full `ctx` instead of minimal values

`do_connect(ctx)` is called inside a Task with the full `ctx` struct captured. The submit task at line 184 already follows the better pattern via `build_pipeline_input(ctx)`. Extract `portal_cfg`/`ibm_cfg` before the closure for symmetry.

---

## Pre-existing `client.ex` (one-line)

- `client.ex:195` — `{:error, %{reason: reason}}` matches any error-shaped map; fallback at line 198 handles exceptions via `Exception.message/1`. Map-match may shadow future Req struct changes.
