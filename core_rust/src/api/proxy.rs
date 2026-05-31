use crate::frb_generated::StreamSink;
use serde::{Deserialize, Serialize};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::str::FromStr;
use std::sync::{Mutex, OnceLock};
use shadowsocks::{
    config::{ServerAddr as SsServerAddr, ServerConfig as SsServerConfig, ServerType as SsServerType},
    context::Context as SsContext,
    crypto::CipherKind,
    relay::{socks5::Address as SsAddress, tcprelay::proxy_stream::client::ProxyClientStream},
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

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

pub struct TrafficStatus {
    pub up: u64,
    pub down: u64,
}

pub enum TrafficMsg {
    Up(u64),
    Down(u64),
}

pub(crate) trait ProxyIoStream: AsyncRead + AsyncWrite + Unpin + Send {}

impl<T> ProxyIoStream for T where T: AsyncRead + AsyncWrite + Unpin + Send {}

pub(crate) type BoxProxyStream = Box<dyn ProxyIoStream>;

static TOKIO_RUNTIME: OnceLock<Runtime> = OnceLock::new();
static ENGINE_TASK: Mutex<Option<JoinHandle<()>>> = Mutex::new(None);

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
pub fn stop_engine() {
    crate::api::tun_proxy::stop_tun();
    if let Some(handle) = ENGINE_TASK.lock().unwrap().take() {
        handle.abort();
    }
}

pub fn start_engine(
    entry_node: ProxyNode,
    exit_node: ProxyNode,
    sink: StreamSink<TrafficStatus>,
) -> Result<(), String> {
    stop_engine();

    let chain = ProxyChain {
        entry_node,
        exit_node,
    };

    validate_proxy_node(&chain.entry_node)?;
    validate_proxy_node(&chain.exit_node)?;
    validate_entry_protocol(&chain.entry_node)?;
    validate_exit_protocol(&chain.exit_node)?;

    let runtime = TOKIO_RUNTIME
        .get_or_init(|| Runtime::new().expect("failed to create tokio runtime for local proxy"));

    let listener = runtime.block_on(bind_local_listener(1080))?;

    let (tx, mut rx) = mpsc::channel::<TrafficMsg>(10000);

    let handle = runtime.spawn(async move {
        let proxy_fut = run_local_proxy_with_metrics(listener, chain.clone(), tx.clone());
        let tun_fut = crate::api::tun_proxy::start_tun(chain, tx);
        
        let traffic_fut = async move {
            let mut current_up = 0;
            let mut current_down = 0;
            let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(1));

            loop {
                tokio::select! {
                    _ = interval.tick() => {
                        let _ = sink.add(TrafficStatus { up: current_up, down: current_down });
                        current_up = 0;
                        current_down = 0;
                    }
                    msg = rx.recv() => {
                        match msg {
                            Some(TrafficMsg::Up(bytes)) => current_up += bytes,
                            Some(TrafficMsg::Down(bytes)) => current_down += bytes,
                            None => break,
                        }
                    }
                }
            }
        };

        tokio::select! {
            res = proxy_fut => {
                if let Err(err) = res {
                    eprintln!("local proxy stopped: {err}");
                }
            }
            res = tun_fut => {
                if let Err(err) = res {
                    eprintln!("tun proxy stopped: {err}");
                }
            }
            _ = traffic_fut => {}
        }
    });

    *ENGINE_TASK.lock().unwrap() = Some(handle);

    Ok(())
}

async fn bind_local_listener(local_port: u16) -> Result<TcpListener, String> {
    let listen_addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), local_port);
    TcpListener::bind(listen_addr)
        .await
        .map_err(|err| format!("failed to bind local listener on {listen_addr}: {err}"))
}

async fn run_local_proxy_with_metrics(
    listener: TcpListener,
    chain: ProxyChain,
    tx: mpsc::Sender<TrafficMsg>,
) -> Result<(), String> {
    loop {
        let (inbound, _) = listener
            .accept()
            .await
            .map_err(|err| format!("failed to accept inbound client: {err}"))?;
        let chain = chain.clone();
        let tx = tx.clone();

        tokio::spawn(async move {
            if let Err(err) = handle_inbound_client_with_metrics(inbound, chain, tx).await {
                eprintln!("proxy session failed: {err}");
            }
        });
    }
}

