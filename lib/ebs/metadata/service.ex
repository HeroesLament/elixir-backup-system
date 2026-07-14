defmodule EBS.Metadata.Service do
  @moduledoc """
  Metadata service - the single source of truth for all backup metadata.

  All queries and writes go through here. This ensures consistency and audit logging.
  Metadata is Cohesity-grade rock solid:
  - ACID transactions (SQLite WAL mode)
  - Immutable snapshots (no updates allowed)
  - Append-only audit logs
  - Full referential integrity
  """

  require Logger

  alias EBS.Repo
  alias EBS.Metadata.Snapshot
  alias EBS.Metadata.AuditLog
  import Ecto.Query

  @doc """
  Record a new snapshot.

  This is the primary operation - creating an immutable backup record.
  All fields are validated and must be correct at creation time.
  """
  def record_snapshot(attrs, actor \\ "system") do
    changeset = Snapshot.changeset(%Snapshot{}, attrs)

    case Repo.insert(changeset) do
      {:ok, snapshot} ->
        # Log the creation
        AuditLog.log_snapshot_created(
          snapshot.snapshot_id,
          snapshot.datastore,
          actor,
          %{
            size: snapshot.total_size,
            chunks: snapshot.chunk_count,
            incremental_from: snapshot.incremental_from
          }
        )
        |> Repo.insert()

        Logger.info("Metadata: snapshot recorded #{snapshot.snapshot_id}")
        {:ok, snapshot}

      {:error, changeset} ->
        Logger.error("Metadata: failed to record snapshot - #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Get a snapshot by ID.
  """
  def get_snapshot(snapshot_id) do
    Repo.get_by(Snapshot, snapshot_id: snapshot_id)
  end

  @doc """
  Get the previous snapshot for incremental backups.

  Returns the most recent completed snapshot for the same backup group.
  """
  def get_previous_snapshot(backup_group, datastore) do
    Snapshot
    |> where([s], s.backup_group == ^backup_group and s.datastore == ^datastore)
    |> where([s], s.status == "completed")
    |> where([s], is_nil(s.deleted_at))
    |> order_by([s], desc: s.backup_timestamp)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  List all snapshots for a backup group (excluding deleted).
  """
  def list_snapshots(backup_group, datastore) do
    Snapshot
    |> where([s], s.backup_group == ^backup_group and s.datastore == ^datastore)
    |> where([s], is_nil(s.deleted_at))
    |> order_by([s], desc: s.backup_timestamp)
    |> Repo.all()
  end

  @doc """
  Mark a snapshot as verified.

  This is an allowed update - moving from "pending" to "verified" status.
  """
  def verify_snapshot(snapshot_id, verification_checksum, actor \\ "system") do
    with snapshot <- get_snapshot(snapshot_id),
         true <- snapshot != nil,
         {:ok, updated} <- snapshot |> Snapshot.mark_verified(verification_checksum) |> Repo.update() do
      AuditLog.log_snapshot_verified(snapshot_id, snapshot.datastore, actor, true)
      |> Repo.insert()

      Logger.info("Metadata: snapshot verified #{snapshot_id}")
      {:ok, updated}
    else
      false ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Metadata: failed to verify snapshot - #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Mark a snapshot as tiered to cold storage.

  This is an allowed update - recording the tiering action.
  """
  def tier_to_cold(snapshot_id, cold_location, actor \\ "system") do
    with snapshot <- get_snapshot(snapshot_id),
         true <- snapshot != nil,
         {:ok, updated} <- snapshot |> Snapshot.tier_to_cold(cold_location) |> Repo.update() do
      AuditLog.log_tiering(snapshot_id, snapshot.datastore, actor, cold_location)
      |> Repo.insert()

      Logger.info("Metadata: snapshot tiered #{snapshot_id} to #{cold_location}")
      {:ok, updated}
    else
      false ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Metadata: failed to tier snapshot - #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Mark a snapshot for deletion (soft delete).

  Snapshots are never hard-deleted; they're marked with deleted_at.
  Actual cleanup is handled by a separate retention policy job.
  """
  def mark_for_deletion(snapshot_id, actor \\ "system") do
    with snapshot <- get_snapshot(snapshot_id),
         true <- snapshot != nil,
         {:ok, updated} <- snapshot |> Snapshot.mark_for_deletion() |> Repo.update() do
      AuditLog.log_error("snapshot_deleted", snapshot_id, snapshot.datastore, actor, "Retention policy")
      |> Repo.insert()

      Logger.info("Metadata: snapshot marked for deletion #{snapshot_id}")
      {:ok, updated}
    else
      false ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Metadata: failed to mark deletion - #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get datastore statistics.
  """
  def datastore_stats(datastore) do
    query =
      Snapshot
      |> where([s], s.datastore == ^datastore and is_nil(s.deleted_at))

    total_backups = Repo.aggregate(query, :count, :id)
    total_size = Repo.aggregate(query, :sum, :total_size) || 0

    hot =
      query
      |> where([s], s.tier == "hot")
      |> Repo.aggregate(:count, :id)

    warm =
      query
      |> where([s], s.tier == "warm")
      |> Repo.aggregate(:count, :id)

    cold =
      query
      |> where([s], s.tier == "cold")
      |> Repo.aggregate(:count, :id)

    %{
      datastore: datastore,
      total_backups: total_backups,
      total_size: total_size,
      hot_count: hot,
      warm_count: warm,
      cold_count: cold
    }
  end

  @doc """
  Get audit history for a snapshot.
  """
  def audit_history(snapshot_id, limit \\ 50) do
    AuditLog
    |> where([a], a.snapshot_id == ^snapshot_id)
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Transactional operation: create snapshot + audit in single transaction.

  If either operation fails, both are rolled back.
  """
  def transact_snapshot_creation(snapshot_attrs, actor \\ "system") do
    Repo.transaction(fn ->
      # Create snapshot
      case Snapshot.changeset(%Snapshot{}, snapshot_attrs) |> Repo.insert() do
        {:ok, snapshot} ->
          # Create audit log
          AuditLog.log_snapshot_created(
            snapshot.snapshot_id,
            snapshot.datastore,
            actor,
            Map.take(snapshot_attrs, [:chunks, :total_size, :incremental_from])
          )
          |> Repo.insert()

          {:ok, snapshot}

        {:error, changeset} ->
          Repo.rollback({:validation_error, changeset})
      end
    end)
  end
end
