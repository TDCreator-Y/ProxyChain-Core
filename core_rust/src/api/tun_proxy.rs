use crate::api::proxy::{connect_via_chain, ProxyChain, TargetAddr, TrafficMsg};
use ipstack::{IpStack, IpStackConfig, IpStackStream};
use smoltcp::wire::{IpProtocol, Ipv4Packet, Ipv6Packet, TcpPacket, UdpPacket};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::pin::Pin;
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::{lookup_host, TcpStream};
use tokio::sync::mpsc;
use tun::Configuration;

const TUN_NAME: &str = "proxy_tun";
const TUN_IPV4: Ipv4Addr = Ipv4Addr::new(198, 18, 0, 1);
const TUN_NETMASK: Ipv4Addr = Ipv4Addr::new(255, 255, 0, 0);
const TUN_DEFAULT_GATEWAY: &str = "198.18.0.1";
const FAKE_IP_NETWORK: [u8; 2] = [198, 18];
const FAKE_IP_START_HOST: u32 = 2;
const FAKE_IP_END_HOST: u32 = 0xfffe;
const MTU: u16 = 1500;

static TUN_RUNTIME: OnceLock<Mutex<Option<TunRuntimeState>>> = OnceLock::new();
static FAKE_IP_STATE: OnceLock<Mutex<FakeIpState>> = OnceLock::new();

#[derive(Clone, Debug)]
struct RouteCommand {
    program: &'static str,
    args: Vec<String>,
}

#[derive(Debug)]
struct TunRuntimeState {
    cleanup_commands: Vec<RouteCommand>,
}

#[derive(Clone, Debug)]
struct PacketMetadata {
    transport: &'static str,
    destination: String,
    port: u16,
    dns_query: Option<String>,
}

#[derive(Debug, Default)]
struct FakeIpState {
    domain_to_fake: HashMap<String, Ipv4Addr>,
    fake_to_domain: HashMap<Ipv4Addr, String>,
    next_host: u32,
}

#[derive(Clone, Debug)]
struct DnsQuestion {
    id: u16,
    flags: u16,
    name: String,
    qtype: u16,
    qclass: u16,
    question_bytes: Vec<u8>,
}

struct PacketTrackedDevice<T> {
    inner: T,
    metadata_tx: mpsc::UnboundedSender<PacketMetadata>,
}

struct TunCleanupGuard;

impl Drop for TunCleanupGuard {
    fn drop(&mut self) {
        stop_tun();
    }
}

impl<T> PacketTrackedDevice<T> {
    fn new(inner: T, metadata_tx: mpsc::UnboundedSender<PacketMetadata>) -> Self {
        Self { inner, metadata_tx }
    }
}

impl<T> AsyncRead for PacketTrackedDevice<T>
where
    T: AsyncRead + Unpin,
{
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let start_len = buf.filled().len();
        match Pin::new(&mut self.inner).poll_read(cx, buf) {
            Poll::Ready(Ok(())) => {
                let filled = buf.filled();
                if filled.len() > start_len {
                    if let Some(meta) = parse_packet_metadata(&filled[start_len..]) {
                        let _ = self.metadata_tx.send(meta);
                    }
                }
                Poll::Ready(Ok(()))
            }
            other => other,
        }
    }
}

