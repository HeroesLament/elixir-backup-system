defmodule EBS.Backup.Agent do
  @moduledoc """
  Backup orchestration agent.

  Coordinates backups to Proxmox Backup Server, tracks metadata, applies policies.
  Driven from IEx for MVP phase.

  Example:
    {:ok, client} = EBS.PBS.Client.authenticate("pbs-host", "root@pam", "password")
    {:ok, meta} = EBS.Backup.Agent.backup_file(client, "/tmp/data.tar.gz", "local", "app1")
    backups = EBS.Backup.Agent.list_backups(client, "local")
  """

  require Logger

  alias EBS.PBS.Client
  alias EBS.Metadata.Store

  @doc """
  Create a backup from a file.

  Reads the file, sends to PBS, tracks metadata.
  """
  @spec backup_file(Client.client(), String.t(), String.t(), String.t(), map()) ::
    {:ok, map()} | {:error, String.t()}
  def backup_file(client, file_path, datastore, backup_name, options \\ %{}) do
    with true <- File.exists?(file_path) || raise("File not found: #{file_path}"),
         {:ok, data} <- File.read(file_path),
         backup_id <- generate_backup_id(backup_name),
         {:ok, _result} <- Client.create_backup(
           client,
           datastore,
           backup_id,
           data,
           options
         ) do
      meta = %{
        backup_id: backup_id,
        source: file_path,
        datastore: datastore,
        size: byte_size(data),
        timestamp: DateTime.utc_now(),
        status: "completed",
        options: options
      }

      # Store metadata
      Store.log_backup(meta)

      Logger.info("Backup.Agent: backed up #{file_path} as #{backup_id}")
      {:ok, meta}
    else
      false ->
        {:error, "File not found: #{file_path}"}

      {:error, reason} ->
        Logger.error("Backup.Agent: backup failed - #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Backup a directory (tar + compress).
  """
  @spec backup_directory(Client.client(), String.t(), String.t(), String.t(), map()) ::
    {:ok, map()} | {:error, String.t()}
  def backup_directory(client, dir_path, datastore, backup_name, options \\ %{}) do
    with true <- File.dir?(dir_path) || raise("Directory not found: #{dir_path}"),
         temp_tar <- Path.join(System.tmp_dir!(), "backup-#{:erlang.unique_integer()}.tar.gz"),
         :ok <- create_tar(dir_path, temp_tar) do
      result = backup_file(client, temp_tar, datastore, backup_name, options)
      File.rm(temp_tar)
      result
    else
      false ->
        {:error, "Directory not found: #{dir_path}"}

      error ->
        {:error, "Failed to create tar: #{inspect(error)}"}
    end
  end

  @doc """
  List all backups in a datastore.
  """
  @spec list_backups(Client.client(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_backups(client, datastore) do
    Client.list_backups(client, datastore)
  end

  @doc """
  Get detailed info about a backup.
  """
  @spec get_backup(Client.client(), String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def get_backup(client, datastore, backup_id) do
    Client.get_backup(client, datastore, backup_id)
  end

  @doc """
  Delete a backup.
  """
  @spec delete_backup(Client.client(), String.t(), String.t()) :: {:ok, nil} | {:error, String.t()}
  def delete_backup(client, datastore, backup_id) do
    Client.delete_backup(client, datastore, backup_id)
  end

  @doc """
  Get backup statistics for a datastore.
  """
  @spec stats(Client.client(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def stats(client, datastore) do
    with {:ok, backups} <- list_backups(client, datastore),
         {:ok, ds_info} <- Client.datastore_info(client, datastore) do
      total_size = Enum.sum(Enum.map(backups, &(&1["size"] || 0)))
      count = length(backups)

      {:ok, %{
        datastore: datastore,
        backup_count: count,
        total_size: total_size,
        datastore_info: ds_info
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Helpers

  defp generate_backup_id(name) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    "#{name}/#{timestamp}"
  end

  defp create_tar(dir_path, tar_path) do
    case System.cmd("tar", ["-czf", tar_path, "-C", dir_path, "."]) do
      {_, 0} -> :ok
      {error, code} -> {:error, "tar failed with code #{code}: #{error}"}
    end
  end
end
