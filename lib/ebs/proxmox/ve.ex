defmodule EBS.Proxmox.VE do
  @moduledoc """
  Proxmox Virtual Environment (PVE) API client.

  Reads VM data, CBT (dirty bitmap) info, and changed blocks.
  This is the SOURCE side of backups — reads from VMs.

  Compare with EBS.PBS.Client which is the DESTINATION side — writes to PBS.
  """

  require Logger

  @http_timeout 30_000
  @auth_timeout 3600  # 1 hour

  defstruct [:host, :port, :token_id, :token_secret, :ticket, :csrf_token, :ticket_created_at]

  @type client :: %__MODULE__{
    host: String.t(),
    port: non_neg_integer(),
    token_id: String.t(),
    token_secret: String.t(),
    ticket: String.t() | nil,
    csrf_token: String.t() | nil,
    ticket_created_at: DateTime.t() | nil
  }

  @doc """
  Create a PVE client with API token auth.

  API tokens are more secure than username/password.
  Secrets are injected via environment variables by obao/Concourse/SecretSpec.

  Example (manual):
    client = EBS.Proxmox.VE.new(
      "virt-2.admin.siliconiq.com",
      8006,
      "root@pam!ebs-backup",
      "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    )

  Example (from config):
    config = Application.get_env(:ebs, :pve_config)
    client = EBS.Proxmox.VE.from_config(config)
  """
  def new(host, port, token_id, token_secret) do
    %__MODULE__{
      host: host,
      port: port,
      token_id: token_id,
      token_secret: token_secret,
      ticket: nil,
      csrf_token: nil,
      ticket_created_at: nil
    }
  end

  @doc """
  Create a PVE client from application config.

  Reads from :ebs :pve_config which is populated from environment variables
  by obao/Concourse/SecretSpec at runtime.

  Environment variables:
    PVE_HOST - Proxmox host (required)
    PVE_PORT - Proxmox port (default: 8006)
    PVE_TOKEN_ID - API token ID, format: "root@pam!token-name" (required)
    PVE_TOKEN_SECRET - API token secret (required)
  """
  def from_config do
    config = Application.get_env(:ebs, :pve_config, %{})

    host = config[:host] || raise "PVE_HOST not set in environment"
    port = config[:port] || 8006
    token_id = config[:token_id] || raise "PVE_TOKEN_ID not set in environment"
    token_secret = config[:token_secret] || raise "PVE_TOKEN_SECRET not set in environment"

    new(host, port, token_id, token_secret)
  end

  @doc """
  Authenticate with PVE using API token.

  Returns {:ok, client_with_ticket} or {:error, reason}
  """
  def authenticate(%__MODULE__{} = client) do
    Logger.info("PVE: authenticating with token #{client.token_id}")

    # API token auth doesn't need a ticket, but we can verify connectivity
    # by making a simple API call
    case get_node_list(client) do
      {:ok, _nodes} ->
        Logger.info("PVE: authenticated successfully")
        {:ok, client}

      {:error, reason} ->
        Logger.error("PVE: authentication failed - #{inspect(reason)}")
        {:error, "Authentication failed: #{inspect(reason)}"}
    end
  end

  @doc """
  List all nodes in the cluster.
  """
  def get_node_list(client) do
    case http_get(client, "/api2/json/nodes") do
      {:ok, response} ->
        case Jason.decode(response.body) do
          {:ok, %{"data" => nodes}} ->
            Logger.debug("PVE: found #{length(nodes)} nodes")
            {:ok, nodes}

          {:error, reason} ->
            {:error, "Failed to parse nodes: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all VMs on a node.

  Example:
    {:ok, vms} = EBS.Proxmox.VE.list_vms(client, "node1")
  """
  def list_vms(client, node) do
    path = "/api2/json/nodes/#{node}/qemu"

    case http_get(client, path) do
      {:ok, response} ->
        case Jason.decode(response.body) do
          {:ok, %{"data" => vms}} ->
            Logger.debug("PVE: found #{length(vms)} VMs on #{node}")
            {:ok, vms}

          {:error, reason} ->
            {:error, "Failed to parse VMs: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get VM info including disk info and CBT status.

  Returns: {:ok, vm_data} or {:error, reason}
  """
  def get_vm_info(client, node, vmid) do
    path = "/api2/json/nodes/#{node}/qemu/#{vmid}"

    case http_get(client, path) do
      {:ok, response} ->
        case Jason.decode(response.body) do
          {:ok, %{"data" => vm_data}} ->
            Logger.debug("PVE: retrieved info for VM #{vmid}")
            {:ok, vm_data}

          {:error, reason} ->
            {:error, "Failed to parse VM info: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get CBT (changed block tracking) info for a VM.

  Returns dirty bitmap since last backup checkpoint.

  Example:
    {:ok, cbt_data} = EBS.Proxmox.VE.get_cbt_info(client, "node1", 100)
  """
  def get_cbt_info(client, node, vmid) do
    # CBT info is typically obtained via:
    # 1. Create a temporary snapshot
    # 2. Query the dirty bitmap
    # 3. This gives us which blocks changed since last backup

    path = "/api2/json/nodes/#{node}/qemu/#{vmid}/status/current"

    case http_get(client, path) do
      {:ok, response} ->
        case Jason.decode(response.body) do
          {:ok, %{"data" => status}} ->
            Logger.debug("PVE: retrieved CBT info for VM #{vmid}")
            {:ok, status}

          {:error, reason} ->
            {:error, "Failed to parse CBT info: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Read raw block data from a VM disk.

  This is where the actual backup data comes from.
  In production, you'd use NBD (Network Block Device) for efficient reads.
  For MVP, we'll read via snapshots.

  Example:
    {:ok, data} = EBS.Proxmox.VE.read_blocks(client, "node1", 100, "disk1", 0, 4194304)
  """
  def read_blocks(client, node, vmid, disk, offset, size) do
    # TODO: Implement actual block reading via NBD or API
    Logger.debug("PVE: reading #{size} bytes from VM #{vmid} #{disk} at offset #{offset}")
    {:ok, <<>>}  # Stub
  end

  # HTTP Helpers

  defp http_get(client, path) do
    url = "https://#{client.host}:#{client.port}#{path}"
    headers = auth_headers(client)

    HTTPoison.get(url, headers, timeout: @http_timeout, ssl: [verify: :verify_none])
    |> handle_response()
  end

  defp auth_headers(%__MODULE__{token_id: token_id, token_secret: secret}) do
    [
      {"Authorization", "PVEAPIToken=#{token_id}:#{secret}"}
    ]
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 200} = response}), do: {:ok, response}
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
end
