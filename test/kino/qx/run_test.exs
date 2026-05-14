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

  defmodule StubHardware do
    @moduledoc false

    def install(opts), do: Process.put(:stub_hardware_opts, opts)

    def run(_circuit, _config, opts) do
      script = Process.get(:stub_hardware_opts, [])
      on_status = Keyword.get(opts, :on_status, fn _ -> :ok end)

      Enum.each(Keyword.get(script, :events, []), fn ev -> on_status.(ev) end)

      case Keyword.get(script, :return) do
        nil -> {:ok, fake_result()}
        other -> other
      end
    end

    def cancel(_job_id, _config) do
      parent = Keyword.get(Process.get(:stub_hardware_opts, []), :cancel_to)
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

  defp config do
    %Qx.Hardware.Config{
      portal_url: "https://test.qxquantum.com",
      portal_token: "qx_live_TEST",
      ibm_api_key: "TEST_KEY",
      ibm_crn: "TEST_CRN",
      ibm_region: "us-south",
      backend: "ibm_brisbane"
    }
  end

  defp fake_circuit, do: %{__fake__: :circuit}

  describe "run/3 — happy path" do
    test "returns {:ok, %SimulationResult{}} when stub returns ok" do
      StubHardware.install(events: [])

      assert {:ok, %Qx.SimulationResult{counts: counts}} =
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

      assert {:ok, %Qx.SimulationResult{}} =
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

      assert %Qx.SimulationResult{} = result
      assert result.counts == %{"00" => 2048, "11" => 2048}
    end

    test "raises Kino.Qx.RunError when stub returns {:error, _}" do
      StubHardware.install(events: [], return: {:error, :unauthorized})

      assert_raise Kino.Qx.RunError, ~r/unauthorized/, fn ->
        Kino.Qx.run!(fake_circuit(), config(), _hardware_mod: StubHardware)
      end
    end

    test "wraps a stage-tagged error reason with the stage name in the message" do
      StubHardware.install(events: [], return: {:error, {:portal_transpile, :invalid_qasm}})

      err =
        try do
          Kino.Qx.run!(fake_circuit(), config(), _hardware_mod: StubHardware)
        rescue
          e in Kino.Qx.RunError -> e
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
    test "Kino.Qx.RunError carries the reason and renders a message" do
      err = %Kino.Qx.RunError{reason: :unauthorized}
      assert Exception.message(err) =~ "unauthorized"
    end

    test "Kino.Qx.Interrupted renders a job-aware message when job_id known" do
      err = %Kino.Qx.Interrupted{job_id: "job_xyz"}
      assert Exception.message(err) =~ "job_xyz"
      assert Exception.message(err) =~ "cancel issued"
    end

    test "Kino.Qx.Interrupted renders a no-job message when job_id is nil" do
      err = %Kino.Qx.Interrupted{job_id: nil}
      assert Exception.message(err) =~ "before a job was submitted"
    end
  end
end
