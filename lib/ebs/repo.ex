defmodule EBS.Repo do
  @moduledoc """
  Ecto repository for EBS metadata.

  All backup metadata lives here: snapshots, backup groups, audit logs, integrity checks.
  SQLite provides durability and ACID guarantees.
  """

  use Ecto.Repo,
    otp_app: :ebs,
    adapter: Ecto.Adapters.SQLite3
end
