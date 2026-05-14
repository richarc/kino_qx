defmodule Kino.Qx.RunError do
  @moduledoc """
  Raised by `Kino.Qx.run!/2,3` when the underlying `Qx.Hardware.run/3`
  returns an `{:error, reason}` tuple.

  The original error reason is available as `:reason`.
  """
  defexception [:reason]

  @impl true
  def message(%{reason: reason}) do
    "Qx hardware run failed: " <> describe(reason)
  end

  defp describe(:unauthorized), do: "unauthorized"
  defp describe({:rate_limited, secs}) when is_integer(secs), do: "rate limited (#{secs}s)"
  defp describe({:network, _}), do: "network failure"
  defp describe({:http, status, _body}), do: "HTTP #{status}"
  defp describe({stage, reason}) when is_atom(stage), do: "[#{stage}] #{describe(reason)}"
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(other), do: inspect(other)
end

defmodule Kino.Qx.Interrupted do
  @moduledoc """
  Raised when `Kino.Qx.run!/2,3` detects that the caller cell process
  was interrupted (Livebook "Stop" button) during a hardware run.

  When raised, the cancel watcher has already issued a best-effort
  `Qx.Hardware.cancel/3` for any in-flight job — though delivery is
  not guaranteed because the parent process may have been killed
  abruptly via `:kill` (untrappable).
  """
  defexception [:job_id]

  @impl true
  def message(%{job_id: nil}),
    do: "Qx hardware run interrupted before a job was submitted."

  def message(%{job_id: job_id}) when is_binary(job_id),
    do: "Qx hardware run interrupted; best-effort cancel issued for job #{job_id}."
end
