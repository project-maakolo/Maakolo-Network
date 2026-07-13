// ignore_for_file: unused_import, unused_field
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'config.dart';
import 'services/l10n.dart';
import 'services/localization_service.dart';

String tApi(String key) => t(key);

class ApiClient {
  final String baseUrl;
  final Duration timeout;
  late final IOClient _client;

  ApiClient({
    String? baseUrl,
    Duration? timeout,
  })  : baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
        timeout = timeout ?? const Duration(seconds: AppConfig.apiTimeout) {

    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);

    _client = IOClient(httpClient);
  }

  static void validateSslConfig() {}

  // Headers

  Map<String, String> _getHeaders({String? token}) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept-Language': LocalizationService.currentLang.toLowerCase(),
    };
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  // Response Processing

  Map<String, dynamic> _processResponse(http.Response response, String defaultErrorKey) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        return jsonDecode(response.body);
      } catch (_) {
        return {"status": "error", "message": tApi('err_server')};
      }
    }
    if (response.statusCode == 401) {
      try {
        final body = jsonDecode(response.body);
        final msg = body['message']?.toString() ?? '';
        if (msg.contains('Session expired') ||
            msg.contains('истекла') ||
            msg.contains('vanhentui')) {
          return {"status": "error", "message": msg, "session_expired": true};
        }
        return {"status": "error", "message": msg};
      } catch (_) {}
    }
    if (response.statusCode >= 500) {
      return {"status": "error", "message": tApi('err_server')};
    }
    try {
      final body = jsonDecode(response.body);
      if (body['message'] != null) {
        return {"status": "error", "message": body['message']};
      }
    } catch (_) {}
    return {"status": "error", "message": tApi(defaultErrorKey)};
  }

  // Account

  Future<Map<String, dynamic>> getMe({String? token}) async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/me'), headers: _getHeaders(token: token))
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> getTraffic({String? token}) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/get_traffic'),
            headers: _getHeaders(token: token),
            body: jsonEncode({}),
          )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } catch (_) {
      return {"status": "error"};
    }
  }

  Future<Map<String, dynamic>> getGeneratedId() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/generate_id'), headers: _getHeaders())
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> register(String accountId, String password) async {
    try {
      final response = await _client
          .post(
        Uri.parse('$baseUrl/register'),
        headers: _getHeaders(),
        body: jsonEncode({'account_id': accountId, 'password': password}),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_reg');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> login(
      String accountId, String password, {String? totpCode}) async {
    try {
      final body = {'account_id': accountId, 'password': password};
      if (totpCode != null && totpCode.isNotEmpty) body['totp_code'] = totpCode;
      final response = await _client
          .post(
        Uri.parse('$baseUrl/login'),
        headers: _getHeaders(),
        body: jsonEncode(body),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_auth');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  // VPN

  Future<Map<String, dynamic>> getVpnKey(
      String accountId, String password, String tariff, {String? token}) async {
    try {
      final body = <String, dynamic>{'account_id': accountId, 'tariff': tariff};
      if (token == null || token.isEmpty) body['password'] = password;

      final response = await _client
          .post(
        Uri.parse('$baseUrl/get_key'),
        headers: _getHeaders(token: token),
        body: jsonEncode(body),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_key');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> switchSlot(
      String accountId, String password, String tariff, {String? token}) async {
    try {
      final body = <String, dynamic>{'account_id': accountId, 'tariff': tariff};
      if (token == null || token.isEmpty) body['password'] = password;

      final response = await _client
          .post(
        Uri.parse('$baseUrl/switch_slot'),
        headers: _getHeaders(token: token),
        body: jsonEncode(body),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  // 2FA

  Future<Map<String, dynamic>> check2FaStatus(
      String accountId, String password, {String? token}) async {
    try {
      final body = <String, dynamic>{'account_id': accountId};
      if (token == null || token.isEmpty) body['password'] = password;

      final response = await _client
          .post(
        Uri.parse('$baseUrl/check_2fa_status'),
        headers: _getHeaders(token: token),
        body: jsonEncode(body),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> enable2fa(
      String accountId, String password, {String? token}) async {
    try {
      final response = await _client
          .post(
        Uri.parse('$baseUrl/enable_2fa'),
        headers: _getHeaders(token: token),
        body: jsonEncode({'account_id': accountId, 'password': password}),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_2fa_enable');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> disable2fa(
      String accountId, String password, String totpCode, {String? token}) async {
    try {
      final response = await _client
          .post(
        Uri.parse('$baseUrl/disable_2fa'),
        headers: _getHeaders(token: token),
        body: jsonEncode({
          'account_id': accountId,
          'password': password,
          'totp_code': totpCode,
        }),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  // Payments

  Future<Map<String, dynamic>> getPricing() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/pricing'), headers: _getHeaders())
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> createFiatInvoice(
      String accountId, String tariff, int months,
      String currency, String method, String returnUrl,
      {String? token}) async {
    try {
      final response = await _client
          .post(
        Uri.parse('$baseUrl/create_fiat_invoice'),
        headers: _getHeaders(token: token),
        body: jsonEncode({
          'account_id': accountId,
          'tariff': tariff,
          'months': months,
          'currency': currency,
          'method': method,
          'return_url': returnUrl,
        }),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> createCryptoInvoice(
      String accountId, String tariff, int months, String currency,
      {String? token}) async {
    try {
      final response = await _client
          .post(
        Uri.parse('$baseUrl/create_crypto_invoice'),
        headers: _getHeaders(token: token),
        body: jsonEncode({
          'account_id': accountId,
          'tariff': tariff,
          'months': months,
          'currency': currency,
        }),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> checkCryptoTx(
      String txnId, String accountId, String password,
      {String? token}) async {
    try {
      final body = <String, dynamic>{'txn_id': txnId, 'account_id': accountId};
      if (token == null || token.isEmpty) body['password'] = password;

      final response = await _client
          .post(
        Uri.parse('$baseUrl/check_crypto_tx'),
        headers: _getHeaders(token: token),
        body: jsonEncode(body),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  // Settings

  Future<Map<String, dynamic>> changePassword(
      String accountId, String oldPassword, String newPassword, String totpCode,
      {String? token}) async {
    try {
      final response = await _client
          .post(
        Uri.parse('$baseUrl/change_password'),
        headers: _getHeaders(token: token),
        body: jsonEncode({
          'account_id': accountId,
          'old_password': oldPassword,
          'new_password': newPassword,
          'totp_code': totpCode,
        }),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> deleteAccount(
      String accountId, String password,
      {String? totpCode, String? token}) async {
    try {
      final body = <String, dynamic>{'account_id': accountId, 'password': password};
      if (totpCode != null && totpCode.isNotEmpty) body['totp_code'] = totpCode;

      final response = await _client
          .post(
        Uri.parse('$baseUrl/delete_account'),
        headers: _getHeaders(token: token),
        body: jsonEncode(body),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  // App Version

  Future<Map<String, dynamic>> checkVersion(String currentVersion) async {
    try {
      final platform = Platform.isIOS ? 'ios' : 'android';
      final response = await _client
          .get(
        Uri.parse('$baseUrl/check_version?v=$currentVersion&platform=$platform'),
        headers: _getHeaders(),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } catch (_) {
      return {"status": "error"};
    }
  }

  Future<Map<String, dynamic>> reportError(
      String accountId, String password, String errorText,
      {String? token}) async {
    try {
      final body = <String, dynamic>{'account_id': accountId, 'error_text': errorText};
      if (token == null || token.isEmpty) body['password'] = password;

      final response = await _client
          .post(
        Uri.parse('$baseUrl/report_error'),
        headers: _getHeaders(token: token),
        body: jsonEncode(body),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  Future<Map<String, dynamic>> leaveFeedback(
      String accountId, String password, int rating, String feedbackText,
      {String? token}) async {
    try {
      final body = <String, dynamic>{'account_id': accountId, 'rating': rating, 'feedback_text': feedbackText};
      if (token == null || token.isEmpty) body['password'] = password;

      final response = await _client
          .post(
        Uri.parse('$baseUrl/leave_feedback'),
        headers: _getHeaders(token: token),
        body: jsonEncode(body),
      )
          .timeout(timeout);
      return _processResponse(response, 'err_server');
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }

  // Crypto Rates

  Future<Map<String, dynamic>> fetchLiveCryptoRates() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/crypto_rates'), headers: _getHeaders())
          .timeout(timeout);
      if (response.statusCode == 200) {
        return {"status": "success", "data": jsonDecode(response.body)};
      }
      return {"status": "error", "message": tApi('err_server')};
    } on SocketException catch (_) {
      return {"status": "error", "message": tApi('err_network')};
    } on TimeoutException catch (_) {
      return {"status": "error", "message": tApi('err_timeout')};
    } catch (_) {
      return {"status": "error", "message": tApi('err_server')};
    }
  }
}
