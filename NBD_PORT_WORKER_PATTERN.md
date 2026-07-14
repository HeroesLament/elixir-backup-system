# NBD Port Worker Pattern for EBS Backup Jobs

## Overview

When a backup job starts, EBS needs to:
1. **Spawn an NBD port worker** - dedicated process for that job's disk I/O
2. **Manage the port** - lifecycle, cleanup, error handling
3. **Coordinate with metadata** - track chunks, snapshots, dedup
4. **Scale to multiple jobs** - one port worker per concurrent backup

This pattern uses Erlang port drivers: spawn `ebs-nbd-daemon` as a subprocess, communicate via Unix socket + length-prefixed JSON/ETF.

---

## Architecture

```
┌────────────────────────────────────┐
│  EBS.Backup.Supervisor             │
│  (manages backup jobs)             │
│                                    │
│  ┌──────────────────────────────┐  │
│  │ EBS.Backup.JobSupervisor     │  │
│  │ (one per backup job)         │  │
│  │                              │  │
│  │ ┌────────────────────────┐   │  │
│  │ │ EBS.NBD.PortWorker     │   │  │
│  │ │ (read blocks via RPC)  │   │  │
│  │ └────────────────────────┘   │  │
│  │ ┌────────────────────────┐   │  │
│  │ │ EBS.Metadata.Service   │   │  │
│  │ │ (record snapshots)     │   │  │
│  │ └────────────────────────┘   │  │
│  │ ┌────────────────────────┐   │  │
│  │ │ EBS.Storage.ChunkStore │   │  │
│  │ │ (write chunks)         │   │  │
│  │ └────────────────────────┘   │  │
│  └──────────────────────────────┘  │
│                                    │
└────────────────────────────────────┘
         ↓ (spawns)
┌────────────────────────────────────┐
│ ebs-nbd-daemon (Rust/Tokio)        │
│ (one per backup job)               │
│ Listens on:                        │
│  /tmp/ebs-nbd-backup-{job_id}.sock │
└────────────────────────────────────┘
         ↓ (reads)
/var/lib/vz/images/{vmid}/vm-{vmid}-disk-*.qcow2
```

---

## Flow: Single Backup Job

### 1. Job Starts

```elixir
iex> EBS.Backup.Agent.backup_vm("virt-2", 100, datastore: "local")
```

### 2. Supervisor Spawns NBD Port Worker

```elixir
defmodule EBS.Backup.JobSupervisor do
  def start_backup(node, vmid, opts) do
    job_id = "backup-#{node}-#{vmid}-#{System.monotonic_time()}"
    
    children = [
      {EBS.NBD.PortWorker, 
        [job_id: job_id, node: node, vmid: vmid, disk: "0"]},
      {EBS.Metadata.Service, []},
      {EBS.Storage.ChunkStore, []},
    ]
    
    {:ok, sup_pid} = Supervisor.start_link(children, strategy: :rest_for_one)
    {:ok, sup_pid, job_id}
  end
end
```

### 3. Port Worker Spawns Daemon

