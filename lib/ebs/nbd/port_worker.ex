defmodule EBS.NBD.PortWorker do
  @moduledoc """
  Manages the NBD daemon port for a single backup job.

  Spawns ebs-nbd-daemon as a subprocess, communicates via Unix socket with
  length-prefixed JSON/ETF encoding.

  Lifecycle:
    1. start_link(job_id, node, vmid, disk) → spawn daemon
    2. read_block(job_id, offset, size) → RPC to daemon
    3. stats(job_id) → fetch job metrics
    4. terminate → kill daemon, cleanup socket

  Crash handling:
    If daemon dies, Supervisor restarts the worker.
    Job can resume from last known chunk.
  """

  use GenServer
  require Logger

  @daemon_bin "/usr/local/bin/ebs-nbd-daemon"
  @socket_dir "/tmp"
  @rpc_timeout 60_000

  def start_link(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(job_id))
  end

  def init(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    node = Keyword.fetch!(opts, :node)
    vmid = Keyword.fetch!(opts, :vmid)
    disk = Keyword.get(opts, :disk, "0")

    socket_path = socket_path_for(job_id)

    # Spawn daemon with args
    cmd = "#{@daemon_bin} --socket #{socket_path} --node #{node} --vmid #{vmid} --disk #{disk}"

    Logger.info("NBD: spawning daemon for job #{job_id}")
    Logger.debug("NBD: command: #{cmd}")

    try do
      port = Port.open({:spawn, cmd}, [:binary, {:packet, 4}])

      {:ok,
       %{
         job_id: job_id,
         port: port,
         socket_path: socket_path,
         node: node,
         vmid: vmid,
         disk: disk,
         chunk_count: 0,
         bytes_read: 0,
         started_at: System.monotonic_time(),
         pending_requests: %{}
       }}
    rescue
      e ->
        Logger.error("NBD: failed to spawn daemon: #{inspect(e)}")
        {:stop, {:failed_to_spawn, e}}
    end
  end

  @doc """
  Read a block from the VM disk via the NBD daemon.

  Returns: {:ok, %{sha256, offset, size, data}} | {:error, reason}
  """
  def read_block(job_id, offset, size) do
    GenServer.call(via_tuple(job_id), {:read_block, offset, size}, @rpc_timeout)
  catch
    :exit, _ -> {:error, "port_worker_not_running"}
  end

  @doc """
  Get current job statistics.
  """
  def stats(job_id) do
    try do
      GenServer.call(via_tuple(job_id), :stats, 5_000)
    catch
      :exit, _ -> {:error, "port_worker_not_running"}
    end
  end

  # GenServer callbacks

  def handle_call({:read_block, offset, size}, from, state) do
    request = %{
      "method" => "read_blocks",
      "args" => [state.node, state.vmid, state.disk, offset, size]
    }

    case send_rpc_request(state.port, request) do
      :ok ->
        request_id = make_ref()

        new_pending = Map.put(state.pending_requests, request_id, from)

        {:noreply,
         %{state | pending_requests: new_pending},
         {:continue, {:timeout_check, request_id}}}

      {:error, reason} ->
        {:reply, {:error, "Failed to send RPC: #{reason}"}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    uptime = System.monotonic_time() - state.started_at

    stats = %{
      job_id: state.job_id,
      chunks_read: state.chunk_count,
      bytes_read: state.bytes_read,
      uptime: uptime,
      socket_path: state.socket_path,
      pending_requests: map_size(state.pending_requests)
    }

    {:reply, stats, state}
  end

  def handle_info({port, {:data, response_bytes}}, %{port: port} = state) do
    case parse_response(response_bytes) do
      {:ok, request_id, chunk} ->
        case Map.pop(state.pending_requests, request_id) do
          {from, pending_requests} when from != nil ->
            GenServer.reply(from, {:ok, chunk})

            new_state = %{
              state
              | chunk_count: state.chunk_count + 1,
                bytes_read: state.bytes_read + chunk.size,
                pending_requests: pending_requests
            }

            {:noreply, new_state}

          {nil, _} ->
            Logger.warn("NBD: received response for unknown request")
            {:noreply, state}
        end

      {:error, _reason} ->
        Logger.error("NBD: failed to parse response")
        {:noreply, state}
    end
  end

  def handle_info({port, :closed}, %{port: port, job_id: job_id} = state) do
    Logger.error("NBD: daemon crashed for job #{job_id}")
    {:stop, :daemon_crashed, state}
  end

  def handle_continue({:timeout_check, _request_id}, state) do
    # Timeout checking could be implemented here if needed
    {:noreply, state}
  end

  def terminate(_reason, state) do
    Logger.info("NBD: terminating port worker for job #{state.job_id}")

    # Close port (kills daemon process)
    Port.close(state.port)

    # Remove socket file
    File.rm(state.socket_path)

    Logger.info("NBD: cleaned up job #{state.job_id}")
  end

  # Private helpers

  defp via_tuple(job_id) do
    {:via, Registry, {EBS.Registry, "nbd-#{job_id}"}}
  end

  defp socket_path_for(job_id) do
    Path.join(@socket_dir, "ebs-nbd-#{job_id}.sock")
  end

  defp send_rpc_request(port, request) do
    try do
      request_json = Jason.encode!(request)
      # Port uses :packet 4 format (4-byte length prefix)
      Port.command(port, request_json)
      :ok
    rescue
      e ->
        {:error, inspect(e)}
    end
  end

  defp parse_response(bytes) do
    try do
      response = Jason.decode!(bytes)

      case response do
        %{"status" => "ok", "data" => data} ->
          chunk = %{
            sha256: data["sha256"],
            offset: data["offset"],
            size: data["size"],
            data: Base.decode64!(data["data"])
          }

          {:ok, make_ref(), chunk}

        %{"status" => "error", "reason" => reason} ->
          {:error, reason}

        _ ->
          {:error, "Invalid response format"}
      end
    rescue
      e ->
        {:error, "Failed to parse JSON: #{inspect(e)}"}
    end
  end
end
