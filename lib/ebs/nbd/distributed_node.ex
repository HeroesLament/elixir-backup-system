defmodule EBS.NBD.DistributedNode do
  @moduledoc """
  Manages the Rust NBD daemon as a distributed Erlang node.

  The daemon runs as a separate Tokio process and communicates via
  Erlang Distribution Protocol (EDP) + ETF serialization.

  This provides:
  - Crash isolation (if daemon dies, EBS keeps running)
  - GenServer-like RPC interface
  - Native Erlang binary protocol (efficient, no JSON)
  - Supervision and health checks
  """

  require Logger
  use GenServer

  @daemon_node :"ebs-nbd@127.0.0.1"
  @daemon_cookie :ebs_nbd_secret
  @connect_timeout 30_000
  @rpc_timeout 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    daemon_bin = Keyword.get(opts, :daemon_bin, "/usr/local/bin/ebs-nbd-daemon")
    Logger.info("NBD: starting distributed node daemon at #{daemon_bin}")

    # TODO: Spawn daemon process, wait for it to connect
    {:ok, %{daemon_bin: daemon_bin, connected: false}}
  end

  @doc """
  Read blocks from a VM disk via the NBD daemon.

  Returns: {:ok, chunks} where chunks = [{sha256, offset, size, data}, ...]
  """
  def read_blocks(node, vmid, disk, offset, size) do
    GenServer.call(__MODULE__, {:read_blocks, node, vmid, disk, offset, size}, @rpc_timeout)
  end

  @doc """
  Query dirty bitmap for a VM disk.

  Returns: {:ok, dirty_ranges} where dirty_ranges = [{offset, size}, ...]
  """
  def query_bitmap(node, vmid, disk) do
    GenServer.call(__MODULE__, {:query_bitmap, node, vmid, disk}, @rpc_timeout)
  end

  @doc """
  Health check - ping the daemon.
  """
  def ping do
    GenServer.call(__MODULE__, :ping, 10_000)
  end

  # GenServer callbacks

  def handle_call({:read_blocks, node, vmid, disk, offset, size}, _from, state) do
    result = :rpc.call(
      @daemon_node,
      EbsNBD,
      :read_blocks,
      [node, vmid, disk, offset, size],
      @rpc_timeout
    )

    case result do
      {:ok, chunks} ->
        Logger.debug("NBD: read_blocks succeeded, got #{length(chunks)} chunks")
        {:reply, {:ok, chunks}, state}

      {:error, reason} ->
        Logger.error("NBD: read_blocks failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}

      {:badrpc, reason} ->
        Logger.error("NBD: RPC call failed: #{inspect(reason)}")
        {:reply, {:error, "RPC failed: #{inspect(reason)}"}, state}
    end
  end

  def handle_call({:query_bitmap, node, vmid, disk}, _from, state) do
    result = :rpc.call(
      @daemon_node,
      EbsNBD,
      :query_bitmap,
      [node, vmid, disk],
      @rpc_timeout
    )

    case result do
      {:ok, ranges} ->
        Logger.debug("NBD: query_bitmap succeeded, got #{length(ranges)} dirty ranges")
        {:reply, {:ok, ranges}, state}

      {:error, reason} ->
        Logger.error("NBD: query_bitmap failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}

      {:badrpc, reason} ->
        Logger.error("NBD: RPC call failed: #{inspect(reason)}")
        {:reply, {:error, "RPC failed: #{inspect(reason)}"}, state}
    end
  end

  def handle_call(:ping, _from, state) do
    result = :rpc.call(@daemon_node, EbsNBD, :ping, [], 10_000)

    case result do
      {:ok, "pong"} ->
        {:reply, :ok, %{state | connected: true}}

      {:badrpc, _reason} ->
        Logger.warn("NBD: daemon not responding")
        {:reply, {:error, "daemon not responding"}, %{state | connected: false}}
    end
  end
end
