import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_singbox_vpn/flutter_singbox.dart';

enum EngineState { disconnected, connecting, connected, disconnecting }

class VpnEngine {
  final _singbox = FlutterSingbox();

  EngineState _state = EngineState.disconnected;
  bool _killswitchActive = false;

  bool get isConnected => _state == EngineState.connected;
  bool get killswitchActive => _killswitchActive;
  EngineState get state => _state;

  Timer? _watchdogTimer;
  Timer? _trafficVerifyTimer;
  StreamSubscription<Map<String, dynamic>?>? _trafficSub;

  String? _lastVpnLink;
  bool _lastUseKillswitch = false;
  bool _lastUseAdblock = false;

  int _sessionBytes = 0;
  bool _rotationInProgress = false;

  static const List<({String stack, String? fp})> _retryMatrix = [
    (stack: 'mixed',  fp: null),
    (stack: 'mixed',  fp: 'firefox'),
    (stack: 'mixed',  fp: 'safari'),
    (stack: 'mixed',  fp: 'ios'),
    (stack: 'system', fp: 'firefox'),
    (stack: 'gvisor', fp: 'firefox'),
  ];

  int _retryIndex = 0;
  String? _activeStack;
  String? _activeFp;

  Stream<Map<String, dynamic>?> get onTrafficUpdate =>
      _singbox.onTrafficUpdate.asBroadcastStream();

  Future<bool> run(
      String vpnLink, {
        bool useKillswitch = false,
        bool useAdblock = false,
        bool resetRetry = true,
      }) async {
    if (_state == EngineState.connecting || _state == EngineState.disconnecting) {
      return false;
    }

    try {
      if (_state == EngineState.connected) {
        await stop();
        await Future.delayed(const Duration(milliseconds: 600));
      }

      _state = EngineState.connecting;

      if (resetRetry) {
        _retryIndex = 0;
      }

      _lastVpnLink       = vpnLink;
      _lastUseKillswitch = useKillswitch;
      _lastUseAdblock    = useAdblock;
      _sessionBytes      = 0;

      final attempt = _retryMatrix[_retryIndex % _retryMatrix.length];
      _activeStack = attempt.stack;

      final effectiveLink = attempt.fp != null
          ? _overrideFp(vpnLink, attempt.fp!)
          : vpnLink;

      final linkData = _parseLink(effectiveLink);
      _activeFp = linkData['fp'];

      debugPrint('🔌 VPN attempt #${_retryIndex + 1}: '
          'stack=${attempt.stack}, fp=$_activeFp, type=${linkData['type']}');

      final configJson = _buildSingboxConfig(
        linkData,
        useKillswitch,
        useAdblock,
        stack: attempt.stack,
      );

      await _singbox.saveConfig(configJson);
      await _singbox.startVPN();

      await Future.delayed(const Duration(milliseconds: 1500));

      bool actualStatus = false;
      for (int i = 0; i < 10; i++) {
        actualStatus = await checkStatus();
        if (actualStatus) break;
        await Future.delayed(const Duration(milliseconds: 500));
      }

      if (actualStatus) {
        _state            = EngineState.connected;
        _killswitchActive = useKillswitch;
        _startWatchdog();
        _scheduleTrafficVerification();
        return true;
      } else {
        await stop();
        return false;
      }
    } catch (e, st) {
      debugPrint('🚨 VPN Engine Error: $e\n$st');
      _state = EngineState.disconnected;
      return false;
    }
  }

