defmodule EBS.Metadata.AuditLog do
  @moduledoc """
  Immutable audit log for compliance and debugging.

  Every significant operation is logged here. Logs are append-only and never modified.
  This is the source of truth for "what happened to this snapshot?"
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "audit_logs" do
    field :action, :string
    field :snapshot_id, :string
    field :datastore, :string
    field :actor, :string  # "system" | "user:mac" | "api-key:xxx"
    field :details, :map  # JSON details
    field :result, :string  # "success" | "failure"
    field :error_message, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)  # Append-only: no updated_at
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:action, :snapshot_id, :datastore, :actor, :details, :result, :error_message])
    |> validate_required([:action, :datastore, :actor, :result])
    |> validate_inclusion(:result, ["success", "failure"])
    |> validate_inclusion(:action, [
      "snapshot_created",
      "snapshot_verified",
      "snapshot_tiered",
      "snapshot_deleted",
      "backup_started",
      "backup_completed",
      "restore_started",
      "restore_completed",
      "policy_applied",
      "retention_enforced"
    ])
  end

  @doc """
  Log a backup creation event.
  """
  def log_snapshot_created(snapshot_id, datastore, actor, details) do
    create_log(%{
      action: "snapshot_created",
      snapshot_id: snapshot_id,
      datastore: datastore,
      actor: actor,
      details: details,
      result: "success"
    })
  end

  @doc """
  Log a backup verification event.
  """
  def log_snapshot_verified(snapshot_id, datastore, actor, checksum_match) do
    create_log(%{
      action: "snapshot_verified",
      snapshot_id: snapshot_id,
      datastore: datastore,
      actor: actor,
      details: %{checksum_match: checksum_match},
      result: "success"
    })
  end

  @doc """
  Log a tiering event.
  """
  def log_tiering(snapshot_id, datastore, actor, destination) do
    create_log(%{
      action: "snapshot_tiered",
      snapshot_id: snapshot_id,
      datastore: datastore,
      actor: actor,
      details: %{destination: destination},
      result: "success"
    })
  end

  @doc """
  Log an error.
  """
  def log_error(action, snapshot_id, datastore, actor, error_message) do
    create_log(%{
      action: action,
      snapshot_id: snapshot_id,
      datastore: datastore,
      actor: actor,
      result: "failure",
      error_message: error_message
    })
  end

  defp create_log(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end
end
