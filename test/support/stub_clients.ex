defmodule Kino.Qx.StubClients do
  @moduledoc """
  In-memory stub module matching the `Kino.Qx.Client` portal surface,
  used by future tests in `test/kino/qx/run_test.exs` (Phase 4).

  Each stub looks up its scripted return value in an ETS-like Agent
  keyed by call name. Tests configure responses up-front, run the
  code under test, then assert on call order via the recorded log.

  This is the lightweight alternative to Mox (not in deps).

  IBM-side stubs were removed when `Kino.Qx.IbmClient` moved upstream
  into `Qx.Hardware.Ibm` (qx 0.7); IBM stubbing now lives in qx's
  test support.
  """

  defmodule Recorder do
    @moduledoc false
    use Agent

    def start_link(initial \\ %{}) do
      Agent.start_link(fn -> %{responses: initial, calls: []} end)
    end

    def set(pid, key, response_or_list) do
      Agent.update(pid, fn state ->
        put_in(state.responses[key], List.wrap(response_or_list))
      end)
    end

    def call(pid, key, args) do
      Agent.get_and_update(pid, fn state ->
        state = update_in(state.calls, &(&1 ++ [{key, args}]))

        case state.responses[key] do
          [response] ->
            {response, state}

          [response | rest] ->
            state = put_in(state.responses[key], rest)
            {response, state}

          nil ->
            raise "StubClients.Recorder: no response scripted for #{inspect(key)}"

          [] ->
            raise "StubClients.Recorder: responses exhausted for #{inspect(key)}"
        end
      end)
    end

    def calls(pid), do: Agent.get(pid, & &1.calls)
  end

  defmodule Portal do
    @moduledoc false
    alias Kino.Qx.StubClients.Recorder

    def transpile(%{__recorder__: pid} = config, payload),
      do: Recorder.call(pid, :transpile, [config, payload])
  end
end
