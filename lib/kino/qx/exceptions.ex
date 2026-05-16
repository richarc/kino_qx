defmodule Kino.Qx.RunError do
  @moduledoc """
  Raised by `Kino.Qx.run!/2,3` when the underlying `Qx.Hardware.run/3`
  returns an `{:error, reason}` tuple.

  The original error reason is available as `:reason`.
  """
  alias Kino.Qx.SafeReason

  defexception [:reason]

  @impl true
  def message(%{reason: reason}) do
    "Qx hardware run failed: " <> SafeReason.describe(reason)
  end
end

defmodule Kino.Qx.Interrupted do
  @moduledoc """
  Raised by `Kino.Qx.run/2,3` and `Kino.Qx.run!/2,3` when the caller
  cell process is interrupted via Livebook's **trappable** "Stop"
  (`:shutdown`) while a hardware run is in flight.

  Before raising, the caller issues a best-effort
  `Qx.Hardware.cancel/3` for any in-flight job (the `:job_id` field
  carries the last-seen job id, or `nil` if no job had started yet).

  This exception is **not** raised on the untrappable `:kill` path:
  there the caller dies immediately and the unlinked cancel watcher
  is the only line of defence — cancel is attempted but no exception
  surfaces because the process is already gone. See
  `Kino.Qx.Run`'s "Interrupt semantics" for the full contract.
  """
  defexception [:job_id]

  @impl true
  def message(%{job_id: nil}),
    do: "Qx hardware run interrupted before a job was submitted."

  def message(%{job_id: job_id}) when is_binary(job_id),
    do: "Qx hardware run interrupted; best-effort cancel issued for job #{job_id}."
end
