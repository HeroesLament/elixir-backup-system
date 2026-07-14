//! SSH Tunnel Manager - QMP over SSH for CBT queries
//!
//! Establishes SSH tunnels to Proxmox nodes for:
//! - QMP communication (query dirty bitmaps)
//! - NBD data plane forwarding (WAN transport)

use anyhow::Result;
use tracing::debug;

pub struct SSHTunnel {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub key_path: String,
}

impl SSHTunnel {
    pub fn new(host: String, user: String, key_path: String) -> Self {
        Self {
            host,
            port: 22,
            user,
            key_path,
        }
    }

    /// Open SSH tunnel for QMP communication
    pub async fn open_qmp_tunnel(&self) -> Result<()> {
        debug!(
            "SSH: opening QMP tunnel to {}@{} (not yet implemented)",
            self.user, self.host
        );
        // TODO: Use ssh2 crate to open tunnel
        Ok(())
    }

    /// Open SSH tunnel for NBD data plane
    pub async fn open_nbd_tunnel(&self, remote_port: u16, local_port: u16) -> Result<()> {
        debug!(
            "SSH: opening NBD tunnel to {}@{}:{} -> localhost:{} (not yet implemented)",
            self.user, self.host, remote_port, local_port
        );
        // TODO: Use ssh2 crate to forward port
        Ok(())
    }

    /// Execute QMP command via SSH
    pub async fn execute_qmp_command(&self, vmid: u32, command: &str) -> Result<String> {
        debug!(
            "SSH: executing QMP command on VM {} via {}@{} (not yet implemented)",
            vmid, self.user, self.host
        );
        // TODO: SSH to node, execute virsh qemu-monitor-command
        Ok("{}".to_string())
    }
}
