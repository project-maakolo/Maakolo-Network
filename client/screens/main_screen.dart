import 'dart:async';
//import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_screen.dart';
import '../config.dart';
import '../assets/styles.dart';
import '../utils/storage.dart';
import '../services/vpn_engine.dart';
import '../api_client.dart';
import '../services/localization_service.dart';

import '../services/l10n.dart';
import '../services/notification_service.dart';

// --- Pricing ---
String getPriceStr(String tariff, String currency) {
  var price = AppConfig.pricing[tariff]?[currency];
  if (currency == 'USD') return '\$$price';
  if (currency == 'EUR') return '€$price';
  return '$price ₽';
}

class MainScreen extends StatefulWidget {
  final Map<String, dynamic> initialUser;
  const MainScreen({super.key, required this.initialUser});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  final VpnEngine _vpn = VpnEngine();
  final ApiClient _api = ApiClient();
  final LocalStorage _storage = LocalStorage();

  late Map<String, dynamic> _currentUser;
  String _userPassword = '';
  String? _userToken;

  String _appCurrency = 'USD';

  bool _isFetchingKey = false;
  bool get _isConnected => _vpn.state == EngineState.connected;
  bool get _isConnecting => _isFetchingKey || _vpn.state == EngineState.connecting;
  bool get _isDisconnecting => _vpn.state == EngineState.disconnecting;

  bool _killswitchEnabled = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  List<ConnectivityResult>? _lastConnectivity;
  bool _smartReconnectEnabled = false;
  bool _isReconnectingProcess = false;
  bool _adblockEnabled = false;
  String _selectedTariff = "base";
  int _daysLeft = 0;

  // --- ТРАФИК ДЛЯ BASE ---
  int _usedTrafficBytes = 0;
  int _totalTrafficBytes = 40 * 1024 * 1024 * 1024; // 40 ГБ

  final ValueNotifier<bool> _isButtonDown = ValueNotifier(false);
  bool _isIdHidden = true;

  final ValueNotifier<int> _sessionSeconds = ValueNotifier(0);
  final ValueNotifier<int> _rxBytes = ValueNotifier(0);
  final ValueNotifier<int> _txBytes = ValueNotifier(0);

  Timer? _sessionTimer;
  StreamSubscription<Map<String, dynamic>?>? _trafficSub;

  static const String _vpnStartKey = 'vpn_session_start_ms';
  static const String _vpnRxKey = 'vpn_session_rx';
  static const String _vpnTxKey = 'vpn_session_tx';

  int? _lastRefreshMs;
  bool _updateChecked = false;

  String _formatTime(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void _startVpnStats({bool reset = true}) async {
    _sessionTimer?.cancel();
    _trafficSub?.cancel();

    final prefs = await SharedPreferences.getInstance();

    if (reset) {
      _sessionSeconds.value = 0;
      _rxBytes.value = 0;
      _txBytes.value = 0;
      await prefs.setInt(_vpnStartKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.setInt(_vpnRxKey, 0);
      await prefs.setInt(_vpnTxKey, 0);
    } else {
      _rxBytes.value = prefs.getInt(_vpnRxKey) ?? 0;
      _txBytes.value = prefs.getInt(_vpnTxKey) ?? 0;
    }

    _trafficSub = _vpn.onTrafficUpdate.listen((stats) {
      if (stats != null && mounted) {
        _rxBytes.value = stats['downlinkTotal'] ?? stats['rx'] ?? _rxBytes.value;
        _txBytes.value = stats['uplinkTotal'] ?? stats['tx'] ?? _txBytes.value;
      }
    });

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      _sessionSeconds.value++;

      prefs.setInt(_vpnRxKey, _rxBytes.value);
      prefs.setInt(_vpnTxKey, _txBytes.value);

      bool isForeground = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

      if (_sessionSeconds.value % 3 == 0 && isForeground) {
        bool realStatus = await _vpn.checkStatus();
        if (!realStatus && _isConnected && mounted) {
          _stopVpnStats();
          setState(() {});
          _snack(t('sys_drop'));
          if (_smartReconnectEnabled && !_isReconnectingProcess) {
            _performSmartReconnect();
          }
        }
      }
    });
  }

  void _stopVpnStats() {
    _sessionTimer?.cancel();
    _sessionTimer = null;
    _trafficSub?.cancel();
    _trafficSub = null;
    SharedPreferences.getInstance().then((p) {
      p.remove(_vpnStartKey);
      p.remove(_vpnRxKey);
      p.remove(_vpnTxKey);
    });
  }

  String _notifText = "";
  bool _notifSuccess = false;
  bool _isNotifVisible = false;
  Timer? _snackTimer;

  bool _isModalVisible = false;
  bool _isModalDismissible = true;
  Widget _modalContent = const SizedBox.shrink();

  int _payStep = 1;
  String _payTariff = "base";
  int _payDuration = 1;
  bool _payCustomDur = false;
  String _payMethod = "card_int";
  final TextEditingController _customDurController = TextEditingController();

  final TextEditingController _disable2faCtrl = TextEditingController();
  final TextEditingController _newPassCtrl = TextEditingController();
  final TextEditingController _totpChangeCtrl = TextEditingController();
  final TextEditingController _delPassCtrl = TextEditingController();
  final TextEditingController _delTotpCtrl = TextEditingController();

  bool _isLoadingInvoice = false;

  String _cryptoCurrency = "TON";
  double? _tonRate;
  double? _ltcRate;
  double? _ethRate;
  Map<String, dynamic>? _cryptoData;

  String? _fiatPayUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUser = Map.from(widget.initialUser);

    _userPassword = _currentUser['password'] ?? '';
    _userToken = _currentUser['token'];

    _updateUserInfo();
    _requestPermissions();
    _loadSettings();
    _initConnectivity();
    _fetchDynamicPricing();

    _syncVpnState();
    _silentDataRefresh(force: true);
    _checkForUpdates();

    LocalizationService.languageNotifier.addListener(_onLanguageChanged);
  }

  @override
  void dispose() {
    LocalizationService.languageNotifier.removeListener(_onLanguageChanged);
    _connectivitySub?.cancel();
    _sessionTimer?.cancel();
    _trafficSub?.cancel();
    _sessionSeconds.dispose();
    _rxBytes.dispose();
    _txBytes.dispose();
    _isButtonDown.dispose();
    _snackTimer?.cancel();
    _customDurController.dispose();

    _disable2faCtrl.dispose();
    _newPassCtrl.dispose();
    _totpChangeCtrl.dispose();
    _delPassCtrl.dispose();
    _delTotpCtrl.dispose();

    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  Future<void> _syncVpnState() async {
    bool realStatus = await _vpn.checkStatus();
    if (mounted) {
      setState(() {});

      if (realStatus && _sessionTimer == null) {
        final prefs = await SharedPreferences.getInstance();
        final startMs = prefs.getInt(_vpnStartKey);
        if (startMs != null) {
          final elapsed = DateTime.now().millisecondsSinceEpoch - startMs;
          _sessionSeconds.value = (elapsed / 1000).floor().clamp(0, 999999);
        }
        _startVpnStats(reset: false);
      } else if (!realStatus) {
        _stopVpnStats();
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_vpnStartKey);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _silentDataRefresh();
      _syncVpnState();
    }
  }

  void _loadSettings() async {
    final val = await _storage.getSmartReconnect();
    final adVal = await _storage.getAdblockEnabled();
    if (mounted) {
      setState(() {
        _smartReconnectEnabled = val;
        _adblockEnabled = adVal;
      });
    }
  }

  void _onLanguageChanged() {
    NotificationService().scheduleSubscriptionNotifications(
      baseExpiryMs: _currentUser["expiry_base"],
      stealthExpiryMs: _currentUser["expiry_stealth"],
    );
  }

  void _initConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      _handleNetworkChange(results);
    });
  }

  void _handleNetworkChange(List<ConnectivityResult> newResult) async {
    if (newResult.isEmpty) return;

    final currentPhysical = newResult.firstWhere(
          (r) => r != ConnectivityResult.vpn,
      orElse: () => ConnectivityResult.none,
    );

    final lastPhysical = _lastConnectivity?.firstWhere(
          (r) => r != ConnectivityResult.vpn,
      orElse: () => ConnectivityResult.none,
    );

    if (currentPhysical == ConnectivityResult.none) {
      _lastConnectivity = newResult;
      return;
    }

    if (lastPhysical != null &&
        lastPhysical != ConnectivityResult.none &&
        lastPhysical != currentPhysical) {
      if (_isConnected && _smartReconnectEnabled && !_isConnecting &&
          !_isDisconnecting && !_isReconnectingProcess) {
        _performSmartReconnect();
      }
    }

    _lastConnectivity = newResult;
  }

  Future<void> _performSmartReconnect() async {
    if (_isReconnectingProcess) return;
    setState(() => _isReconnectingProcess = true);
    try {
      if (mounted && _isConnected) await _toggleVpn();
      await Future.delayed(const Duration(seconds: 2));
      if (mounted && !_isConnected) await _toggleVpn();
    } finally {
      if (mounted) setState(() => _isReconnectingProcess = false);
    }
  }

  Future<void> _fetchDynamicPricing() async {
    try {
      final res = await _api.getPricing();
      if (res['status'] == 'success' && res['pricing'] != null) {
        final Map<String, dynamic> p = res['pricing'];
        AppConfig.pricing = {
          'base': Map<String, dynamic>.from(p['base'] ?? AppConfig.pricing['base']!),
          'stealth': Map<String, dynamic>.from(p['stealth'] ?? AppConfig.pricing['stealth']!),
        };
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  void _checkSessionExpired(Map<String, dynamic> result) {
    if (result['session_expired'] == true) {
      _storage.clearSession().then((_) {
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) =>
              const AuthScreen(),
              transitionsBuilder: (context, animation, secondaryAnimation,
                  child) =>
                  FadeTransition(opacity: animation, child: child),
              transitionDuration: const Duration(milliseconds: 400),
            ),
                (Route<dynamic> route) => false,
          );
        }
      });
    }
  }

  Future<void> _silentDataRefresh({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && _lastRefreshMs != null && (now - _lastRefreshMs! < 30000)) {
      return;
    }
    _lastRefreshMs = now;

    num oldBase = _currentUser["expiry_base"] ?? 0;
    num oldStealth = _currentUser["expiry_stealth"] ?? 0;

    final res = await _api.getMe(token: _userToken);

    _checkSessionExpired(res);

    if (res["status"] == "2fa_required") {
      if (mounted) {
        setState(() => _currentUser["2fa_enabled"] = true);
        await _storage.saveSession(_currentUser);
      }
      return;
    }

    if (res["status"] == "success" && mounted) {
      setState(() {
        _currentUser["balance"] = res["balance"];
        _currentUser["expiry_base"] = res["expiry_base"];
        _currentUser["expiry_stealth"] = res["expiry_stealth"];
        _currentUser["base_slot"] = res["base_slot"] ?? 0;
        _currentUser["stealth_slot"] = res["stealth_slot"] ?? 0;
        _currentUser["2fa_enabled"] = res["2fa_enabled"] ?? false;

        if (res["token"] != null) {
          _userToken = res["token"];
          _currentUser["token"] = _userToken;
        }
      });

      if (_selectedTariff == "base") {
        final trafficRes = await _api.getTraffic(token: _userToken);
        if (trafficRes["status"] == "success" && mounted) {
          setState(() {
            _usedTrafficBytes = trafficRes["used_bytes"] ?? 0;
            _totalTrafficBytes = trafficRes["total_bytes"] ?? (40 * 1024 * 1024 * 1024);
          });
        }
      }

      _updateUserInfo();
      await _storage.saveSession(_currentUser);
      await NotificationService().scheduleSubscriptionNotifications(
        baseExpiryMs: res["expiry_base"],
        stealthExpiryMs: res["expiry_stealth"],
      );

      if ((res["expiry_base"] ?? 0) > oldBase) {
        _snack(t('sub_base_renewed'), success: true);
      }
      if ((res["expiry_stealth"] ?? 0) > oldStealth) {
        _snack(t('sub_stealth_renewed'), success: true);
      }
    }
  }

  String _formatId(String rawId) {
    String clean = rawId.replaceAll(" ", "");
    if (clean.length > 16) clean = clean.substring(0, 16);
    return clean.replaceAllMapped(
        RegExp(r".{4}"), (match) => "${match.group(0)} ").trim();
  }

  int _getDays(num exp) {
    int expMs = exp.toInt();
    int nowMs = DateTime.now().millisecondsSinceEpoch;
    int days = ((expMs - nowMs) / (24 * 60 * 60 * 1000)).floor();
    return days > 0 ? days : 0;
  }

  void _updateUserInfo() {
    setState(() {
      num exp = _selectedTariff == "stealth"
          ? (_currentUser["expiry_stealth"] ?? 0)
          : (_currentUser["expiry_base"] ?? 0);
      _daysLeft = _getDays(exp);
    });
  }

  void _snack(String msg, {bool success = false}) {
    if (!mounted) return;
    _snackTimer?.cancel();
    setState(() {
      _notifText = msg;
      _notifSuccess = success;
      _isNotifVisible = true;
    });

    final int ms = (2000 + (msg.length / 20).floor() * 1000).clamp(2000, 5000);
    _snackTimer = Timer(Duration(milliseconds: ms), () {
      if (mounted) setState(() => _isNotifVisible = false);
    });
  }

  void _openModal(Widget content, {bool dismissible = true}) {
    setState(() {
      _modalContent = content;
      _isModalDismissible = dismissible;
      _isModalVisible = true;
    });
  }

  void _closeModal() {
    FocusScope.of(context).unfocus();
    setState(() => _isModalVisible = false);
  }

