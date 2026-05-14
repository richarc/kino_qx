defmodule Kino.Qx do
  @moduledoc """
  Livebook Smart Cells + pipeline functions for running quantum
  circuits on real IBM hardware via the [Qx Portal](https://qxportal.dev).

  ## Smart Cells

    * `Kino.Qx.CredentialsCell` — emits `qx = %Qx.Hardware.Config{...}`
      after collecting portal URL / region / backend / optimization
      level / shots. Tokens come from Livebook secrets.
    * `Kino.Qx.SmartCell` — snippet browser for the Qx Portal.

  ## Pipeline

      circuit
      |> Kino.Qx.run!(qx)
      |> Qx.Draw.plot_counts(title: "Bell state")

  See `run/3` and `run!/3`. Non-Livebook callers can use
  `Qx.Hardware.run/3` directly from the `:qx` library — `Kino.Qx.run/3`
  adds the live `Kino.Frame` status panel and best-effort cancel
  watcher around the same call.
  """

  alias Qx.Hardware

  @doc """
  Runs a quantum circuit on real hardware, blocking until the job
  reaches a terminal status. Returns `{:ok, %Qx.SimulationResult{}}`
  on success or `{:error, reason}` on failure.

  Renders a live status panel above the result while the job is in
  flight, and registers a best-effort cancel watcher that fires
  `Qx.Hardware.cancel/3` if the caller cell process dies during the
  run (Livebook "Stop" button).

  See `Qx.Hardware.run/3` for the underlying behaviour and `:opts`
  passthrough.
  """
  @spec run(Qx.QuantumCircuit.t(), Hardware.Config.t(), keyword()) ::
          {:ok, Qx.SimulationResult.t()} | {:error, term()}
  def run(circuit, config, opts \\ []),
    do: Kino.Qx.Run.run(circuit, config, opts)

  @doc """
  Like `run/3` but raises `Kino.Qx.RunError` on failure and returns
  the bare `%Qx.SimulationResult{}` so the result pipes cleanly into
  `Qx.Draw.plot_counts/2`.

      circuit
      |> Kino.Qx.run!(qx)
      |> Qx.Draw.plot_counts(title: "Bell state")
  """
  @spec run!(Qx.QuantumCircuit.t(), Hardware.Config.t(), keyword()) ::
          Qx.SimulationResult.t()
  def run!(circuit, config, opts \\ []),
    do: Kino.Qx.Run.run!(circuit, config, opts)

  @doc """
  Returns the version of `:kino_qx` reported in `mix.exs`.

  Useful when filing issues or in CI logs.

      iex> is_binary(Kino.Qx.version())
      true

  """
  @spec version() :: String.t()
  def version do
    Application.spec(:kino_qx, :vsn) |> to_string()
  end
end
