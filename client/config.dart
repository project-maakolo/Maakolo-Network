import 'api_client.dart';

abstract class AppConfig {
  AppConfig._();

  // Set to true for production builds
  static const bool isProduction = true;

  // API
  static const String _devApiUrl  = "http://localhost:5000";
  static const String _prodApiUrl = "https://api.example.com";

  static String get apiBaseUrl => isProduction ? _prodApiUrl : _devApiUrl;

  static const int apiTimeout = 15;

  // App 
  static const String appName = "Maakolo";
  static const String version = "1.0.0";
  static const int minPasswordLength = 8;
  static const int serverWarningThreshold = 50;

  // Prices — updated dynamically via GET /pricing
  static Map<String, Map<String, dynamic>> pricing = {
    'base':    {'RUB': 150,  'USD': 1.99, 'EUR': 1.89},
    'stealth': {'RUB': 200,  'USD': 2.99, 'EUR': 2.89},
  };

  // Security
  // SSL is always enabled. Pinning fingerprint is set in ApiClient._serverFingerprint.

  static void validate() {
    // Ensure real fingerprint is set in production before any request
    ApiClient.validateSslConfig();
  }

  // External Links
  static const String telegramBotUrl = "https://t.me/your_bot";
  static const String supportEmail   = "support@example.com";
}
