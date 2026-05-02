defmodule Kino.Qx.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Kino.SmartCell.register(Kino.Qx.SmartCell)
    Supervisor.start_link([], strategy: :one_for_one, name: Kino.Qx.Supervisor)
  end
end
