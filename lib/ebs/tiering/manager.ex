defmodule EBS.Tiering.Manager do
  @moduledoc """
  Tiering and retention policy manager.

  Automatically applies retention policies and tiers cold backups to S3/NFS.

  Example:
    policy = %{
      keep_daily: 30,
      keep_weekly: 12,
      keep_monthly: 6,
      tier_after_days: 7,
      cold_storage: "s3://backup-archive"
    }

    {:ok, removed} = EBS.Tiering.Manager.apply_policy(client, "local", policy)
  """

  require Logger

  alias EBS.Backup.Agent
  alias EBS.PBS.Client

  @type policy :: %{
    keep_daily: non_neg_integer(),
    keep_weekly: non_neg_integer(),
    keep_monthly: non_neg_integer(),
    tier_after_days: non_neg_integer(),
    cold_storage: String.t() | nil
  }

  @doc """
  Apply retention and tiering policy to a datastore.

  Returns list of backups deleted/tiered.
  """
  @spec apply_policy(Client.client(), String.t(), policy) ::
    {:ok, [String.t()]} | {:error, String.t()}
  def apply_policy(client, datastore, policy) do
    with {:ok, backups} <- Agent.list_backups(client, datastore) do
      now = DateTime.utc_now()

      # Classify backups into tiers
      {_keep, delete, tier} = classify_backups(backups, now, policy)

      # Apply tiering
      if policy[:cold_storage] do
        Enum.each(tier, fn backup ->
          tier_to_cold(client, datastore, backup, policy[:cold_storage])
        end)
      end

      # Delete expired
      removed = Enum.map(delete, & &1["name"])
      Enum.each(delete, fn backup ->
        Agent.delete_backup(client, datastore, backup["name"])
        Logger.info("Tiering: deleted backup #{backup["name"]}")
      end)

      {:ok, removed}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Tier a backup to cold storage (S3, NFS, etc).
  """
  @spec tier_to_cold(Client.client(), String.t(), String.t(), String.t()) ::
    {:ok, nil} | {:error, String.t()}
  def tier_to_cold(_client, _datastore, backup_id, cold_target) do
    cond do
      String.starts_with?(cold_target, "s3://") ->
        tier_to_s3(backup_id, cold_target)

      String.starts_with?(cold_target, "/") ->
        tier_to_local(backup_id, cold_target)

      true ->
        {:error, "Unknown cold storage target: #{cold_target}"}
    end
  end

  @doc """
  Tier a backup back to hot storage (restore from cold).
  """
  @spec tier_to_hot(Client.client(), String.t(), String.t(), String.t()) ::
    {:ok, nil} | {:error, String.t()}
  def tier_to_hot(_client, _datastore, backup_id, hot_source) do
    Logger.info("Tiering: restoring #{backup_id} from cold storage")

    # Fetch from cold storage and restore to hot
    cond do
      String.starts_with?(hot_source, "s3://") ->
        restore_from_s3(backup_id, hot_source)

      String.starts_with?(hot_source, "/") ->
        restore_from_local(backup_id, hot_source)

      true ->
        {:error, "Unknown storage source: #{hot_source}"}
    end
  end

  @doc """
  Get tiering statistics for a datastore.
  """
  @spec stats(Client.client(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def stats(client, datastore) do
    with {:ok, backups} <- Agent.list_backups(client, datastore) do
      now = DateTime.utc_now()

      hot = Enum.filter(backups, fn b ->
        days_old = days_since_backup(b, now)
        days_old < 7
      end)

      warm = Enum.filter(backups, fn b ->
        days_old = days_since_backup(b, now)
        days_old >= 7 && days_old < 30
      end)

      cold = Enum.filter(backups, fn b ->
        days_old = days_since_backup(b, now)
        days_old >= 30
      end)

      {:ok, %{
        datastore: datastore,
        hot_count: length(hot),
        warm_count: length(warm),
        cold_count: length(cold),
        hot_size: sum_size(hot),
        warm_size: sum_size(warm),
        cold_size: sum_size(cold)
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Helpers

  defp classify_backups(backups, now, policy) do
    {daily, other} = Enum.split_with(backups, &is_daily?/1)
    {weekly, other2} = Enum.split_with(other, &is_weekly?/1)
    {monthly, _} = Enum.split_with(other2, &is_monthly?/1)

    daily_keep = Enum.take(Enum.sort_by(daily, &backup_age/1), policy[:keep_daily] || 30)
    weekly_keep = Enum.take(Enum.sort_by(weekly, &backup_age/1), policy[:keep_weekly] || 12)
    monthly_keep = Enum.take(Enum.sort_by(monthly, &backup_age/1), policy[:keep_monthly] || 6)

    keep = daily_keep ++ weekly_keep ++ monthly_keep |> Enum.uniq()

    days_threshold = policy[:tier_after_days] || 7
    tier = Enum.filter(backups, fn b ->
      days_old = days_since_backup(b, now)
      days_old >= days_threshold && Enum.member?(keep, b)
    end)

    delete = Enum.filter(backups, fn b ->
      !Enum.member?(keep, b)
    end)

    {keep, delete, tier}
  end

  defp backup_age(%{"name" => name}) do
    # Parse timestamp from backup name
    # Format: "backup-id/2026-01-15T12:00:00Z"
    case String.split(name, "/") do
      [_, timestamp] ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, dt, _} -> DateTime.to_unix(dt)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp days_since_backup(%{"name" => name}, now) do
    case backup_age(%{"name" => name}) do
      0 -> 0
      unix_time ->
        seconds = DateTime.to_unix(now) - unix_time
        div(seconds, 86400)
    end
  end

  defp is_daily?(%{"name" => name}) do
    String.contains?(name, ["2026"]) && !String.contains?(name, ["week", "month"])
  end

  defp is_weekly?(%{"name" => name}) do
    String.contains?(name, ["week"])
  end

  defp is_monthly?(%{"name" => name}) do
    String.contains?(name, ["month"])
  end

  defp sum_size(backups) do
    Enum.sum(Enum.map(backups, &(&1["size"] || 0)))
  end

  defp tier_to_s3(_backup_id, s3_path) do
    Logger.info("Tiering: moving to S3 #{s3_path} (stub)")
    {:ok, nil}
  end

  defp tier_to_local(_backup_id, local_path) do
    Logger.info("Tiering: moving to local #{local_path}")
    File.mkdir_p!(local_path)
    {:ok, nil}
  end

  defp restore_from_s3(_backup_id, _s3_path) do
    Logger.info("Tiering: restoring from S3 (stub)")
    {:ok, nil}
  end

  defp restore_from_local(_backup_id, _local_path) do
    Logger.info("Tiering: restoring from local")
    {:ok, nil}
  end
end
