defmodule Kino.Qx.StubHardware do
  @moduledoc """
  In-memory stub matching the `Qx.Hardware` surface used by
  `Kino.Qx.Run` (`run/3` + `cancel/3`), injected via the
  `:_hardware_mod` test seam in `test/kino/qx/run_test.exs`.

  Placement mirrors `Kino.Qx.StubClients` (test/support, compiled only
  in `:test` via `elixirc_paths/1`).

  The script is held in `:persistent_term`, **not** the process
  dictionary, because `Kino.Qx.Run.run/3` executes the hardware call
  inside a worker `Task` — a different process from the test that
  calls `install/1`. `run_test.exs` is `async: false`, so the single
  global key is safe.

  Script keys (`install/1`):

    * `:events`    — list of `on_status` events to replay before returning
    * `:return`    — scripted return value (default: `{:ok, fake result}`)
    * `:block`     — when `true`, `run/3` blocks forever after replaying
      events (simulates an in-flight job; the interrupt path's
      `Task.shutdown(.., :brutal_kill)` is what stops it)
    * `:cancel_to` — pid that `cancel/3` notifies with `:stub_cancel_called`
  """

  @key {__MODULE__, :opts}

  @doc "Installs the script (process-independent)."
  def install(opts), do: :persistent_term.put(@key, opts)

  defp script, do: :persistent_term.get(@key, [])

  def run(_circuit, _config, opts) do
    s = script()
    on_status = Keyword.get(opts, :on_status, fn _ -> :ok end)

    Enum.each(Keyword.get(s, :events, []), fn ev -> on_status.(ev) end)

    if Keyword.get(s, :block, false) do
      receive do
        :__stub_never__ -> :ok
      end
    end

    case Keyword.get(s, :return) do
      nil -> {:ok, fake_result()}
      other -> other
    end
  end

  def cancel(_job_id, _config) do
    parent = Keyword.get(script(), :cancel_to)
    if parent, do: send(parent, :stub_cancel_called)
    :ok
  end

  defp fake_result do
    %Qx.SimulationResult{
      probabilities: %{"00" => 0.5, "11" => 0.5},
      classical_bits: 2,
      state: nil,
      shots: 4096,
      counts: %{"00" => 2048, "11" => 2048}
    }
  end
end
