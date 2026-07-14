/// Erlang RPC over Unix sockets

use anyhow::{anyhow, Result};
use std::path::Path;
use tokio::net::UnixListener;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tracing::{debug, error};

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

    // Parse JSON request
    let response = match parse_rpc_request(&request_buf) {
        Ok((method, _args)) => {
            debug!("RPC call: {}", method);
            format_ok_response("stub")
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
