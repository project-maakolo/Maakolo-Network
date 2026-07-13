import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../utils/storage.dart';
import '../assets/styles.dart';
import 'main_screen.dart';
import '../services/localization_service.dart';
import '../utils/validators.dart';
import '../services/l10n.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  String _state = "welcome";

  final ApiClient _api = ApiClient();
  final LocalStorage _storage = LocalStorage();
  final TextEditingController _idController = TextEditingController();
  final TextEditingController _pwdController = TextEditingController();
  final TextEditingController _totpController = TextEditingController();
  bool _isPasswordVisible = false;
  bool _acceptedTos = false;
  bool _isGeneratingId = false;

  // Notifications
  String _notifText = "";
  bool _notifSuccess = false;
  bool _isNotifVisible = false;
  Timer? _snackTimer;

  // Modal
  bool _isModalVisible = false;
  bool _isModalDismissible = true;
  Widget _modalContent = const SizedBox.shrink();

  // Entrance animation
  late AnimationController _entranceCtrl;
  late Animation<double> _entranceFade;

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _entranceFade = CurvedAnimation(
      parent: _entranceCtrl,
      curve: Curves.easeOut,
    );
    _entranceCtrl.forward();
  }

  @override
  void dispose() {
    _snackTimer?.cancel();
    _entranceCtrl.dispose();
    _idController.dispose();
    _pwdController.dispose();
    _totpController.dispose();
    super.dispose();
  }

  String get _tosText {
    if (LocalizationService.currentLang == 'FI') {
      return """[FI TOS - unchanged]""";
    }
    if (LocalizationService.currentLang == 'EN') {
      return """[EN TOS - unchanged]""";
    }
    return """[RU TOS - unchanged]""";
  }

  // UI Navigation

  void _toLogin() {
    setState(() {
      _state = "login";
      _idController.clear();
      _pwdController.clear();
      _totpController.clear();
      _acceptedTos = false;
    });
  }

  void _toRegister() {
    setState(() {
      _state = "register";
      _idController.clear();
      _pwdController.clear();
      _totpController.clear();
      _acceptedTos = false;
    });
    _initId();
  }

  void _toWelcome() {
    setState(() {
      _state = "welcome";
    });
  }

  String _formatId(String rawId) {
    String clean = rawId.replaceAll(" ", "");
    return clean.replaceAllMapped(RegExp(r".{4}"), (match) => "${match.group(0)} ").trim();
  }

  // API Calls

  Future<void> _initId() async {
    setState(() => _isGeneratingId = true);
    final res = await _api.getGeneratedId();
    if (!mounted) return;
    setState(() => _isGeneratingId = false);

    if (res["account_id"] != null) {
      setState(() {
        _idController.text = _formatId(res["account_id"]);
      });
    } else {
      _snack(t('err_get_id'));
    }
  }

  Future<void> _executeLogin(String uid, String pwd, {String? totpCode}) async {
    _closeModal();
    _snack(t('connecting'), success: true);

    final res = await _api.login(uid, pwd, totpCode: totpCode);

    if (res["status"] == "success") {
      Map<String, dynamic> userData = {
        "id": uid,
        "password": pwd,
        "balance": res["balance"] ?? 0.0,
        "expiry_base": res["expiry_base"] ?? 0,
        "expiry_stealth": res["expiry_stealth"] ?? 0,
        "2fa_enabled": res["2fa_enabled"] ?? false,
        "token": res["token"],
      };

      await _storage.saveSession(userData);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) => MainScreen(initialUser: userData),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
    } else if (res["status"] == "2fa_required") {
      _show2faModal(uid, pwd);
    } else {
      _snack(res["message"] ?? t('err_login'));
    }
  }

  Future<void> _executeRegister(String uid, String pwd) async {
    _closeModal();
    _snack(t('creating_profile'), success: true);

    final res = await _api.register(uid, pwd);
    if (res["status"] == "success") {
      _openModal(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.security, color: AppColors.accent, size: 40),
            const SizedBox(height: 15),
            Text(t('offer_2fa_title'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(
              t('offer_2fa_desc'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => _setup2FaDuringReg(uid, pwd),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 45),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppBorderRadius.full)),
              ),
              child: Text(t('btn_setup_2fa'), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () {
                _closeModal();
                _executeLogin(uid, pwd);
              },
              child: Text(t('btn_skip'), style: const TextStyle(color: AppColors.textMuted)),
            ),
          ],
        ),
      );
    } else {
      _snack(res["error"] ?? t('err_reg'));
    }
  }

  Future<void> _setup2FaDuringReg(String uid, String pwd) async {
    _closeModal();
    _snack(t('gen_key'), success: true);
    final res = await _api.enable2fa(uid, pwd);
    if (!mounted) return;

    if (res["status"] == "success" && res["secret"] != null) {
      String secret = res["secret"];
      _openModal(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.security, color: AppColors.accent, size: 40),
              const SizedBox(height: 15),
              Text(t('2fa_key_title'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Text(t('2fa_key_desc'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
              const SizedBox(height: 15),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                child: Text(secret, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.accent, letterSpacing: 2), textAlign: TextAlign.center),
              ),
              const SizedBox(height: 15),
              ElevatedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: secret));
                  _snack(t('key_copied'), success: true);
                },
                icon: const Icon(Icons.copy_rounded, color: Colors.white, size: 18),
                label: Text(t('copy_key')),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.surface, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 45), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: () => _executeLogin(uid, pwd),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 45), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
                child: Text(t('login_account'), style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          dismissible: false
      );
    } else {
      _snack(t('err_2fa_setup'));
      _executeLogin(uid, pwd);
    }
  }

  // Notifications

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

  // Modals

  void _openModal(Widget content, {bool dismissible = true}) {
    setState(() {
      _modalContent = Container(
        width: 340,
        padding: const EdgeInsets.all(25),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A).withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(25),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1),
          boxShadow: const [BoxShadow(color: Colors.black, blurRadius: 30)],
        ),
        child: content,
      );
      _isModalDismissible = dismissible;
      _isModalVisible = true;
    });
  }

  void _closeModal() {
    setState(() {
      _isModalVisible = false;
    });
  }

  void _show2faModal(String uid, String pwd) {
    _totpController.clear();
    _openModal(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.security, color: AppColors.accent, size: 40),
          const SizedBox(height: 15),
          Text(t('2fa_login_title'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(
            t('2fa_login_desc'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _totpController,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            style: const TextStyle(fontFamily: ComponentStyles.dataFont, fontSize: 28, letterSpacing: 8, color: AppColors.accent),
            decoration: InputDecoration(
              hintText: t('code_hint'),
              hintStyle: const TextStyle(fontSize: 16, letterSpacing: 0, color: AppColors.textMuted),
              counterText: "",
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 20),
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () {
              if (_totpController.text.length == 6) {
                _executeLogin(uid, pwd, totpCode: _totpController.text);
              } else {
                _snack(t('enter_6_digits'));
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 45),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppBorderRadius.full)),
            ),
            child: Text(t('confirm_btn'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 5),
          TextButton(
            onPressed: _closeModal,
            child: Text(t('cancel'), style: const TextStyle(color: AppColors.textMuted)),
          ),
        ],
      ),
      dismissible: false,
    );
  }

  // Validation

  void _preLoginCheck() {
    String uid = _idController.text.replaceAll(" ", "");
    String pwd = _pwdController.text;

    var idCheck = Validators.validateUserId(uid);
    if (!idCheck.$1) {
      _snack(idCheck.$2);
      return;
    }

    if (pwd.isEmpty) {
      _snack(t('fill_fields'));
      return;
    }

    _executeLogin(uid, pwd);
  }

  void _preRegisterCheck() {
    if (_isGeneratingId) return;

    String uid = _idController.text.replaceAll(" ", "");
    String pwd = _pwdController.text;

    var idCheck = Validators.validateUserId(uid);
    if (!idCheck.$1) {
      _snack(idCheck.$2);
      return;
    }

    var pwdCheck = Validators.validatePassword(pwd);
    if (!pwdCheck.$1) {
      _snack(pwdCheck.$2);
      return;
    }

    if (!_acceptedTos) {
      _snack(t('err_tos'));
      return;
    }

    _showWarningModal(uid, pwd);
  }

  void _showWarningModal(String uid, String pwd) {
    bool isIdCopied = false;
    bool isIdAgreed = false;

    _openModal(
      StatefulBuilder(
          builder: (context, setModalState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t('warn_title'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.error)),
                const SizedBox(height: 10),
                Text(
                  t('warn_desc'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                ),
                const SizedBox(height: 15),
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Text(
                    _idController.text,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.accent, fontFamily: ComponentStyles.dataFont),
                  ),
                ),
                const SizedBox(height: 15),

                ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _idController.text));
                    _snack(t('id_copied'), success: true);
                    setModalState(() => isIdCopied = true);
                  },
                  icon: Icon(Icons.copy_rounded, color: isIdCopied ? AppColors.success : Colors.white),
                  label: Text(isIdCopied ? t('id_copied_modal') : t('copy_id')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.surface,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 45),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppBorderRadius.full)),
                  ),
                ),

                const SizedBox(height: 20),

                GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    setModalState(() => isIdAgreed = !isIdAgreed);
                  },
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        margin: const EdgeInsets.only(top: 2),
                        decoration: BoxDecoration(
                          color: isIdAgreed ? AppColors.accent : Colors.transparent,
                          border: Border.all(color: isIdAgreed ? AppColors.accent : AppColors.textMuted, width: 2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: isIdAgreed ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          t('save_id_warning'),
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.2),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                ElevatedButton(
                  onPressed: (isIdCopied && isIdAgreed) ? () => _executeRegister(uid, pwd) : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: (isIdCopied && isIdAgreed) ? AppColors.accent : AppColors.surface,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 45),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppBorderRadius.full)),
                  ),
                  child: Text(t('saved_data'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),

                const SizedBox(height: 5),
                TextButton(
                  onPressed: _closeModal,
                  child: Text(t('cancel'), style: const TextStyle(color: AppColors.textMuted)),
                ),
              ],
            );
          }
      ),
    );
  }

  void _showFullTos() {
    _openModal(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t('tos_full_title'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Container(
            height: 350,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              borderRadius: BorderRadius.circular(15),
            ),
            child: SingleChildScrollView(
              child: Text(_tosText, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            ),
          ),
          const SizedBox(height: 15),
          ElevatedButton(
            onPressed: _closeModal,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 45),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppBorderRadius.full)),
            ),
            child: Text(t('back_btn')),
          ),
        ],
      ),
    );
  }

  // UI Layout

  Widget _buildLogo() {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.15),
            blurRadius: 80,
            spreadRadius: 10,
          ),
        ],
      ),
      child: Image.asset(
        'assets/logo_white_2x.png',
        width: 110,
        height: 110,
        fit: BoxFit.contain,
      ),
    );
  }

  Widget _buildBtn(String text, VoidCallback action, {bool fill = true}) {
    return _PressableButton(
      text: text,
      onPressed: action,
      fill: fill,
    );
  }

  Widget _buildTosCheckbox() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() => _acceptedTos = !_acceptedTos),
          child: Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: _acceptedTos ? AppColors.accent : Colors.transparent,
              border: Border.all(
                color: _acceptedTos ? AppColors.accent : AppColors.textMuted,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: _acceptedTos
                ? const Icon(Icons.check, size: 16, color: Colors.white)
                : null,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Wrap(
            children: [
              GestureDetector(
                onTap: () => setState(() => _acceptedTos = !_acceptedTos),
                child: Text('${t('tos_checkbox')} ', style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
              ),
              GestureDetector(
                onTap: _showFullTos,
                child: Text(t('tos_link'), style: const TextStyle(color: AppColors.accent, fontSize: 13)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_state == "welcome") {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildLogo(),
          const SizedBox(height: 15),
          const Text("Maakolo", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          Text(t('subtitle'), style: const TextStyle(fontSize: 16, color: AppColors.textMuted)),
          const SizedBox(height: 40),
          _buildBtn(t('login_btn'), _toLogin, fill: true),
          const SizedBox(height: 10),
          _buildBtn(t('register_btn'), _toRegister, fill: false),
        ],
      );
    }

    else if (_state == "login") {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(t('login_title'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 30),
          TextFormField(
            controller: _idController,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontFamily: ComponentStyles.dataFont, fontSize: 18, letterSpacing: 2),
            decoration: ComponentStyles.inputStyle(t('id_hint')),
          ),
          const SizedBox(height: 15),
          TextFormField(
            controller: _pwdController,
            obscureText: !_isPasswordVisible,
            style: const TextStyle(fontSize: 16),
            decoration: ComponentStyles.inputStyle(t('pwd_hint')).copyWith(
              suffixIcon: IconButton(
                icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off, color: AppColors.textMuted),
                onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible),
              ),
            ),
          ),
          const SizedBox(height: 30),
          _buildBtn(t('continue_btn'), _preLoginCheck, fill: true),
          TextButton(onPressed: _toWelcome, child: Text(t('back_btn'), style: const TextStyle(color: AppColors.textMuted))),
        ],
      );
    }

    else {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(t('reg_title'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(t('reg_desc'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          const SizedBox(height: 20),
          TextFormField(
            controller: _idController,
            readOnly: true,
            style: const TextStyle(fontFamily: ComponentStyles.dataFont, fontSize: 18, letterSpacing: 2, color: AppColors.accent),
            decoration: ComponentStyles.inputStyle(t('gen_id_hint')).copyWith(
              suffixIcon: _isGeneratingId
                  ? const Padding(
                padding: EdgeInsets.all(12.0),
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)
                ),
              )
                  : null,
            ),
          ),
          const SizedBox(height: 15),
          TextFormField(
            controller: _pwdController,
            obscureText: !_isPasswordVisible,
            style: const TextStyle(fontSize: 16),
            decoration: ComponentStyles.inputStyle(t('create_pwd_hint')).copyWith(
              suffixIcon: IconButton(
                icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off, color: AppColors.textMuted),
                onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible),
              ),
            ),
          ),
          const SizedBox(height: 30),
          _buildTosCheckbox(),
          const SizedBox(height: 20),
          _buildBtn(t('register_btn'), _isGeneratingId ? () {} : _preRegisterCheck, fill: true),
          TextButton(onPressed: _toWelcome, child: Text(t('back_btn'), style: const TextStyle(color: AppColors.textMuted))),
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          FadeTransition(
            opacity: _entranceFade,
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight),
                      child: Center(
                        child: _buildContent(),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          if (_state == "welcome")
            Positioned(
              bottom: 10,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Center(
                  child: TextButton(
                    onPressed: () async {
                      await LocalizationService.toggleLanguage();
                      setState(() {});
                    },
                    style: TextButton.styleFrom(
                      splashFactory: NoSplash.splashFactory,
                    ),
                    child: Text(
                      LocalizationService.getLanguageButtonText(),
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
              ),
            ),

          if (_isModalVisible)
            GestureDetector(
              onTap: _isModalDismissible ? _closeModal : null,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _isModalVisible ? 1.0 : 0.0,
                child: Container(color: Colors.black.withValues(alpha: 0.85)),
              ),
            ),

          if (_isModalVisible)
            Center(child: _modalContent),

          AnimatedPositioned(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            top: _isNotifVisible ? 60 : -100,
            left: 40,
            right: 40,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
              decoration: BoxDecoration(
                color: _notifSuccess ? AppColors.success : AppColors.error,
                borderRadius: BorderRadius.circular(AppBorderRadius.full),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 5))
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                _notifText,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PressableButton extends StatefulWidget {
  final String text;
  final VoidCallback onPressed;
  final bool fill;

  const _PressableButton({
    required this.text,
    required this.onPressed,
    required this.fill,
  });

  @override
  State<_PressableButton> createState() => _PressableButtonState();
}

class _PressableButtonState extends State<_PressableButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.94).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeIn),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _ctrl.forward(),
      onPointerUp: (_) => _ctrl.reverse(),
      onPointerCancel: (_) => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: ElevatedButton(
          onPressed: widget.onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.fill ? AppColors.primary : AppColors.surface,
            foregroundColor: widget.fill ? Colors.black : Colors.white,
            minimumSize: const Size(300, 55),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppBorderRadius.full),
            ),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              widget.text,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}
