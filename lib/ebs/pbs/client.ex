defmodule EBS.PBS.Client do
  @moduledoc """
  HTTP/2 client for Proxmox Backup Server (PBS).

  Handles authentication, backup creation/retrieval, and restore operations.
  Uses ticket-based auth (valid for ~2 hours).

  Example:
    {:ok, ticket, csrf} = EBS.PBS.Client.authenticate("pbs-host", "root@pam", "password")
    {:ok, backups} = EBS.PBS.Client.list_backups(ticket, "local")
  """

  require Logger

  @auth_timeout 7200  # 2 hours in seconds
  @http_timeout 30000  # 30 seconds

  defstruct [:host, :port, :ticket, :csrf_token, :ticket_created_at]

  @type client :: %__MODULE__{
    host: String.t(),
    port: non_neg_integer(),
    ticket: String.t() | nil,
    csrf_token: String.t() | nil,
    ticket_created_at: DateTime.t() | nil
  }

  @type auth_response :: {:ok, client} | {:error, String.t()}
  @type backup_response :: {:ok, map()} | {:error, String.t()}
  @type list_response :: {:ok, [map()]} | {:error, String.t()}

  @doc """
  Authenticate with Proxmox Backup Server from config.

  Reads from :ebs :pbs_config which is populated from environment variables
  by obao/Concourse/SecretSpec at runtime.

  Environment variables:
    PBS_HOST - PBS host (required)
    PBS_PORT - PBS port (default: 8007)
    PBS_USER - PBS user (default: root@pam)
    PBS_PASSWORD - PBS password (required)
  """
  @spec authenticate_from_config() :: auth_response
  def authenticate_from_config do
    config = Application.get_env(:ebs, :pbs_config, %{})

    host = config[:host] || raise "PBS_HOST not set in environment"
    port = config[:port] || 8007
    user = config[:user] || "root@pam"
    password = config[:password] || raise "PBS_PASSWORD not set in environment"

    authenticate(host, user, password, port)
  end

  @doc """
  Authenticate with Proxmox Backup Server (manual).

  Returns a client struct with ticket + CSRF token for subsequent API calls.
  """
  @spec authenticate(String.t(), String.t(), String.t(), non_neg_integer()) :: auth_response
  def authenticate(host, user, password, port \\ 8007) do
    client = %__MODULE__{
      host: host,
      port: port,
      ticket: nil,
      csrf_token: nil,
      ticket_created_at: nil
    }

    body = URI.encode_query(%{
      "username" => user,
      "password" => password
    })

    with {:ok, response} <- http_post(client, "/api2/json/access/ticket", body),
         {:ok, data} <- Jason.decode(response.body),
         data = data["data"] do
      Logger.info("PBS: authenticated as #{user}")

      {:ok, %{
        client
        | ticket: data["ticket"],
          csrf_token: data["csrf-token"],
          ticket_created_at: DateTime.utc_now()
      }}
    else
      {:error, reason} ->
        Logger.error("PBS: authentication failed - #{inspect(reason)}")
        {:error, "Authentication failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Check if the current ticket is still valid (not expired).
  """
  @spec ticket_valid?(client) :: boolean()
  def ticket_valid?(%__MODULE__{ticket_created_at: nil}), do: false
  def ticket_valid?(%__MODULE__{ticket_created_at: created_at}) do
    seconds_elapsed = DateTime.diff(DateTime.utc_now(), created_at)
    seconds_elapsed < @auth_timeout
  end

  @doc """
  List all backup groups in a datastore.

  Returns list of backup group metadata.
  """
  @spec list_backups(client, String.t()) :: list_response
  def list_backups(client, datastore) do
    unless ticket_valid?(client) do
      return_error("Ticket expired")
    end

    path = "/api2/json/admin/datastore/#{datastore}/backup-groups"

    with {:ok, response} <- http_get(client, path),
         {:ok, data} <- Jason.decode(response.body) do
      Logger.debug("PBS: listed #{length(data["data"] || [])} backups in #{datastore}")
      {:ok, data["data"] || []}
    else
      {:error, reason} ->
        Logger.error("PBS: list_backups failed - #{inspect(reason)}")
        {:error, "Failed to list backups: #{inspect(reason)}"}
    end
  end

  @doc """
  Get details about a specific backup.
  """
  @spec get_backup(client, String.t(), String.t()) :: backup_response
  def get_backup(client, datastore, backup_id) do
    unless ticket_valid?(client) do
      return_error("Ticket expired")
    end

    path = "/api2/json/admin/datastore/#{datastore}/backup-groups/#{backup_id}"

    with {:ok, response} <- http_get(client, path),
         {:ok, data} <- Jason.decode(response.body) do
      {:ok, data["data"]}
    else
      {:error, reason} ->
        Logger.error("PBS: get_backup failed - #{inspect(reason)}")
        {:error, "Failed to get backup: #{inspect(reason)}"}
    end
  end

  @doc """
  Start a new backup in a datastore.

  Parameters:
    - backup_id: identifier like "vm-100/2026-01-15T12:00:00Z"
    - data: binary content to back up
    - options: %{
        encryption: "none" | "aes256",
        compress: "none" | "zstd"
      }
  """
  @spec create_backup(client, String.t(), String.t(), binary(), map()) :: backup_response
  def create_backup(client, datastore, backup_id, data, options \\ %{}) do
    unless ticket_valid?(client) do
      return_error("Ticket expired")
    end

    path = "/api2/json/admin/datastore/#{datastore}/backup-groups"
    body = Jason.encode!(%{
      "backup-id" => backup_id,
      "data" => Base.encode64(data),
      "encryption" => Map.get(options, :encryption, "none"),
      "compress" => Map.get(options, :compress, "none")
    })

    with {:ok, response} <- http_post(client, path, body),
         {:ok, data} <- Jason.decode(response.body) do
      Logger.info("PBS: backup created #{backup_id}")
      {:ok, data["data"]}
    else
      {:error, reason} ->
        Logger.error("PBS: create_backup failed - #{inspect(reason)}")
        {:error, "Failed to create backup: #{inspect(reason)}"}
    end
  end

  @doc """
  Delete a backup.
  """
  @spec delete_backup(client, String.t(), String.t()) :: {:ok, nil} | {:error, String.t()}
  def delete_backup(client, datastore, backup_id) do
    unless ticket_valid?(client) do
      return_error("Ticket expired")
    end

    path = "/api2/json/admin/datastore/#{datastore}/backup-groups/#{backup_id}"

    with {:ok, _response} <- http_delete(client, path) do
      Logger.info("PBS: backup deleted #{backup_id}")
      {:ok, nil}
    else
      {:error, reason} ->
        Logger.error("PBS: delete_backup failed - #{inspect(reason)}")
        {:error, "Failed to delete backup: #{inspect(reason)}"}
    end
  end

  @doc """
  Get PBS server version and info.
  """
  @spec version(client) :: {:ok, map()} | {:error, String.t()}
  def version(client) do
    with {:ok, response} <- http_get(client, "/api2/json/version"),
         {:ok, data} <- Jason.decode(response.body) do
      {:ok, data["data"]}
    else
      {:error, reason} ->
        {:error, "Failed to get version: #{inspect(reason)}"}
    end
  end

  @doc """
  Get datastore info (size, usage, etc).
  """
  @spec datastore_info(client, String.t()) :: {:ok, map()} | {:error, String.t()}
  def datastore_info(client, datastore) do
    unless ticket_valid?(client) do
      return_error("Ticket expired")
    end

    path = "/api2/json/admin/datastore/#{datastore}/status"

    with {:ok, response} <- http_get(client, path),
         {:ok, data} <- Jason.decode(response.body) do
      {:ok, data["data"]}
    else
      {:error, reason} ->
        {:error, "Failed to get datastore info: #{inspect(reason)}"}
    end
  end

  # HTTP Helpers

  defp http_get(client, path) do
    url = "https://#{client.host}:#{client.port}#{path}"
    headers = auth_headers(client)

    HTTPoison.get(url, headers, timeout: @http_timeout, ssl: [verify: :verify_none])
    |> handle_response()
  end

  defp http_post(client, path, body) do
    url = "https://#{client.host}:#{client.port}#{path}"
    headers = auth_headers(client) ++ [{"Content-Type", "application/x-www-form-urlencoded"}]

    HTTPoison.post(url, body, headers, timeout: @http_timeout, ssl: [verify: :verify_none])
    |> handle_response()
  end

  defp http_delete(client, path) do
    url = "https://#{client.host}:#{client.port}#{path}"
    headers = auth_headers(client)

    HTTPoison.delete(url, headers, timeout: @http_timeout, ssl: [verify: :verify_none])
    |> handle_response()
  end

  defp auth_headers(%__MODULE__{ticket: nil}), do: []
  defp auth_headers(%__MODULE__{ticket: ticket, csrf_token: csrf}) do
    [
      {"Authorization", "PVEAuthCookie=#{ticket}"},
      {"X-CSRF-Token", csrf}
    ]
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 200} = response}), do: {:ok, response}
  defp handle_response({:ok, %HTTPoison.Response{status_code: 400} = response}) do
    {:error, "Bad request: #{response.body}"}
  end
  defp handle_response({:ok, %HTTPoison.Response{status_code: 401} = response}) do
    {:error, "Unauthorized: #{response.body}"}
  end
  defp handle_response({:ok, %HTTPoison.Response{status_code: 403} = response}) do
    {:error, "Forbidden: #{response.body}"}
  end
  defp handle_response({:ok, %HTTPoison.Response{status_code: 404} = response}) do
    {:error, "Not found: #{response.body}"}
  end
  defp handle_response({:ok, %HTTPoison.Response{status_code: status} = response}) do
    {:error, "HTTP #{status}: #{response.body}"}
  end
  defp handle_response({:error, reason}), do: {:error, reason}

  defp return_error(msg), do: {:error, msg}
end
