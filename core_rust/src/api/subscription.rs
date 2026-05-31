use anyhow::{anyhow, Result};
use crate::api::proxy::{ProxyNode, ProxyProtocol};
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine as _,
};
use serde::Deserialize;
use serde_json::Value;
use url::Url;

#[derive(Debug, Deserialize)]
struct ClashConfig {
    proxies: Option<Vec<ClashProxy>>,
}

#[derive(Debug, Deserialize)]
struct ClashProxy {
    name: String,
    #[serde(rename = "type")]
    proxy_type: String,
    server: String,
    port: u16,
    password: Option<String>,
    uuid: Option<String>,
    cipher: Option<String>,
}

pub async fn fetch_subscription(url: String) -> Result<Vec<ProxyNode>> {
    let response = reqwest::get(&url)
        .await
        .map_err(|err| anyhow!("failed to fetch subscription: {err}"))?;
        
    let status = response.status();
    if !status.is_success() {
        return Err(anyhow!("subscription request failed with status {status}"));
    }

    let text = response
        .text()
        .await
        .map_err(|err| anyhow!("failed to read subscription response body: {err}"))?;

    let nodes = parse_subscription_text(&text)?;
    
    if nodes.is_empty() {
        return Err(anyhow!("No valid proxy nodes found in the subscription"));
    }
    
    Ok(nodes)
}

fn parse_subscription_text(text: &str) -> Result<Vec<ProxyNode>> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }

    if looks_like_clash_yaml(trimmed) {
        parse_clash_yaml(trimmed)
    } else {
        parse_base64_sub(trimmed)
    }
}

fn looks_like_clash_yaml(text: &str) -> bool {
    text.lines()
        .any(|line| line.trim_start().starts_with("proxies:"))
}

fn parse_clash_yaml(text: &str) -> Result<Vec<ProxyNode>> {
    let config: ClashConfig =
        serde_yaml::from_str(text).map_err(|err| anyhow!("failed to parse clash yaml: {err}"))?;

    let nodes = config
        .proxies
        .unwrap_or_default()
        .into_iter()
        .enumerate()
        .filter_map(|(index, proxy)| {
            let protocol = match proxy.proxy_type.as_str() {
                "ss" | "shadowsocks" => ProxyProtocol::Shadowsocks,
                "trojan" => ProxyProtocol::Trojan,
                "socks5" => ProxyProtocol::Socks5,
                "vmess" => ProxyProtocol::Vmess,
                _ => return None,
            };

            Some(ProxyNode {
                id: format!("yaml_{index}_{}", proxy.server),
                name: proxy.name,
                protocol,
                server: proxy.server,
                port: proxy.port,
                password: proxy.password.or(proxy.uuid).unwrap_or_default(),
                cipher: proxy.cipher,
            })
        })
        .collect();

    Ok(nodes)
}

fn parse_base64_sub(text: &str) -> Result<Vec<ProxyNode>> {
    let decoded = decode_subscription_blob(text);
    let decoded_text = String::from_utf8_lossy(&decoded);
    let source_text = decoded_text.trim();
    let source_text = if source_text.is_empty() { text } else { source_text };

    let nodes: Vec<ProxyNode> = source_text
        .lines()
        .enumerate()
        .filter_map(|(index, line)| parse_proxy_uri(line.trim(), index))
        .collect();

    Ok(nodes)
}

fn decode_subscription_blob(text: &str) -> Vec<u8> {
    let compact = text.replace(['\n', '\r'], "");
    STANDARD
        .decode(&compact)
        .or_else(|_| URL_SAFE_NO_PAD.decode(&compact))
        .unwrap_or_else(|_| text.as_bytes().to_vec())
}

fn parse_proxy_uri(uri: &str, index: usize) -> Option<ProxyNode> {
    if uri.is_empty() {
        return None;
    }

    if let Some(encoded) = uri.strip_prefix("vmess://") {
        return parse_vmess_uri(encoded, index);
    }
    if let Some(rest) = uri.strip_prefix("ss://") {
        return parse_ss_uri(rest, index);
    }

    let parsed_url = Url::parse(uri).ok()?;
    match parsed_url.scheme() {
        "trojan" => parse_trojan_uri(&parsed_url, index),
        "socks5" => parse_socks5_uri(&parsed_url, index),
        _ => None,
    }
}

fn parse_trojan_uri(parsed_url: &Url, index: usize) -> Option<ProxyNode> {
    let name = decode_fragment(parsed_url.fragment(), format!("Trojan Node {index}"));

    Some(ProxyNode {
        id: format!("b64_trojan_{index}"),
        name,
        protocol: ProxyProtocol::Trojan,
        server: parsed_url.host_str()?.to_string(),
        port: parsed_url.port().unwrap_or(443),
        password: parsed_url.username().to_string(),
        cipher: None,
    })
}

fn parse_socks5_uri(parsed_url: &Url, index: usize) -> Option<ProxyNode> {
    let name = decode_fragment(parsed_url.fragment(), format!("Socks5 Node {index}"));

    Some(ProxyNode {
        id: format!("b64_socks5_{index}"),
        name,
        protocol: ProxyProtocol::Socks5,
        server: parsed_url.host_str()?.to_string(),
        port: parsed_url.port().unwrap_or(1080),
        password: parsed_url.password().unwrap_or_default().to_string(),
        cipher: None,
    })
}

