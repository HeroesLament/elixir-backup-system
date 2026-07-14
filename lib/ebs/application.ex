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

      # Registry for tracking backup jobs and NBD port workers
      {Registry, keys: :unique, name: EBS.Registry},

      # Chunk storage
      {EBS.Storage.ChunkStore, []},

      # Legacy ETS store (will be replaced by Repo)
      {EBS.Metadata.Store, []},

      # Supervisor for backup jobs (created dynamically)
      {DynamicSupervisor, name: EBS.Backup.DynamicSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: EBS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