// VPN & Account Logic

  Future<void> _toggleVpn() async {
    if (_isConnected || _isConnecting || _isDisconnecting) {
      final stopFuture = _vpn.stop();
      setState(() {});

      await stopFuture;
      _stopVpnStats();

      if (mounted) setState(() {});
      return;
    }

    if (_daysLeft <= 0) {
      _snack(t('checking_sub'), success: true);
      await _silentDataRefresh(force: true);

      if (_daysLeft <= 0) {
        _snack(t('no_sub'));
        _showPayModal();
        return;
      }
    }

    setState(() => _isFetchingKey = true);

    try {
      final resp = await _api.getVpnKey(
          _currentUser["id"], _userPassword, _selectedTariff, token: _userToken);

      _checkSessionExpired(resp);

      if (resp["status"] == "success" && resp["vless_link"] != null) {
        setState(() => _isFetchingKey = false);

        bool started = await _vpn.run(
            resp["vless_link"], useKillswitch: _killswitchEnabled,
            useAdblock: _adblockEnabled);

        if (mounted) {
          setState(() {});
          if (started) {
            _startVpnStats();
          } else {
            _snack(t('err_core'));
          }
        }
      } else {
        if (mounted) {
          setState(() => _isFetchingKey = false);
          _snack(resp["message"] ?? t('err_srv_key'));
        }
      }
    } catch (ex) {
      if (mounted) {
        setState(() => _isFetchingKey = false);
        _snack(t('err_network'));
      }
    } finally {
      if (mounted) {
        setState(() => _isFetchingKey = false);
      }
    }
  }

  Future<void> _handleNetworkSwitch(String newTariff) async {
    _closeModal();
    if (_selectedTariff == newTariff) return;

    setState(() => _selectedTariff = newTariff);
    _updateUserInfo();

    if (_isConnected || _isConnecting) {
      _snack(t('reconnecting'), success: true);
      final stopFuture = _vpn.stop();
      setState(() {});

      await stopFuture;
      _stopVpnStats();
      setState(() {});

      await Future.delayed(const Duration(milliseconds: 1200));

      if (!mounted) return;
      await _toggleVpn();
    }
  }

  Future<void> _triggerFailover() async {
    _closeModal();
    _snack(t('switching_route'));
    try {
      final data = await _api.switchSlot(
          _currentUser["id"], _userPassword, _selectedTariff, token: _userToken);

      _checkSessionExpired(data);

      if (data["status"] == "success") {
        int newSlot = data["new_slot"] ?? 0;
        setState(() {
          if (_selectedTariff == "base") {
            _currentUser["base_slot"] = newSlot;
          } else {
            _currentUser["stealth_slot"] = newSlot;
          }
        });
        await _storage.saveSession(_currentUser);
        _snack(t('route_switched').replaceAll('{n}', (newSlot + 1).toString()), success: true);

        if (_isConnected || _isConnecting) {
          final stopFuture = _vpn.stop();
          setState(() {});

          await stopFuture;
          _stopVpnStats();
          setState(() {});

          await Future.delayed(const Duration(milliseconds: 1200));

          if (!mounted) return;
          await _toggleVpn();
        }
      } else {
        _snack(data["message"] ?? t('err_route_switch'));
      }
    } catch (ex) {
      _snack(t('err_no_conn'));
    }
  }

  Future<void> _logout() async {
    _closeModal();
    _snack(t('logging_out'), success: true);
    try {
      if (_isConnected || _isConnecting || _isDisconnecting) {
        await _vpn.stop();
        if (!mounted) return;
        setState(() {});
      }
    } catch (e) {
      debugPrint(e.toString());
    }
    await _storage.clearSession();
    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder(
          pageBuilder: (context, animation,
              secondaryAnimation) => const AuthScreen(),
          transitionsBuilder: (context, animation, secondaryAnimation,
              child) => FadeTransition(opacity: animation, child: child),
          transitionDuration: const Duration(milliseconds: 400),
        ),
            (Route<dynamic> route) => false
    );
  }

// 2FA Logic

  Future<void> _setup2FA() async {
    _closeModal();
    _snack(t('checking_status'), success: true);

    final statusRes = await _api.check2FaStatus(
        _currentUser["id"], _userPassword, token: _userToken);
    bool isEnabled = statusRes["status"] == "success" &&
        statusRes["is_enabled"] == true;

    if (isEnabled) {
      _disable2faCtrl.clear();
      _openModal(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.security, color: AppColors.error, size: 40),
            const SizedBox(height: 15),
            Text(t('disable_2fa'),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(t('disable_2fa_desc'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 15),
            TextFormField(
              controller: _disable2faCtrl,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 6,
              style: const TextStyle(fontFamily: ComponentStyles.dataFont,
                  fontSize: 28,
                  letterSpacing: 8,
                  color: AppColors.accent),
              decoration: InputDecoration(
                  hintText: t('code_hint'),
                  hintStyle: const TextStyle(fontSize: 16,
                      letterSpacing: 0,
                      color: AppColors.textMuted),
                  counterText: "",
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(vertical: 20)),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                if (_disable2faCtrl.text.length == 6) {
                  _snack(t('disabling'));
                  final res = await _api.disable2fa(
                      _currentUser["id"], _userPassword,
                      _disable2faCtrl.text, token: _userToken);
                  if (res["status"] == "success") {
                    _closeModal();
                    setState(() => _currentUser["2fa_enabled"] = false);
                    await _storage.saveSession(_currentUser);
                    _snack(t('2fa_disabled'), success: true);
                  } else {
                    _snack(res["message"] ?? t('err_invalid_code'));
                  }
                } else {
                  _snack(t('enter_6_digits'));
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 45),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15))),
              child: Text(t('disable_prot'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 5),
            TextButton(onPressed: _closeModal,
                child: Text(t('cancel'),
                    style: const TextStyle(color: AppColors.textMuted))),
          ],
        ),
      );
    } else {
      _openModal(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.security, color: AppColors.accent, size: 40),
            const SizedBox(height: 15),
            Text(t('enable_2fa'),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(t('enable_2fa_desc'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                _closeModal();
                _snack(t('gen_key'), success: true);
                final res = await _api.enable2fa(
                    _currentUser["id"], _userPassword, token: _userToken);

                if (res["status"] == "success" && res["secret"] != null) {
                  String secret = res["secret"];
                  _openModal(
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.security, color: AppColors.accent,
                              size: 40),
                          const SizedBox(height: 15),
                          Text(t('2fa_key_title'), style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center),
                          const SizedBox(height: 10),
                          Text(t('2fa_key_desc'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.textMuted)),
                          const SizedBox(height: 15),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 15, vertical: 12),
                            decoration: BoxDecoration(color: AppColors.accent
                                .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: AppColors.accent.withValues(
                                        alpha: 0.3))),
                            child: Text(secret, style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: AppColors.accent,
                                letterSpacing: 2), textAlign: TextAlign
                                .center),
                          ),
                          const SizedBox(height: 15),
                          ElevatedButton.icon(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: secret));
                              _snack(t('key_copied'), success: true);
                            },
                            icon: const Icon(Icons.copy_rounded, color: Colors
                                .white, size: 18),
                            label: Text(t('copy_key')),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.surface,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(double.infinity, 45),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(15))),
                          ),
                          const SizedBox(height: 10),
                          ElevatedButton(
                            onPressed: () async {
                              _closeModal();
                              setState(() =>
                              _currentUser["2fa_enabled"] = true);
                              await _storage.saveSession(_currentUser);
                              _snack(t('2fa_activated'), success: true);
                            },
                            style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.accent,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(double.infinity, 45),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(15))),
                            child: Text(t('saved_key'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                      dismissible: false
                  );
                } else {
                  _snack(res["message"] ?? t('err_key_gen'));
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 45),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15))),
              child: Text(
                  t('btn_gen_key'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 5),
            TextButton(onPressed: _closeModal,
                child: Text(t('cancel'),
                    style: const TextStyle(color: AppColors.textMuted))),
          ],
        ),
      );
    }
  }

