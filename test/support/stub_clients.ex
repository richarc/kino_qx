defmodule Kino.Qx.StubClients do
  @moduledoc """
  In-memory stub modules matching the `Kino.Qx.IbmClient` and
  `Kino.Qx.Client` surfaces used by `Kino.Qx.TranspilePipeline`.

  Each stub looks up its scripted return value in an ETS-like Agent
  keyed by call name. Tests configure responses up-front, run the
  pipeline, then assert on call order via the recorded log.

  This is the lightweight alternative to Mox (not in deps).
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

  defmodule Ibm do
    @moduledoc false
    alias Kino.Qx.StubClients.Recorder

    def iam_exchange(%{__recorder__: pid} = config),
      do: Recorder.call(pid, :iam_exchange, [config])

    def list_backends(%{__recorder__: pid} = config),
      do: Recorder.call(pid, :list_backends, [config])

    def fetch_backend_properties(%{__recorder__: pid} = config, name),
      do: Recorder.call(pid, :fetch_backend_properties, [config, name])

    def open_session(%{__recorder__: pid} = config, backend, max_ttl \\ 3600),
      do: Recorder.call(pid, :open_session, [config, backend, max_ttl])

    def submit_sampler(%{__recorder__: pid} = config, qasm, backend, session_id),
      do: Recorder.call(pid, :submit_sampler, [config, qasm, backend, session_id])

    def poll_job(%{__recorder__: pid} = config, job_id),
      do: Recorder.call(pid, :poll_job, [config, job_id])

    def fetch_results(%{__recorder__: pid} = config, job_id),
      do: Recorder.call(pid, :fetch_results, [config, job_id])

    def close_session(%{__recorder__: pid} = config, session_id),
      do: Recorder.call(pid, :close_session, [config, session_id])
  end

  defmodule Portal do
    @moduledoc false
    alias Kino.Qx.StubClients.Recorder

    def transpile(%{__recorder__: pid} = config, payload),
      do: Recorder.call(pid, :transpile, [config, payload])
  end
end