  void _scheduleTrafficVerification() {
    _trafficVerifyTimer?.cancel();
    _trafficVerifyTimer = Timer(const Duration(seconds: 7), () async {
      if (_state != EngineState.connected) return;
      if (_rotationInProgress)             return;

      if (_sessionBytes == 0) {
        final nextIndex = _retryIndex + 1;

        if (nextIndex >= _retryMatrix.length) {
          debugPrint('⚠️ VPN: все ${_retryMatrix.length} вариантов исчерпаны, '
              'оставляем текущее подключение. Watchdog продолжит мониторинг.');
          return;
        }

        final next = _retryMatrix[nextIndex];
        debugPrint('🔄 VPN: 0 bytes in 7s — switching stack=$_activeStack→${next.stack}');

        _rotationInProgress = true;
        _retryIndex = nextIndex;

        _stopWatchdog();
        _trafficVerifyTimer?.cancel();
        try {
          await _singbox.stopVPN();
        } catch (_) {}
        _state            = EngineState.disconnected;
        _killswitchActive = false;

        await Future.delayed(const Duration(milliseconds: 800));
        _rotationInProgress = false;

        final link = _lastVpnLink;
        if (link != null && _state == EngineState.disconnected) {
          await run(
            link,
            useKillswitch: _lastUseKillswitch,
            useAdblock:    _lastUseAdblock,
            resetRetry:    false,
          );
        }
      } else {
        debugPrint('✅ VPN: OK — stack=$_activeStack, fp=$_activeFp, '
            'трафик: $_sessionBytes байт за первые 7с');
      }
    });
  }

  Future<void> stop() async {
    if (_state == EngineState.disconnecting) return;

    _state = EngineState.disconnecting;
    _stopWatchdog();
    _trafficVerifyTimer?.cancel();
    _trafficVerifyTimer   = null;

    try {
      await _singbox.stopVPN();
    } catch (_) {} finally {
      _state              = EngineState.disconnected;
      _killswitchActive   = false;
      _rotationInProgress = false;
    }
  }

  Future<bool> checkStatus() async {
    try {
      final status = await _singbox.getVPNStatus();
      final s = status.toLowerCase();
      final isConn = s.contains('started') ||
          (s.contains('connect') && !s.contains('disconnect'));

      if (isConn && _state == EngineState.disconnected) {
        _state = EngineState.connected;
      }
      if (!isConn && _state == EngineState.connected) {
        _state            = EngineState.disconnected;
        _killswitchActive = false;
      }

      return isConn;
    } catch (_) {
      return false;
    }
  }

  void _startWatchdog() {
    _stopWatchdog();

    _trafficSub = onTrafficUpdate.listen((data) {
      if (data != null) {
        final up   = (data['uplink']   as num?)?.toInt() ?? 0;
        final down = (data['downlink'] as num?)?.toInt() ?? 0;
        if ((up > 0 || down > 0) && _state == EngineState.connected) {
          _sessionBytes += up + down;
          _resetWatchdog();
        }
      }
    });

    _resetWatchdog();
  }

