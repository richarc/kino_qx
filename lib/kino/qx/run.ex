defmodule Kino.Qx.Run do
  @moduledoc """
  Implementation of `Kino.Qx.run/2,3` and `Kino.Qx.run!/2,3`.

  Wraps `Qx.Hardware.run/3` with a live `Kino.Frame` status panel
  (rendered above the eventual result) and a best-effort cancel
  watcher that fires `Qx.Hardware.cancel/3` if the caller cell
  process dies during a run.

  ## Architecture

      caller cell process
        │
        ├── frame = Kino.Frame.new() |> tap(&Kino.render/1)
        │
        ├── watcher = spawn(...)                  ← unlinked
        │   └── monitors caller; if :DOWN, calls
        │       Qx.Hardware.cancel/3 with the last-seen job_id
        │
        ├── on_status callback:
        │     – appends a line to the frame
        │     – broadcasts {:job_id, _} to the watcher when the
        │       pipeline emits {:ibm, :job_started, _}
        │     – forwards events to caller-supplied :on_status if any
        │
        └── Qx.Hardware.run(circuit, config, on_status: on_status)
              ← blocks synchronously
              ← returns {:ok, %SimulationResult{}} | {:error, reason}

  ## Interrupt semantics

  Livebook's "Stop" button may deliver `:shutdown` (trappable) or
  `:kill` (untrappable). Either way the **caller dies**; the watcher
  is unlinked so it survives and runs the cancel. If Livebook tears
  down the entire session, the watcher dies too and the IBM job is
  orphaned — runs to completion, burns shots. This is the silent
  leak flagged in the plan's Risks section.
  """

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

    state_ref = make_ref()
    state_key = {:kino_qx_state, state_ref}

    initial = %{
      lines: [],
      started_at: System.monotonic_time(:millisecond),
      job_id: nil,
      frame: frame
    }

    Process.put(state_key, initial)
    render_frame(initial)

    # `:_hardware_mod` is an undocumented test seam — production callers
    # never set it. Tests pass a stub module exposing `run/3` and `cancel/3`.
    {hardware_mod, opts} = Keyword.pop(opts, :_hardware_mod, Hardware)

    watcher = start_cancel_watcher(self(), config, hardware_mod)

    on_status = build_on_status(state_key, watcher, caller_on_status)
    hw_opts = Keyword.put(opts, :on_status, on_status)

    try do
      result = hardware_mod.run(circuit, config, hw_opts)
      state = Process.get(state_key)
      render_terminal(state, result)
      send(watcher, :done)
      result
    after
      Process.delete(state_key)
    end
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
        # job already terminated.
        if job_id, do: hardware_mod.cancel(job_id, config)

      {:DOWN, ^ref, :process, _pid, _normal} ->
        :ok
    end
  end

  ## --------------------------------------------------------------
  ## Status callback — forwards to watcher + frame + caller
  ## --------------------------------------------------------------

  defp build_on_status(state_key, watcher, caller_on_status) do
    fn event ->
      case event do
        {:ibm, :job_started, job_id} when is_binary(job_id) ->
          send(watcher, {:job_id, job_id})

        _ ->
          :ok
      end

      state = Process.get(state_key)
      new_state = handle_status_event(state, event)
      Process.put(state_key, new_state)
      render_frame(new_state)

      _ =
        try do
          caller_on_status.(event)
        rescue
          _ -> :ok
        end

      :ok
    end
  end

  defp handle_status_event(state, event) do
    state =
      case event do
        {:ibm, :job_started, job_id} -> %{state | job_id: job_id}
        _ -> state
      end

    line = render_event_line(event, state)
    %{state | lines: state.lines ++ [line]}
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

  defp render_event_line({:ibm, :polling, %{} = poll}, state) do
    status = Map.get(poll, :status) || Map.get(poll, "status") || "polling"
    queue = Map.get(poll, :queue_position) || Map.get(poll, "queue_position")
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
    do: "· " <> inspect(other)

  defp render_frame(state) do
    markdown = Enum.join(state.lines, "  \n")
    Kino.Frame.render(state.frame, Kino.Markdown.new(markdown))
  end

  defp render_terminal(state, {:ok, _result}) do
    line = "✔ done in #{elapsed_seconds(state)}s"
    render_frame(%{state | lines: state.lines ++ [line]})
  end

  defp render_terminal(state, {:error, reason}) do
    line = "✖ error: " <> error_summary(reason)
    render_frame(%{state | lines: state.lines ++ [line]})
  end

  defp error_summary({:network, _}), do: "network failure"
  defp error_summary({:http, status, _body}), do: "HTTP #{status}"
  defp error_summary({:rate_limited, secs}) when is_integer(secs), do: "rate limited (#{secs}s)"

  defp error_summary({stage, reason}) when is_atom(stage),
    do: "#{stage}: #{error_summary(reason)}"

  defp error_summary(:unauthorized), do: "unauthorized"
  defp error_summary(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_summary(reason) when is_binary(reason), do: reason
  defp error_summary(other), do: inspect(other)

  defp elapsed_seconds(state) do
    div(System.monotonic_time(:millisecond) - state.started_at, 1000)
  end
end
