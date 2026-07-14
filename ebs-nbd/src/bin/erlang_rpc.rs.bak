/// Erlang RPC over Unix sockets
///
/// Listens on a Unix socket and handles RPC calls encoded in ETF format.
/// This bridges between Elixir's :rpc.call and Rust async handlers.

use anyhow::{anyhow, Result};
use std::path::Path;
use tokio::net::UnixListener;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tracing::{info, error, debug};

pub struct RpcServer {
    socket_path: String,
}

impl RpcServer {
    pub fn new(socket_path: &str) -> Result<Self> {
        // Remove existing socket if it exists
        if Path::new(socket_path).exists() {
            std::fs::remove_file(socket_path)?;
        }

        Ok(Self {
            socket_path: socket_path.to_string(),
        })
    }

    pub async fn run(&self) -> Result<()> {
        let listener = UnixListener::bind(&self.socket_path)?;

        loop {
            let (mut socket, _) = listener.accept().await?;
            let socket_path = self.socket_path.clone();

            tokio::spawn(async move {
                if let Err(e) = handle_connection(&mut socket).await {
                    error!("RPC handler error: {}", e);
                }
            });
        }
    }
}

async fn handle_connection(socket: &mut tokio::net::UnixStream) -> Result<()> {
    // Read request (length-prefixed)
    let mut len_buf = [0u8; 4];
    socket.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;

    let mut request_buf = vec![0u8; len];
    socket.read_exact(&mut request_buf).await?;

    debug!("RPC request received, {} bytes", len);

    // Parse ETF request
    let response = match parse_rpc_request(&request_buf) {
        Ok((method, args)) => {
            debug!("RPC call: {} with {} args", method, args.len());
            handle_rpc_call(&method, &args).await
        }
        Err(e) => {
            error!("Failed to parse RPC request: {}", e);
            format_error_response(&format!("Parse error: {}", e))
        }
    };

    // Send response (length-prefixed)
    let response_bytes = response.into_bytes();
    let len = response_bytes.len() as u32;
    socket.write_all(&len.to_be_bytes()).await?;
    socket.write_all(&response_bytes).await?;

    Ok(())
}

fn parse_rpc_request(data: &[u8]) -> Result<(String, Vec<String>)> {
    // TODO: Parse ETF format
    // For now, expect simple JSON format: {"method": "read_blocks", "args": [...]}
    let json: serde_json::Value = serde_json::from_slice(data)?;

    let method = json
        .get("method")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("Missing method"))?
        .to_string();

    let args = json
        .get("args")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("Missing args"))?
        .iter()
        .map(|v| v.to_string())
        .collect();

    Ok((method, args))
}

async fn handle_rpc_call(method: &str, args: &[String]) -> String {
    match method {
        "read_blocks" => {
            if args.len() < 5 {
                return format_error_response("read_blocks requires 5 args");
            }

            let node = args[0].clone();
            let vmid = args[1].clone();
            let disk = args[2].clone();
            let offset = args[3].clone();
            let size = args[4].clone();

            debug!(
                "read_blocks: node={}, vmid={}, disk={}, offset={}, size={}",
                node, vmid, disk, offset, size
            );

            // TODO: Call actual read_blocks handler
            format_ok_response(&format!(
                "{{\"sha256\": \"stub\", \"data\": \"base64-stub\"}}"
            ))
        }

        "query_bitmap" => {
            if args.len() < 3 {
                return format_error_response("query_bitmap requires 3 args");
            }

            let node = args[0].clone();
            let vmid = args[1].clone();
            let disk = args[2].clone();

            debug!("query_bitmap: node={}, vmid={}, disk={}", node, vmid, disk);

            // TODO: Call actual query_bitmap handler
            format_error_response("Not yet implemented")
        }

        "ping" => format_ok_response("pong"),

        _ => format_error_response(&format!("Unknown method: {}", method)),
    }
}

fn format_ok_response(data: &str) -> String {
    format!(
        "{{\"status\": \"ok\", \"data\": {}}}",
        data
    )
}

fn format_error_response(reason: &str) -> String {
    format!(
        "{{\"status\": \"error\", \"reason\": \"{}\"}}",
        reason.replace("\"", "\\\"")
    )
}
