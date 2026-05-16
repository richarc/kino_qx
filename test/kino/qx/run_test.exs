defmodule Kino.Qx.RunTest do
  @moduledoc """
  Tests for `Kino.Qx.run/2,3` and `Kino.Qx.run!/2,3`.

  Uses an injected `:_hardware_mod` test seam so we don't need real
  IBM credentials. The stub module emits the same `on_status` events
  `Qx.Hardware.run/3` would emit, then returns a scripted result.

  End-to-end behaviour against real hardware is tested in
  `test/kino/qx/integration/ibm_live_test.exs` (tagged `:ibm_live`).
  """
  use ExUnit.Case, async: false

  alias Kino.Qx.Interrupted
  alias Kino.Qx.RunError
  alias Kino.Qx.SafeReason
  alias Kino.Qx.StubHardware
  alias Qx.Hardware.Config
  alias Qx.SimulationResult

  defp config do
    %Config{
      portal_url: "https://test.qxquantum.com",
      portal_token: "qx_live_TEST",
      ibm_api_key: "TEST_KEY",
      ibm_crn: "TEST_CRN",
      ibm_region: "us-south",
      backend: "ibm_brisbane"
    }
  end

  defp fake_circuit, do: %{__fake__: :circuit}

  @portal_token_sentinel "qx_live_PORTAL_SECRET_DO_NOT_LEAK"
  @ibm_key_sentinel "IBM_API_KEY_SECRET_DO_NOT_LEAK"

  defp secret_config do
    %Config{
      portal_url: "https://test.qxquantum.com",
      portal_token: @portal_token_sentinel,
      ibm_api_key: @ibm_key_sentinel,
      ibm_crn: "crn:SECRET",
      ibm_region: "us-south",
      backend: "ibm_brisbane",
      access_token: "IAM_ACCESS_TOKEN_SECRET_DO_NOT_LEAK"
    }
  end

  defp refute_leaks(string) do
    refute string =~ @portal_token_sentinel
    refute string =~ @ibm_key_sentinel
    refute string =~ "IAM_ACCESS_TOKEN_SECRET_DO_NOT_LEAK"
    refute string =~ "crn:SECRET"
    string
  end

  describe "run/3 — happy path" do
    test "returns {:ok, %SimulationResult{}} when stub returns ok" do
      StubHardware.install(events: [])

      assert {:ok, %SimulationResult{counts: counts}} =
               Kino.Qx.run(fake_circuit(), config(), _hardware_mod: StubHardware)

      assert counts == %{"00" => 2048, "11" => 2048}
    end

    test "invokes caller-supplied :on_status with every event" do
      events = [
        {:ibm, :authenticating},
        {:portal, :transpiling},
        {:ibm, :submitting},
        {:ibm, :job_started, "job_abc"},
        {:ibm, :polling, %{status: "RUNNING", queue_position: 14}},
        {:ibm, :fetching_results}
      ]

      StubHardware.install(events: events)
      parent = self()
      caller_status = fn ev -> send(parent, {:caller_saw, ev}) end

      assert {:ok, %SimulationResult{}} =
               Kino.Qx.run(fake_circuit(), config(),
                 _hardware_mod: StubHardware,
                 on_status: caller_status
               )

      for ev <- events do
        assert_received {:caller_saw, ^ev}
      end
    end
  end

  describe "run!/3 — pipe-friendly variant" do
    test "returns bare %SimulationResult{} when stub returns ok" do
      StubHardware.install(events: [])

      result = Kino.Qx.run!(fake_circuit(), config(), _hardware_mod: StubHardware)

      assert %SimulationResult{} = result
      assert result.counts == %{"00" => 2048, "11" => 2048}
    end

    test "raises RunError when stub returns {:error, _}" do
      StubHardware.install(events: [], return: {:error, :unauthorized})

      assert_raise RunError, ~r/unauthorized/, fn ->
        Kino.Qx.run!(fake_circuit(), config(), _hardware_mod: StubHardware)
      end
    end

    test "wraps a stage-tagged error reason with the stage name in the message" do
      StubHardware.install(events: [], return: {:error, {:portal_transpile, :invalid_qasm}})

      err =
        try do
          Kino.Qx.run!(fake_circuit(), config(), _hardware_mod: StubHardware)
        rescue
          e in RunError -> e
        end

      assert err.reason == {:portal_transpile, :invalid_qasm}
      assert Exception.message(err) =~ "portal_transpile"
      assert Exception.message(err) =~ "invalid_qasm"
    end
  end

  describe "run/3 — error returns tuple, not raise" do
    test "tuple variant returns {:error, reason} without raising" do
      StubHardware.install(events: [], return: {:error, {:network, :timeout}})

      assert {:error, {:network, :timeout}} =
               Kino.Qx.run(fake_circuit(), config(), _hardware_mod: StubHardware)
    end
  end

  describe "exception classes" do
    test "RunError carries the reason and renders a message" do
      err = %RunError{reason: :unauthorized}
      assert Exception.message(err) =~ "unauthorized"
    end

    test "Interrupted renders a job-aware message when job_id known" do
      err = %Interrupted{job_id: "job_xyz"}
      assert Exception.message(err) =~ "job_xyz"
      assert Exception.message(err) =~ "cancel issued"
    end

    test "Interrupted renders a no-job message when job_id is nil" do
      err = %Interrupted{job_id: nil}
      assert Exception.message(err) =~ "before a job was submitted"
    end
  end

  describe "public Kino.Qx entrypoint smoke (S6)" do
    # The user-facing pipeline shape is `circuit |> Kino.Qx.run!(qx)` —
    # the 2-arg form (default opts, default no-op on_status). True
    # 2-arity can't carry the `:_hardware_mod` seam, so we drive the
    # public `Kino.Qx` delegators (qx.ex, not Kino.Qx.Run) with ONLY the
    # seam: no `:on_status`, exercising the default-callback code path
    # that the on_status-supplying tests above never hit.

    test "Kino.Qx.run/3 (public) returns {:ok, result} with default opts + events" do
      StubHardware.install(
        events: [
          {:portal, :transpiling},
          {:ibm, :submitting},
          {:ibm, :job_started, "job_pub"},
          {:ibm, :polling, "Running"},
          {:ibm, :fetching_results}
        ]
      )

      assert {:ok, %SimulationResult{counts: %{"00" => 2048, "11" => 2048}}} =
               Kino.Qx.run(fake_circuit(), config(), _hardware_mod: StubHardware)
    end

    test "Kino.Qx.run!/3 (public) returns the bare %SimulationResult{} for piping" do
      StubHardware.install(events: [])

      result = Kino.Qx.run!(fake_circuit(), config(), _hardware_mod: StubHardware)

      assert %SimulationResult{} = result
      assert result.counts == %{"00" => 2048, "11" => 2048}
    end

    test "Kino.Qx.run!/3 (public) raises RunError on {:error, _}" do
      StubHardware.install(events: [], return: {:error, :unauthorized})

      assert_raise RunError, ~r/unauthorized/, fn ->
        Kino.Qx.run!(fake_circuit(), config(), _hardware_mod: StubHardware)
      end
    end
  end

  describe "interrupt path — Interrupted is actually raised (W1/W2)" do
    test "trappable :shutdown cancels the in-flight job and raises Interrupted with job_id" do
      test_pid = self()

      StubHardware.install(
        events: [{:ibm, :job_started, "job_INT"}],
        block: true,
        cancel_to: test_pid
      )

      runner =
        spawn(fn ->
          try do
            Kino.Qx.run(fake_circuit(), config(),
              _hardware_mod: StubHardware,
              on_status: fn
                {:ibm, :job_started, _} = ev -> send(test_pid, {:saw, ev})
                _ -> :ok
              end
            )
          rescue
            e -> send(test_pid, {:raised, e})
          end
        end)

      # Wait until the job is in-flight (run_loop has threaded the job_id
      # and the worker is blocked) before interrupting.
      assert_receive {:saw, {:ibm, :job_started, "job_INT"}}, 1_000

      Process.exit(runner, :shutdown)

      assert_receive :stub_cancel_called, 1_000
      assert_receive {:raised, %Interrupted{job_id: "job_INT"}}, 1_000

      # Exactly ONE cancel — the caller cancelled and stood the watcher
      # down; the watcher must NOT also fire on the caller's :DOWN.
      refute_receive :stub_cancel_called, 200
    end

    test "interrupt before any job_started raises Interrupted{job_id: nil} and does not cancel" do
      test_pid = self()

      StubHardware.install(events: [], block: true, cancel_to: test_pid)

      runner =
        spawn(fn ->
          try do
            Kino.Qx.run(fake_circuit(), config(),
              _hardware_mod: StubHardware,
              on_status: fn _ -> send(test_pid, :saw_status) end
            )
          rescue
            e -> send(test_pid, {:raised, e})
          end
        end)

      # No job_started, so synchronise on liveness another way: give the
      # worker time to reach its blocking receive, then interrupt.
      Process.sleep(50)
      Process.exit(runner, :shutdown)

      assert_receive {:raised, %Interrupted{job_id: nil}}, 1_000
      # job_id was nil, so no cancel should be issued.
      refute_receive :stub_cancel_called, 200
    end

    test "normal completion does NOT cancel" do
      StubHardware.install(events: [], cancel_to: self())

      assert {:ok, %SimulationResult{}} =
               Kino.Qx.run(fake_circuit(), config(), _hardware_mod: StubHardware)

      refute_receive :stub_cancel_called, 200
    end

    test "run!/3 lets Interrupted propagate (not wrapped in RunError)" do
      test_pid = self()

      StubHardware.install(
        events: [{:ibm, :job_started, "job_BANG"}],
        block: true,
        cancel_to: test_pid
      )

      runner =
        spawn(fn ->
          try do
            Kino.Qx.run!(fake_circuit(), config(),
              _hardware_mod: StubHardware,
              on_status: fn
                {:ibm, :job_started, _} = ev -> send(test_pid, {:saw, ev})
                _ -> :ok
              end
            )
          rescue
            e -> send(test_pid, {:raised, e})
          end
        end)

      assert_receive {:saw, {:ibm, :job_started, "job_BANG"}}, 1_000
      Process.exit(runner, :shutdown)

      assert_receive {:raised, raised}, 1_000
      assert %Interrupted{job_id: "job_BANG"} = raised
      refute match?(%RunError{}, raised)
    end
  end

  describe "B1 — token-leak regression (Config never inspected)" do
    # The frame's terminal/error line is `"✖ error: " <> SafeReason.describe(reason)`
    # and `RunError.message/1` is `"Qx hardware run failed: " <> SafeReason.describe(reason)`.
    # Exercising `SafeReason.describe/1` + `RunError` over every Config-bearing
    # shape covers both the exception message and the rendered frame line.

    test "RunError message redacts a bare %Config{} reason" do
      msg = Exception.message(%RunError{reason: secret_config()})
      refute_leaks(msg)
      assert msg == "Qx hardware run failed: config (redacted)"
    end

    test "RunError message redacts a {stage, %Config{}} reason" do
      msg =
        Exception.message(%RunError{reason: {:portal_transpile, secret_config()}})

      refute_leaks(msg)
      assert msg =~ "portal_transpile"
      assert msg =~ "config (redacted)"
    end

    test "SafeReason.describe redacts Config at bare / {stage,_} / {:error,_} / nested depths" do
      cfg = secret_config()

      for reason <- [
            cfg,
            {:error, cfg},
            {:portal_transpile, cfg},
            {:ibm_submit, {:error, cfg}},
            {:error, {:stage, cfg}}
          ] do
        reason
        |> SafeReason.describe()
        |> refute_leaks()
        |> then(&assert(&1 =~ "redacted"))
      end
    end

    test "SafeReason.describe never inspects an unknown reason that embeds a Config" do
      # A shape we don't explicitly model must collapse to a fixed string,
      # not `inspect/1` (which would dump the embedded tokens).
      weird = {:totally, :unexpected, secret_config()}

      result = SafeReason.describe(weird)
      refute_leaks(result)
      assert result == "unexpected error"
    end

    test "SafeReason.describe keeps the friendly mappings intact" do
      assert SafeReason.describe(:unauthorized) == "unauthorized"
      assert SafeReason.describe({:rate_limited, 30}) == "rate limited (30s)"
      assert SafeReason.describe({:network, :timeout}) == "network failure"
      assert SafeReason.describe({:http, 503, "body"}) == "HTTP 503"
      assert SafeReason.describe({:portal, :invalid_qasm}) == "portal: invalid_qasm"
    end

    test "frame terminal line for an {:error, %Config{}} return does not leak tokens" do
      StubHardware.install(events: [], return: {:error, {:portal_transpile, secret_config()}})

      assert {:error, {:portal_transpile, %Config{}}} =
               Kino.Qx.run(fake_circuit(), secret_config(), _hardware_mod: StubHardware)

      # Re-assert the exact content the frame interpolates for this reason.
      refute_leaks("✖ error: " <> SafeReason.describe({:portal_transpile, secret_config()}))
    end
  end
end
