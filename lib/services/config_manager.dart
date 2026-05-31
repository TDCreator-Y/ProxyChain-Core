import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../src/rust/api/proxy.dart';

class ConfigManager {
  static late final SharedPreferences _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static const String _entryNodeKey = 'vpn_entry_node';
  static const String _exitNodeKey = 'vpn_exit_node';
  static const String _exitNodesListKey = 'vpn_exit_nodes_list';
  static const String _entryNodesListKey = 'vpn_entry_nodes_list';
  static const String _subscriptionUrlKey = 'vpn_subscription_url';

  // --- ProxyNode JSON Serialization Helpers ---

  static Map<String, dynamic> proxyNodeToJson(ProxyNode node) {
    return {
      'id': node.id,
      'name': node.name,
      'protocol': node.protocol.index,
      'server': node.server,
      'port': node.port,
      'password': node.password,
      'cipher': node.cipher,
    };
  }

  static ProxyNode proxyNodeFromJson(Map<String, dynamic> json) {
    return ProxyNode(
      id: json['id'] as String,
      name: json['name'] as String,
      protocol: ProxyProtocol.values[json['protocol'] as int],
      server: json['server'] as String,
      port: json['port'] as int,
      password: json['password'] as String,
      cipher: json['cipher'] as String?,
    );
  }

  // --- Entry Node ---

  static Future<void> saveEntryNode(ProxyNode node) async {
    await _prefs.setString(_entryNodeKey, jsonEncode(proxyNodeToJson(node)));
  }

  static ProxyNode? getEntryNode() {
    final data = _prefs.getString(_entryNodeKey);
    if (data != null) {
      try {
        return proxyNodeFromJson(jsonDecode(data));
      } catch (e) {
        // Fallback or ignore on parse error
      }
    }
    return null;
  }

  // --- Exit Node ---

  static Future<void> saveExitNode(ProxyNode node) async {
    await _prefs.setString(_exitNodeKey, jsonEncode(proxyNodeToJson(node)));
  }

  static ProxyNode? getExitNode() {
    final data = _prefs.getString(_exitNodeKey);
    if (data != null) {
      try {
        return proxyNodeFromJson(jsonDecode(data));
      } catch (e) {
        // Fallback or ignore on parse error
      }
    }
    return null;
  }

  // --- Entry Nodes List (from Subscription) ---

  static Future<void> saveEntryNodesList(List<ProxyNode> nodes) async {
    final jsonList = nodes.map((n) => proxyNodeToJson(n)).toList();
    await _prefs.setString(_entryNodesListKey, jsonEncode(jsonList));
  }

  static List<ProxyNode> getEntryNodesList() {
    final data = _prefs.getString(_entryNodesListKey);
    if (data != null) {
      try {
        final List<dynamic> jsonList = jsonDecode(data);
        return jsonList.map((json) => proxyNodeFromJson(json)).toList();
      } catch (e) {
        // Fallback or ignore on parse error
      }
    }
    return [];
  }

  // --- Exit Nodes List (from Subscription) ---

  static Future<void> saveExitNodesList(List<ProxyNode> nodes) async {
    final jsonList = nodes.map((n) => proxyNodeToJson(n)).toList();
    await _prefs.setString(_exitNodesListKey, jsonEncode(jsonList));
  }

  static List<ProxyNode> getExitNodesList() {
    final data = _prefs.getString(_exitNodesListKey);
    if (data != null) {
      try {
        final List<dynamic> jsonList = jsonDecode(data);
        return jsonList.map((json) => proxyNodeFromJson(json)).toList();
      } catch (e) {
        // Fallback or ignore on parse error
      }
    }
    return [];
  }

  // --- Subscription URL ---

  static Future<void> saveSubscriptionUrl(String url) async {
    await _prefs.setString(_subscriptionUrlKey, url);
  }

  static String getSubscriptionUrl() {
    return _prefs.getString(_subscriptionUrlKey) ?? '';
  }
}