  void _resetWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 90), () async {
      bool stillAlive = false;
      for (int attempt = 0; attempt < 3; attempt++) {
        stillAlive = await checkStatus();
        if (stillAlive) break;
        if (attempt < 2) await Future.delayed(const Duration(seconds: 3));
      }

      if (!stillAlive && _state == EngineState.connected) {
        debugPrint('🚨 Watchdog: туннель мёртв (3/3 проверок), реконнект');
        _state = EngineState.disconnected;
        _stopWatchdog();

        final link = _lastVpnLink;
        if (link != null) {
          await Future.delayed(const Duration(seconds: 2));
          if (_state == EngineState.disconnected) {
            await run(
              link,
              useKillswitch: _lastUseKillswitch,
              useAdblock:    _lastUseAdblock,
              resetRetry:    true,
            );
          }
        } else {
          await stop();
        }
      }
    });
  }

  void _stopWatchdog() {
    _trafficSub?.cancel();
    _trafficSub    = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  String _overrideFp(String link, String newFp) {
    try {
      final uri    = Uri.parse(link);
      final params = Map<String, String>.from(uri.queryParameters);
      params['fp'] = newFp;
      return uri.replace(queryParameters: params).toString();
    } catch (_) {
      return link;
    }
  }

  Map<String, String> _parseLink(String link) {
    try {
      final uri = Uri.parse(link);

      if (uri.scheme == 'hy2' || uri.scheme == 'hysteria2') {
        return {
          'type': 'hysteria2',
          'password': uri.userInfo,
          'server': uri.host,
          'port': uri.port.toString(),
          'sni': uri.queryParameters['sni'] ?? '',
          'fp': uri.queryParameters['fp'] ?? 'firefox',
        };
      }

      // Если это старый VLESS
      return {
        'type': 'vless',
        'uuid':   uri.userInfo,
        'server': uri.host,
        'port':   uri.port.toString(),
        'pbk':    uri.queryParameters['pbk'] ?? '',
        'sid':    uri.queryParameters['sid'] ?? '',
        'sni':    uri.queryParameters['sni'] ?? '',
        'fp':     uri.queryParameters['fp']  ?? 'firefox',
      };
    } catch (e) {
      throw Exception('Invalid VPN link format');
    }
  }

  bool _isIp(String host) {
    try { Uri.parseIPv4Address(host); return true; } catch (_) {}
    try { Uri.parseIPv6Address(host); return true; } catch (_) {}
    return false;
  }

  String _buildSingboxConfig(
      Map<String, String> data,
      bool useKillswitch,
      bool useAdblock, {
        String stack = 'mixed',
      }) {
    final serverHost = data['server'] ?? '';

    final List<Map<String, dynamic>> routeRules = [
      {'protocol': 'dns', 'outbound': 'dns_remote'},
      {
        'ip_cidr': [
          '224.0.0.0/3',
          'ff00::/8',
          '192.168.0.0/16',
          '10.0.0.0/8',
          '172.16.0.0/12',
          '127.0.0.0/8',
        ],
        'outbound': 'direct',
      },
    ];

    try {
      Uri.parseIPv4Address(serverHost);
      routeRules.add({'ip_cidr': ['$serverHost/32'], 'outbound': 'direct'});
    } catch (_) {
      try {
        Uri.parseIPv6Address(serverHost);
        routeRules.add({'ip_cidr': ['$serverHost/128'], 'outbound': 'direct'});
      } catch (_) {
        routeRules.add({'domain': [serverHost], 'outbound': 'direct'});
      }
    }

    final config = <String, dynamic>{
      'log': {'level': 'fatal'},
      'dns': {
        'servers': [
          {
            'tag':     'dns_remote',
            'address': useAdblock ? 'tls://dns.adguard-dns.com' : 'tls://1.1.1.1',
            'detour':  'proxy',
          },
          {
            'tag':     'dns_local',
            'address': 'local',
            'detour':  'direct',
          },
        ],
        'rules': [
          if (serverHost.isNotEmpty && !_isIp(serverHost))
            {'domain': [serverHost], 'server': 'dns_local'},
          {'outbound': 'direct', 'server': 'dns_local'},
        ],
        'final':             'dns_remote',
        'independent_cache': true,
      },
      'inbounds': [
        {
          'type':           'tun',
          'tag':            'tun-in',
          'interface_name': 'tun0',
          'inet4_address':  '172.19.0.1/30',
          'inet6_address':  'fdfe:dcba:9876::1/126',
          'mtu':            1400,
          'auto_route':     true,
          'strict_route':   useKillswitch,
          'stack':          stack,
          'sniff':                      true,
          'sniff_override_destination': false,
        },
      ],
      'outbounds': [
        if (data['type'] == 'hysteria2')
          {
            'type': 'hysteria2',
            'tag': 'proxy',
            'server': data['server'],
            'server_port': int.parse(data['port']!),
            'password': data['password'],
            'tls': {
              'enabled': true,
              'server_name': data['sni'],
              'insecure': true,
              'alpn': ['h3'],
              'utls': {
                'enabled': true,
                'fingerprint': data['fp']
              }
            }
          }
        else
          {
            'type': 'vless',
            'tag': 'proxy',
            'server': data['server'],
            'server_port': int.parse(data['port']!),
            'uuid': data['uuid'],
            'flow': 'xtls-rprx-vision',
            'packet_encoding': 'xudp',
            'domain_strategy': 'prefer_ipv4',
            'tls': {
              'enabled': true,
              'server_name': data['sni'],
              'utls': {
                'enabled': true,
                'fingerprint': data['fp']
              },
              'reality': {
                'enabled': true,
                'public_key': data['pbk'],
                'short_id': data['sid'],
              }
            }
          },
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block',  'tag': 'block'},
      ],
      'route': {
        'auto_detect_interface': true,
        'final':                 'proxy',
        'rules':                 routeRules,
      },
    };

    return jsonEncode(config);
  }
}
