// test/services/local_storage_service_test.dart
//
// Unit tests for LocalStorageService.
// Uses SharedPreferences.setMockInitialValues() to avoid real storage.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:journal_app/services/local_storage_service.dart';
import 'package:journal_app/models/journal_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalStorageService', () {
    late LocalStorageService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = LocalStorageService();
    });

    // ── Entries ──────────────────────────────────────────────────────────

    group('entries', () {
      test('loadEntries returns empty list when no data stored', () async {
        final entries = await service.loadEntries();
        expect(entries, isEmpty);
      });

      test('saveEntries and loadEntries round-trip correctly', () async {
        final now = DateTime(2026, 4, 1, 12, 0);
        final entries = [
          JournalEntry(
            id: 'id-1',
            authorId: 'local',
            authorUsername: 'me',
            createdAt: now,
            updatedAt: now,
            content: 'Hello, world!',
          ),
          JournalEntry(
            id: 'id-2',
            authorId: 'local',
            authorUsername: 'me',
            createdAt: now.add(const Duration(hours: 1)),
            updatedAt: now.add(const Duration(hours: 1)),
            content: 'Second entry with "quotes" and\nnewlines.',
          ),
        ];

        await service.saveEntries(entries);
        final loaded = await service.loadEntries();

        expect(loaded.length, 2);
        expect(loaded[0].id, 'id-1');
        expect(loaded[0].content, 'Hello, world!');
        expect(loaded[0].authorId, 'local');
        expect(loaded[0].authorUsername, 'me');
        expect(loaded[0].createdAt, now);
        expect(loaded[1].id, 'id-2');
        expect(loaded[1].content, 'Second entry with "quotes" and\nnewlines.');
      });

      test('saveEntries overwrites previous data', () async {
        final now = DateTime.now();
        final first = [
          JournalEntry(
            id: 'a',
            authorId: 'local',
            authorUsername: 'me',
            createdAt: now,
            updatedAt: now,
            content: 'First',
          ),
        ];
        final second = [
          JournalEntry(
            id: 'b',
            authorId: 'local',
            authorUsername: 'me',
            createdAt: now,
            updatedAt: now,
            content: 'Replaced',
          ),
        ];

        await service.saveEntries(first);
        await service.saveEntries(second);
        final loaded = await service.loadEntries();

        expect(loaded.length, 1);
        expect(loaded[0].id, 'b');
        expect(loaded[0].content, 'Replaced');
      });

      test('saveEntries with empty list clears entries', () async {
        final now = DateTime.now();
        await service.saveEntries([
          JournalEntry(
            id: 'x',
            authorId: 'local',
            authorUsername: 'me',
            createdAt: now,
            updatedAt: now,
            content: 'Will be cleared',
          ),
        ]);

        await service.saveEntries([]);
        final loaded = await service.loadEntries();
        expect(loaded, isEmpty);
      });
    });

    // ── Onboarding state ────────────────────────────────────────────────

    group('onboarding state', () {
      test('defaults to not completed', () async {
        expect(await service.isOnboardingCompleted(), isFalse);
      });

      test('can be set to completed', () async {
        await service.setOnboardingCompleted(true);
        expect(await service.isOnboardingCompleted(), isTrue);
      });

      test('can be toggled back to not completed', () async {
        await service.setOnboardingCompleted(true);
        await service.setOnboardingCompleted(false);
        expect(await service.isOnboardingCompleted(), isFalse);
      });
    });

    // ── Offline mode flag ───────────────────────────────────────────────

    group('offline mode', () {
      test('defaults to false', () async {
        expect(await service.isOfflineMode(), isFalse);
      });

      test('can be set to true', () async {
        await service.setOfflineMode(true);
        expect(await service.isOfflineMode(), isTrue);
      });

      test('can be toggled back to false', () async {
        await service.setOfflineMode(true);
        await service.setOfflineMode(false);
        expect(await service.isOfflineMode(), isFalse);
      });
    });

    // ── Independence ────────────────────────────────────────────────────

    test('entries, onboarding, and offline mode are independent', () async {
      final now = DateTime.now();
      await service.setOnboardingCompleted(true);
      await service.setOfflineMode(true);
      await service.saveEntries([
        JournalEntry(
          id: 'z',
          authorId: 'local',
          authorUsername: 'me',
          createdAt: now,
          updatedAt: now,
          content: 'Independent',
        ),
      ]);

      // Each value should be independently stored.
      expect(await service.isOnboardingCompleted(), isTrue);
      expect(await service.isOfflineMode(), isTrue);
      final entries = await service.loadEntries();
      expect(entries.length, 1);
      expect(entries[0].content, 'Independent');

      // Clearing one shouldn't affect others.
      await service.setOfflineMode(false);
      expect(await service.isOnboardingCompleted(), isTrue);
      expect((await service.loadEntries()).length, 1);
    });
  });
}