```elixir
defmodule EBS.NBD.PortWorker do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:job_id]))
  end
  
  def init(opts) do
    job_id = opts[:job_id]
    node = opts[:node]
    vmid = opts[:vmid]
    disk = opts[:disk]
    
    socket_path = "/tmp/ebs-nbd-#{job_id}.sock"
    daemon_bin = "/usr/local/bin/ebs-nbd-daemon"
    
    # Spawn daemon as port driver
    cmd = "#{daemon_bin} --socket #{socket_path} --node #{node} --vmid #{vmid} --disk #{disk}"
    port = Port.open({:spawn, cmd}, [:binary, {:packet, 4}])
    
    Logger.info("NBD: spawned daemon for job #{job_id} on #{socket_path}")
    
    {:ok, %{
      job_id: job_id,
      port: port,
      socket_path: socket_path,
      node: node,
      vmid: vmid,
      disk: disk,
      chunk_count: 0,
      bytes_read: 0
    }}
  end
  
  def read_block(job_id, offset, size) do
    GenServer.call(via_tuple(job_id), {:read_block, offset, size}, 60_000)
  end
  
  def stats(job_id) do
    GenServer.call(via_tuple(job_id), :stats)
  end
  
  # Handle RPC calls to daemon
  def handle_call({:read_block, offset, size}, from, state) do
    request = %{
      "method" => "read_blocks",
      "args" => [state.node, state.vmid, state.disk, offset, size]
    }
    
    request_json = Jason.encode!(request)
    request_bytes = :binary.encode_unsigned(byte_size(request_json)) <> request_json
    
    Port.command(state.port, request_bytes)
    
    {:noreply, %{state | pending_request: from}}
  end
  
  # Handle daemon response
  def handle_info({port, {:data, response_bytes}}, %{port: port, pending_request: from} = state) do
    case parse_response(response_bytes) do
      {:ok, chunk} ->
        GenServer.reply(from, {:ok, chunk})
        
        new_state = state
          |> Map.put(:chunk_count, state.chunk_count + 1)
          |> Map.put(:bytes_read, state.bytes_read + chunk.size)
          |> Map.put(:pending_request, nil)
        
        {:noreply, new_state}
      
      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        {:noreply, %{state | pending_request: nil}}
    end
  end
  
  # Handle daemon crash
  def handle_info({port, :closed}, %{port: port, job_id: job_id} = state) do
    Logger.error("NBD: daemon crashed for job #{job_id}")
    {:stop, :daemon_crashed, state}
  end
  
  def terminate(_reason, state) do
    Port.close(state.port)
    File.rm(state.socket_path)
    Logger.info("NBD: cleaned up daemon for job #{state.job_id}")
  end
  
  defp via_tuple(job_id) do
    {:via, Registry, {EBS.Registry, "nbd-#{job_id}"}}
  end
  
  defp parse_response(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"status" => "ok", "data" => data}} ->
        {:ok, %{
          sha256: data["sha256"],
          offset: data["offset"],
          size: data["size"],
          data: Base.decode64!(data["data"])
        }}
      
      {:ok, %{"status" => "error", "reason" => reason}} ->
        {:error, reason}
      
      {:error, e} ->
        {:error, "Failed to parse response: #{inspect(e)}"}
    end
  end
end
```

### 4. Backup Loop Reads Blocks

```elixir
defmodule EBS.Backup.Agent do
  def backup_vm(node, vmid, opts) do
    {:ok, _sup_pid, job_id} = 
      EBS.Backup.JobSupervisor.start_backup(node, vmid, opts)
    
    # Read disk in chunks
    disk_size = 10 * 1_073_741_824  # 10GB
    chunk_size = 65536
    
    chunks = 0..((disk_size - 1) // chunk_size)
    |> Stream.each(fn chunk_num ->
      offset = chunk_num * chunk_size
      size = min(chunk_size, disk_size - offset)
      
      case EBS.NBD.PortWorker.read_block(job_id, offset, size) do
        {:ok, chunk} ->
          # Store chunk
          {:ok, sha256} = EBS.Storage.ChunkStore.store_chunk(chunk.data)
          
          # Record in snapshot
          EBS.Metadata.Service.record_chunk(
            snapshot_id: snapshot_id,
            offset: chunk.offset,
            sha256: sha256,
            size: chunk.size
          )
        
        {:error, reason} ->
          Logger.error("NBD: read failed at offset #{offset}: #{reason}")
          raise "Backup failed"
      end
    end)
    |> Stream.run()
    
    # Finalize snapshot
    {:ok, snapshot} = EBS.Metadata.Service.finalize_snapshot(snapshot_id)
    
    {:ok, snapshot}
  end
end
```

### 5. Job Finishes, Supervisor Cleanup

```elixir
# When backup completes or fails, supervisor stops
Supervisor.stop(sup_pid)

# Triggers:
# - EBS.NBD.PortWorker.terminate/2
#   ├─ Closes port
#   ├─ Kills daemon process
#   └─ Removes socket file
# - EBS.Metadata.Service shutdown
# - EBS.Storage.ChunkStore shutdown
```

---

## Multi-Job Concurrency

```
Job 1: backup-virt-2-100-123456
  └─ /tmp/ebs-nbd-backup-virt-2-100-123456.sock
  └─ ebs-nbd-daemon (PID 12345)

Job 2: backup-virt-3-101-123457
  └─ /tmp/ebs-nbd-backup-virt-3-101-123457.sock
  └─ ebs-nbd-daemon (PID 12346)

Job 3: backup-virt-4-105-123458
  └─ /tmp/ebs-nbd-backup-virt-4-105-123458.sock
  └─ ebs-nbd-daemon (PID 12347)
```

Each job has:
- Isolated NBD daemon (can crash independently)
- Own socket file (no conflicts)
- Separate metrics (chunk count, bytes read)
- Shared chunk store (dedup across jobs)