async fn handle_inbound_client_with_metrics(
    mut inbound: TcpStream,
    chain: ProxyChain,
    tx: mpsc::Sender<TrafficMsg>,
) -> Result<(), String> {
    let requested_target = socks5_accept_client(&mut inbound).await?;
    let nested_stream = connect_via_chain(&chain, &requested_target).await?;

    let (mut ri, mut wi) = inbound.into_split();
    let (mut ro, mut wo) = tokio::io::split(nested_stream);

    let tx_up = tx.clone();
    let tx_down = tx.clone();

    let client_to_server = tokio::spawn(async move {
        let mut buf = vec![0u8; 8192];
        loop {
            let n = ri.read(&mut buf).await.unwrap_or(0);
            if n == 0 {
                break;
            }
            if wo.write_all(&buf[..n]).await.is_err() {
                break;
            }
            let _ = tx_up.send(TrafficMsg::Up(n as u64)).await;
        }
    });

    let server_to_client = tokio::spawn(async move {
        let mut buf = vec![0u8; 8192];
        loop {
            let n = ro.read(&mut buf).await.unwrap_or(0);
            if n == 0 {
                break;
            }
            if wi.write_all(&buf[..n]).await.is_err() {
                break;
            }
            let _ = tx_down.send(TrafficMsg::Down(n as u64)).await;
        }
    });

    let _ = tokio::try_join!(client_to_server, server_to_client);

    Ok(())
}

pub(crate) async fn connect_via_chain(
    chain: &ProxyChain,
    requested_target: &TargetAddr,
) -> Result<BoxProxyStream, String> {
    let exit_target = TargetAddr::Domain(chain.exit_node.server.clone(), chain.exit_node.port);
    let entry_addr = format!("{}:{}", chain.entry_node.server, chain.entry_node.port);
    let entry_tcp = TcpStream::connect(&entry_addr)
        .await
        .map_err(|err| {
            format!(
                "failed to connect to entry proxy node {} ({}): {err}",
                chain.entry_node.name, entry_addr
            )
        })?;
    let entry_stream = handshake_proxy(entry_tcp, &chain.entry_node, &exit_target).await?;
    handshake_proxy(entry_stream, &chain.exit_node, requested_target).await
}

