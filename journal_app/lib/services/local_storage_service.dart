// services/local_storage_service.dart
//
// Persists journal entries and onboarding state to SharedPreferences
// for offline/local-only mode (no server connection).

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/journal_entry.dart';

class LocalStorageService {
  static const _kEntries = 'offline_journal_entries';
  static const _kOnboardingCompleted = 'onboarding_completed';
  static const _kOfflineMode = 'offline_mode';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ── Entries ──────────────────────────────────────────────────────────────

  Future<List<JournalEntry>> loadEntries() async {
    final prefs = await _instance;
    final raw = prefs.getString(_kEntries);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => JournalEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveEntries(List<JournalEntry> entries) async {
    final prefs = await _instance;
    final json = jsonEncode(entries.map((e) => e.toJson()).toList());
    await prefs.setString(_kEntries, json);
  }

  // ── Onboarding state ────────────────────────────────────────────────────

  Future<bool> isOnboardingCompleted() async {
    final prefs = await _instance;
    return prefs.getBool(_kOnboardingCompleted) ?? false;
  }

  Future<void> setOnboardingCompleted(bool value) async {
    final prefs = await _instance;
    await prefs.setBool(_kOnboardingCompleted, value);
  }

  // ── Offline mode flag ───────────────────────────────────────────────────

  Future<bool> isOfflineMode() async {
    final prefs = await _instance;
    return prefs.getBool(_kOfflineMode) ?? false;
  }

  Future<void> setOfflineMode(bool value) async {
    final prefs = await _instance;
    await prefs.setBool(_kOfflineMode, value);
  }
}
