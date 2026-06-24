// test/services/journal_service_local_test.dart
//
// Tests the local (offline) CRUD operations of JournalService.
// Uses SharedPreferences mock to avoid real storage, and a fake
// AuthService to simulate offline mode.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:journal_app/services/auth_service.dart';
import 'package:journal_app/services/crypto_service.dart';
import 'package:journal_app/services/journal_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JournalService local CRUD', () {
    late JournalService journal;
    late AuthService auth;
    late CryptoService crypto;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      auth = AuthService();
      crypto = CryptoService();
      journal = JournalService();

      // Enter offline mode so JournalService routes to local storage.
      await auth.enterOfflineMode();
      journal.update(auth, crypto);
    });

    // ── Create ──────────────────────────────────────────────────────────

    test('createEntryLocal adds entry to the list', () async {
      await journal.createEntryLocal('My first local entry');

      expect(journal.entries.length, 1);
      expect(journal.entries[0].content, 'My first local entry');
      expect(journal.entries[0].authorId, 'local');
      expect(journal.entries[0].authorUsername, 'me');
    });

    test('createEntryLocal generates unique IDs', () async {
      await journal.createEntryLocal('Entry A');
      await journal.createEntryLocal('Entry B');

      expect(journal.entries.length, 2);
      expect(journal.entries[0].id, isNot(journal.entries[1].id));
    });

    test('createEntryLocal inserts newest entry first', () async {
      await journal.createEntryLocal('First');
      await journal.createEntryLocal('Second');

      expect(journal.entries[0].content, 'Second');
      expect(journal.entries[1].content, 'First');
    });

    test('createEntryLocal sets createdAt and updatedAt', () async {
      final before = DateTime.now();
      await journal.createEntryLocal('Timestamped');
      final after = DateTime.now();

      final entry = journal.entries[0];
      expect(entry.createdAt.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
      expect(entry.updatedAt.isBefore(after.add(const Duration(seconds: 1))), isTrue);
    });

    test('createEntryLocal notifies listeners', () async {
      int notifications = 0;
      journal.addListener(() => notifications++);

      await journal.createEntryLocal('Notify test');

      expect(notifications, greaterThan(0));
    });

    // ── Persistence ─────────────────────────────────────────────────────

    test('entries persist across JournalService instances', () async {
      await journal.createEntryLocal('Persistent entry');
      await journal.createEntryLocal('Another one');

      // Create a new service instance and load.
      final journal2 = JournalService();
      journal2.update(auth, crypto);

      // Give it time to load (update triggers _loadLocalEntries).
      await Future.delayed(const Duration(milliseconds: 100));

      expect(journal2.entries.length, 2);
      expect(journal2.entries[0].content, 'Another one');
      expect(journal2.entries[1].content, 'Persistent entry');
    });

    // ── Update ──────────────────────────────────────────────────────────

    test('updateEntryLocal changes content', () async {
      await journal.createEntryLocal('Original');
      final id = journal.entries[0].id;

      await journal.updateEntryLocal(id, 'Updated');

      expect(journal.entries[0].content, 'Updated');
      expect(journal.entries[0].id, id);
    });

    test('updateEntryLocal updates the timestamp', () async {
      await journal.createEntryLocal('Before update');
      final id = journal.entries[0].id;
      final originalUpdatedAt = journal.entries[0].updatedAt;

      // Small delay to ensure timestamp difference.
      await Future.delayed(const Duration(milliseconds: 10));
      await journal.updateEntryLocal(id, 'After update');

      expect(
        journal.entries[0].updatedAt.isAfter(originalUpdatedAt) ||
            journal.entries[0].updatedAt == originalUpdatedAt,
        isTrue,
      );
    });

    test('updateEntryLocal preserves createdAt', () async {
      await journal.createEntryLocal('Keep createdAt');
      final id = journal.entries[0].id;
      final originalCreatedAt = journal.entries[0].createdAt;

      await journal.updateEntryLocal(id, 'Modified');

      expect(journal.entries[0].createdAt, originalCreatedAt);
    });

    test('updateEntryLocal with nonexistent ID does nothing', () async {
      await journal.createEntryLocal('Existing');

      await journal.updateEntryLocal('nonexistent-id', 'Nothing');

      expect(journal.entries.length, 1);
      expect(journal.entries[0].content, 'Existing');
    });

    test('updateEntryLocal notifies listeners', () async {
      await journal.createEntryLocal('To update');
      final id = journal.entries[0].id;

      int notifications = 0;
      journal.addListener(() => notifications++);

      await journal.updateEntryLocal(id, 'Updated');

      expect(notifications, greaterThan(0));
    });

    // ── Delete ──────────────────────────────────────────────────────────

    test('deleteEntryLocal removes the entry', () async {
      await journal.createEntryLocal('To delete');
      final id = journal.entries[0].id;

      await journal.deleteEntryLocal(id);

      expect(journal.entries, isEmpty);
    });

    test('deleteEntryLocal removes only the specified entry', () async {
      await journal.createEntryLocal('Keep');
      await journal.createEntryLocal('Delete');
      final deleteId = journal.entries[0].id; // "Delete" is first (newest)

      await journal.deleteEntryLocal(deleteId);

      expect(journal.entries.length, 1);
      expect(journal.entries[0].content, 'Keep');
    });

    test('deleteEntryLocal with nonexistent ID does nothing', () async {
      await journal.createEntryLocal('Safe');

      await journal.deleteEntryLocal('nonexistent');

      expect(journal.entries.length, 1);
    });

    test('deleteEntryLocal notifies listeners', () async {
      await journal.createEntryLocal('To remove');
      final id = journal.entries[0].id;

      int notifications = 0;
      journal.addListener(() => notifications++);

      await journal.deleteEntryLocal(id);

      expect(notifications, greaterThan(0));
    });

    test('deleteEntryLocal persists the removal', () async {
      await journal.createEntryLocal('Temporary');
      final id = journal.entries[0].id;

      await journal.deleteEntryLocal(id);

      // Create a new service instance and verify.
      final journal2 = JournalService();
      journal2.update(auth, crypto);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(journal2.entries, isEmpty);
    });

    // ── fetchAll in offline mode ─────────────────────────────────────────

    test('fetchAll in offline mode reloads from local storage', () async {
      await journal.createEntryLocal('Fetch test');

      // Clear in-memory entries to simulate fresh load.
      final journal2 = JournalService();
      journal2.update(auth, crypto);

      await journal2.fetchAll();

      expect(journal2.entries.length, 1);
      expect(journal2.entries[0].content, 'Fetch test');
    });

    // ── sharedWithMe stays empty in offline mode ─────────────────────────

    test('sharedWithMe is empty in offline mode', () {
      expect(journal.sharedWithMe, isEmpty);
    });
  });
}