fn parse_vmess_uri(encoded: &str, index: usize) -> Option<ProxyNode> {
    let decoded = STANDARD
        .decode(encoded)
        .or_else(|_| URL_SAFE_NO_PAD.decode(encoded))
        .ok()?;
    let json_text = String::from_utf8(decoded).ok()?;
    let value: Value = serde_json::from_str(&json_text).ok()?;

    let name = value["ps"]
        .as_str()
        .map(str::to_string)
        .unwrap_or_else(|| format!("Vmess Node {index}"));
    let server = value["add"].as_str()?.to_string();
    let port = value["port"]
        .as_str()
        .and_then(|raw| raw.parse::<u16>().ok())
        .or_else(|| value["port"].as_u64().and_then(|raw| u16::try_from(raw).ok()))
        .unwrap_or(443);

    Some(ProxyNode {
        id: format!("b64_vmess_{index}"),
        name,
        protocol: ProxyProtocol::Vmess,
        server,
        port,
        password: value["id"].as_str().unwrap_or_default().to_string(),
        cipher: value["scy"].as_str().map(str::to_string),
    })
}

fn parse_ss_uri(rest: &str, index: usize) -> Option<ProxyNode> {
    let (core, name_raw) = rest.split_once('#').unwrap_or((rest, ""));
    let name = decode_percent(name_raw, format!("SS Node {index}"));
    let core = core.split('?').next().unwrap_or(core);

    if let Ok(parsed_url) = Url::parse(&format!("ss://{core}")) {
        if let Some(host) = parsed_url.host_str() {
            let (method, password) = decode_ss_userinfo(parsed_url.username())?;
            return Some(ProxyNode {
                id: format!("b64_ss_{index}"),
                name,
                protocol: ProxyProtocol::Shadowsocks,
                server: host.to_string(),
                port: parsed_url.port().unwrap_or(8388),
                password,
                cipher: Some(method),
            });
        }
    }

    let decoded_core = STANDARD
        .decode(core)
        .or_else(|_| URL_SAFE_NO_PAD.decode(core))
        .ok()?;
    let decoded_core = String::from_utf8(decoded_core).ok()?;
    let (userinfo, hostport) = decoded_core.rsplit_once('@')?;
    let (method, password) = userinfo.split_once(':')?;
    let (host, port) = split_host_port(hostport)?;

    Some(ProxyNode {
        id: format!("b64_ss_{index}"),
        name,
        protocol: ProxyProtocol::Shadowsocks,
        server: host.to_string(),
        port,
        password: password.to_string(),
        cipher: Some(method.to_string()),
    })
}

fn decode_ss_userinfo(userinfo: &str) -> Option<(String, String)> {
    let decoded = STANDARD
        .decode(userinfo)
        .or_else(|_| URL_SAFE_NO_PAD.decode(userinfo))
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .unwrap_or_else(|| userinfo.to_string());
    let (method, password) = decoded.split_once(':')?;
    Some((method.to_string(), password.to_string()))
}

fn split_host_port(hostport: &str) -> Option<(&str, u16)> {
    let (host, port_raw) = hostport.rsplit_once(':')?;
    let port = port_raw.parse::<u16>().ok()?;
    Some((host, port))
}

fn decode_fragment(fragment: Option<&str>, fallback: String) -> String {
    fragment
        .map(|value| decode_percent(value, fallback.clone()))
        .unwrap_or(fallback)
}

fn decode_percent(value: &str, fallback: String) -> String {
    urlencoding::decode(value)
        .map(|decoded| decoded.into_owned())
        .unwrap_or(fallback)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_clash_yaml_nodes() {
        let yaml = r#"
proxies:
  - name: "HK Entry"
    type: socks5
    server: 1.2.3.4
    port: 1080
    password: "pass"
  - name: "US Exit"
    type: vmess
    server: vmess.example.com
    port: 443
    uuid: "uuid-123"
    cipher: "auto"
"#;

        let nodes = parse_subscription_text(yaml).expect("yaml should parse");

        assert_eq!(nodes.len(), 2);
        assert!(matches!(nodes[0].protocol, ProxyProtocol::Socks5));
        assert_eq!(nodes[0].server, "1.2.3.4");
        assert!(matches!(nodes[1].protocol, ProxyProtocol::Vmess));
        assert_eq!(nodes[1].password, "uuid-123");
        assert_eq!(nodes[1].cipher.as_deref(), Some("auto"));
    }

    #[test]
    fn parses_base64_subscription_lines() {
        let vmess_json = r#"{"v":"2","ps":"VMess Node","add":"vmess.example.com","port":"443","id":"uuid-001","scy":"auto"}"#;
        let vmess_line = format!("vmess://{}", STANDARD.encode(vmess_json));
        let trojan_line = "trojan://secret@example.com:443#Trojan%20Node";
        let content = format!("{vmess_line}\n{trojan_line}");
        let encoded = STANDARD.encode(content);

        let nodes = parse_subscription_text(&encoded).expect("base64 should parse");

        assert_eq!(nodes.len(), 2);
        assert!(matches!(nodes[0].protocol, ProxyProtocol::Vmess));
        assert_eq!(nodes[0].server, "vmess.example.com");
        assert_eq!(nodes[0].password, "uuid-001");
        assert!(matches!(nodes[1].protocol, ProxyProtocol::Trojan));
        assert_eq!(nodes[1].name, "Trojan Node");
    }

    #[test]
    fn parses_ss_uri_with_base64_userinfo() {
        let userinfo = STANDARD.encode("aes-256-gcm:secret");
        let uri = format!("ss://{userinfo}@1.2.3.4:8388#SS%20Node");

        let node = parse_proxy_uri(&uri, 0).expect("ss uri should parse");

        assert!(matches!(node.protocol, ProxyProtocol::Shadowsocks));
        assert_eq!(node.server, "1.2.3.4");
        assert_eq!(node.port, 8388);
        assert_eq!(node.password, "secret");
        assert_eq!(node.cipher.as_deref(), Some("aes-256-gcm"));
    }
}
