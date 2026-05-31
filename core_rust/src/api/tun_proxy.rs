use crate::api::proxy::{connect_via_chain, ProxyChain, TargetAddr, TrafficMsg};
use ipstack::{IpStack, IpStackConfig, IpStackStream};
use std::net::Ipv4Addr;
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;
use tun::Configuration;
use std::process::Command;

pub(crate) async fn start_tun(chain: ProxyChain, tx: mpsc::Sender<TrafficMsg>) -> Result<(), String> {
    let mut config = Configuration::default();
    let ipv4 = Ipv4Addr::new(198, 18, 0, 1);
    let netmask = Ipv4Addr::new(255, 254, 0, 0);
    const MTU: u16 = 1500;

    config.tun_name("proxy_tun0")
        .address(ipv4)
        .netmask(netmask)
        .mtu(MTU)
        .up();

    #[cfg(target_os = "windows")]
    config.platform_config(|_config| {
        // Required for wintun initialization
    });

    let tun_device = match tun::create_as_async(&config) {
        Ok(dev) => dev,
        Err(e) => return Err(format!("Failed to create TUN device: {}", e)),
    };

    let mut ipstack_config = IpStackConfig::default();
    ipstack_config.mtu(MTU).unwrap();
    let mut ip_stack = IpStack::new(ipstack_config, tun_device);

    // Setup routes
    if let Err(e) = setup_routes(&chain.entry_node.server) {
        eprintln!("Failed to setup routes: {}", e);
        // Continue anyway for testing
    }

    println!("TUN device proxy_tun0 started with IP 198.18.0.1");

    while let Ok(stream) = ip_stack.accept().await {
        let chain_clone = chain.clone();
        let tx_clone = tx.clone();
        
        match stream {
            IpStackStream::Tcp(tcp) => {
                tokio::spawn(async move {
                    // From the TUN stack's perspective, the "local_addr" is the target destination
                    // that the local client wanted to reach (e.g., youtube.com IP).
                    let target_addr = tcp.local_addr();
                    
                    let nested_stream = match connect_via_chain(&chain_clone, &TargetAddr::Ip(target_addr)).await {
                        Ok(s) => s,
                        Err(e) => {
                            eprintln!("Failed to connect via chain for TCP {}: {}", target_addr, e);
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
                            use tokio::io::AsyncReadExt;
                            let n = ri.read(&mut buf).await.unwrap_or(0);
                            if n == 0 { break; }
                            if wo.write_all(&buf[..n]).await.is_err() { break; }
                            let _ = tx_up.send(TrafficMsg::Up(n as u64)).await;
                        }
                    });

                    let server_to_client = tokio::spawn(async move {
                        let mut buf = vec![0u8; 8192];
                        loop {
                            use tokio::io::AsyncReadExt;
                            let n = ro.read(&mut buf).await.unwrap_or(0);
                            if n == 0 { break; }
                            if wi.write_all(&buf[..n]).await.is_err() { break; }
                            let _ = tx_down.send(TrafficMsg::Down(n as u64)).await;
                        }
                    });

                    let _ = tokio::try_join!(client_to_server, server_to_client);
                });
            }
            IpStackStream::Udp(udp) => {
                tokio::spawn(async move {
                    let target_addr = udp.local_addr().to_string();
                    eprintln!("UDP proxying is not fully implemented yet for: {}", target_addr);
                });
            }
            IpStackStream::UnknownNetwork(_) => {}
            IpStackStream::UnknownTransport(_) => {}
        }
    }

    Ok(())
}

fn setup_routes(entry_server: &str) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        // Example: Add route for entry_server to bypass TUN (assuming default gateway)
        // Here we just execute route add for entry server using existing gateway
        // To be precise, we need to find the current gateway. For simplicity, we just log it.
        println!("Modifying Windows routing table (Requires Administrator privileges)");
        
        // 1. Get default gateway (Mocked or omitted for simplicity in this task)
        // 2. Add route for entry node: route add <entry_server> mask 255.255.255.255 <physical_gateway>
        // 3. Add default route to TUN: route add 0.0.0.0 mask 0.0.0.0 198.18.0.1 metric 1
        
        let _ = Command::new("route")
            .args(&["add", entry_server, "mask", "255.255.255.255", "192.168.1.1"]) // mock physical gw
            .output();
            
        let _ = Command::new("route")
            .args(&["add", "0.0.0.0", "mask", "0.0.0.0", "198.18.0.1", "metric", "1"])
            .output();
    }

    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("route").args(&["add", "-host", entry_server, "192.168.1.1"]).output();
        let _ = Command::new("route").args(&["add", "default", "198.18.0.1"]).output();
    }
    
    Ok(())
}