// Live Crypto Rates

  Future<void> _fetchLiveCryptoRates(StateSetter setModalState) async {
    if (!_isModalVisible) return;
    setModalState(() => _isLoadingInvoice = true);
    try {
      final res = await _api.fetchLiveCryptoRates();
      if (!mounted || !_isModalVisible) return;

      if (res["status"] == "success") {
        final List data = res["data"];
        setModalState(() {
          for (var item in data) {
            if (item['symbol'] == 'TONUSDT') {
              _tonRate = double.parse(item['price']);
            }
            if (item['symbol'] == 'LTCUSDT') {
              _ltcRate = double.parse(item['price']);
            }
            if (item['symbol'] == 'ETHUSDT') {
              _ethRate = double.parse(item['price']);
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        _snack(t('err_rates'));
      }
    }
    if (_isModalVisible) setModalState(() => _isLoadingInvoice = false);
  }

// Payment System

  Future<void> _processFiatPayment(String tariff, int months, String currency,
      String method, StateSetter setModalState) async {
    setModalState(() => _isLoadingInvoice = true);

    try {
      String returnUrl = "${AppConfig.apiBaseUrl}/success";
      final data = await _api.createFiatInvoice(
          _currentUser["id"], tariff, months, currency, method, returnUrl, token: _userToken);

      setModalState(() => _isLoadingInvoice = false);

      if (data["status"] == "success" && data["pay_url"] != null) {
        setModalState(() {
          _fiatPayUrl = data["pay_url"];
          _payStep = 5;
        });
      } else {
        _snack(data["message"] ?? t('err_cashier'));
      }
    } catch (e) {
      setModalState(() => _isLoadingInvoice = false);
      _snack(t('err_no_conn'));
    }
  }

  Future<void> _checkFiatPaymentStatus() async {
    _snack(t('checking_pay'), success: true);

    num oldBase = _currentUser["expiry_base"] ?? 0;
    num oldStealth = _currentUser["expiry_stealth"] ?? 0;

    final res = await _api.login(_currentUser["id"], _userPassword);
    if (!mounted) return;

    if (res["status"] == "success") {
      num newBase = res["expiry_base"] ?? 0;
      num newStealth = res["expiry_stealth"] ?? 0;

      if (newBase > oldBase || newStealth > oldStealth) {
        _closeModal();
        _snack(t('pay_found'), success: true);
        if (mounted) {
          setState(() {
            _currentUser["balance"] = res["balance"];
            _currentUser["expiry_base"] = newBase;
            _currentUser["expiry_stealth"] = newStealth;
            _currentUser["base_slot"] = res["base_slot"] ?? 0;
            _currentUser["stealth_slot"] = res["stealth_slot"] ?? 0;
            _currentUser["2fa_enabled"] = res["2fa_enabled"] ?? false;
          });
          _updateUserInfo();
          await _storage.saveSession(_currentUser);
        }
      } else {
        _snack(t('pay_not_found'));
      }
    } else {
      _snack(t('err_status'));
    }
  }

  Future<void> _checkCryptoPayment(String txnId) async {
    _snack(t('checking_pay'));
    final res = await _api.checkCryptoTx(txnId, _currentUser['id'], _userPassword, token: _userToken);
    if (!mounted) return;

    if (res['status'] == 'success') {
      if (res['paid'] == true) {
        _closeModal();
        _snack(t('pay_found'), success: true);
        _silentDataRefresh(force: true);
      } else {
        _snack(res['message'] ?? t('wait_conf'));
      }
    } else {
      _snack(res['message'] ?? t('err_tx_check'));
    }
  }

  void _showPayModal() {
    setState(() {
      _payStep = 1;
      _payTariff = _selectedTariff;
      _payDuration = 1;
      _payCustomDur = false;
      _appCurrency =
      LocalizationService.currentLang == 'RU' ? 'RUB' : (LocalizationService
          .currentLang == 'FI' ? 'EUR' : 'USD');
      _payMethod = _appCurrency == 'RUB' ? "sbp" : "card_int";
      _cryptoCurrency = "TON";
      _customDurController.text = "";
      _fiatPayUrl = null;
      _cryptoData = null;
      _isLoadingInvoice = false;
    });

    _openModal(
        StatefulBuilder(
            builder: (context, setModalState) {
              List<Widget> contentControls = [];
              Widget? actionBtn;

              double priceVal = ((AppConfig.pricing[_payTariff]?[_appCurrency] ?? 0) as num).toDouble() * _payDuration;
              double priceUsdForCrypto = ((AppConfig.pricing[_payTariff]?['USD'] ?? 0) as num).toDouble() * _payDuration;

              Widget buildDurBox(String text, bool selected,
                  VoidCallback onClick) {
                Color borderCol = selected ? AppColors.accent : Colors.white
                    .withValues(alpha: 0.1);
                Color bgCol = selected ? AppColors.accent.withValues(
                    alpha: 0.1) : Colors.white.withValues(alpha: 0.05);
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onClick();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 55,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: bgCol,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: borderCol, width: selected ? 2 : 1)),
                    child: Text(text, textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: selected ? AppColors.accent : Colors
                                .white)),
                  ),
                );
              }

              Widget buildFolded(String stepName, String val,
                  VoidCallback onClick) {
                return GestureDetector(
                  onTap: onClick,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 15, vertical: 12),
                    margin: const EdgeInsets.only(bottom: 5),
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.02),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.05))),
                    child: Row(
                      children: [
                        Text(stepName, style: const TextStyle(
                            fontSize: 12, color: AppColors.textMuted)),
                        const Spacer(),
                        Text(val, style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: AppColors.textPrimary)),
                        const SizedBox(width: 10),
                        const Icon(Icons.edit_rounded, size: 14,
                            color: AppColors.textMuted),
                      ],
                    ),
                  ),
                );
              }

              if (_payStep == 1) {
                contentControls = [
                  Text(t('pay_step1'), style: const TextStyle(fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 15),
                  GestureDetector(
                    onTap: () => setModalState(() => _payTariff = "base"),
                    child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                            color: _payTariff == "base" ? AppColors.accent
                                .withValues(alpha: 0.1) : Colors.white
                                .withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(color: _payTariff == "base"
                                ? AppColors.accent
                                : Colors.white.withValues(alpha: 0.1),
                                width: _payTariff == "base" ? 2 : 1)),
                        child: Row(children: [
                          Container(padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: Colors.white
                                  .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12)),
                              child: Icon(
                                  Icons.wifi_rounded, color: _payTariff ==
                                  "base" ? AppColors.accent : AppColors
                                  .textMuted, size: 24)),
                          const SizedBox(width: 15),
                          Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t('base_net'), style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    fontSize: 15)),
                                Text('${getPriceStr(
                                    "base", _appCurrency)} / ${t(
                                    'month_short')}', style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.accent,
                                    fontSize: 13)),
                                const SizedBox(height: 2),
                                Text(t('base_desc'), style: const TextStyle(
                                    fontSize: 11, color: AppColors.textMuted))
                              ]))
                        ])),
                  ),
                  GestureDetector(
                    onTap: () => setModalState(() => _payTariff = "stealth"),
                    child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                            color: _payTariff == "stealth" ? AppColors.accent
                                .withValues(alpha: 0.1) : Colors.white
                                .withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                                color: _payTariff == "stealth" ? AppColors
                                    .accent : Colors.white.withValues(
                                    alpha: 0.1),
                                width: _payTariff == "stealth" ? 2 : 1)),
                        child: Row(children: [
                          Container(padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: Colors.white
                                  .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12)),
                              child: Icon(
                                  Icons.security_rounded, color: _payTariff ==
                                  "stealth" ? AppColors.accent : AppColors
                                  .textMuted, size: 24)),
                          const SizedBox(width: 15),
                          Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t('stealth_net'), style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    fontSize: 15)),
                                Text('${getPriceStr(
                                    "stealth", _appCurrency)} / ${t(
                                    'month_short')}', style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.accent,
                                    fontSize: 13)),
                                const SizedBox(height: 2),
                                Text(t('stealth_desc'),
                                    style: const TextStyle(fontSize: 11,
                                        color: AppColors.textMuted))
                              ]))
                        ])),
                  )
                ];
                actionBtn = ElevatedButton(
                    onPressed: () => setModalState(() => _payStep = 2),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                                AppBorderRadius.full))),
                    child: Text(t('btn_next_time')));
              }
              else if (_payStep == 2) {
                contentControls = [
                  buildFolded(t('network'),
                      _payTariff == "base" ? t('base_net') : t(
                          'stealth_net'), () =>
                          setModalState(() => _payStep = 1)),
                  const SizedBox(height: 10),
                  Text(t('pay_step2'), style: const TextStyle(fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      Expanded(child: buildDurBox("1 ${t('month_short')}",
                          _payDuration == 1 && !_payCustomDur, () =>
                              setModalState(() {
                                _payDuration = 1;
                                _payCustomDur = false;
                              }))),
                      const SizedBox(width: 10),
                      Expanded(child: buildDurBox("3 ${t('month_short')}",
                          _payDuration == 3 && !_payCustomDur, () =>
                              setModalState(() {
                                _payDuration = 3;
                                _payCustomDur = false;
                              }))),
                      const SizedBox(width: 10),
                      Expanded(child: buildDurBox("6 ${t('month_short')}",
                          _payDuration == 6 && !_payCustomDur, () =>
                              setModalState(() {
                                _payDuration = 6;
                                _payCustomDur = false;
                              }))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  buildDurBox(t('custom_dur'), _payCustomDur, () =>
                      setModalState(() => _payCustomDur = true)),
                  if (_payCustomDur) ...[
                    const SizedBox(height: 15),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _customDurController,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(fontSize: 16),
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(3),
                            ],
                            decoration: ComponentStyles
                                .inputStyle(t('months_count'))
                                .copyWith(contentPadding: const EdgeInsets
                                .symmetric(horizontal: 15)),
                            onChanged: (val) {
                              setModalState(() {
                                _payDuration = int.tryParse(val) ?? 0;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(t('month_short'), style: const TextStyle(
                            color: AppColors.textMuted)),
                      ],
                    ),
                  ],
                  const SizedBox(height: 15),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(t('total'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 15)),
                        Text(
                          _appCurrency == 'USD' ? '\$${priceVal.toStringAsFixed(2)}' : (_appCurrency == 'EUR' ? '€${priceVal.toStringAsFixed(2)}' : '${priceVal.toInt()} ₽'),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.accent, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ];
                actionBtn = ElevatedButton(
                  onPressed: _payDuration > 0 ? () {
                    setModalState(() => _payStep = 3);
                    if (_tonRate == null && !_isLoadingInvoice) {
                      _fetchLiveCryptoRates(setModalState);
                    }
                  } : null,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                              AppBorderRadius.full))),
                  child: Text(t('btn_next_pay')),
                );
              }
              else if (_payStep == 3) {
                bool isBtnDisabled = false;
                bool isFiat = _payMethod == "card_int" || _payMethod == "sbp";

                String displayFinalPrice = '';
                if (_appCurrency == 'USD') {
                  displayFinalPrice = '\$${priceVal.toStringAsFixed(2)}';
                } else if (_appCurrency == 'EUR') {
                  displayFinalPrice = '€${priceVal.toStringAsFixed(2)}';
                } else {
                  displayFinalPrice = '${priceVal.toInt()} ₽';
                }

                String btnText = t('pay_amount').replaceAll('{n}', displayFinalPrice);

                if (_payMethod == "crypto") {
                  if (_isLoadingInvoice) {
                    btnText = t('loading_rates');
                    isBtnDisabled = true;
                  } else {
                    double displayAmount = priceUsdForCrypto;
                    bool rateError = false;

                    if (_cryptoCurrency == "TON") {
                      if (_tonRate != null) {
                        displayAmount = priceUsdForCrypto / _tonRate!;
                      } else {
                        rateError = true;
                      }
                    } else if (_cryptoCurrency == "ETH") {
                      if (_ethRate != null) {
                        displayAmount = priceUsdForCrypto / _ethRate!;
                      } else {
                        rateError = true;
                      }
                    } else if (_cryptoCurrency == "LTC") {
                      if (_ltcRate != null) {
                        displayAmount = priceUsdForCrypto / _ltcRate!;
                      } else {
                        rateError = true;
                      }
                    } else if (_cryptoCurrency == "USDT") {
                      displayAmount = priceUsdForCrypto;
                    }

                    if (rateError) {
                      btnText = t('err_rate');
                      isBtnDisabled = true;
                    } else {
                      int decimals = (_cryptoCurrency == "ETH" || _cryptoCurrency == "LTC") ? 4 : 2;
                      btnText = t('pay_crypto_amount').replaceAll('{n}', displayAmount.toStringAsFixed(decimals)).replaceAll('{c}', _cryptoCurrency);
                    }
                  }

                } else if (_payMethod == "stars") {
                  btnText = t('open_tg');
                } else if (_isLoadingInvoice) {
                  btnText = t('loading_cashier');
                  isBtnDisabled = true;
                }

                contentControls = [
                  buildFolded(t('network'),
                      _payTariff == "base" ? t('base_net') : t(
                          'stealth_net'), () =>
                          setModalState(() => _payStep = 1)),
                  buildFolded(t('duration'),
                      "$_payDuration ${t('month_short')}", () =>
                          setModalState(() => _payStep = 2)),
                  const SizedBox(height: 10),
                  Text(t('pay_step3'), style: const TextStyle(fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 15),

                  GestureDetector(
                    onTap: () =>
                        setModalState(() {
                          if (!isFiat) {
                            _appCurrency = LocalizationService.currentLang == 'RU'
                                ? 'RUB'
                                : (LocalizationService.currentLang == 'FI' ? 'EUR' : 'USD');
                            _payMethod = _appCurrency == 'RUB' ? "sbp" : "card_int";
                          }
                        }),
                    child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                            color: isFiat ? AppColors.accent.withValues(
                                alpha: 0.1) : Colors.white.withValues(
                                alpha: 0.05),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                                color: isFiat ? AppColors.accent : Colors
                                    .white.withValues(alpha: 0.1),
                                width: isFiat ? 2 : 1)
                        ),
                        child: Row(children: [
                          Container(padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: Colors.white
                                  .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12)),
                              child: Icon(Icons.credit_card_rounded,
                                  color: isFiat ? AppColors.accent : AppColors
                                      .textMuted, size: 24)),
                          const SizedBox(width: 15),
                          Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t('bank_card'), style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    fontSize: 15)),
                                const SizedBox(height: 2),
                                Text(t('pay_any_curr'),
                                    style: const TextStyle(fontSize: 11,
                                        color: AppColors.textMuted))
                              ]))
                        ])
                    ),
                  ),

                  AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOutCubic,
                      child: isFiat ? Padding(
                        padding: const EdgeInsets.only(top: 5, bottom: 10),
                        child: Row(
                          children: [
                            Expanded(
                                child: buildDurBox(
                                    "USD",
                                    _appCurrency == 'USD',
                                        () => _snack(t('err_payment_unavailable'))
                                )
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                                child: buildDurBox(
                                    "EUR",
                                    _appCurrency == 'EUR',
                                        () => _snack(t('err_payment_unavailable'))
                                )
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: buildDurBox(
                                "RUB", _appCurrency == 'RUB', () =>
                                setModalState(() {
                                  _payMethod = "sbp";
                                  _appCurrency = "RUB";
                                }))),
                          ],
                        ),
                      ) : const SizedBox.shrink()
                  ),

                  GestureDetector(
                    onTap: () {
                      setModalState(() => _payMethod = "crypto");
                      if (_tonRate == null &&
                          !_isLoadingInvoice) {
                        _fetchLiveCryptoRates(
                            setModalState);
                      }
                    },
                    child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                            color: _payMethod == "crypto" ? AppColors.accent
                                .withValues(alpha: 0.1) : Colors.white
                                .withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                                color: _payMethod == "crypto" ? AppColors
                                    .accent : Colors.white.withValues(
                                    alpha: 0.1),
                                width: _payMethod == "crypto" ? 2 : 1)),
                        child: Row(children: [
                          Container(padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: Colors.white
                                  .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12)),
                              child: Icon(Icons.currency_bitcoin_rounded,
                                  color: _payMethod == "crypto"
                                      ? AppColors.accent
                                      : AppColors.textMuted,
                                  size: 24)),
                          const SizedBox(width: 15),
                          Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t('crypto'), style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    fontSize: 15)),
                                const SizedBox(height: 2),
                                Text(t('crypto_desc'), style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textMuted))
                              ]))
                        ])),
                  ),

                  AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOutCubic,
                      child: _payMethod == "crypto" ? Padding(
                        padding: const EdgeInsets.only(top: 5, bottom: 10),
                        child: Column(
                          children: [
                            Row(children: [
                              Expanded(child: buildDurBox("USDT (TRC20)",
                                  _cryptoCurrency == "USDT", () {
                                    if (priceUsdForCrypto < 4.99) {
                                      _snack(t('min_usdt'));
                                    } else {
                                      setModalState(() =>
                                      _cryptoCurrency = "USDT");
                                    }
                                  })),
                              const SizedBox(width: 10),
                              Expanded(child: buildDurBox(
                                  "TON", _cryptoCurrency == "TON", () =>
                                  setModalState(() =>
                                  _cryptoCurrency = "TON"))),
                            ]),
                            const SizedBox(height: 10),
                            Row(children: [
                              Expanded(child: buildDurBox(
                                  "LTC", _cryptoCurrency == "LTC", () =>
                                  setModalState(() =>
                                  _cryptoCurrency = "LTC"))),
                              const SizedBox(width: 10),
                              Expanded(child: buildDurBox(
                                  "ETH", _cryptoCurrency == "ETH", () =>
                                  setModalState(() =>
                                  _cryptoCurrency = "ETH"))),
                            ])
                          ],
                        ),
                      ) : const SizedBox.shrink()
                  ),

                  GestureDetector(
                    onTap: () => setModalState(() => _payMethod = "stars"),
                    child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                            color: _payMethod == "stars" ? AppColors.accent
                                .withValues(alpha: 0.1) : Colors.white
                                .withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                                color: _payMethod == "stars" ? AppColors
                                    .accent : Colors.white.withValues(
                                    alpha: 0.1),
                                width: _payMethod == "stars" ? 2 : 1)
                        ),
                        child: Row(children: [
                          Container(padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: Colors.white
                                  .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12)),
                              child: Icon(Icons.star_rounded,
                                  color: _payMethod == "stars"
                                      ? Colors.orange
                                      : AppColors.textMuted, size: 24)),
                          const SizedBox(width: 15),
                          Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text("Telegram Stars", style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    fontSize: 15)),
                                const SizedBox(height: 2),
                                Text(t('via_tg_bot'),
                                    style: const TextStyle(fontSize: 11,
                                        color: AppColors.textMuted))
                              ]))
                        ])
                    ),
                  ),

                  AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOutCubic,
                      child: _payMethod == "stars" ? Padding(
                          padding: const EdgeInsets.only(top: 5, bottom: 10),
                          child: Text(t('tg_bot_only'),
                              style: const TextStyle(
                                  color: AppColors.textMuted, fontSize: 12),
                              textAlign: TextAlign.center
                          )
                      ) : const SizedBox.shrink()
                  ),
                ];

                actionBtn = ElevatedButton(
                  onPressed: isBtnDisabled ? null : () async {
                    if (_payMethod == "stars") {
                      String lang = LocalizationService.currentLang;
                      String targetId = _currentUser["id"];
                      String payload = "pay_${_payTariff}_${_payDuration}_${targetId}_$lang";
                      launchUrl(Uri.parse("${AppConfig.telegramBotUrl}?start=$payload"),
                          mode: LaunchMode.externalApplication);

                      return;
                    }

                    if (_payMethod == "crypto") {
                      setModalState(() => _isLoadingInvoice = true);
                      String apiCurrency = _cryptoCurrency == "USDT"
                          ? "USDT_TRX"
                          : _cryptoCurrency;
                      final res = await _api.createCryptoInvoice(
                          _currentUser["id"], _payTariff, _payDuration,
                          apiCurrency, token: _userToken);
                      setModalState(() => _isLoadingInvoice = false);
                      if (res["status"] == "success") {
                        setModalState(() {
                          _cryptoData = res;
                          _payStep = 4;
                        });
                      } else {
                        _snack(res["message"] ?? t('err_cashier'));
                      }
                    } else {
                      _processFiatPayment(
                          _payTariff, _payDuration, _appCurrency, _payMethod,
                          setModalState);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 55),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                              AppBorderRadius.full))),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(btnText, style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(width: 5),
                      if (!isBtnDisabled) Icon(_payMethod == "stars"
                          ? Icons.open_in_new_rounded
                          : Icons.arrow_forward_rounded, size: 18),
                    ],
                  ),
                );
              }
              else if (_payStep == 4 && _cryptoData != null) {
                String wallet = _cryptoData!["wallet_hash"];
                String amount = _cryptoData!["amount_crypto"];
                String txnId = _cryptoData!["txn_id"];

                contentControls = [
                  Text(t('awaiting_pay'), style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.accent), textAlign: TextAlign.center),
                  const SizedBox(height: 10),
                  Text(t('send_exact'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12)),
                  const SizedBox(height: 20),

                  Text(t('amount_to_pay'), style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
                  Container(
                      margin: const EdgeInsets.only(top: 5, bottom: 15),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(10)),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text("$amount $_cryptoCurrency",
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                    color: Colors.white)),
                            GestureDetector(
                              onTap: () {
                                Clipboard.setData(
                                    ClipboardData(text: amount));
                                _snack(t('amount_copied'), success: true);
                              },
                              child: const Icon(
                                  Icons.copy_rounded, color: AppColors.accent,
                                  size: 22),
                            )
                          ]
                      )
                  ),

                  Text(t('wallet_address'), style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
                  Container(
                      margin: const EdgeInsets.only(top: 5, bottom: 5),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(10)),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                                child: Text(wallet, style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: Colors.white))),
                            const SizedBox(width: 10),
                            GestureDetector(
                              onTap: () {
                                Clipboard.setData(
                                    ClipboardData(text: wallet));
                                _snack(t('address_copied'), success: true);
                              },
                              child: const Icon(
                                  Icons.copy_rounded, color: AppColors.accent,
                                  size: 22),
                            )
                          ]
                      )
                  ),
                ];

                actionBtn = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton(
                      onPressed: () => _checkCryptoPayment(txnId),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.success,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 55),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                  AppBorderRadius.full))),
                      child: Text(t('btn_check_pay'), style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                    const SizedBox(height: 5),
                    TextButton(
                      onPressed: () => setModalState(() => _payStep = 3),
                      child: Text(t('back_to_select'),
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 13)),
                    ),
                  ],
                );
              }
              else if (_payStep == 5 && _fiatPayUrl != null) {
                contentControls = [
                  Text(t('fiat_pay_title'), style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.accent), textAlign: TextAlign.center),
                  const SizedBox(height: 15),

                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppColors.error.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: AppColors.error, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            t('fiat_warn'),
                            style: const TextStyle(color: AppColors.error,
                                fontSize: 11,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 15),

                  Text(
                    t('fiat_redirect'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 20),

                  ElevatedButton.icon(
                    onPressed: () async {
                      final Uri url = Uri.parse(_fiatPayUrl!);
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url, mode: LaunchMode.externalApplication);
                      } else {
                        _snack(t('err_browser'));
                      }
                    },
                    icon: const Icon(Icons.open_in_browser_rounded, color: Colors.white),
                    label: Text(t('btn_open_gateway')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 55),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15)),
                    ),
                  ),
                  const SizedBox(height: 10),

                  Center(
                    child: TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _fiatPayUrl!));
                        _snack(t('link_copied'), success: true);
                      },
                      icon: const Icon(Icons.copy_rounded, size: 16,
                          color: AppColors.textMuted),
                      label: Text(
                        t('btn_copy_link'),
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12),
                      ),
                    ),
                  ),
                ];

                actionBtn = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton(
                      onPressed: _checkFiatPaymentStatus,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.success,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 55),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                                AppBorderRadius.full)),
                      ),
                      child: Text(t('btn_check_pay'), style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                    const SizedBox(height: 5),
                    TextButton(
                      onPressed: () => setModalState(() => _payStep = 3),
                      child: Text(t('back_to_select'),
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 13)),
                    ),
                  ],
                );
              }

              return ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 650),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text((_payStep == 4 || _payStep == 5) ? t('payment') : t('pay_title'),
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                        IconButton(icon: const Icon(
                            Icons.close_rounded, color: AppColors.textMuted),
                            onPressed: _closeModal),
                      ],
                    ),
                    Divider(color: Colors.white.withValues(alpha: 0.1),
                        height: 1),
                    const SizedBox(height: 5),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: contentControls),
                      ),
                    ),
                    Padding(padding: const EdgeInsets.only(top: 15),
                        child: actionBtn),
                  ],
                ),
              );
            }
        )
    );
  }

  void _showNetworkSelector() {
    Widget networkOption(String title, String sub, IconData icon,
        bool selected, VoidCallback onClick) {
      Color color = selected ? AppColors.accent : Colors.white;
      Color bg = selected ? AppColors.accent.withValues(alpha: 0.1) : Colors
          .white.withValues(alpha: 0.05);
      Color border = selected ? AppColors.accent : Colors.transparent;
      return GestureDetector(
        onTap: onClick,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(15),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(color: bg,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: border)),
          child: Row(
            children: [
              Container(padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, color: color)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                  Text(sub,
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ]),
              )
            ],
          ),
        ),
      );
    }

    _openModal(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t('pay_step1'), style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
          const SizedBox(height: 15),
          networkOption(t('base_net'), t('base_desc'), Icons.wifi_rounded,
              _selectedTariff == "base", () => _handleNetworkSwitch("base")),
          networkOption(
              t('stealth_net'), t('stealth_desc'), Icons.security_rounded,
              _selectedTariff == "stealth", () =>
              _handleNetworkSwitch("stealth")),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: _showPlanComparison,
            icon: const Icon(Icons.info_outline_rounded, color: AppColors.accent, size: 18),
            label: Text(t('plan_compare'), style: const TextStyle(color: AppColors.accent)),
          ),
          TextButton(onPressed: _closeModal,
              child: Text(t('cancel'),
                  style: const TextStyle(color: AppColors.textMuted))),
        ],
      ),
    );
  }

  void _showChangePasswordModal() async {
    _closeModal();
    _snack(t('checking_sec'), success: true);

    final statusRes = await _api.check2FaStatus(
        _currentUser["id"], _userPassword, token: _userToken);
    bool isEnabled = statusRes["status"] == "success" &&
        statusRes["is_enabled"] == true;

    if (!isEnabled) {
      _snack(t('err_need_2fa'));
      return;
    }

    _newPassCtrl.clear();
    _totpChangeCtrl.clear();

    _openModal(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
              Icons.password_rounded, color: AppColors.accent, size: 40),
          const SizedBox(height: 15),
          Text(t('change_pwd_title'),
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 15),
          TextField(
            controller: _newPassCtrl,
            obscureText: true,
            decoration: ComponentStyles.inputStyle(t('new_pwd')),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _totpChangeCtrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: ComponentStyles.inputStyle(t('2fa_code')).copyWith(
                counterText: ""),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () async {
              if (_newPassCtrl.text.length < AppConfig.minPasswordLength ||
                  !RegExp(r'^(?=.*[A-Za-z])(?=.*\d)(?=.*[\W_]).+$').hasMatch(
                      _newPassCtrl.text)) {
                _snack(t('err_pwd_req'));
                return;
              }
              if (_totpChangeCtrl.text.length != 6) {
                _snack(t('err_6_code'));
                return;
              }

              _snack(t('changing_pwd'));

              final res = await _api.changePassword(
                  _currentUser["id"], _userPassword, _newPassCtrl.text,
                  _totpChangeCtrl.text, token: _userToken);

              if (res["status"] == "success") {
                _closeModal();
                _snack(t('pwd_changed'), success: true);
                await _storage.clearToken();
                if (mounted) {
                  await Future.delayed(const Duration(seconds: 2));
                  if (mounted) _logout();
                }
              } else {
                _snack(res["message"] ?? t('err_pwd_change'));
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 45),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15))),
            child: Text(t('save'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 5),
          TextButton(onPressed: () {
            _closeModal();
            _showSettings();
          },
              child: Text(t('cancel'),
                  style: const TextStyle(color: AppColors.textMuted))),
        ],
      ),
    );
  }

  void _showDeleteAccountModal() async {
    _closeModal();
    final statusRes = await _api.check2FaStatus(
        _currentUser["id"], _userPassword, token: _userToken);
    bool is2FaEnabled = statusRes["status"] == "success" &&
        statusRes["is_enabled"] == true;

    _delPassCtrl.clear();
    _delTotpCtrl.clear();

    _openModal(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_rounded, color: AppColors.error, size: 40),
          const SizedBox(height: 15),
          Text(t('del_acc_title'),
              style: const TextStyle(fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.error)),
          const SizedBox(height: 10),
          Text(t('del_acc_desc'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textMuted)),
          const SizedBox(height: 15),
          TextField(
            controller: _delPassCtrl,
            obscureText: true,
            decoration: ComponentStyles.inputStyle(t('curr_pwd')),
          ),
          if (is2FaEnabled) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _delTotpCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: ComponentStyles.inputStyle(t('enter_2fa')).copyWith(
                  counterText: ""),
            ),
          ],
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () async {
              if (_delPassCtrl.text.isEmpty) {
                _snack(t('enter_pwd'));
                return;
              }
              if (is2FaEnabled && _delTotpCtrl.text.length != 6) {
                _snack(t('enter_2fa'));
                return;
              }

              _closeModal();
              _snack(t('deleting_data'));

              final res = await _api.deleteAccount(
                  _currentUser["id"], _delPassCtrl.text,
                  totpCode: is2FaEnabled ? _delTotpCtrl.text : null, token: _userToken);

              if (res["status"] == "success") {
                _logout();
                _snack(t('acc_deleted'), success: true);
              } else {
                _snack(res["message"] ?? t('err_delete'));
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 45),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15))),
            child: Text(t('del_perm'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 5),
          TextButton(onPressed: () {
            _closeModal();
            _showSettings();
          },
              child: Text(t('cancel'),
                  style: const TextStyle(color: AppColors.textMuted))),
        ],
      ),
    );
  }

  void _showFailoverConfirmModal() {
    _openModal(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t('recovery_title'),
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
          const SizedBox(height: 10),
          Text(t('recovery_desc'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textMuted)),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _triggerFailover,
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 45),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15))),
            child: Text(
                t('switch_route_btn'),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
          ),
          const SizedBox(height: 5),
          TextButton(onPressed: () {
            _closeModal();
            _showSettings();
          },
              child: Text(t('cancel'),
                  style: const TextStyle(color: AppColors.textMuted))),
        ],
      ),
    );
  }

  void _showPanicDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
          ),
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: AppColors.error),
              const SizedBox(width: 10),
              Text(
                t('panic_title'),
                style: const TextStyle(color: AppColors.error,
                    fontWeight: FontWeight.bold,
                    fontSize: 16),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('panic_desc'),
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 15),
              Text(
                t('panic_bullets'),
                style: const TextStyle(color: AppColors.error, fontSize: 13, fontWeight: FontWeight.bold, height: 1.4),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(t('panic_cancel'),
                  style: const TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                _closeModal();

                _snack(t('panic_exec'), success: true);

                try {
                  await _vpn.stop();
                } catch (_) {}
                await _storage.clearSession();

                if (!mounted) return;

                Navigator.of(context).pushAndRemoveUntil(
                    PageRouteBuilder(
                      pageBuilder: (context, anim,
                          anim2) => const AuthScreen(),
                      transitionsBuilder: (context, anim, anim2, child) =>
                          FadeTransition(opacity: anim, child: child),
                      transitionDuration: const Duration(milliseconds: 500),
                    ),
                        (Route<dynamic> route) => false
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                t('panic_destroy'),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }

// Traffic Gauge
  Widget _buildTrafficGauge() {
    if (_selectedTariff != "base") return const SizedBox.shrink();

    double percent = (_usedTrafficBytes / _totalTrafficBytes).clamp(0.0, 1.0);
    double remainingGb = (_totalTrafficBytes - _usedTrafficBytes) / (1024 * 1024 * 1024);

    Color gaugeColor = AppColors.success;
    if (remainingGb < 10) gaugeColor = Colors.orange;
    if (remainingGb < 2) gaugeColor = AppColors.error;

    return Padding(
      padding: const EdgeInsets.only(top: 15, left: 5, right: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(t('traffic_left', n: remainingGb.toStringAsFixed(1)),
                  style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
              Text("${(percent * 100).toInt()}%",
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: gaugeColor)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: percent,
              backgroundColor: Colors.white.withValues(alpha: 0.05),
              valueColor: AlwaysStoppedAnimation<Color>(gaugeColor),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

// Plan Comparison
  void _showPlanComparison() {
    _closeModal();
    _openModal(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline_rounded, color: AppColors.accent, size: 40),
            const SizedBox(height: 15),
            Text(t('plan_compare'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(flex: 2, child: SizedBox()),
                  Expanded(flex: 3, child: Text('Base', textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted,
                          fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text('Stealth', textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 12, color: AppColors.accent,
                          fontWeight: FontWeight.bold))),
                ],
              ),
            ),
            _buildComparisonRow(t('plan_traffic'), t('plan_base_traffic'), t('plan_unlimited')),
            _buildComparisonRow(t('plan_speed'), t('plan_std'), t('plan_max')),
            _buildComparisonRow(t('ad_title'), t('no'), t('available')),
            _buildComparisonRow(t('plan_priority'), t('plan_normal'), t('plan_high')),

            const SizedBox(height: 25),
            ElevatedButton(
              onPressed: _closeModal,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              child: Text(t('got_it'), style: const TextStyle(fontWeight: FontWeight.bold)),
            )
          ],
        )
    );
  }

  Widget _buildComparisonRow(String label, String base, String stealth) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 13))),
          Expanded(flex: 3, child: Text(base, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Colors.white))),
          Expanded(flex: 3, child: Text(stealth, textAlign: TextAlign.right, style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 13))),
        ],
      ),
    );
  }

  void _showSettings() {
    Widget buildCard(List<Widget> children) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Column(
          children: children,
        ),
      );
    }

    Widget actionItem(IconData icon, String text, VoidCallback onClick,
        {Color color = Colors.white, String? subtitle}) {
      return InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onClick();
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text, style: TextStyle(fontSize: 14, color: color)),
                    if (subtitle != null) Text(subtitle,
                        style: const TextStyle(fontSize: 10, color: AppColors
                            .textMuted)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: color.withValues(alpha: 0.3), size: 18),
            ],
          ),
        ),
      );
    }

    Widget innerDiv() =>
        Divider(color: Colors.white.withValues(alpha: 0.05),
            height: 0.5,
            indent: 46);

    _openModal(
        StatefulBuilder(
            builder: (context, setModalState) {
              int currentSlot = _selectedTariff == "base"
                  ? (_currentUser["base_slot"] ?? 0)
                  : (_currentUser["stealth_slot"] ?? 0);
              int displaySlot = currentSlot + 1;

              Widget switchItem(IconData icon, String title, String sub,
                  bool val, ValueChanged<bool> onChanged) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 4),
                  child: Row(
                    children: [
                      Icon(icon, color: AppColors.textPrimary, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: const TextStyle(
                                  fontSize: 14)),
                              Text(sub, style: const TextStyle(
                                  fontSize: 10, color: AppColors.textMuted)),
                            ],
                          )
                      ),
                      Transform.scale(
                        scale: 0.85,
                        child: Switch(
                          value: val,
                          activeThumbColor: AppColors.accent,
                          onChanged: onChanged,
                        ),
                      ),
                    ],
                  ),
                );
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(t('settings'), style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                      GestureDetector(
                        onTap: () async {
                          HapticFeedback.lightImpact();
                          await LocalizationService.toggleLanguage();
                          setState(() {});
                          _closeModal();
                          Future.delayed(
                              const Duration(milliseconds: 300), () =>
                              _showSettings());
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white
                                  .withValues(alpha: 0.1))
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.language_rounded, size: 14,
                                  color: AppColors.textMuted),
                              const SizedBox(width: 4),
                              Text(
                                LocalizationService.currentLang,
                                style: const TextStyle(fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textMuted),
                              ),
                            ],
                          ),
                        ),
                      )
                    ],
                  ),
                  const SizedBox(height: 12),

                  Flexible(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [

                          buildCard([
                            switchItem(
                                Icons.shield_rounded,
                                "Killswitch",
                                t('ks_desc'),
                                _killswitchEnabled,
                                    (val) {
                                  HapticFeedback.lightImpact();
                                  setModalState(() =>
                                  _killswitchEnabled = val);
                                  setState(() => _killswitchEnabled = val);
                                }
                            ),
                            innerDiv(),
                            switchItem(
                                Icons.alt_route_rounded,
                                t('sr_title'),
                                t('sr_desc'),
                                _smartReconnectEnabled,
                                    (val) async {
                                  HapticFeedback.lightImpact();
                                  setModalState(() =>
                                  _smartReconnectEnabled = val);
                                  setState(() =>
                                  _smartReconnectEnabled = val);
                                  await _storage.setSmartReconnect(val);
                                }
                            ),
                            innerDiv(),
                            Stack(
                              children: [
                                Opacity(
                                  opacity: _selectedTariff == "base" ? 0.5 : 1.0,
                                  child: switchItem(
                                      Icons.shield_moon_rounded,
                                      t('ad_title'),
                                      _selectedTariff == "base" ? t('adblock_stealth_only') : t('ad_desc'),
                                      _adblockEnabled,
                                          (val) async {
                                        if (_selectedTariff == "base") {
                                          _closeModal();
                                          _snack(t('adblock_stealth_only'));
                                          // Принудительно открываем покупку с тарифом Stealth
                                          setState(() => _payTariff = "stealth");
                                          _showPayModal();
                                          return;
                                        }
                                        HapticFeedback.lightImpact();
                                        setModalState(() => _adblockEnabled = val);
                                        setState(() => _adblockEnabled = val);
                                        await _storage.setAdblockEnabled(val);
                                        if (_isConnected) {
                                          _snack(t('ad_apply'));
                                        }
                                      }
                                  ),
                                ),
                                if (_selectedTariff == "base")
                                  const Positioned(
                                    right: 15,
                                    top: 15,
                                    child: Icon(Icons.lock_rounded, size: 16, color: AppColors.textMuted),
                                  ),
                              ],
                            ),

                            innerDiv(),
                            actionItem(Icons.auto_fix_high_rounded, t('fix_conn'), _showFailoverConfirmModal,
                                color: AppColors.accent,
                                subtitle: t('if_net_blocked')),
                          ]),

                          buildCard([
                            actionItem(
                                Icons.security,
                                t('2fa_menu'),
                                _setup2FA,
                                color: AppColors.textPrimary,
                                subtitle: (_currentUser["2fa_enabled"] ==
                                    true) ? t('enabled') : t('disabled')
                            ),
                            innerDiv(),
                            actionItem(Icons.password_rounded, t('change_pwd_title'), _showChangePasswordModal,
                                color: AppColors.textPrimary,
                                subtitle: t('2fa_req')),
                          ]),

                          buildCard([
                            Row(
                              children: [
                                Expanded(
                                  child: InkWell(
                                    onTap: () => _openSupport("bug"),
                                    borderRadius: BorderRadius.circular(16),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10),
                                      child: Column(
                                        children: [
                                          const Icon(Icons.bug_report_rounded,
                                              color: AppColors.textMuted,
                                              size: 18),
                                          const SizedBox(height: 2),
                                          Text(t('report_bug'),
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: AppColors.textMuted))
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                Container(width: 1,
                                    height: 30,
                                    color: Colors.white.withValues(
                                        alpha: 0.05)),
                                Expanded(
                                  child: InkWell(
                                    onTap: () => _openSupport("feedback"),
                                    borderRadius: BorderRadius.circular(16),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10),
                                      child: Column(
                                        children: [
                                          const Icon(Icons.lightbulb_rounded,
                                              color: AppColors.textMuted,
                                              size: 18),
                                          const SizedBox(height: 2),
                                          Text(t('feedback'),
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: AppColors.textMuted))
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          ]),

                          buildCard([
                            actionItem(Icons.logout_rounded, t('log_out'), _logout,
                                color: Colors.orange),
                            innerDiv(),
                            actionItem(Icons.delete_forever_rounded, t('del_acc_title'), _showDeleteAccountModal,
                                color: AppColors.error),
                            innerDiv(),
                            actionItem(Icons.warning_amber_rounded, t('panic_title'), _showPanicDialog,
                                color: AppColors.error,
                                subtitle: t('destroy_ses')),
                          ]),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),
                  Text(
                      "v${AppConfig.version}  •  ${t('route')}: $displaySlot (${_selectedTariff
                          .toUpperCase()})",
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textMuted)
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: _closeModal,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 8),
                      child: Text(
                          t('close'),
                          style: const TextStyle(color: AppColors.textMuted,
                              fontWeight: FontWeight.bold,
                              fontSize: 13)
                      ),
                    ),
                  ),
                ],
              );
            }
        )
    );
  }

  void _openSupport(String type) {
    _closeModal();
    _openModal(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              IconButton(
                  onPressed: () {
                    _closeModal();
                    Future.delayed(const Duration(milliseconds: 150), () =>
                        _showSettings());
                  },
                  icon: const Icon(
                      Icons.arrow_back_rounded, color: AppColors.textMuted)
              )
            ],
          ),
          Icon(type == "bug" ? Icons.bug_report_rounded : Icons
              .lightbulb_rounded, color: AppColors.accent, size: 40),
          const SizedBox(height: 15),
          Text(t('support_title'),
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(
              t('support_desc'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted)
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () async {
              _closeModal();
              String action = type == "bug" ? "bug" : "support";
              String lang = LocalizationService.currentLang;
              final Uri url = Uri.parse("${AppConfig.telegramBotUrl}?start=${action}_$lang");
              launchUrl(url, mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.telegram),
            label: const Text("Telegram"),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 45),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15))),
          ),
          const SizedBox(height: 15),
          Text(
              t('no_tg'),
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted)
          ),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: AppConfig.supportEmail));
              _snack(t('email_copied'), success: true);
            },
            icon: const Icon(
                Icons.copy_rounded, size: 14, color: AppColors.textMuted),
            label: const Text(AppConfig.supportEmail,
                style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _glassTile({required Widget child, VoidCallback? onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (onTap != null) {
            HapticFeedback.lightImpact();
            onTap();
          }
        },
        splashColor: Colors.white.withValues(alpha: 0.05),
        highlightColor: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.08), width: 1),
          ),
          child: child,
        ),
      ),
    );
  }

