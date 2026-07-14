defmodule EBS.Metadata.Schema do
  @moduledoc """
  Metadata schema and validation.

  Every piece of metadata is immutable after creation, versioned, and audit-logged.
  This is Cohesity-grade: metadata integrity is non-negotiable.
  """

  defmodule Snapshot do
    @moduledoc """
    A snapshot is an immutable point-in-time backup.

    Once created, a snapshot record never changes. All fields are final.
    """

    defstruct [
      # Immutable identifiers
      :snapshot_id,           # "vm-100/2026-01-15T10:00:00Z"
      :datastore,             # "local", "s3://archive", etc
      :backup_group,          # "vm-100" (for organizing snapshots)
      :vm_id,                 # "100" or "lxc-50"
      :vm_type,               # "qemu" or "lxc"

      # Immutable content metadata
      :chunks,                # [%{hash: "abc123", size: 4194304, offset: 0}, ...]
      :total_size,            # bytes
      :content_checksum,      # SHA256 of all chunks concatenated
      :chunk_count,

      # Immutable timestamps
      :created_at,            # DateTime when snapshot was created
      :backup_timestamp,      # DateTime of VM state (may differ from created_at)

      # Immutable backup metadata
      :encryption,            # "none" | "aes256"
      :compression,           # "none" | "zstd"
      :dedup_ratio,           # 0.45 (45% dedup, i.e., 45% of data was already on server)

      # Immutable retention & tiering
      :retention_days,        # Keep for this many days (set at backup time)
      :tier,                  # "hot" | "warm" | "cold" (current tier)
      :tier_timestamp,        # When it was last tiered
      :cold_location,         # Where it lives in cold storage (if tiered)

      # Immutable source metadata
      :source_type,           # "proxmox-cbt" | "file" | "directory"
      :source_path,           # "/path/to/file" or "proxmox:pve/qemu/100"
      :incremental_from,      # snapshot_id of previous backup (if incremental)

      # Immutable verification
      :status,                # "completed" | "failed" | "pending" | "verified"
      :status_message,        # If failed, why
      :verification_checksum, # Final checksum after upload verification

      # Audit trail
      :created_by,            # "system" | "user:mac" | "api-key:xxx"
      :metadata_version,      # Schema version for forward compatibility
    ]

    @type t :: %__MODULE__{}

    def new(attrs) do
      required = [
        :snapshot_id, :datastore, :backup_group, :vm_id, :vm_type,
        :chunks, :total_size, :content_checksum, :chunk_count,
        :created_at, :backup_timestamp, :retention_days
      ]

      # Validate all required fields are present
      case Enum.all?(required, &Map.has_key?(attrs, &1)) do
        true ->
          __MODULE__
          |> struct(attrs)
          |> validate()

        false ->
          missing = Enum.filter(required, &(!Map.has_key?(attrs, &1)))
          {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
      end
    end

    defp validate(snapshot) do
      cond do
        # Snapshots must have at least 0 bytes (file could be empty)
        snapshot.total_size < 0 ->
          {:error, "total_size cannot be negative"}

        # Chunks must sum to total_size
        sum_chunks(snapshot.chunks) != snapshot.total_size ->
          {:error, "chunks size doesn't match total_size"}

        # Checksum must be valid SHA256
        !valid_sha256?(snapshot.content_checksum) ->
          {:error, "content_checksum must be valid SHA256"}

        # Status must be valid
        snapshot.status not in ["completed", "failed", "pending", "verified"] ->
          {:error, "invalid status"}

        # Tier must be valid
        snapshot.tier not in ["hot", "warm", "cold"] ->
          {:error, "invalid tier"}

        # Retention must be positive
        snapshot.retention_days < 0 ->
          {:error, "retention_days cannot be negative"}

        true ->
          {:ok, snapshot}
      end
    end

    defp sum_chunks(chunks) do
      Enum.sum(Enum.map(chunks, &(&1.size || 0)))
    end

    defp valid_sha256?(hash) when is_binary(hash) do
      String.match?(hash, ~r/^[a-f0-9]{64}$/)
    end

    defp valid_sha256?(_), do: false
  end

  defmodule BackupGroup do
    @moduledoc """
    A backup group is a collection of snapshots for the same entity (VM, filesystem, etc).

    Groups are mutable (snapshots get added), but group metadata is append-only.
    """

    defstruct [
      :backup_group_id,      # "vm-100"
      :datastore,            # "local"
      :created_at,           # First snapshot in this group
      :vm_type,              # "qemu" | "lxc" | "file"
      :metadata_version,
    ]

    @type t :: %__MODULE__{}
  end

  defmodule AuditLog do
    @moduledoc """
    Immutable audit log for compliance and debugging.

    Every metadata change is logged here. Logs are append-only and never modified.
    """

    defstruct [
      :id,                   # UUID
      :timestamp,            # When the action occurred
      :action,               # "snapshot_created" | "snapshot_tiered" | "snapshot_deleted" | etc
      :snapshot_id,          # Which snapshot (if applicable)
      :datastore,
      :actor,                # "system" | "user:mac" | "api-key:xxx"
      :details,              # JSON details of what changed
      :result,               # "success" | "failure"
      :error_message,        # If failed
    ]

    @type t :: %__MODULE__{}
  end

  defmodule IntegrityCheck do
    @moduledoc """
    Periodic integrity verification record.

    Snapshots can be verified at any time. Results are logged for audit.
    """

    defstruct [
      :id,                   # UUID
      :snapshot_id,
      :datastore,
      :checked_at,           # When we verified
      :status,               # "pass" | "fail"
      :details,              # What was checked
      :checksum_match,       # true if content_checksum still matches
      :chunk_verification,   # How many chunks verified OK
    ]

    @type t :: %__MODULE__{}
  end
end
