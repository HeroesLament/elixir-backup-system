defmodule EBS.Application do
  @moduledoc "EBS OTP Application"
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {EBS.Storage.BlockPool, []},
      {EBS.Storage.ConsistencyChecker, []},
      {EBS.Proxmox.CBTMonitor, []},
      {EBS.Backup.Scheduler, []},
      {EBS.Backup.Coordinator, []},
      {EBS.Policy.Engine, []},
      {EBS.Restore.Reconstructor, []},
      {EBS.Events, []}
    ]

    opts = [strategy: :one_for_one, name: EBS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
