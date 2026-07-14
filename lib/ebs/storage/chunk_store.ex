defmodule EBS.Storage.ChunkStore do
  @moduledoc """
  Content-addressable chunk storage.

  All chunks are stored by their SHA256 hash, enabling:
  - Deduplication across snapshots
  - Chunk-level integrity verification
  - Efficient garbage collection (ref counting)

  Storage layout:
    /mnt/backups/chunks/
    ├── 0a/                    # First 2 chars of SHA256
    │   ├── 0a1b2c3d...        # Full SHA256 = filename
    │   └── 0a9e8f7d...
    ├── 1f/
    │   ├── 1f2a3b4c...
    │   └── 1f9d8c7b...
  """

  require Logger
  use GenServer

  @default_chunk_dir "/mnt/backups/chunks"
  @chunk_prefix_len 2

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    chunk_dir = Keyword.get(opts, :chunk_dir, @default_chunk_dir)
    File.mkdir_p!(chunk_dir)
    Logger.info("ChunkStore: initialized at #{chunk_dir}")
    {:ok, %{chunk_dir: chunk_dir}}
  end

  @doc """
  Store a chunk with SHA256 hash.

  Returns: {:ok, sha256} or {:error, reason}
  """
  def store_chunk(data, opts \\ []) do
    GenServer.call(__MODULE__, {:store, data, opts})
  end

  @doc """
  Retrieve a chunk by SHA256 hash.

  Returns: {:ok, data} or {:error, reason}
  """
  def get_chunk(sha256) do
    GenServer.call(__MODULE__, {:get, sha256})
  end

  @doc """
  Check if chunk exists.

  Returns: boolean
  """
  def chunk_exists?(sha256) do
    GenServer.call(__MODULE__, {:exists, sha256})
  end

  @doc """
  Increment reference count for a chunk.

  Multiple snapshots can reference the same chunk.
  """
  def increment_ref(sha256) do
    GenServer.cast(__MODULE__, {:increment_ref, sha256})
  end

  @doc """
  Decrement reference count for a chunk.

  When ref_count reaches 0, chunk can be garbage collected.
  """
  def decrement_ref(sha256) do
    GenServer.cast(__MODULE__, {:decrement_ref, sha256})
  end

  @doc """
  Get chunk statistics.

  Returns: %{total_chunks, total_size, duplicate_blocks, dedup_savings}
  """
  def get_stats do
    GenServer.call(__MODULE__, :stats)
  end

  # GenServer callbacks

  def handle_call({:store, data, opts}, _from, %{chunk_dir: chunk_dir} = state) do
    sha256 = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    # Check if chunk already exists
    case chunk_exists_internal(sha256, chunk_dir) do
      true ->
        Logger.debug("ChunkStore: chunk #{String.slice(sha256, 0..7)} already exists (dedup)")
        {:reply, {:ok, sha256}, state}

      false ->
        case store_chunk_internal(sha256, data, chunk_dir, opts) do
          :ok ->
            Logger.debug("ChunkStore: stored chunk #{String.slice(sha256, 0..7)} (#{byte_size(data)} bytes)")
            {:reply, {:ok, sha256}, state}

          {:error, reason} ->
            Logger.error("ChunkStore: failed to store chunk: #{reason}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:get, sha256}, _from, %{chunk_dir: chunk_dir} = state) do
    case get_chunk_internal(sha256, chunk_dir) do
      {:ok, data} ->
        {:reply, {:ok, data}, state}

      {:error, reason} ->
        Logger.error("ChunkStore: failed to get chunk #{String.slice(sha256, 0..7)}: #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:exists, sha256}, _from, %{chunk_dir: chunk_dir} = state) do
    exists = chunk_exists_internal(sha256, chunk_dir)
    {:reply, exists, state}
  end

  def handle_call(:stats, _from, %{chunk_dir: chunk_dir} = state) do
    stats = compute_stats(chunk_dir)
    {:reply, stats, state}
  end

  def handle_cast({:increment_ref, sha256}, state) do
    # TODO: Update SQLite ref_count
    Logger.debug("ChunkStore: increment ref for chunk #{String.slice(sha256, 0..7)}")
    {:noreply, state}
  end

  def handle_cast({:decrement_ref, sha256}, state) do
    # TODO: Update SQLite ref_count, mark for GC if 0
    Logger.debug("ChunkStore: decrement ref for chunk #{String.slice(sha256, 0..7)}")
    {:noreply, state}
  end

  # Private helpers

  defp store_chunk_internal(sha256, data, chunk_dir, _opts) do
    prefix = String.slice(sha256, 0..(@chunk_prefix_len - 1))
    prefix_dir = Path.join(chunk_dir, prefix)
    chunk_path = Path.join(prefix_dir, sha256)

    with :ok <- File.mkdir_p(prefix_dir),
         :ok <- File.write(chunk_path, data) do
      :ok
    else
      {:error, reason} ->
        {:error, "Failed to write chunk: #{inspect(reason)}"}
    end
  end

  defp get_chunk_internal(sha256, chunk_dir) do
    prefix = String.slice(sha256, 0..(@chunk_prefix_len - 1))
    chunk_path = Path.join([chunk_dir, prefix, sha256])

    case File.read(chunk_path) do
      {:ok, data} ->
        {:ok, data}

      {:error, :enoent} ->
        {:error, "Chunk not found: #{chunk_path}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp chunk_exists_internal(sha256, chunk_dir) do
    prefix = String.slice(sha256, 0..(@chunk_prefix_len - 1))
    chunk_path = Path.join([chunk_dir, prefix, sha256])
    File.exists?(chunk_path)
  end

  defp compute_stats(chunk_dir) do
    case File.ls(chunk_dir) do
      {:ok, prefixes} ->
        {total_chunks, total_size} =
          Enum.reduce(prefixes, {0, 0}, fn prefix, {chunks, size} ->
            prefix_dir = Path.join(chunk_dir, prefix)

            case File.ls(prefix_dir) do
              {:ok, chunk_files} ->
                chunk_count = length(chunk_files)

                total_file_size =
                  Enum.reduce(chunk_files, 0, fn chunk_file, acc ->
                    chunk_path = Path.join(prefix_dir, chunk_file)

                    case File.stat(chunk_path) do
                      {:ok, stat} -> acc + stat.size
                      {:error, _} -> acc
                    end
                  end)

                {chunks + chunk_count, size + total_file_size}

              {:error, _} ->
                {chunks, size}
            end
          end)

        %{
          total_chunks: total_chunks,
          total_size: total_size,
          avg_chunk_size: if(total_chunks > 0, do: total_size / total_chunks, else: 0)
        }

      {:error, _} ->
        %{total_chunks: 0, total_size: 0, avg_chunk_size: 0}
    end
  end
end