impl<T> AsyncWrite for PacketTrackedDevice<T>
where
    T: AsyncWrite + Unpin,
{
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

pub(crate) async fn start_tun(chain: ProxyChain, tx: mpsc::Sender<TrafficMsg>) -> Result<(), String> {
    stop_tun();

    let mut config = Configuration::default();
    config
        .tun_name(TUN_NAME)
        .address(TUN_IPV4)
        .netmask(TUN_NETMASK)
        .mtu(MTU)
        .up();

    #[cfg(target_os = "windows")]
    config.platform_config(|_config| {});

    let tun_device = tun::create_as_async(&config)
        .map_err(|err| format!("failed to create TUN device {TUN_NAME}: {err}"))?;

    let route_state = install_routes(&chain.entry_node.server, chain.entry_node.port).await?;
    replace_tun_state(route_state)?;
    let _cleanup_guard = TunCleanupGuard;

    let (metadata_tx, mut metadata_rx) = mpsc::unbounded_channel::<PacketMetadata>();
    tokio::spawn(async move {
        while let Some(meta) = metadata_rx.recv().await {
            if let Some(domain) = meta.dns_query {
                eprintln!(
                    "TUN DNS query observed: {} {}:{} -> {}",
                    meta.transport, meta.destination, meta.port, domain
                );
            } else {
                eprintln!(
                    "TUN packet observed: {} {}:{}",
                    meta.transport, meta.destination, meta.port
                );
            }
        }
    });

    let tracked_device = PacketTrackedDevice::new(tun_device, metadata_tx);
    let mut ipstack_config = IpStackConfig::default();
    ipstack_config
        .mtu(MTU)
        .map_err(|err| format!("failed to configure ipstack MTU: {err}"))?;
    let mut ip_stack = IpStack::new(ipstack_config, tracked_device);

    eprintln!("TUN device {TUN_NAME} started with IP {TUN_IPV4}/16");

    while let Ok(stream) = ip_stack.accept().await {
        let chain_clone = chain.clone();
        let tx_clone = tx.clone();

        match stream {
            IpStackStream::Tcp(tcp) => {
                tokio::spawn(async move {
                    let original_target = resolve_original_tcp_destination(tcp.local_addr(), tcp.peer_addr());
                    let should_direct = match original_target.ip() {
                        IpAddr::V4(ip) => should_bypass(&ip),
                        IpAddr::V6(_) => false,
                    };
                    let target_addr = resolve_tcp_target_addr(tcp.local_addr(), tcp.peer_addr());
                    let nested_stream = match connect_tcp_upstream(&chain_clone, original_target, &target_addr, should_direct).await {
                        Ok(stream) => stream,
                        Err(err) => {
                            eprintln!(
                                "failed to establish TCP upstream for original target {} / routed target {:?}: {err}",
                                original_target, target_addr
                            );
                            return;
                        }
                    };

                    let (mut ri, mut wi) = tokio::io::split(tcp);
                    let (mut ro, mut wo) = tokio::io::split(nested_stream);
                    let tx_up = tx_clone.clone();
                    let tx_down = tx_clone.clone();

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
                });
            }
            IpStackStream::Udp(udp) => {
                tokio::spawn(async move {
                    if let Err(err) = handle_udp_stream(udp).await {
                        eprintln!("UDP flow handling failed: {err}");
                    }
                });
            }
            IpStackStream::UnknownNetwork(_) => {}
            IpStackStream::UnknownTransport(_) => {}
        }
    }

    Ok(())
}

pub(crate) fn stop_tun() {
    if let Some(state) = tun_runtime().lock().unwrap().take() {
        for command in state.cleanup_commands {
            if let Err(err) = run_command(&command) {
                eprintln!("failed to cleanup route via {:?}: {err}", command.args);
            }
        }
    }
    clear_fake_ip_state();
}

fn parse_packet_metadata(packet: &[u8]) -> Option<PacketMetadata> {
    match packet.first().map(|byte| byte >> 4) {
        Some(4) => parse_ipv4_metadata(packet),
        Some(6) => parse_ipv6_metadata(packet),
        _ => None,
    }
}

fn parse_ipv4_metadata(packet: &[u8]) -> Option<PacketMetadata> {
    let packet = Ipv4Packet::new_checked(packet).ok()?;
    let destination = packet.dst_addr().to_string();
    parse_transport_metadata(packet.next_header(), packet.payload(), destination)
}

fn parse_ipv6_metadata(packet: &[u8]) -> Option<PacketMetadata> {
    let packet = Ipv6Packet::new_checked(packet).ok()?;
    let destination = packet.dst_addr().to_string();
    parse_transport_metadata(packet.next_header(), packet.payload(), destination)
}

fn parse_transport_metadata(
    protocol: IpProtocol,
    payload: &[u8],
    destination: String,
) -> Option<PacketMetadata> {
    match protocol {
        IpProtocol::Tcp => {
            let packet = TcpPacket::new_checked(payload).ok()?;
            Some(PacketMetadata {
                transport: "tcp",
                destination,
                port: packet.dst_port(),
                dns_query: None,
            })
        }
        IpProtocol::Udp => {
            let packet = UdpPacket::new_checked(payload).ok()?;
            let dns_query = if packet.dst_port() == 53 {
                parse_dns_query(packet.payload()).map(|query| query.name)
            } else {
                None
            };
            Some(PacketMetadata {
                transport: "udp",
                destination,
                port: packet.dst_port(),
                dns_query,
            })
        }
        _ => None,
    }
}

async fn handle_udp_stream(mut udp: ipstack::IpStackUdpStream) -> Result<(), String> {
    let local_addr = udp.local_addr();
    let peer_addr = udp.peer_addr();
    let mut buf = vec![0u8; 2048];

    loop {
        let n = udp
            .read(&mut buf)
            .await
            .map_err(|err| format!("failed to read UDP payload for {peer_addr}: {err}"))?;
        if n == 0 {
            return Ok(());
        }

        let payload = &buf[..n];
        let dns_port_hit = local_addr.port() == 53 || peer_addr.port() == 53;
        if !dns_port_hit {
            eprintln!("UDP flow observed for {peer_addr} but UDP relay is not implemented yet");
            continue;
        }

        let Some(query) = parse_dns_query(payload) else {
            eprintln!("UDP/53 payload for {peer_addr} is not a supported DNS query");
            continue;
        };

        let fake_ip = if should_answer_with_fake_ip(&query) {
            Some(allocate_fake_ip(&query.name)?)
        } else {
            None
        };

        let response = build_dns_response(&query, fake_ip);
        udp.write_all(&response)
            .await
            .map_err(|err| format!("failed to write DNS response for {}: {err}", query.name))?;

        if let Some(fake_ip) = fake_ip {
            eprintln!("Fake-IP assigned: {} -> {}", query.name, fake_ip);
        }
    }
}

fn should_answer_with_fake_ip(query: &DnsQuestion) -> bool {
    query.qclass == 1 && matches!(query.qtype, 1 | 255)
}

fn parse_dns_query(payload: &[u8]) -> Option<DnsQuestion> {
    if payload.len() < 12 {
        return None;
    }

    let id = u16::from_be_bytes([payload[0], payload[1]]);
    let flags = u16::from_be_bytes([payload[2], payload[3]]);
    let qdcount = u16::from_be_bytes([payload[4], payload[5]]);
    if flags & 0x8000 != 0 || qdcount == 0 {
        return None;
    }

    let (name, cursor) = parse_dns_name(payload, 12)?;
    if payload.len() < cursor + 4 {
        return None;
    }

    let qtype = u16::from_be_bytes([payload[cursor], payload[cursor + 1]]);
    let qclass = u16::from_be_bytes([payload[cursor + 2], payload[cursor + 3]]);
    let question_end = cursor + 4;

    Some(DnsQuestion {
        id,
        flags,
        name,
        qtype,
        qclass,
        question_bytes: payload[12..question_end].to_vec(),
    })
}

fn parse_dns_name(payload: &[u8], offset: usize) -> Option<(String, usize)> {
    let mut cursor = offset;
    let mut labels = Vec::new();

    loop {
        let len = *payload.get(cursor)? as usize;
        cursor += 1;

        if len == 0 {
            break;
        }
        if len & 0b1100_0000 != 0 {
            return None;
        }
        if payload.len() < cursor + len {
            return None;
        }

        let label = std::str::from_utf8(&payload[cursor..cursor + len]).ok()?;
        labels.push(label.to_string());
        cursor += len;
    }

    Some((labels.join("."), cursor))
}

fn build_dns_response(query: &DnsQuestion, fake_ip: Option<Ipv4Addr>) -> Vec<u8> {
    let mut response = Vec::with_capacity(64);
    response.extend_from_slice(&query.id.to_be_bytes());

    let recursion_desired = query.flags & 0x0100;
    let response_flags = 0x8000 | 0x0080 | recursion_desired;
    response.extend_from_slice(&response_flags.to_be_bytes());
    response.extend_from_slice(&1u16.to_be_bytes());
    response.extend_from_slice(&(fake_ip.is_some() as u16).to_be_bytes());
    response.extend_from_slice(&0u16.to_be_bytes());
    response.extend_from_slice(&0u16.to_be_bytes());
    response.extend_from_slice(&query.question_bytes);

    if let Some(fake_ip) = fake_ip {
        response.extend_from_slice(&0xc00cu16.to_be_bytes());
        response.extend_from_slice(&1u16.to_be_bytes());
        response.extend_from_slice(&1u16.to_be_bytes());
        response.extend_from_slice(&60u32.to_be_bytes());
        response.extend_from_slice(&4u16.to_be_bytes());
        response.extend_from_slice(&fake_ip.octets());
    }

    response
}

async fn connect_tcp_upstream(
    chain: &ProxyChain,
    original_target: SocketAddr,
    routed_target: &TargetAddr,
    should_direct: bool,
) -> Result<Box<dyn crate::api::proxy::ProxyIoStream>, String> {
    if should_direct {
        let stream = TcpStream::connect(original_target)
            .await
            .map_err(|err| format!("failed to bypass-connect to {original_target}: {err}"))?;
        return Ok(Box::new(stream));
    }

    connect_via_chain(chain, routed_target).await
}

fn resolve_original_tcp_destination(local_addr: SocketAddr, peer_addr: SocketAddr) -> SocketAddr {
    if peer_addr.ip() != IpAddr::V4(TUN_IPV4) {
        return peer_addr;
    }

    local_addr
}

fn resolve_tcp_target_addr(local_addr: SocketAddr, peer_addr: SocketAddr) -> TargetAddr {
    for candidate in [peer_addr, local_addr] {
        if let IpAddr::V4(ip) = candidate.ip() {
            if let Some(domain) = lookup_fake_ip_domain(ip) {
                return TargetAddr::Domain(domain, candidate.port());
            }
        }
    }

    if peer_addr.ip() != IpAddr::V4(TUN_IPV4) {
        return TargetAddr::Ip(peer_addr);
    }

    TargetAddr::Ip(local_addr)
}

fn should_bypass(ip: &Ipv4Addr) -> bool {
    is_lan_ip(ip) || is_cn_ip(ip)
}

fn is_lan_ip(ip: &Ipv4Addr) -> bool {
    let octets = ip.octets();
    if octets[0] == 127 {
        return true;
    }
    if octets[0] == 10 {
        return true;
    }
    if octets[0] == 192 && octets[1] == 168 {
        return true;
    }
    if octets[0] == 172 && (16..=31).contains(&octets[1]) {
        return true;
    }
    false
}

fn is_cn_ip(_ip: &Ipv4Addr) -> bool {
    // GeoIP 占位：后续可替换为读取本地 `cn_ip.txt` 或更完整的 CIDR 匹配。
    false
}

fn allocate_fake_ip(domain: &str) -> Result<Ipv4Addr, String> {
    let mut state = fake_ip_state().lock().unwrap();
    if let Some(existing) = state.domain_to_fake.get(domain) {
        return Ok(*existing);
    }

    if state.next_host == 0 {
        state.next_host = FAKE_IP_START_HOST;
    }

    let start_host = state.next_host;
    loop {
        if state.next_host > FAKE_IP_END_HOST {
            state.next_host = FAKE_IP_START_HOST;
        }

        let candidate = fake_ip_from_host(state.next_host);
        state.next_host += 1;

        if !state.fake_to_domain.contains_key(&candidate) {
            state.domain_to_fake.insert(domain.to_string(), candidate);
            state.fake_to_domain.insert(candidate, domain.to_string());
            return Ok(candidate);
        }

        if state.next_host == start_host {
            break;
        }
    }

    Err("fake-ip address pool is exhausted".to_string())
}

fn lookup_fake_ip_domain(fake_ip: Ipv4Addr) -> Option<String> {
    fake_ip_state()
        .lock()
        .unwrap()
        .fake_to_domain
        .get(&fake_ip)
        .cloned()
}

fn clear_fake_ip_state() {
    let mut state = fake_ip_state().lock().unwrap();
    state.domain_to_fake.clear();
    state.fake_to_domain.clear();
    state.next_host = 0;
}

fn fake_ip_state() -> &'static Mutex<FakeIpState> {
    FAKE_IP_STATE.get_or_init(|| Mutex::new(FakeIpState::default()))
}

