defmodule Kino.Qx.TranspilePipelineTest do
  @moduledoc """
  Verifies the orchestrator's stage sequencing, error routing, and
  poll-loop behaviour with stub IBM + Portal clients.

  Stubs mirror the real client surface; configs carry a
  `__recorder__` agent pid so calls are recorded and scripted
  responses are popped in order.
  """
  use ExUnit.Case, async: true

  alias Kino.Qx.StubClients
  alias Kino.Qx.StubClients.Recorder
  alias Kino.Qx.TranspilePipeline

  setup do
    {:ok, recorder} = Recorder.start_link()

    portal_config = %{__recorder__: recorder, token: "qx_live_x", base_url: "http://x"}

    ibm_config = %{
      __recorder__: recorder,
      api_key: "ibm_key",
      crn: "crn:..",
      region: :us_south
    }

    %{recorder: recorder, portal_config: portal_config, ibm_config: ibm_config}
  end

  defp base_input(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        ibm_config: ctx.ibm_config,
        portal_config: ctx.portal_config,
        qasm: "OPENQASM 3.0; qubit[2] q; measure q;",
        backend: "ibm_brisbane",
        optimization_level: 1,
        ibm_client: StubClients.Ibm,
        portal_client: StubClients.Portal,
        sleep: fn _ -> :ok end
      },
      overrides
    )
  end

  defp script_happy_path(recorder, opts \\ []) do
    poll_sequence =
      Keyword.get(opts, :polls, [
        {:ok, %{status: "QUEUED", reason: nil, queue_position: 3}},
        {:ok, %{status: "RUNNING", reason: nil, queue_position: 0}},
        {:ok, %{status: "DONE", reason: nil, queue_position: 0}}
      ])

    Recorder.set(recorder, :iam_exchange, {:ok, %{__recorder__: recorder, access_token: "t"}})

    Recorder.set(
      recorder,
      :fetch_backend_properties,
      {:ok, %{coupling_map: [[0, 1]], basis_gates: ["cx"], num_qubits: 2}}
    )

    Recorder.set(
      recorder,
      :transpile,
      {:ok, %{qasm: "TRANSPILED;", metadata: %{depth: 1, size: 1, num_qubits: 2}}}
    )

    Recorder.set(recorder, :open_session, {:ok, "session_1"})
    Recorder.set(recorder, :submit_sampler, {:ok, "job_1"})
    Recorder.set(recorder, :poll_job, poll_sequence)

    Recorder.set(
      recorder,
      :fetch_results,
      {:ok, %{counts: %{"00" => 500, "11" => 524}, metadata: %{execution_time_ms: 42}}}
    )

    Recorder.set(recorder, :close_session, :ok)
  end

  describe "run/1 happy path" do
    test "sequences all stages and returns merged result", ctx do
      script_happy_path(ctx.recorder)

      test_pid = self()
      input = base_input(ctx, %{on_status: &send(test_pid, {:status, &1})})

      assert {:ok, result} = TranspilePipeline.run(input)
      assert result.counts == %{"00" => 500, "11" => 524}
      assert result.transpiled_qasm == "TRANSPILED;"
      assert result.job_id == "job_1"
      # Metadata merged from portal + ibm
      assert result.metadata.depth == 1

      assert result.metadata[:execution_time_ms] == 42 or
               result.metadata["execution_time_ms"] == 42

      events = drain_statuses()
      assert {:ibm, :authenticating} in events
      assert {:ibm, :fetching_backend} in events
      assert {:portal, :transpiling} in events
      assert {:ibm, :opening_session} in events
      assert {:ibm, :submitting} in events
      assert {:ibm, :polling, "QUEUED", 3} in events
      assert {:ibm, :polling, "DONE", 0} in events
      assert {:ibm, :fetching_results} in events

      # Verify call ORDER (key sequence, not args)
      call_keys = ctx.recorder |> Recorder.calls() |> Enum.map(&elem(&1, 0))

      assert call_keys == [
               :iam_exchange,
               :fetch_backend_properties,
               :transpile,
               :open_session,
               :submit_sampler,
               :poll_job,
               :poll_job,
               :poll_job,
               :fetch_results,
               :close_session
             ]
    end

    test "transpile payload uses backend properties + optimization_level", ctx do
      script_happy_path(ctx.recorder)

      assert {:ok, _} = TranspilePipeline.run(base_input(ctx, %{optimization_level: 3}))

      [{:transpile, [_config, payload]} | _] =
        ctx.recorder
        |> Recorder.calls()
        |> Enum.filter(fn {k, _} -> k == :transpile end)

      assert payload.coupling_map == [[0, 1]]
      assert payload.basis_gates == ["cx"]
      assert payload.optimization_level == 3
      assert payload.qasm =~ "OPENQASM"
    end

    test "submit receives the transpiled qasm, not the original", ctx do
      script_happy_path(ctx.recorder)
      assert {:ok, _} = TranspilePipeline.run(base_input(ctx))

      [{:submit_sampler, [_, qasm, backend, session]}] =
        ctx.recorder |> Recorder.calls() |> Enum.filter(fn {k, _} -> k == :submit_sampler end)

      assert qasm == "TRANSPILED;"
      assert backend == "ibm_brisbane"
      assert session == "session_1"
    end
  end

  describe "error routing" do
    test "iam_exchange failure → {:error, :ibm_auth, reason}", ctx do
      Recorder.set(ctx.recorder, :iam_exchange, {:error, :unauthorized})

      assert {:error, :ibm_auth, :unauthorized} = TranspilePipeline.run(base_input(ctx))
    end

    test "fetch_backend_properties failure → {:error, :ibm_auth, _}", ctx do
      Recorder.set(ctx.recorder, :iam_exchange, {:ok, %{__recorder__: ctx.recorder}})
      Recorder.set(ctx.recorder, :fetch_backend_properties, {:error, :not_found})

      assert {:error, :ibm_auth, :not_found} = TranspilePipeline.run(base_input(ctx))
    end

    test "portal transpile failure → {:error, :portal_transpile, reason}", ctx do
      Recorder.set(ctx.recorder, :iam_exchange, {:ok, %{__recorder__: ctx.recorder}})

      Recorder.set(
        ctx.recorder,
        :fetch_backend_properties,
        {:ok, %{coupling_map: [], basis_gates: [], num_qubits: 0}}
      )

      Recorder.set(ctx.recorder, :transpile, {:error, :transpile_failed})

      assert {:error, :portal_transpile, :transpile_failed} =
               TranspilePipeline.run(base_input(ctx))
    end

    test "submit_sampler failure → {:error, :ibm_submit, reason}", ctx do
      script_happy_path(ctx.recorder)
      Recorder.set(ctx.recorder, :submit_sampler, {:error, {:http, 500, %{}}})

      assert {:error, :ibm_submit, {:http, 500, %{}}} = TranspilePipeline.run(base_input(ctx))
    end

    test "polling exceeds timeout → :ibm_polling_timeout", ctx do
      script_happy_path(ctx.recorder,
        polls: List.duplicate({:ok, %{status: "QUEUED", reason: nil, queue_position: 1}}, 100)
      )

      assert {:error, :ibm_polling_timeout, :deadline_exceeded} =
               TranspilePipeline.run(base_input(ctx, %{timeout_ms: 0}))
    end

    test "job ends with status ERROR → :ibm_job_failed", ctx do
      script_happy_path(
        ctx.recorder,
        polls: [
          {:ok, %{status: "QUEUED", reason: nil, queue_position: 0}},
          {:ok, %{status: "ERROR", reason: "circuit too large", queue_position: 0}}
        ]
      )

      assert {:error, :ibm_job_failed, %{status: "ERROR", reason: "circuit too large"}} =
               TranspilePipeline.run(base_input(ctx))
    end

    test "job ends with status CANCELLED → :ibm_job_failed", ctx do
      script_happy_path(
        ctx.recorder,
        polls: [{:ok, %{status: "CANCELLED", reason: "user", queue_position: 0}}]
      )

      assert {:error, :ibm_job_failed, %{status: "CANCELLED"}} =
               TranspilePipeline.run(base_input(ctx))
    end

    test "poll request itself fails → :ibm_polling", ctx do
      script_happy_path(ctx.recorder, polls: [{:error, {:network, :timeout}}])

      assert {:error, :ibm_polling, {:network, :timeout}} = TranspilePipeline.run(base_input(ctx))
    end

    test "fetch_results failure → :ibm_results (Estimator shape)", ctx do
      script_happy_path(ctx.recorder)
      Recorder.set(ctx.recorder, :fetch_results, {:error, :unsupported_result})

      assert {:error, :ibm_results, :unsupported_result} =
               TranspilePipeline.run(base_input(ctx))
    end

    test "open_session failure → :ibm_submit", ctx do
      script_happy_path(ctx.recorder)
      Recorder.set(ctx.recorder, :open_session, {:error, {:http, 500, %{}}})

      assert {:error, :ibm_submit, {:http, 500, %{}}} = TranspilePipeline.run(base_input(ctx))
    end
  end

  describe "on_status callback" do
    test "is optional", ctx do
      script_happy_path(ctx.recorder)
      assert {:ok, _} = TranspilePipeline.run(base_input(ctx))
    end

    test "polling emits status + queue_position on each iteration", ctx do
      script_happy_path(ctx.recorder)

      test_pid = self()
      input = base_input(ctx, %{on_status: &send(test_pid, {:status, &1})})

      assert {:ok, _} = TranspilePipeline.run(input)

      poll_events =
        drain_statuses()
        |> Enum.filter(&match?({:ibm, :polling, _, _}, &1))

      assert length(poll_events) == 3
      assert {:ibm, :polling, "QUEUED", 3} in poll_events
      assert {:ibm, :polling, "RUNNING", 0} in poll_events
      assert {:ibm, :polling, "DONE", 0} in poll_events
    end
  end

  ## ---- helpers ----------------------------------------------------

  defp drain_statuses(acc \\ []) do
    receive do
      {:status, event} -> drain_statuses([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
