defmodule EBS.Metadata.Store do
  @moduledoc """
  Backup metadata persistence.

  Stores backup history, statistics, and restore points in ETS.
  For MVP, uses in-memory ETS table.

  Example:
    EBS.Metadata.Store.log_backup(%{
      backup_id: "vm-1/2026-01-15T12:00:00Z",
      datastore: "local",
      size: 1_073_741_824,
      timestamp: DateTime.utc_now(),
      status: "completed"
    })

    history = EBS.Metadata.Store.get_backup_history("local", 20)
  """

  require Logger

  use GenServer

  @table_name :ebs_backups

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Create in-memory ETS table
    :ets.new(@table_name, [:named_table, :ordered_set, :public])
    Logger.info("Metadata.Store: initialized")
    {:ok, %{}}
  end

  @doc """
  Log a backup completion.
  """
  @spec log_backup(map()) :: :ok
  def log_backup(metadata) do
    GenServer.cast(__MODULE__, {:log_backup, metadata})
  end

  @doc """
  Get backup history for a datastore.
  """
  @spec get_backup_history(String.t(), non_neg_integer()) :: [map()]
  def get_backup_history(datastore, limit \\ 20) do
    GenServer.call(__MODULE__, {:get_history, datastore, limit})
  end

  @doc """
  Get statistics for a datastore.
  """
  @spec get_stats(String.t()) :: map()
  def get_stats(datastore) do
    GenServer.call(__MODULE__, {:get_stats, datastore})
  end

  @doc """
  Get all backups in a datastore.
  """
  @spec list_backups(String.t()) :: [map()]
  def list_backups(datastore) do
    GenServer.call(__MODULE__, {:list_backups, datastore})
  end

  @doc """
  Delete backup metadata.
  """
  @spec delete_backup(String.t()) :: :ok
  def delete_backup(backup_id) do
    GenServer.cast(__MODULE__, {:delete_backup, backup_id})
  end

  @doc """
  Get raw statistics for debugging.
  """
  @spec raw_stats() :: map()
  def raw_stats do
    GenServer.call(__MODULE__, :raw_stats)
  end

  # Callbacks

  @impl true
  def handle_cast({:log_backup, metadata}, state) do
    backup_id = metadata.backup_id
    datastore = metadata.datastore
    timestamp = (metadata.timestamp || DateTime.utc_now()) |> DateTime.to_unix()

    key = {datastore, timestamp, backup_id}
    :ets.insert(@table_name, {key, metadata})

    Logger.debug("Metadata.Store: logged backup #{backup_id}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:delete_backup, backup_id}, state) do
    :ets.match_delete(@table_name, {{:_, :_, backup_id}, :_})
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_history, datastore, limit}, _from, state) do
    backups = :ets.match_object(@table_name, {{datastore, :_, :_}, :_})
    |> Enum.map(fn {_, meta} -> meta end)
    |> Enum.sort_by(&(&1.timestamp || DateTime.utc_now()), :desc)
    |> Enum.take(limit)

    {:reply, backups, state}
  end

  @impl true
  def handle_call({:get_stats, datastore}, _from, state) do
    backups = :ets.match_object(@table_name, {{datastore, :_, :_}, :_})
    |> Enum.map(fn {_, meta} -> meta end)

    total_backups = length(backups)
    total_size = Enum.sum(Enum.map(backups, &(&1.size || 0)))

    successful = Enum.count(backups, &(&1.status == "completed"))
    failed = Enum.count(backups, &(&1.status == "failed"))

    stats = %{
      datastore: datastore,
      total_backups: total_backups,
      successful_backups: successful,
      failed_backups: failed,
      total_size: total_size,
      average_size: if(total_backups > 0, do: div(total_size, total_backups), else: 0)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:list_backups, datastore}, _from, state) do
    backups = :ets.match_object(@table_name, {{datastore, :_, :_}, :_})
    |> Enum.map(fn {_, meta} -> meta end)

    {:reply, backups, state}
  end

  @impl true
  def handle_call(:raw_stats, _from, state) do
    count = :ets.info(@table_name, :size)
    memory = :ets.info(@table_name, :memory)

    stats = %{
      table_size: count,
      table_memory: memory * 8,
      all_backups: :ets.match_object(@table_name, {:_, :_})
    }

    {:reply, stats, state}
  end
end
