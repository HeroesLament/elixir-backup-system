defmodule EBS.Backup.JobSupervisor do
  @moduledoc """
  Supervises a single backup job.

  Children:
    - EBS.NBD.PortWorker (reads blocks from disk)
    - Metadata tracking (snapshots, chunks)

  Lifecycle:
    1. start_backup(node, vmid, opts) → spawn supervisor + children
    2. Backup loop calls EBS.NBD.PortWorker.read_block(job_id, offset, size)
    3. Metadata service records chunks
    4. Finalize snapshot
    5. Supervisor stops (cleanup)

  Error handling:
    - If port worker dies → Supervisor restarts (rest_for_one strategy)
    - Max retries: 3, exponential backoff
  """

  use Supervisor
  require Logger

  def start_link(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple(job_id))
  end

  def init(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    node = Keyword.fetch!(opts, :node)
    vmid = Keyword.fetch!(opts, :vmid)
    disk = Keyword.get(opts, :disk, "0")

    Logger.info("Backup: starting job supervisor for #{node}:#{vmid}")

    children = [
      {EBS.NBD.PortWorker,
       [job_id: job_id, node: node, vmid: vmid, disk: disk]}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 300)
  end

  @doc """
  Start a new backup job.

  Returns: {:ok, supervisor_pid, job_id}
  """
  def start_backup(node, vmid, opts \\ []) do
    job_id = "backup-#{node}-#{vmid}-#{System.monotonic_time()}"

    supervisor_opts = [
      job_id: job_id,
      node: node,
      vmid: vmid,
      disk: Keyword.get(opts, :disk, "0")
    ]

    case start_link(supervisor_opts) do
      {:ok, pid} ->
        Logger.info("Backup: spawned job supervisor #{job_id}")
        {:ok, pid, job_id}

      {:error, reason} ->
        Logger.error("Backup: failed to start job supervisor: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp via_tuple(job_id) do
    {:via, Registry, {EBS.Registry, "job-#{job_id}"}}
  end
end
