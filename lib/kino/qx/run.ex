defmodule Kino.Qx.Run do
  @moduledoc """
  Implementation of `Kino.Qx.run/2,3` and `Kino.Qx.run!/2,3`.

  Wraps `Qx.Hardware.run/3` with a live `Kino.Frame` status panel
  (rendered above the eventual result) and a best-effort cancel
  watcher that fires `Qx.Hardware.cancel/3` if the caller cell
  process dies during a run.

  ## Architecture

      caller cell process  (Process.flag(:trap_exit, true))
        │
        ├── frame = Kino.Frame.new() |> tap(&Kino.render/1)
        │
        ├── watcher = spawn(...)                  ← unlinked
        │   └── monitors caller; only fires Qx.Hardware.cancel/3
        │       on the UNTRAPPABLE :kill path (see below)
        │
        ├── worker = Task.async(fn -> Hardware.run(...) end)
        │   └── on_status sends {:status, event} back to the caller
        │
        └── run_loop/1  (caller stays alive in a receive loop)
              ├─ {:status, event}    → frame + job_id + caller cb
              ├─ {ref, result}       → render terminal, :done, return
              ├─ {:DOWN, ref, ...}   → worker crash, propagate
              └─ {:EXIT, _, reason}  → trappable interrupt (below)

  ## Interrupt semantics

  Livebook's "Stop" may deliver `:shutdown` (trappable) or `:kill`
  (untrappable). The blocking hardware call runs in a worker `Task`
  so the caller stays in `run_loop/1`:

    * **`:shutdown` (trappable)** — the caller receives
      `{:EXIT, _, :shutdown}`, brutally stops the worker, issues the
      cancel **once itself**, signals the watcher `:done` (so the
      watcher stands down and does NOT cancel again on the caller's
      subsequent `:DOWN`), then **raises `Kino.Qx.Interrupted`** with
      the last-seen `job_id`. This is the now-true contract.

    * **`:kill` (untrappable)** — the caller dies immediately without
      running its handler. Only here does the unlinked watcher fire
      the cancel (its `{:DOWN, caller, reason != :normal}` arm). No
      `Kino.Qx.Interrupted` is raised — the process is already gone.

  ### Single-cancel gating

  On the trappable path the caller cancels and then sends the watcher
  `:done`. Erlang orders the `:done` message before the monitor
  `:DOWN` generated when the caller later dies, so the watcher always
  processes `:done` first and exits without cancelling — exactly one
  `Qx.Hardware.cancel/3` fires (the caller's). On the `:kill` path the
  caller never sends `:done`, so exactly one cancel fires (the
  watcher's).

  ### Residual races (honest caveats)

    * **Spurious cancel.** If the caller is killed in the narrow
      window *after* the worker returns but *before* `send(watcher,
      :done)`, the watcher still sees an abnormal `:DOWN` and issues a
      cancel for an already-finished job. `Qx.Hardware.cancel/3`
      treats an IBM 404 as expected, so this is harmless noise.
    * **Untrappable teardown.** A `:kill` (or a full Livebook session
      teardown that also kills the watcher) leaves the IBM job
      orphaned — it runs to completion and burns shots. This is the
      silent leak flagged in the plan's Risks section; only the
      upstream-side fix (job TTL / server cancel) fully closes it.
  """

  require Logger

  alias Kino.Qx.SafeReason
  alias Qx.Hardware

  @spec run!(Qx.QuantumCircuit.t(), Hardware.Config.t(), keyword()) ::
          Qx.SimulationResult.t()
  def run!(circuit, %Hardware.Config{} = config, opts \\ []) do
    case run(circuit, config, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise Kino.Qx.RunError, reason: reason
    end
  end

  @spec run(Qx.QuantumCircuit.t(), Hardware.Config.t(), keyword()) ::
          {:ok, Qx.SimulationResult.t()} | {:error, term()}
  def run(circuit, %Hardware.Config{} = config, opts \\ []) do
    frame = Kino.Frame.new() |> tap(&Kino.render/1)
    caller_on_status = Keyword.get(opts, :on_status, fn _ -> :ok end)

    # `:_hardware_mod` is an undocumented test seam — production callers
    # never set it. Tests pass a stub module exposing `run/3` and `cancel/3`.
    {hardware_mod, opts} = Keyword.pop(opts, :_hardware_mod, Hardware)

    state = %{
      lines: [],
      started_at: System.monotonic_time(:millisecond),
      job_id: nil,
      frame: frame
    }

    render_frame(state)

    watcher = start_cancel_watcher(self(), config, hardware_mod)
    caller = self()

    # Trap exits so a Livebook "Stop" delivering :shutdown (trappable)
    # arrives as a message we can act on — cancel the in-flight job and
    # raise Kino.Qx.Interrupted. :kill is untrappable and still relies
    # on the unlinked watcher (documented residual). Restore the prior
    # flag in `after` so we don't leave the cell process trapping.
    prev_trap = Process.flag(:trap_exit, true)

    hw_opts =
      Keyword.put(opts, :on_status, fn event -> send(caller, {:status, event}) end)

    task = Task.async(fn -> hardware_mod.run(circuit, config, hw_opts) end)

    try do
      run_loop(%{
        task: task,
        state: state,
        watcher: watcher,
        caller_on_status: caller_on_status,
        hardware_mod: hardware_mod,
        config: config
      })
    after
      Process.flag(:trap_exit, prev_trap)
    end
  end

  ## --------------------------------------------------------------
  ## Caller receive loop — owns the frame, threads job_id, and is the
  ## trappable-interrupt handler. The blocking hardware call runs in a
  ## monitored worker Task so this loop stays alive to catch :shutdown.
  ## --------------------------------------------------------------

  defp run_loop(ctx) do
    %{task: %Task{ref: task_ref, pid: task_pid} = task} = ctx

    receive do
      {:status, event} ->
        ctx
        |> handle_status(event)
        |> run_loop()

      {^task_ref, result} ->
        Process.demonitor(task_ref, [:flush])
        render_terminal(ctx.state, result)
        send(ctx.watcher, :done)
        result

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        # Worker crashed without delivering a result. Demonitor for
        # symmetry with the normal path (R2.3 / W7), stand the watcher
        # down, then propagate the crash as the caller's own exit.
        Process.demonitor(task_ref, [:flush])
        send(ctx.watcher, :done)
        exit(reason)

      {:EXIT, ^task_pid, _reason} ->
        # Linked worker exit signal — paired with {ref, result} or the
        # abnormal :DOWN above, which carry the actual outcome. Ignore.
        run_loop(ctx)

      {:EXIT, _from, reason} when reason in [:shutdown, :killed] ->
        # Livebook interrupt of THIS caller via the trappable path.
        # Stop the worker, issue the cancel exactly once here, tell the
        # watcher to stand down (so it does NOT re-cancel on our :DOWN),
        # then raise so the contract (`Kino.Qx.Interrupted`) is real.
        _ = Task.shutdown(task, :brutal_kill)

        if ctx.state.job_id,
          do: safe_cancel(ctx.hardware_mod, ctx.state.job_id, ctx.config)

        send(ctx.watcher, :done)
        raise Kino.Qx.Interrupted, job_id: ctx.state.job_id

      {:EXIT, _from, _reason} ->
        # Unrelated linked process exited (e.g. :normal). Ignore.
        run_loop(ctx)
    end
  end

  defp handle_status(ctx, event) do
    case event do
      {:ibm, :job_started, jid} when is_binary(jid) ->
        send(ctx.watcher, {:job_id, jid})

      _ ->
        :ok
    end

    new_state = handle_status_event(ctx.state, event)
    render_frame(new_state)

    # A buggy caller-supplied callback must not crash the run loop, but
    # don't swallow it silently either. Log the exception TYPE only —
    # never the event or message (no value leak; S2).
    try do
      ctx.caller_on_status.(event)
    rescue
      e ->
        Logger.warning("Kino.Qx: caller :on_status callback raised #{inspect(e.__struct__)}")
    end

    %{ctx | state: new_state}
  end

  ## --------------------------------------------------------------
  ## Cancel watcher — survives caller death (unlinked)
  ## --------------------------------------------------------------

  defp start_cancel_watcher(caller, config, hardware_mod) do
    spawn(fn ->
      ref = Process.monitor(caller)
      cancel_watcher_loop(ref, config, nil, hardware_mod)
    end)
  end

  defp cancel_watcher_loop(ref, config, job_id, hardware_mod) do
    receive do
      {:job_id, new_id} when is_binary(new_id) ->
        cancel_watcher_loop(ref, config, new_id, hardware_mod)

      :done ->
        # Caller signalled normal completion; tear down.
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _pid, reason} when reason != :normal ->
        # Caller died abnormally (Livebook interrupt or crash). Best-effort
        # cancel. We don't propagate failures — IBM 404 is expected if the
        # job already terminated. Guard the call: a raise here would crash
        # the watcher and BEAM would dump its closure env (which captures
        # `config`, i.e. tokens) into the Livebook log.
        if job_id, do: safe_cancel(hardware_mod, job_id, config)

      {:DOWN, ^ref, :process, _pid, _normal} ->
        :ok
    end
  end

  # Never let a cancel failure propagate: a raise/exit/throw here would
  # crash the watcher and BEAM's crash report would `inspect` the
  # closure env, leaking `config` (portal/IBM tokens) to the log. Log a
  # fixed string only — never the reason, exception, or config.
  defp safe_cancel(hardware_mod, job_id, config) do
    hardware_mod.cancel(job_id, config)
    :ok
  rescue
    _ ->
      Logger.warning("Kino.Qx: cancel watcher failed to cancel in-flight job")
      :ok
  catch
    _, _ ->
      Logger.warning("Kino.Qx: cancel watcher failed to cancel in-flight job")
      :ok
  end

  ## --------------------------------------------------------------
  ## Status event → frame state
  ## --------------------------------------------------------------

  defp handle_status_event(state, event) do
    state =
      case event do
        {:ibm, :job_started, job_id} -> %{state | job_id: job_id}
        _ -> state
      end

    line = render_event_line(event, state)
    # Prepend (O(1)); render_frame/1 reverses once (W6: was O(n²)).
    %{state | lines: [line | state.lines]}
  end

  ## --------------------------------------------------------------
  ## Frame rendering
  ## --------------------------------------------------------------

  defp render_event_line({:portal, :connecting}, _),
    do: "⏳ connecting to portal…"

  defp render_event_line({:portal, :listing_backends}, _),
    do: "⏳ listing backends…"

  defp render_event_line({:ibm, :authenticating}, _),
    do: "⏳ authenticating with IBM…"

  defp render_event_line({:ibm, :fetching_backend}, _),
    do: "⏳ fetching backend properties…"

  defp render_event_line({:portal, :transpiling}, _),
    do: "⏳ transpiling via qxportal…"

  defp render_event_line({:ibm, :submitting}, _),
    do: "⏳ submitting to IBM…"

  defp render_event_line({:ibm, :job_started, job_id}, _),
    do: "✔ submitted: `#{job_id}`"

  # Poll-key contract (S3): upstream `Qx.Hardware` emits
  # `{:ibm, :polling, status}` with `status` a BINARY (hardware.ex);
  # the underlying poll-status map is ATOM-keyed (`%{status:, reason:}`)
  # and never crosses into kino_qx. The binary clause below is the real
  # production path; this map clause stays only for the atom-keyed test
  # seam / forward-compat — no string-key fallback (it can't occur).
  defp render_event_line({:ibm, :polling, %{} = poll}, state) do
    status = Map.get(poll, :status, "polling")
    queue = Map.get(poll, :queue_position)
    elapsed = elapsed_seconds(state)
    queue_part = if queue, do: " (queue: #{queue})", else: ""
    "⏳ #{status}#{queue_part} (#{elapsed}s)"
  end

  defp render_event_line({:ibm, :polling, status}, state) when is_binary(status) do
    "⏳ #{status} (#{elapsed_seconds(state)}s)"
  end

  defp render_event_line({:ibm, :fetching_results}, _),
    do: "⏳ fetching results…"

  defp render_event_line(other, _),
    do: "· " <> SafeReason.describe(other)

  # `state.lines` is kept newest-first (prepended); reverse once here.
  defp render_frame(state) do
    markdown = state.lines |> Enum.reverse() |> Enum.join("  \n")
    Kino.Frame.render(state.frame, Kino.Markdown.new(markdown))
  end

  defp render_terminal(state, {:ok, _result}) do
    line = "✔ done in #{elapsed_seconds(state)}s"
    render_frame(%{state | lines: [line | state.lines]})
  end

  defp render_terminal(state, {:error, reason}) do
    line = "✖ error: " <> SafeReason.describe(reason)
    render_frame(%{state | lines: [line | state.lines]})
  end

  defp elapsed_seconds(state) do
    div(System.monotonic_time(:millisecond) - state.started_at, 1000)
  end
end