fn fake_ip_from_host(host: u32) -> Ipv4Addr {
    Ipv4Addr::new(
        FAKE_IP_NETWORK[0],
        FAKE_IP_NETWORK[1],
        ((host >> 8) & 0xff) as u8,
        (host & 0xff) as u8,
    )
}

async fn install_routes(entry_server: &str, entry_port: u16) -> Result<TunRuntimeState, String> {
    let entry_ip = resolve_entry_ipv4(entry_server, entry_port).await?;
    let default_gateway = discover_default_gateway()?;
    let (install_commands, cleanup_commands) = build_route_commands(entry_ip, default_gateway);

    let mut installed_cleanups = Vec::new();
    for (install, cleanup) in install_commands.iter().zip(cleanup_commands.iter()) {
        if let Err(err) = run_command(install) {
            for rollback in installed_cleanups.into_iter().rev() {
                let _ = run_command(&rollback);
            }
            return Err(err);
        }
        installed_cleanups.push(cleanup.clone());
    }

    Ok(TunRuntimeState { cleanup_commands })
}

async fn resolve_entry_ipv4(entry_server: &str, entry_port: u16) -> Result<Ipv4Addr, String> {
    if let Ok(ip) = entry_server.parse::<Ipv4Addr>() {
        return Ok(ip);
    }

    let mut resolved = lookup_host((entry_server, entry_port))
        .await
        .map_err(|err| format!("failed to resolve entry server {entry_server}:{entry_port}: {err}"))?;

    resolved
        .find_map(|addr| match addr.ip() {
            IpAddr::V4(ip) => Some(ip),
            IpAddr::V6(_) => None,
        })
        .ok_or_else(|| format!("entry server {entry_server} did not resolve to an IPv4 address"))
}

