//! EBS NBD Sidecar Library
//!
//! Provides:
//! - Erlang Distribution Protocol (EDP) node support via Unix socket RPC
//! - GenServer-like RPC interface exposed to Elixir
//! - NBD block reading (direct, LAN, WAN transports)
//! - SHA256 chunk computation
//! - SSH tunnel orchestration for QMP/CBT queries

pub mod nbd;
pub mod rpc;
pub mod ssh;
pub mod chunk;
pub mod erlang_rpc;

pub use nbd::NBDClient;
pub use rpc::RpcHandler;
pub use chunk::ChunkComputer;
pub use nbd::Transport;
