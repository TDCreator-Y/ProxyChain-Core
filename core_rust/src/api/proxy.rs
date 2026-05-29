use serde::{Deserialize, Serialize};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::OnceLock;
use tokio::io::{self, AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::runtime::Runtime;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ProxyProtocol {
    Shadowsocks,
    Trojan,
    Socks5,
    Vmess,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyNode {
    pub id: String,
    pub name: String,
    pub protocol: ProxyProtocol,
    pub server: String,
    pub port: u16,
    pub password: String,
    pub cipher: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyChain {
    pub entry_node: ProxyNode,
    pub exit_node: ProxyNode,
}

static TOKIO_RUNTIME: OnceLock<Runtime> = OnceLock::new();

#[flutter_rust_bridge::frb(sync)]
pub fn create_mock_chain() -> ProxyChain {
    ProxyChain {
        entry_node: ProxyNode {
            id: "node_entry_01".to_string(),
            name: "HK-Entry-Node".to_string(),
            protocol: ProxyProtocol::Socks5,
            server: "127.0.0.1".to_string(),
            port: 1081,
            password: "super_secret_entry".to_string(),
            cipher: None,
        },
        exit_node: ProxyNode {
            id: "node_exit_02".to_string(),
            name: "US-Exit-Node".to_string(),
            protocol: ProxyProtocol::Socks5,
            server: "127.0.0.1".to_string(),
            port: 1082,
            password: "super_secret_exit".to_string(),
            cipher: Some("test-socks5".to_string()),
        },
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn start_local_proxy(chain: ProxyChain, local_port: u16) -> Result<(), String> {
    validate_proxy_node(&chain.entry_node)?;
    validate_proxy_node(&chain.exit_node)?;
    validate_proxy_protocol(&chain.entry_node)?;
    validate_proxy_protocol(&chain.exit_node)?;

    let runtime = TOKIO_RUNTIME
        .get_or_init(|| Runtime::new().expect("failed to create tokio runtime for local proxy"));

    let listener =
        runtime.block_on(bind_local_listener(local_port))?;

    runtime.spawn(async move {
        if let Err(err) = run_local_proxy(listener, chain).await {
            eprintln!("local proxy stopped: {err}");
        }
    });

    Ok(())
}

async fn bind_local_listener(local_port: u16) -> Result<TcpListener, String> {
    let listen_addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), local_port);
    TcpListener::bind(listen_addr)
        .await
        .map_err(|err| format!("failed to bind local listener on {listen_addr}: {err}"))
}

async fn run_local_proxy(listener: TcpListener, chain: ProxyChain) -> Result<(), String> {
    loop {
        let (inbound, _) = listener
            .accept()
            .await
            .map_err(|err| format!("failed to accept inbound client: {err}"))?;
        let chain = chain.clone();

        tokio::spawn(async move {
            if let Err(err) = handle_inbound_client(inbound, chain).await {
                eprintln!("proxy session failed: {err}");
            }
        });
    }
}

async fn handle_inbound_client(mut inbound: TcpStream, chain: ProxyChain) -> Result<(), String> {
    let requested_target = socks5_accept_client(&mut inbound).await?;
    let mut nested_stream = connect_via_chain(&chain, &requested_target).await?;

    io::copy_bidirectional(&mut inbound, &mut nested_stream)
        .await
        .map_err(|err| format!("bidirectional copy failed: {err}"))?;

    Ok(())
}

async fn connect_via_chain(
    chain: &ProxyChain,
    requested_target: &TargetAddr,
) -> Result<TcpStream, String> {
    let mut entry_stream = connect_to_proxy_node(&chain.entry_node).await?;

    socks5_connect(
        &mut entry_stream,
        &TargetAddr::Domain(chain.exit_node.server.clone(), chain.exit_node.port),
    )
    .await?;

    socks5_connect(&mut entry_stream, requested_target).await?;
    Ok(entry_stream)
}

async fn connect_to_proxy_node(node: &ProxyNode) -> Result<TcpStream, String> {
    let addr = format!("{}:{}", node.server, node.port);
    let mut stream = TcpStream::connect(&addr)
        .await
        .map_err(|err| format!("failed to connect to proxy node {} ({}): {err}", node.name, addr))?;

    socks5_handshake(&mut stream).await?;
    Ok(stream)
}

fn validate_proxy_node(node: &ProxyNode) -> Result<(), String> {
    if node.server.trim().is_empty() {
        return Err(format!("proxy node {} has empty server", node.name));
    }
    if node.port == 0 {
        return Err(format!("proxy node {} has invalid port 0", node.name));
    }
    Ok(())
}

fn validate_proxy_protocol(node: &ProxyNode) -> Result<(), String> {
    match node.protocol {
        ProxyProtocol::Socks5 => Ok(()),
        _ => Err(format!(
            "protocol {:?} is not implemented yet; only Socks5 is supported as a test stub",
            node.protocol
        )),
    }
}

#[derive(Debug, Clone)]
enum TargetAddr {
    Ip(SocketAddr),
    Domain(String, u16),
}

async fn socks5_accept_client(stream: &mut TcpStream) -> Result<TargetAddr, String> {
    let version = stream
        .read_u8()
        .await
        .map_err(|err| format!("failed to read client socks version: {err}"))?;
    if version != 5 {
        return Err(format!("unsupported socks version from client: {version}"));
    }

    let method_count = stream
        .read_u8()
        .await
        .map_err(|err| format!("failed to read auth method count: {err}"))?;
    let mut methods = vec![0u8; method_count as usize];
    stream
        .read_exact(&mut methods)
        .await
        .map_err(|err| format!("failed to read auth methods: {err}"))?;

    if !methods.contains(&0x00) {
        return Err("client does not support no-auth socks5".to_string());
    }

    stream
        .write_all(&[0x05, 0x00])
        .await
        .map_err(|err| format!("failed to reply socks handshake: {err}"))?;

    let request = read_socks5_frame(stream).await?;
    if request.command != 0x01 {
        return Err(format!(
            "unsupported socks command from client: {}",
            request.command
        ));
    }

    stream
        .write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        .await
        .map_err(|err| format!("failed to send socks connect response: {err}"))?;

    Ok(request.target)
}

async fn socks5_handshake(stream: &mut TcpStream) -> Result<(), String> {
    stream
        .write_all(&[0x05, 0x01, 0x00])
        .await
        .map_err(|err| format!("failed to send upstream socks handshake: {err}"))?;

    let version = stream
        .read_u8()
        .await
        .map_err(|err| format!("failed to read upstream socks version: {err}"))?;
    let method = stream
        .read_u8()
        .await
        .map_err(|err| format!("failed to read upstream auth method: {err}"))?;

    if version != 5 {
        return Err(format!("unsupported upstream socks version: {version}"));
    }
    if method != 0x00 {
        return Err(format!("upstream socks auth method {method} is not supported"));
    }

    Ok(())
}

async fn socks5_connect(stream: &mut TcpStream, target: &TargetAddr) -> Result<(), String> {
    let mut request = vec![0x05, 0x01, 0x00];
    match target {
        TargetAddr::Ip(SocketAddr::V4(addr)) => {
            request.push(0x01);
            request.extend_from_slice(&addr.ip().octets());
            request.extend_from_slice(&addr.port().to_be_bytes());
        }
        TargetAddr::Ip(SocketAddr::V6(addr)) => {
            request.push(0x04);
            request.extend_from_slice(&addr.ip().octets());
            request.extend_from_slice(&addr.port().to_be_bytes());
        }
        TargetAddr::Domain(host, port) => {
            if host.len() > u8::MAX as usize {
                return Err(format!("target host is too long for socks5: {host}"));
            }
            request.push(0x03);
            request.push(host.len() as u8);
            request.extend_from_slice(host.as_bytes());
            request.extend_from_slice(&port.to_be_bytes());
        }
    }

    stream
        .write_all(&request)
        .await
        .map_err(|err| format!("failed to send upstream connect request: {err}"))?;

    let response = read_socks5_frame(stream).await?;
    if response.command != 0x00 {
        return Err(format!(
            "upstream socks connect failed with reply code {}",
            response.command
        ));
    }

    Ok(())
}

struct Socks5Frame {
    command: u8,
    target: TargetAddr,
}

async fn read_socks5_frame(stream: &mut TcpStream) -> Result<Socks5Frame, String> {
    let version = stream
        .read_u8()
        .await
        .map_err(|err| format!("failed to read socks frame version: {err}"))?;
    if version != 5 {
        return Err(format!("unsupported socks frame version: {version}"));
    }

    let command = stream
        .read_u8()
        .await
        .map_err(|err| format!("failed to read socks command: {err}"))?;
    let _reserved = stream
        .read_u8()
        .await
        .map_err(|err| format!("failed to read socks reserved byte: {err}"))?;
    let addr_type = stream
        .read_u8()
        .await
        .map_err(|err| format!("failed to read socks address type: {err}"))?;

    let target = match addr_type {
        0x01 => {
            let mut octets = [0u8; 4];
            stream
                .read_exact(&mut octets)
                .await
                .map_err(|err| format!("failed to read ipv4 target: {err}"))?;
            let port = stream
                .read_u16()
                .await
                .map_err(|err| format!("failed to read ipv4 target port: {err}"))?;
            TargetAddr::Ip(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(octets)), port))
        }
        0x03 => {
            let host_len = stream
                .read_u8()
                .await
                .map_err(|err| format!("failed to read domain length: {err}"))?;
            let mut host = vec![0u8; host_len as usize];
            stream
                .read_exact(&mut host)
                .await
                .map_err(|err| format!("failed to read domain target: {err}"))?;
            let port = stream
                .read_u16()
                .await
                .map_err(|err| format!("failed to read domain target port: {err}"))?;
            let host =
                String::from_utf8(host).map_err(|err| format!("invalid utf8 in domain target: {err}"))?;
            TargetAddr::Domain(host, port)
        }
        0x04 => {
            let mut octets = [0u8; 16];
            stream
                .read_exact(&mut octets)
                .await
                .map_err(|err| format!("failed to read ipv6 target: {err}"))?;
            let port = stream
                .read_u16()
                .await
                .map_err(|err| format!("failed to read ipv6 target port: {err}"))?;
            TargetAddr::Ip(SocketAddr::new(IpAddr::from(octets), port))
        }
        other => return Err(format!("unsupported socks address type: {other}")),
    };

    Ok(Socks5Frame { command, target })
}