---

## Error Handling

### Daemon Crash Mid-Job

```elixir
# If daemon dies while reading:
def handle_info({port, :closed}, state) do
  # Supervisor restarts the worker with exponential backoff
  # Job can retry reading from checkpoint
  {:stop, :daemon_crashed, state}
end
```

Supervisor strategy: `rest_for_one`
- If port worker dies → restart it + metadata service + chunk store
- If chunk store dies → restart chunk store only
- Max retries: 3
- Exponential backoff: 1s, 2s, 4s

### Read Timeout

```elixir
# RPC call to daemon times out after 60 seconds
def read_block(job_id, offset, size) do
  GenServer.call(via_tuple(job_id), {:read_block, offset, size}, 60_000)
  # Timeout → :timeout error → log + retry
end
```

### Partial Backup Recovery

```elixir
# If backup interrupted, restart from last chunk
def resume_backup(snapshot_id) do
  {:ok, snapshot} = EBS.Metadata.Service.get_snapshot(snapshot_id)
  last_chunk_offset = snapshot.chunks |> Enum.max_by(& &1.offset) |> Map.get(:offset)
  
  # Resume from last_chunk_offset + chunk_size
  backup_vm(node, vmid, opts, resume_from: last_chunk_offset)
end
```

---

## Port Worker Registration

```elixir
# In EBS.Application startup
children = [
  EBS.Repo,
  EBS.Metadata.Store,
  EBS.Storage.ChunkStore,
  {Registry, keys: :unique, name: EBS.Registry},  # Register port workers
  EBS.Backup.Supervisor,                           # Start backup jobs here
]
```

---

## Metrics & Monitoring

```elixir
defmodule EBS.NBD.PortWorker do
  def stats(job_id) do
    GenServer.call(via_tuple(job_id), :stats)
  end
end

# In handle_call
def handle_call(:stats, _from, state) do
  stats = %{
    job_id: state.job_id,
    chunks_read: state.chunk_count,
    bytes_read: state.bytes_read,
    uptime: System.monotonic_time() - state.started_at,
    daemon_pid: state.daemon_pid,
    socket_path: state.socket_path
  }
  
  {:reply, stats, state}
end

# Usage
iex> EBS.NBD.PortWorker.stats("backup-virt-2-100-123456")
%{
  job_id: "backup-virt-2-100-123456",
  chunks_read: 153600,
  bytes_read: 10737418240,
  uptime: 45_000_000_000,  # ~45 seconds (monotonic time)
  daemon_pid: 12345,
  socket_path: "/tmp/ebs-nbd-backup-virt-2-100-123456.sock"
}
```

---

## Daemon Startup Args

The Rust daemon accepts:

```bash
ebs-nbd-daemon \
  --socket /tmp/ebs-nbd-backup-virt-2-100-123456.sock \
  --node virt-2 \
  --vmid 100 \
  --disk 0 \
  --log-level debug
```

This allows the daemon to be independent - it doesn't know about Elixir, just:
1. Listen on socket
2. Accept RPC calls
3. Read from disk
4. Return JSON responses

---

## Implementation Checklist

- [ ] Update `ebs-nbd-daemon` to accept command-line args (--socket, --node, --vmid, --disk)
- [ ] Create `EBS.NBD.PortWorker` GenServer with lifecycle management
- [ ] Create `EBS.Backup.JobSupervisor` to spawn job-specific supervisors
- [ ] Integrate `EBS.NBD.PortWorker.read_block/3` into backup loop
- [ ] Add metrics collection (chunk_count, bytes_read, uptime)
- [ ] Error handling for daemon crashes + retry logic
- [ ] Registry for multi-job tracking
- [ ] Integration tests: parallel backup jobs, daemon crashes, recovery

---

## Summary

**Pattern: One NBD port worker per backup job**

```
Backup Job Start
  ├─ Spawn Job Supervisor
  │   ├─ Spawn NBD Port Worker
  │   │   └─ Spawn Rust daemon process
  │   ├─ Metadata Service
  │   └─ Chunk Store
  └─ Read loop: PortWorker.read_block() → store → metadata

Error: Daemon crashes
  └─ Supervisor restarts Port Worker (auto-retry)

Backup finishes
  └─ Supervisor stops
      ├─ Kill daemon
      ├─ Remove socket
      └─ Cleanup
```

This keeps jobs isolated, allows parallel backups, handles failures gracefully, and scales to dozens of concurrent jobs.

