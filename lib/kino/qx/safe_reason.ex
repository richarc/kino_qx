defmodule Kino.Qx.SafeReason do
  @moduledoc """
  The single error-reason → human-readable string mapper used by
  `Kino.Qx.Run` (frame + terminal lines) and `Kino.Qx.RunError`.

  ## Security contract

  `Qx.Hardware.run/3` error reasons can embed a
  `Qx.Hardware.Config` — directly or nested in a `{stage, _}` /
  `{:error, _}` tuple. That struct carries `:portal_token`,
  `:ibm_api_key`, `:ibm_crn`, and `:access_token`. Livebook persists
  smart-cell / frame output into the `.livemd` file, so a naive
  `inspect/1` on such a reason would leak those secrets to disk and
  to the Livebook log.

  This module therefore:

    * redacts a `Qx.Hardware.Config` to `"config (redacted)"` at any
      of the common nesting depths (bare, `{stage, %Config{}}`,
      `{:error, %Config{}}`, and recursively through `{stage, reason}`);
    * **never** calls `inspect/1` on an arbitrary reason — an
      unrecognised shape collapses to the fixed string
      `"unexpected error"` with no value interpolation.

  The upstream root-cause fix is `@derive Inspect` on
  `Qx.Hardware.Config` (tracked as a `qx` bug); this module is the
  local defence in depth.
  """

  alias Qx.Hardware.Config

  @spec describe(term()) :: String.t()
  def describe(:unauthorized), do: "unauthorized"

  def describe({:rate_limited, secs}) when is_integer(secs),
    do: "rate limited (#{secs}s)"

  def describe({:network, _}), do: "network failure"

  def describe({:http, status, _body}), do: "HTTP #{status}"

  # Redact a Config wherever it shows up in the common error shapes.
  # These clauses MUST precede the generic `{stage, reason}` recursion.
  def describe(%Config{}), do: "config (redacted)"

  def describe({:error, %Config{}}), do: "config (redacted)"

  def describe({stage, %Config{}}) when is_atom(stage),
    do: "#{stage}: config (redacted)"

  def describe({stage, reason}) when is_atom(stage),
    do: "#{stage}: #{describe(reason)}"

  def describe(reason) when is_atom(reason), do: Atom.to_string(reason)

  def describe(reason) when is_binary(reason), do: reason

  # Anything we don't explicitly understand may embed a Config (and
  # therefore tokens) at an unanticipated depth — never inspect it.
  def describe(_other), do: "unexpected error"
end