fn build_route_commands(entry_ip: Ipv4Addr, default_gateway: Ipv4Addr) -> (Vec<RouteCommand>, Vec<RouteCommand>) {
    #[cfg(target_os = "windows")]
    {
        let install_commands = vec![
            RouteCommand {
                program: "route",
                args: vec![
                    "add".to_string(),
                    entry_ip.to_string(),
                    "mask".to_string(),
                    "255.255.255.255".to_string(),
                    default_gateway.to_string(),
                ],
            },
            RouteCommand {
                program: "route",
                args: vec![
                    "add".to_string(),
                    "0.0.0.0".to_string(),
                    "mask".to_string(),
                    "0.0.0.0".to_string(),
                    TUN_DEFAULT_GATEWAY.to_string(),
                    "metric".to_string(),
                    "1".to_string(),
                ],
            },
        ];
        let cleanup_commands = vec![
            RouteCommand {
                program: "route",
                args: vec!["delete".to_string(), entry_ip.to_string()],
            },
            RouteCommand {
                program: "route",
                args: vec!["delete".to_string(), "0.0.0.0".to_string()],
            },
        ];
        return (install_commands, cleanup_commands);
    }

    #[cfg(target_os = "macos")]
    {
        let install_commands = vec![
            RouteCommand {
                program: "route",
                args: vec![
                    "-n".to_string(),
                    "add".to_string(),
                    "-host".to_string(),
                    entry_ip.to_string(),
                    default_gateway.to_string(),
                ],
            },
            RouteCommand {
                program: "route",
                args: vec![
                    "-n".to_string(),
                    "add".to_string(),
                    "default".to_string(),
                    TUN_DEFAULT_GATEWAY.to_string(),
                ],
            },
        ];
        let cleanup_commands = vec![
            RouteCommand {
                program: "route",
                args: vec![
                    "-n".to_string(),
                    "delete".to_string(),
                    "-host".to_string(),
                    entry_ip.to_string(),
                ],
            },
            RouteCommand {
                program: "route",
                args: vec![
                    "-n".to_string(),
                    "delete".to_string(),
                    "default".to_string(),
                    TUN_DEFAULT_GATEWAY.to_string(),
                ],
            },
        ];
        return (install_commands, cleanup_commands);
    }

    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    {
        let _ = entry_ip;
        let _ = default_gateway;
        (Vec::new(), Vec::new())
    }
}

