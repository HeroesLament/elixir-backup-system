defmodule EBS.Application do
  @moduledoc """
  EBS MVP Application.

  Starts only essential services:
  - Metadata store (ETS-based backup history)

  Everything else is driven from IEx.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("EBS: starting MVP application")

    children = [
      # Database (metadata durability)
      EBS.Repo,

      # Legacy ETS store (will be replaced by Repo)
      {EBS.Metadata.Store, []}
    ]

    opts = [strategy: :one_for_one, name: EBS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
