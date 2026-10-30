//! The MCP server's socket: on this computer only, at the same address as the Mac's (`MCP.url` in
//! Joinery/MCP/Protocol/MCP.swift). Everything else, from HTTP to the tools, is the core's: each request's bytes go to
//! the window, which hands them to the core, and its answer comes back through `mcp_respond`.

use base64::{engine::general_purpose::STANDARD, Engine};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tauri::{AppHandle, Emitter};

/// The Mac's port, or `JOINERY_MCP_PORT`'s, to run beside a Mac copy while testing.
fn port() -> u16 {
    std::env::var("JOINERY_MCP_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(8723)
}

/// Responses awaited, by request.
fn waiting() -> &'static Mutex<HashMap<u64, Sender<Vec<u8>>>> {
    static WAITING: OnceLock<Mutex<HashMap<u64, Sender<Vec<u8>>>>> = OnceLock::new();
    WAITING.get_or_init(Default::default)
}

static STARTED: OnceLock<Result<(), String>> = OnceLock::new();

/// Starts listening, once; says why it couldn't, usually something else on the port.
#[tauri::command]
pub fn mcp_start(app: AppHandle) -> Result<(), String> {
    STARTED
        .get_or_init(|| {
            let listener = TcpListener::bind(("127.0.0.1", port())).map_err(|e| {
                if e.kind() == std::io::ErrorKind::AddrInUse {
                    format!("Port {} is in use by another app, perhaps another copy of Joinery.", port())
                } else {
                    e.to_string()
                }
            })?;
            std::thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    let app = app.clone();
                    std::thread::spawn(move || serve(stream, app));
                }
            });
            Ok(())
        })
        .clone()
}

#[derive(Clone, serde::Serialize)]
struct Request {
    id: u64,
    request: String,
}

fn serve(mut stream: TcpStream, app: AppHandle) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let Some(request) = read_request(&mut stream) else { return };
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let (send, receive) = channel();
    waiting().lock().unwrap().insert(id, send);
    if app.emit("mcp-request", Request { id, request: STANDARD.encode(&request) }).is_err() {
        waiting().lock().unwrap().remove(&id);
        return;
    }
    // An assistant's call can take a while: starting to share waits on the relay.
    let response = receive.recv_timeout(Duration::from_secs(120)).unwrap_or_else(|_| {
        b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec()
    });
    waiting().lock().unwrap().remove(&id);
    let _ = stream.write_all(&response);
}

/// A whole request: its head, and as much body as it says it has, up to 8 MB.
fn read_request(stream: &mut TcpStream) -> Option<Vec<u8>> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 64 * 1024];
    loop {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            return None;
        }
        buffer.extend_from_slice(&chunk[..n]);
        if let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buffer[..end]).to_lowercase();
            let length = head
                .lines()
                .find_map(|line| line.strip_prefix("content-length:").and_then(|v| v.trim().parse::<usize>().ok()))
                .unwrap_or(0);
            if buffer.len() >= end + 4 + length {
                return Some(buffer);
            }
        }
        if buffer.len() > 8 << 20 {
            return None;
        }
    }
}

#[tauri::command]
pub fn mcp_respond(id: u64, response: String) {
    if let Some(send) = waiting().lock().unwrap().remove(&id) {
        let _ = send.send(STANDARD.decode(response).unwrap_or_default());
    }
}