async fn handshake_proxy<S>(
    mut stream: S,
    node: &ProxyNode,
    target: &TargetAddr,
) -> Result<BoxProxyStream, String>
where
    S: ProxyIoStream + 'static,
{
    match &node.protocol {
        ProxyProtocol::Socks5 => {
            socks5_handshake(&mut stream).await?;
            socks5_connect(&mut stream, target).await?;
            Ok(Box::new(stream))
        }
        ProxyProtocol::Shadowsocks => connect_to_shadowsocks_stream(stream, node, target),
        unsupported => Err(format!(
            "protocol {:?} is not implemented yet for proxy handshakes",
            unsupported
        )),
    }
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

fn validate_entry_protocol(node: &ProxyNode) -> Result<(), String> {
    match node.protocol {
        ProxyProtocol::Socks5 => Ok(()),
        ProxyProtocol::Shadowsocks => {
            let cipher = node
                .cipher
                .as_deref()
                .ok_or_else(|| format!("shadowsocks node {} is missing cipher", node.name))?;
            CipherKind::from_str(cipher)
                .map_err(|err| format!("invalid shadowsocks cipher for {}: {err}", node.name))?;
            if node.password.is_empty() {
                return Err(format!("shadowsocks node {} is missing password", node.name));
            }
            Ok(())
        }
        _ => Err(format!(
            "protocol {:?} is not implemented yet for entry nodes; only Socks5 and Shadowsocks are supported",
            node.protocol
        )),
    }
}

fn validate_exit_protocol(node: &ProxyNode) -> Result<(), String> {
    match node.protocol {
        ProxyProtocol::Socks5 => Ok(()),
        ProxyProtocol::Shadowsocks => {
            let cipher = node
                .cipher
                .as_deref()
                .ok_or_else(|| format!("shadowsocks node {} is missing cipher", node.name))?;
            CipherKind::from_str(cipher)
                .map_err(|err| format!("invalid shadowsocks cipher for {}: {err}", node.name))?;
            if node.password.is_empty() {
                return Err(format!("shadowsocks node {} is missing password", node.name));
            }
            Ok(())
        }
        _ => Err(format!(
            "protocol {:?} is not implemented yet for exit nodes; only Socks5 and Shadowsocks are supported",
            node.protocol
        )),
    }
}

#[derive(Debug, Clone)]
pub(crate) enum TargetAddr {
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

async fn socks5_handshake<S>(stream: &mut S) -> Result<(), String>
where
    S: AsyncRead + AsyncWrite + Unpin + ?Sized,
{
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

async fn socks5_connect<S>(stream: &mut S, target: &TargetAddr) -> Result<(), String>
where
    S: AsyncRead + AsyncWrite + Unpin + ?Sized,
{
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

async fn read_socks5_frame<S>(stream: &mut S) -> Result<Socks5Frame, String>
where
    S: AsyncRead + Unpin + ?Sized,
{
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

fn connect_to_shadowsocks_stream<S>(
    stream: S,
    node: &ProxyNode,
    target: &TargetAddr,
) -> Result<BoxProxyStream, String>
where
    S: ProxyIoStream + 'static,
{
    let cipher = node
        .cipher
        .as_deref()
        .ok_or_else(|| format!("shadowsocks node {} is missing cipher", node.name))?;
    let method = CipherKind::from_str(cipher)
        .map_err(|err| format!("invalid shadowsocks cipher for {}: {err}", node.name))?;
    let server_addr = SsServerAddr::from_str(&format!("{}:{}", node.server, node.port))
        .map_err(|err| format!("invalid shadowsocks server address for {}: {err}", node.name))?;
    let server_config = SsServerConfig::new(server_addr, node.password.clone(), method)
        .map_err(|err| format!("failed to build shadowsocks config for {}: {err}", node.name))?;
    let context = SsContext::new_shared(SsServerType::Local);
    let target_addr = to_shadowsocks_address(target);
    let stream = ProxyClientStream::from_stream(context, stream, &server_config, target_addr);
    Ok(Box::new(stream))
}

fn to_shadowsocks_address(target: &TargetAddr) -> SsAddress {
    match target {
        TargetAddr::Ip(addr) => SsAddress::SocketAddress(*addr),
        TargetAddr::Domain(host, port) => SsAddress::DomainNameAddress(host.clone(), *port),
    }
}

pub async fn test_chain_latency(entry: ProxyNode, exit: ProxyNode) -> Result<i32, String> {
    let chain = ProxyChain {
        entry_node: entry,
        exit_node: exit,
    };
    
    let start_time = std::time::Instant::now();
    let target = TargetAddr::Domain("www.gstatic.com".to_string(), 80);
    
    let mut stream = connect_via_chain(&chain, &target)
        .await
        .map_err(|e| format!("Failed to connect via chain: {}", e))?;

    let req = b"GET /generate_204 HTTP/1.1\r\nHost: www.gstatic.com\r\nConnection: close\r\n\r\n";
    stream.write_all(req).await.map_err(|e| format!("Failed to send HTTP request: {}", e))?;

    let mut buf = [0u8; 1024];
    let n = stream.read(&mut buf).await.map_err(|e| format!("Failed to read HTTP response: {}", e))?;
    let response = String::from_utf8_lossy(&buf[..n]);

    if response.starts_with("HTTP/1.1 204") || response.starts_with("HTTP/1.0 204") {
        let elapsed = start_time.elapsed().as_millis() as i32;
        Ok(elapsed)
    } else {
        Err(format!("Invalid response from server: {}", response))
    }
}
