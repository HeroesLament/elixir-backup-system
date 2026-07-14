defmodule EBS.Repo.Migrations.CreateMetadataSchema do
  use Ecto.Migration

  def change do
    # Snapshots table - immutable backup records
    create table(:snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :snapshot_id, :string, null: false
      add :datastore, :string, null: false
      add :backup_group, :string, null: false
      add :vm_id, :string, null: false
      add :vm_type, :string, null: false

      # Content metadata
      add :chunks, :binary, null: false  # JSON array
      add :total_size, :bigint, null: false
      add :content_checksum, :string, null: false
      add :chunk_count, :integer, null: false

      # Timestamps
      add :created_at, :utc_datetime_usec, null: false
      add :backup_timestamp, :utc_datetime_usec, null: false

      # Backup config
      add :encryption, :string, default: "none"
      add :compression, :string, default: "none"
      add :dedup_ratio, :float

      # Retention & tiering
      add :retention_days, :integer, null: false
      add :tier, :string, default: "hot", null: false
      add :tier_timestamp, :utc_datetime_usec
      add :cold_location, :string

      # Source
      add :source_type, :string, null: false
      add :source_path, :string, null: false
      add :incremental_from, :string

      # Status
      add :status, :string, default: "pending", null: false
      add :status_message, :string
      add :verification_checksum, :string

      # Audit
      add :created_by, :string, default: "system"
      add :metadata_version, :integer, default: 1

      # Soft delete
      add :deleted_at, :utc_datetime_usec

      # Indexing
      add :indexed_at, :utc_datetime_usec

      # Timestamps
      timestamps(type: :utc_datetime_usec)
    end

    # Indexes for common queries
    create index(:snapshots, [:snapshot_id], unique: true)
    create index(:snapshots, [:datastore])
    create index(:snapshots, [:backup_group])
    create index(:snapshots, [:vm_id])
    create index(:snapshots, [:status])
    create index(:snapshots, [:tier])
    create index(:snapshots, [:created_at])
    create index(:snapshots, [:deleted_at])

    # Audit log table - append-only
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action, :string, null: false
      add :snapshot_id, :string
      add :datastore, :string, null: false
      add :actor, :string, null: false
      add :details, :binary  # JSON
      add :result, :string, null: false
      add :error_message, :string

      # Only created_at, no updated_at (append-only)
      add :inserted_at, :utc_datetime_usec, null: false
    end

    # Indexes for audit queries
    create index(:audit_logs, [:snapshot_id])
    create index(:audit_logs, [:datastore])
    create index(:audit_logs, [:action])
    create index(:audit_logs, [:inserted_at])
    create index(:audit_logs, [:actor])

    # Backup groups table - organizes snapshots
    create table(:backup_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :backup_group_id, :string, null: false
      add :datastore, :string, null: false
      add :vm_type, :string, null: false
      add :created_at, :utc_datetime_usec, null: false

      add :metadata_version, :integer, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create index(:backup_groups, [:backup_group_id, :datastore], unique: true)
    create index(:backup_groups, [:datastore])

    # Integrity checks table
    create table(:integrity_checks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :snapshot_id, :string, null: false
      add :datastore, :string, null: false
      add :checked_at, :utc_datetime_usec, null: false
      add :status, :string, null: false  # "pass" | "fail"
      add :details, :binary  # JSON
      add :checksum_match, :boolean
      add :chunk_verification, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:integrity_checks, [:snapshot_id])
    create index(:integrity_checks, [:datastore])
    create index(:integrity_checks, [:status])
  end
end