fn discover_default_gateway() -> Result<Ipv4Addr, String> {
    #[cfg(target_os = "windows")]
    {
        let output = Command::new("route")
            .args(["print", "-4", "0.0.0.0"])
            .output()
            .map_err(|err| format!("failed to inspect Windows routing table: {err}"))?;
        if !output.status.success() {
            return Err(format!(
                "route print failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            let parts: Vec<_> = line.split_whitespace().collect();
            if parts.len() >= 3 && parts[0] == "0.0.0.0" && parts[1] == "0.0.0.0" {
                if let Ok(gateway) = parts[2].parse::<Ipv4Addr>() {
                    return Ok(gateway);
                }
            }
        }

        return Err("failed to parse Windows default gateway".to_string());
    }

    #[cfg(target_os = "macos")]
    {
        let output = Command::new("route")
            .args(["-n", "get", "default"])
            .output()
            .map_err(|err| format!("failed to inspect macOS routing table: {err}"))?;
        if !output.status.success() {
            return Err(format!(
                "route -n get default failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            let trimmed = line.trim();
            if let Some(value) = trimmed.strip_prefix("gateway:") {
                return value
                    .trim()
                    .parse::<Ipv4Addr>()
                    .map_err(|err| format!("failed to parse macOS default gateway: {err}"));
            }
        }

        return Err("failed to parse macOS default gateway".to_string());
    }

    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    {
        Err("route discovery is not implemented on this platform".to_string())
    }
}

fn replace_tun_state(state: TunRuntimeState) -> Result<(), String> {
    let mut guard = tun_runtime().lock().unwrap();
    if guard.is_some() {
        return Err("TUN runtime state was not cleaned up before reinitialization".to_string());
    }
    *guard = Some(state);
    Ok(())
}

fn tun_runtime() -> &'static Mutex<Option<TunRuntimeState>> {
    TUN_RUNTIME.get_or_init(|| Mutex::new(None))
}

fn run_command(command: &RouteCommand) -> Result<(), String> {
    let output = Command::new(command.program)
        .args(&command.args)
        .output()
        .map_err(|err| {
            format!(
                "failed to execute {} {:?}: {err}",
                command.program, command.args
            )
        })?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    Err(format!(
        "command {} {:?} failed with code {:?}: {}{}",
        command.program,
        command.args,
        output.status.code(),
        stderr.trim(),
        if stdout.trim().is_empty() {
            String::new()
        } else {
            format!(" | stdout: {}", stdout.trim())
        }
    ))
}
