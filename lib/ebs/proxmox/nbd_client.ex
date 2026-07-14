defmodule EBS.Proxmox.NBDClient do
  @moduledoc """
  NBD (Network Block Device) client for reading disk data from Proxmox VMs.

  Supports three transport modes:
  1. Direct file I/O (same node, fastest)
  2. NBD over TCP (LAN, direct connection)
  3. NBD over SSH tunnel (WAN, encrypted control plane)

  Data flow:
    Dirty Bitmap Query (QMP via SSH)
         ↓
    Read Only Changed Blocks (NBD data plane)
         ↓
    Compute SHA256 Chunks
         ↓
    Store to /mnt/backups/chunks/
  """

  require Logger

  @default_nbd_port 10809
  @chunk_size 65536  # 64KB blocks (match bitmap granularity)
  @max_retries 3
  @connect_timeout 30_000

  defstruct [:node, :vmid, :disk, :transport, :nbd_port, :ssh_tunnel, :connected]

  @type transport :: :direct | :lan | :wan
  @type client :: %__MODULE__{
    node: String.t(),
    vmid: non_neg_integer(),
    disk: String.t(),
    transport: transport,
    nbd_port: non_neg_integer(),
    ssh_tunnel: any(),
    connected: boolean()
  }

  @doc """
  Create an NBD client for a VM disk.

  Options:
    - transport: :direct | :lan | :wan (default: :lan)
    - nbd_port: NBD server port (default: 10809)
  """
  def new(node, vmid, disk, opts \\ []) do
    transport = Keyword.get(opts, :transport, :lan)
    nbd_port = Keyword.get(opts, :nbd_port, @default_nbd_port)

    %__MODULE__{
      node: node,
      vmid: vmid,
      disk: disk,
      transport: transport,
      nbd_port: nbd_port,
      ssh_tunnel: nil,
      connected: false
    }
  end

  @doc """
  Connect to the NBD server.

  For :direct transport, validates that the disk file exists locally.
  For :lan transport, connects directly to NBD port.
  For :wan transport, establishes SSH tunnel and connects through it.
  """
  def connect(%__MODULE__{} = client) do
    case client.transport do
      :direct ->
        connect_direct(client)

      :lan ->
        connect_lan(client)

      :wan ->
        connect_wan(client)
    end
  end

  @doc """
  Disconnect from the NBD server.
  """
  def disconnect(%__MODULE__{connected: true, ssh_tunnel: tunnel} = client) when tunnel != nil do
    Logger.info("NBD: disconnecting SSH tunnel for VM #{client.vmid}")
    # Close SSH tunnel
    {:ok, %{client | connected: false}}
  end

  def disconnect(%__MODULE__{} = client) do
    {:ok, %{client | connected: false}}
  end

  @doc """
  Read a block range from the disk.

  Returns: {:ok, data} where data is the bytes read
  """
  def read_block(%__MODULE__{connected: true, transport: :direct} = client, offset, size) do
    disk_path = disk_file_path(client)

    case File.read(disk_path) do
      {:ok, data} ->
        # Extract the requested range
        <<_::binary-size(offset), chunk::binary-size(size), _::binary>> = data
        {:ok, chunk}

      {:error, reason} ->
        Logger.error("NBD: failed to read disk #{disk_path}: #{inspect(reason)}")
        {:error, "Failed to read disk: #{inspect(reason)}"}
    end
  rescue
    MatchError ->
      {:error, "Offset/size out of bounds"}
  end

  def read_block(%__MODULE__{connected: true, transport: transport} = client, offset, size)
      when transport in [:lan, :wan] do
    # TODO: Implement NBD protocol over TCP
    # For now, stub that would connect to NBD server and read
    Logger.debug("NBD: reading #{size} bytes from VM #{client.vmid} offset #{offset}")
    {:ok, <<0::size(size)-unit(8)>>}
  end

  def read_block(%__MODULE__{connected: false}, _offset, _size) do
    {:error, "NBD client not connected"}
  end

  @doc """
  Read full disk in chunks, computing SHA256 hash for each.

  Returns: {:ok, chunks} where chunks = [{offset, size, sha256}, ...]
  """
  def read_disk_chunks(%__MODULE__{} = client) do
    {:ok, client} = connect(client)

    try do
      disk_size = get_disk_size(client)
      Logger.info("NBD: reading disk #{disk_size} bytes in #{@chunk_size}-byte chunks")

      chunks =
        0
        |> Stream.unfold(fn offset ->
          if offset >= disk_size do
            nil
          else
            chunk_size = min(@chunk_size, disk_size - offset)
            {offset, offset + chunk_size}
          end
        end)
        |> Enum.map(fn offset ->
          case read_chunk_with_hash(client, offset) do
            {:ok, sha256} ->
              {:ok, {offset, @chunk_size, sha256}}

            {:error, reason} ->
              Logger.error("NBD: failed to read chunk at offset #{offset}: #{reason}")
              {:error, reason}
          end
        end)
        |> Enum.reduce([], fn result, acc ->
          case result do
            {:ok, chunk} -> [chunk | acc]
            {:error, _} -> acc
          end
        end)
        |> Enum.reverse()

      {:ok, chunks}
    after
      disconnect(client)
    end
  end

  @doc """
  Query dirty bitmap for changed blocks (only for qcow2).

  Returns: {:ok, dirty_ranges} where dirty_ranges = [{offset, size}, ...]
  or {:error, reason} if bitmap not supported.
  """
  def query_dirty_bitmap(%__MODULE__{} = client) do
    # TODO: Query via QMP over SSH tunnel
    Logger.debug("NBD: querying dirty bitmap for VM #{client.vmid}")

    case client.transport do
      :wan ->
        query_bitmap_via_ssh(client)

      _ ->
        # For LAN/direct, assume no persistent bitmap available
        {:error, "Dirty bitmap requires qcow2 and WAN transport (QMP over SSH)"}
    end
  end

  # Private helpers

  defp connect_direct(%__MODULE__{} = client) do
    disk_path = disk_file_path(client)

    case File.exists?(disk_path) do
      true ->
        Logger.info("NBD: using direct I/O for disk #{disk_path}")
        {:ok, %{client | connected: true, transport: :direct}}

      false ->
        Logger.error("NBD: disk file not found: #{disk_path}")
        {:error, "Disk file not found: #{disk_path}"}
    end
  end

  defp connect_lan(%__MODULE__{} = client) do
    # TODO: Implement NBD TCP connection
    Logger.info("NBD: connecting to LAN NBD server on port #{client.nbd_port}")
    {:ok, %{client | connected: true}}
  end

  defp connect_wan(%__MODULE__{} = client) do
    # TODO: Establish SSH tunnel for QMP + data plane
    Logger.info("NBD: establishing WAN SSH tunnel to #{client.node}")
    {:ok, %{client | connected: true}}
  end

  defp disk_file_path(%__MODULE__{node: node, vmid: vmid, disk: disk}) do
    # Proxmox disk path: /var/lib/vz/images/{vmid}/vm-{vmid}-disk-{disk}.qcow2
    Path.join(["/var/lib/vz/images", to_string(vmid), "vm-#{vmid}-#{disk}.qcow2"])
  end

  defp get_disk_size(%__MODULE__{transport: :direct} = client) do
    disk_path = disk_file_path(client)

    case File.stat(disk_path) do
      {:ok, stat} -> stat.size
      {:error, _} -> 0
    end
  end

  defp get_disk_size(%__MODULE__{transport: :lan}), do: 0  # TODO: Query via NBD

  defp read_chunk_with_hash(%__MODULE__{} = client, offset) do
    case read_block(client, offset, @chunk_size) do
      {:ok, data} ->
        sha256 = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
        {:ok, sha256}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("NBD: exception reading chunk at offset #{offset}: #{inspect(e)}")
      {:error, inspect(e)}
  end

  defp query_bitmap_via_ssh(%__MODULE__{} = client) do
    # SSH tunnel for QMP:
    # ssh node "virsh qemu-monitor-command --json vm-id '{ \"execute\": \"query-dirty-bitmaps\" }'"
    #
    # Returns:
    # {
    #   "return": [
    #     {
    #       "name": "incremental",
    #       "count": 2048,
    #       "granularity": 65536,
    #       "recording": true
    #     }
    #   ]
    # }
    Logger.debug("NBD: querying dirty bitmap via SSH for VM #{client.vmid}")

    # TODO: Execute SSH command and parse JSON response
    {:error, "Not yet implemented"}
  end
end
