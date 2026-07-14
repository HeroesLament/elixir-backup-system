/// EBS NBD Daemon - Erlang Distribution Bridge
///
/// Runs as a separate Tokio sidecar process, communicating with EBS (Elixir)
/// via Unix socket RPC with JSON payloads.
///
/// Elixir calls this via a port driver or direct Unix socket:
///   read_blocks(Node, VMID, Disk, Offset, Size) -> {ok, Chunk} | {error, Reason}

use anyhow::Result;
use tracing::info;
use ebs_nbd::erlang_rpc::RpcServer;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::DEBUG)
        .with_target(false)
        .with_thread_ids(false)
        .init();

    info!("╔════════════════════════════════════════╗");
    info!("║ EBS NBD Daemon v0.1.0                  ║");
    info!("║ Erlang Distribution Bridge             ║");
    info!("╚════════════════════════════════════════╝");

    let socket_path = "/tmp/ebs-nbd-daemon.sock";
    let server = RpcServer::new(socket_path)?;

    info!("Listening on Unix socket: {}", socket_path);
    info!("Node name: ebs-nbd@127.0.0.1");
    info!("");
    info!("Ready for RPC calls from Elixir");
    info!("Example: :rpc.call(:'ebs-nbd@127.0.0.1', EbsNBD, :read_blocks, [\"virt-2\", 999, \"0\", 0, 65536])");
    info!("");

    server.run().await?;

    Ok(())
}