// Update Checker
  Future<void> _checkForUpdates() async {
    if (_updateChecked) return;
    _updateChecked = true;

    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    final res = await _api.checkVersion(AppConfig.version);
    if (!mounted) return;

    if (res['has_update'] == true) {
      if (_isModalVisible) return;
      final Map<String, dynamic> links = res['update_links'] ?? {};

      _showUpdateDialog(
        newVersion: res['latest_version'] ?? '',
        changelog:  res['changelog'] ?? '',
        links:      links,
        mandatory:  res['is_mandatory'] == true,
      );
    }
  }

  void _showUpdateDialog({
    required String newVersion,
    required String changelog,
    required Map<String, dynamic> links,
    required bool mandatory,
  }) {
    _openModal(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                mandatory ? Icons.warning_amber_rounded : Icons.system_update_rounded,
                color: mandatory ? AppColors.error : AppColors.accent,
                size: 28,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  mandatory ? t('req_update') : t('update_avail'),
                  style: TextStyle(
                    color: mandatory ? AppColors.error : AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              "v$newVersion",
              style: const TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.bold,
                fontFamily: ComponentStyles.dataFont,
              ),
            ),
          ),
          const SizedBox(height: 15),

          Text(
            t('whats_new'),
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(changelog, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5)),

          if (mandatory) ...[
            const SizedBox(height: 15),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t('version_unsupported'),
                      style: const TextStyle(fontSize: 11, color: AppColors.error),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 20),
          Text(
            t('choose_dl'),
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          const SizedBox(height: 10),

          if (links['telegram'] != null && links['telegram'].toString().isNotEmpty)
            ElevatedButton.icon(
              onPressed: () {
                launchUrl(Uri.parse(links['telegram']), mode: LaunchMode.externalApplication);
              },
              icon: const Icon(Icons.telegram, color: Colors.white),
              label: Text(t('dl_tg')),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2AABEE),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 45),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),

          const SizedBox(height: 8),

          if (links['website'] != null && links['website'].toString().isNotEmpty)
            ElevatedButton.icon(
              onPressed: () {
                launchUrl(Uri.parse(links['website']), mode: LaunchMode.externalApplication);
              },
              icon: const Icon(Icons.language_rounded, color: Colors.white),
              label: Text(t('dl_web')),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.surface,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 45),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),

          const SizedBox(height: 10),

          Center(
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: links['website'] ?? links['telegram'] ?? ''));
                _snack(t('link_copied'), success: true);
              },
              icon: const Icon(Icons.copy_rounded, size: 16, color: AppColors.textMuted),
              label: Text(
                t('copy_link'),
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
          ),

          if (!mandatory) ...[
            const SizedBox(height: 5),
            Center(
              child: TextButton(
                onPressed: _closeModal,
                child: Text(t('later'), style: const TextStyle(color: AppColors.textMuted)),
              ),
            ),
          ]
        ],
      ),
      dismissible: !mandatory,
    );
  }

  @override
  Widget build(BuildContext context) {
    Color statusColor = _isDisconnecting ? Colors.blueGrey : (_isConnecting
        ? Colors.orange
        : (_isConnected ? AppColors.success : AppColors.error));
    String statusText = _isDisconnecting ? t('disconnecting') : (_isConnecting
        ? t('connecting')
        : (_isConnected ? "${t('connected')} (${_selectedTariff
        .toUpperCase()})" : t('disconnected')));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                      left: 20, right: 10, top: 15),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Maakolo", style: TextStyle(fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary)),
                      IconButton(icon: const Icon(
                          Icons.settings_rounded, color: AppColors
                          .textPrimary), onPressed: _showSettings)
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 15)
                      .copyWith(top: 10),
                  child: _glassTile(
                    child: Row(
                      children: [
                        Container(padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                shape: BoxShape.circle),
                            child: const Icon(Icons.person_rounded,
                                color: AppColors.textPrimary, size: 20)),
                        const SizedBox(width: 10),

                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(t('profile'), style: const TextStyle(
                                      fontSize: 9,
                                      color: AppColors.textMuted,
                                      fontWeight: FontWeight.bold)),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: () {
                                      HapticFeedback.lightImpact();
                                      setState(() =>
                                      _isIdHidden = !_isIdHidden);
                                    },
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                          milliseconds: 200),
                                      transitionBuilder: (child, animation) =>
                                          ScaleTransition(
                                              scale: animation, child: child),
                                      child: Icon(
                                        _isIdHidden ? Icons
                                            .visibility_off_rounded : Icons
                                            .visibility_rounded,
                                        key: ValueKey(_isIdHidden),
                                        color: _isIdHidden ? AppColors
                                            .textMuted : AppColors.accent,
                                        size: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              SizedBox(
                                height: 22,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Stack(
                                    alignment: Alignment.centerLeft,
                                    children: [
                                      AnimatedOpacity(
                                        duration: const Duration(
                                            milliseconds: 200),
                                        opacity: _isIdHidden ? 1.0 : 0.0,
                                        child: const Text(
                                          "•••• •••• •••• ••••",
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: AppColors.textPrimary,
                                            fontWeight: FontWeight.bold,
                                            fontFamily: ComponentStyles
                                                .dataFont,
                                            letterSpacing: 1.5,
                                            height: 1.0,
                                          ),
                                        ),
                                      ),
                                      AnimatedOpacity(
                                        duration: const Duration(
                                            milliseconds: 200),
                                        opacity: _isIdHidden ? 0.0 : 1.0,
                                        child: Text(
                                          _formatId(_currentUser["id"]),
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: AppColors.textPrimary,
                                            fontWeight: FontWeight.bold,
                                            fontFamily: ComponentStyles
                                                .dataFont,
                                            letterSpacing: 1.0,
                                            height: 1.0,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(t('sub'), style: const TextStyle(fontSize: 9,
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.bold)),
                            Row(
                              children: [
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 300),
                                  transitionBuilder: (child, animation) =>
                                      FadeTransition(
                                          opacity: animation, child: child),
                                  child: Text("$_daysLeft ${t('days')}",
                                      key: ValueKey(_daysLeft),
                                      style: TextStyle(fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures()
                                          ],
                                          color: _daysLeft > 0 ? AppColors
                                              .success : AppColors.error)),
                                ),
                                const SizedBox(width: 5),
                                GestureDetector(onTap: _showPayModal,
                                    child: const Icon(
                                        Icons.add_circle_rounded,
                                        color: AppColors.accent, size: 20)),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: RepaintBoundary(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 400),
                          opacity: _isConnected ? 0.35 : 0.15,
                          child: Image.asset(
                              'assets/map1.png', fit: BoxFit.fitWidth),
                        ),
                        Align(
                          alignment: const Alignment(-0.1, -0.17),
                          child: SizedBox(
                            width: 30,
                            height: 30,
                            child: Center(
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 400),
                                curve: Curves.easeOutBack,
                                width: _isConnected ? 25 : 10.1,
                                height: _isConnected ? 25 : 10.1,
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _isConnected
                                        ? AppColors.success.withValues(
                                        alpha: 0.2)
                                        : (_isConnecting || _isDisconnecting
                                        ? AppColors.accent.withValues(
                                        alpha: 0.2)
                                        : Colors.white.withValues(alpha: 0.1))
                                ),
                                alignment: Alignment.center,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 400),
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _isConnected
                                          ? AppColors.success
                                          : (_isConnecting || _isDisconnecting
                                          ? AppColors.accent
                                          : AppColors.textMuted),
                                      boxShadow: _isConnected ? const [
                                        BoxShadow(color: AppColors.success,
                                            blurRadius: 10)
                                      ] : (_isConnecting || _isDisconnecting
                                          ? const [
                                        BoxShadow(color: AppColors.accent,
                                            blurRadius: 10)
                                      ]
                                          : const [])
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 15,
                          child: Column(
                            children: [
                              GestureDetector(
                                onTapDown: (_) {
                                  HapticFeedback.mediumImpact();
                                  _isButtonDown.value = true;
                                },
                                onTapUp: (_) {
                                  _isButtonDown.value = false;
                                  _toggleVpn();
                                },
                                onTapCancel: () =>
                                _isButtonDown.value = false,
                                child: ValueListenableBuilder<bool>(
                                  valueListenable: _isButtonDown,
                                  builder: (context, isDown, child) {
                                    return AnimatedScale(
                                      scale: isDown ? 0.93 : 1.0,
                                      duration: const Duration(
                                          milliseconds: 150),
                                      curve: Curves.easeInOutCubic,
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                            milliseconds: 400),
                                        width: 100,
                                        height: 100,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: _isConnected
                                              ? AppColors.accent.withValues(
                                              alpha: 0.2)
                                              : Colors.white.withValues(
                                              alpha: 0.1),
                                          border: Border.all(
                                              color: _isConnected ? AppColors
                                                  .accent : Colors.white
                                                  .withValues(alpha: 0.15),
                                              width: 1),
                                          boxShadow: [
                                            BoxShadow(color: _isConnected
                                                ? AppColors.accent.withValues(
                                                alpha: 0.4)
                                                : Colors.transparent,
                                                blurRadius: _isConnected
                                                    ? 25
                                                    : 10)
                                          ],
                                        ),
                                        alignment: Alignment.center,
                                        child: AnimatedSwitcher(
                                          duration: const Duration(
                                              milliseconds: 300),
                                          transitionBuilder: (child,
                                              animation) =>
                                              ScaleTransition(
                                                  scale: animation,
                                                  child: FadeTransition(
                                                      opacity: animation,
                                                      child: child)),
                                          child: (_isConnecting ||
                                              _isDisconnecting)
                                              ? const CircularProgressIndicator(
                                              key: ValueKey('loader'),
                                              color: Colors.white,
                                              strokeWidth: 3)
                                              : Icon(Icons
                                              .power_settings_new_rounded,
                                              key: ValueKey(_isConnected),
                                              size: 45,
                                              color: _isConnected ? AppColors
                                                  .accent : Colors.white),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  AnimatedContainer(duration: const Duration(
                                      milliseconds: 300),
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: statusColor)),
                                  const SizedBox(width: 8),
                                  AnimatedSwitcher(
                                    duration: const Duration(
                                        milliseconds: 300),
                                    transitionBuilder: (child, animation) =>
                                        FadeTransition(
                                            opacity: animation, child: child),
                                    child: Text(
                                      statusText,
                                      key: ValueKey(statusText),
                                      style: TextStyle(fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: statusColor,
                                          letterSpacing: 1.0),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(
                      left: 15, right: 15, bottom: 20, top: 10),
                  child: Column(
                    children: [
                      _glassTile(
                        onTap: _showNetworkSelector,
                        child: AnimatedSize(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.topCenter,
                          child: Column(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Container(padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                          color: AppColors.accent.withValues(
                                              alpha: 0.1),
                                          shape: BoxShape.circle),
                                      child: const Icon(Icons.wifi_rounded,
                                          color: AppColors.accent, size: 20)),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment
                                          .start,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(t('current_net'),
                                            style: const TextStyle(fontSize: 9,
                                                color: AppColors.textMuted,
                                                fontWeight: FontWeight.bold)),
                                        const SizedBox(height: 2),
                                        Text(_selectedTariff == "base" ? t(
                                            'base_net') : t('stealth_net'),
                                            style: const TextStyle(fontSize: 14,
                                                color: AppColors.textPrimary,
                                                fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),

                                  if (_isConnected)
                                    Row(
                                      children: [
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment
                                              .end,
                                          mainAxisAlignment: MainAxisAlignment
                                              .center,
                                          children: [
                                            ValueListenableBuilder<int>(
                                                valueListenable: _sessionSeconds,
                                                builder: (context, seconds,
                                                    child) {
                                                  return Text(
                                                    _formatTime(seconds),
                                                    style: const TextStyle(
                                                        fontSize: 14,
                                                        fontWeight: FontWeight
                                                            .bold,
                                                        color: AppColors.accent,
                                                        fontFeatures: [
                                                          FontFeature
                                                              .tabularFigures()
                                                        ]
                                                    ),
                                                  );
                                                }
                                            ),
                                            const SizedBox(height: 4),
                                            ValueListenableBuilder<int>(
                                                valueListenable: _txBytes,
                                                builder: (context, tx, child) {
                                                  return Row(
                                                    children: [
                                                      const Icon(Icons
                                                          .arrow_upward_rounded,
                                                          size: 10,
                                                          color: AppColors
                                                              .success),
                                                      const SizedBox(width: 4),
                                                      Text(_formatBytes(tx),
                                                          style: const TextStyle(
                                                              fontSize: 10,
                                                              color: AppColors
                                                                  .textMuted)),
                                                    ],
                                                  );
                                                }
                                            ),
                                            const SizedBox(height: 2),
                                            ValueListenableBuilder<int>(
                                                valueListenable: _rxBytes,
                                                builder: (context, rx, child) {
                                                  return Row(
                                                    children: [
                                                      const Icon(Icons
                                                          .arrow_downward_rounded,
                                                          size: 10,
                                                          color: AppColors
                                                              .accent),
                                                      const SizedBox(width: 4),
                                                      Text(_formatBytes(rx),
                                                          style: const TextStyle(
                                                              fontSize: 10,
                                                              color: AppColors
                                                                  .textMuted)),
                                                    ],
                                                  );
                                                }
                                            ),
                                          ],
                                        ),
                                        const SizedBox(width: 15),
                                      ],
                                    ),

                                  const Icon(Icons.unfold_more_rounded,
                                      color: AppColors.textMuted),
                                ],
                              ),
                              _buildTrafficGauge(),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 12),

                      _glassTile(
                        onTap: () => _snack(t('loc_soon')),
                        child: Row(
                          children: [
                            Container(padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                    color: Colors.white.withValues(
                                        alpha: 0.1), shape: BoxShape.circle),
                                child: const Icon(Icons.public_rounded,
                                    color: AppColors.textPrimary, size: 20)),
                            const SizedBox(width: 10),
                            Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t('location'), style: const TextStyle(
                                      fontSize: 9,
                                      color: AppColors.textMuted,
                                      fontWeight: FontWeight.bold)),
                                  Text(t('loc_frankfurt'),
                                      style: const TextStyle(fontSize: 14,
                                          color: AppColors.textPrimary,
                                          fontWeight: FontWeight.bold)),
                                ])),
                            const Icon(Icons.chevron_right_rounded,
                                color: AppColors.textMuted),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          IgnorePointer(
            ignoring: !_isModalVisible,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: _isModalVisible ? 1.0 : 0.0,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  GestureDetector(
                    onTap: _isModalDismissible ? _closeModal : null,
                    child: Container(
                        color: Colors.black.withValues(alpha: 0.85)),
                  ),
                  AnimatedScale(
                    scale: _isModalVisible ? 1.0 : 0.85,
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutBack,
                    child: Container(
                      width: 340,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xF21A1A1A),
                        borderRadius: BorderRadius.circular(25),
                        border: Border.all(color: Colors.white.withValues(
                            alpha: 0.1), width: 1),
                        boxShadow: const [BoxShadow(color: Colors.black,
                            blurRadius: 40,
                            spreadRadius: 5)
                        ],
                      ),
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOutCubic,
                        child: _modalContent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            top: _isNotifVisible ? 60 : -100,
            left: 40,
            right: 40,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  vertical: 15, horizontal: 20),
              decoration: BoxDecoration(
                  color: _notifSuccess ? AppColors.success : AppColors.error,
                  borderRadius: BorderRadius.circular(AppBorderRadius.full),
                  boxShadow: const [
                    BoxShadow(color: Colors.black38,
                        blurRadius: 10,
                        offset: Offset(0, 5))
                  ]),
              alignment: Alignment.center,
              child: Text(_notifText,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
