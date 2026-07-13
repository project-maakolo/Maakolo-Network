import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';

class LocalStorage {
  static final LocalStorage _instance = LocalStorage._internal();
  factory LocalStorage() => _instance;
  LocalStorage._internal();
  static Database? _db;

  static Completer<Database>? _initCompleter;

  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

  Future<String> _getDbEncryptionKey() async {
    String? key = await _secureStorage.read(key: 'sqlite_key');
    if (key == null) {
      final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      key = base64Url.encode(bytes);
      await _secureStorage.write(key: 'sqlite_key', value: key);
    }
    return key;
  }

  Future<Database> get database async {
    if (_db != null) return _db!;

    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<Database>();
    try {
      _db = await _initDb();
      _initCompleter!.complete(_db);
      return _db!;
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null; 
      rethrow;
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE user (
        id TEXT PRIMARY KEY,
        balance REAL DEFAULT 0.0,
        subscription_status TEXT,
        expiry_base INTEGER DEFAULT 0,
        expiry_stealth INTEGER DEFAULT 0,
        base_slot INTEGER DEFAULT 0,
        stealth_slot INTEGER DEFAULT 0
      )
    ''');
  }

  Future<Database> _initDb({bool isRetry = false}) async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, "maakolo_client_secure.db");
    String dbKey = await _getDbEncryptionKey();

    try {
      return await openDatabase(
        path,
        password: dbKey,
        version: 2,
        onCreate: _onCreate,
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 2) {
            await db.execute("ALTER TABLE user ADD COLUMN base_slot INTEGER DEFAULT 0");
            await db.execute("ALTER TABLE user ADD COLUMN stealth_slot INTEGER DEFAULT 0");
          }
        },
      );
    } catch (e) {
      if (isRetry) {
        debugPrint("[LocalStorage] КРИТИЧЕСКАЯ ОШИБКА: База не открылась даже после сброса: $e");
        rethrow;
      }
      debugPrint("[LocalStorage] Ошибка ключа БД, удаляем битый файл: $e");
      File dbFile = File(path);
      if (await dbFile.exists()) {
        await dbFile.delete();
      }
      await _secureStorage.delete(key: 'sqlite_key');
      return await _initDb(isRetry: true);
    }
  }


  Future<void> saveSession(Map<String, dynamic> userData) async {
    try {
      if (userData['token'] != null) {
        await _secureStorage.write(key: 'auth_token', value: userData['token']);
      }
      if (userData['password'] != null) {
        await _secureStorage.write(key: 'auth_password', value: userData['password']);
      }

      final db = await database;
      await db.transaction((txn) async {
        await txn.delete('user');
        await txn.insert('user', {
          'id': userData['id'],
          'balance': (userData['balance'] ?? 0.0).toDouble(),
          'subscription_status': userData['subscription_status'] ?? 'inactive',
          'expiry_base': userData['expiry_base'] ?? 0,
          'expiry_stealth': userData['expiry_stealth'] ?? 0,
          'base_slot': userData['base_slot'] ?? 0,
          'stealth_slot': userData['stealth_slot'] ?? 0,
        });
      });
    } catch (ex) {
      debugPrint("[LocalStorage] Save session error: $ex");
    }
  }

  Future<Map<String, dynamic>?> getSession() async {
    try {
      final db = await database;
      List<Map<String, dynamic>> maps = await db.query('user', limit: 1);
      if (maps.isNotEmpty) {
        var user = Map<String, dynamic>.from(maps.first);
        user['token'] = await _secureStorage.read(key: 'auth_token');
        user['password'] = await _secureStorage.read(key: 'auth_password');
        return user;
      }
      return null;
    } catch (ex) {
      debugPrint("[LocalStorage] Get session error: $ex");
      return null;
    }
  }

  Future<String?> getPassword() async {
    return await _secureStorage.read(key: 'auth_password');
  }

  Future<void> clearSession() async {
    try {
      final db = await database;
      await db.delete('user');
      await _secureStorage.deleteAll();
      await db.close();
      _db = null;
      _initCompleter = null;
    } catch (e) {
      debugPrint("[LocalStorage] Clear session error: $e");
    }
  }
// Clear token only
  Future<void> clearToken() async {
    await _secureStorage.delete(key: 'auth_token');
  }


  Future<void> setSmartReconnect(bool value) async {
    await _secureStorage.write(key: 'smart_reconnect', value: value.toString());
  }

  Future<bool> getSmartReconnect() async {
    String? val = await _secureStorage.read(key: 'smart_reconnect');
    return val == 'true';
  }


  Future<void> setAdblockEnabled(bool value) async {
    await _secureStorage.write(key: 'adblock_enabled', value: value.toString());
  }

  Future<bool> getAdblockEnabled() async {
    String? val = await _secureStorage.read(key: 'adblock_enabled');
    return val == 'true';
  }
}
