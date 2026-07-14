defmodule EBS.Metadata.Snapshot do
  @moduledoc """
  Snapshot Ecto schema.

  A snapshot is an immutable point-in-time backup. Once created, it never changes.
  Immutability is enforced at the database level (no updates allowed).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "snapshots" do
    # Identifiers
    field :snapshot_id, :string  # "vm-100/2026-01-15T10:00:00Z"
    field :datastore, :string
    field :backup_group, :string
    field :vm_id, :string
    field :vm_type, :string  # "qemu" | "lxc" | "file"

    # Content metadata
    field :chunks, {:array, :map}  # [{hash, size, offset}, ...]
    field :total_size, :integer  # bytes
    field :content_checksum, :string  # SHA256
    field :chunk_count, :integer

    # Timestamps (immutable)
    field :created_at, :utc_datetime
    field :backup_timestamp, :utc_datetime

    # Backup configuration
    field :encryption, :string, default: "none"
    field :compression, :string, default: "none"
    field :dedup_ratio, :float  # 0.45 = 45% of data was already on server

    # Retention & tiering
    field :retention_days, :integer
    field :tier, :string, default: "hot"  # "hot" | "warm" | "cold"
    field :tier_timestamp, :utc_datetime
    field :cold_location, :string  # Where in cold storage

    # Source
    field :source_type, :string  # "proxmox-cbt" | "file" | "directory"
    field :source_path, :string
    field :incremental_from, :string  # snapshot_id of previous backup

    # Verification
    field :status, :string, default: "pending"  # "pending" | "completed" | "failed" | "verified"
    field :status_message, :string
    field :verification_checksum, :string  # Final checksum after upload

    # Audit
    field :created_by, :string, default: "system"
    field :metadata_version, :integer, default: 1

    # Tracking (denormalized for queries)
    field :deleted_at, :utc_datetime  # Soft delete for retention
    field :indexed_at, :utc_datetime  # When metadata was indexed

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :snapshot_id, :datastore, :backup_group, :vm_id, :vm_type,
      :chunks, :total_size, :content_checksum, :chunk_count,
      :created_at, :backup_timestamp, :encryption, :compression, :dedup_ratio,
      :retention_days, :tier, :tier_timestamp, :cold_location,
      :source_type, :source_path, :incremental_from,
      :status, :status_message, :verification_checksum, :created_by, :metadata_version
    ])
    |> validate_required([
      :snapshot_id, :datastore, :backup_group, :vm_id, :vm_type,
      :chunks, :total_size, :content_checksum, :chunk_count,
      :created_at, :backup_timestamp, :retention_days,
      :source_type, :source_path, :status, :created_by
    ])
    |> validate_inclusion(:status, ["pending", "completed", "failed", "verified"])
    |> validate_inclusion(:tier, ["hot", "warm", "cold"])
    |> validate_inclusion(:vm_type, ["qemu", "lxc", "file"])
    |> validate_number(:total_size, greater_than_or_equal_to: 0)
    |> validate_number(:retention_days, greater_than_or_equal_to: 0)
    |> validate_checksum(:content_checksum)
    |> unique_constraint(:snapshot_id, name: :snapshots_snapshot_id_index)
  end

  defp validate_checksum(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if String.match?(value, ~r/^[a-f0-9]{64}$/i) do
        []
      else
        [{field, "must be a valid SHA256 hex string"}]
      end
    end)
  end

  @doc """
  Create a new snapshot record.

  Snapshots are immutable once created. This function enforces all required validations.
  """
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end

  @doc """
  Mark a snapshot as tiered to cold storage.

  This is one of the few allowed updates - moving tier status and location.
  """
  def tier_to_cold(snapshot, location) do
    snapshot
    |> change(
      tier: "cold",
      cold_location: location,
      tier_timestamp: DateTime.utc_now()
    )
  end

  @doc """
  Mark a snapshot as verified.
  """
  def mark_verified(snapshot, verification_checksum) do
    snapshot
    |> change(
      status: "verified",
      verification_checksum: verification_checksum
    )
  end

  @doc """
  Soft delete a snapshot (mark for deletion, actual data cleanup happens later).
  """
  def mark_for_deletion(snapshot) do
    snapshot
    |> change(deleted_at: DateTime.utc_now())
  end
end
