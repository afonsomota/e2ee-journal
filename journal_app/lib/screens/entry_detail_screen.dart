// screens/entry_detail_screen.dart
//
// Shows a single entry and (for owned entries) the sharing UI.
// [Step6] The share dialog is where the magic of key re-encryption happens
//         behind the scenes.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/journal_entry.dart';
import '../services/journal_service.dart';
import 'entry_editor_screen.dart';

class EntryDetailScreen extends StatelessWidget {
  final JournalEntry entry;
  final bool isOwned;

  const EntryDetailScreen({
    super.key,
    required this.entry,
    required this.isOwned,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(isOwned ? 'My Entry' : 'Shared by ${entry.authorUsername}'),
        actions: [
          if (isOwned) ...[
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => EntryEditorScreen(entry: entry),
                ),
              ),
              tooltip: 'Edit',
            ),
            IconButton(
              icon: const Icon(Icons.share_outlined),
              onPressed: () => _showShareDialog(context),
              tooltip: 'Share',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDelete(context),
              tooltip: 'Delete',
            ),
          ],
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Metadata row
            Row(
              children: [
                Icon(
                  entry.encryptedBlob != null ? Icons.lock : Icons.lock_open,
                  size: 16,
                  color: entry.encryptedBlob != null
                      ? Colors.green.shade600
                      : Colors.orange,
                ),
                const SizedBox(width: 8),
                Text(
                  entry.encryptedBlob != null
                      ? entry.encryptedContentKey != null
                          ? 'Hybrid E2EE (Step 5+)'
                          : 'Symmetric E2EE (Step 3)'
                      : 'No encryption (Step 1)',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic),
                ),
                const Spacer(),
                Text(
                  _formatDate(entry.updatedAt),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),

            // Shared-with list [Step6]
            if (isOwned && entry.sharedWith.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                children: [
                  Icon(Icons.people_outline,
                      size: 14, color: scheme.secondary),
                  ...entry.sharedWith.map(
                    (u) => Chip(
                      label: Text(u, style: const TextStyle(fontSize: 11)),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 24),

            // Entry content
            SelectableText(
              entry.content.isEmpty ? '(empty entry)' : entry.content,
              style: const TextStyle(fontSize: 17, height: 1.7),
            ),
          ],
        ),
      ),
    );
  }

  // ── Step 6: Share dialog ───────────────────────────────────────────────────
  //
  // BLOG NOTE: From the user's perspective, they just type a username and tap
  // Share.  Behind the scenes, JournalService:
  //   1. Fetches the recipient's public key from the server.
  //   2. Decrypts the content key with our private key.
  //   3. Re-encrypts it with the recipient's public key.
  //   4. Posts only the new key blob — the encrypted body never changes.

  Future<void> _showShareDialog(BuildContext context) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.lock_outline, size: 20),
            SizedBox(width: 8),
            Text('Share Entry'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The entry content key will be re-encrypted with the recipient\'s '
              'public key. The server cannot read either.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Recipient username',
                prefixIcon: Icon(Icons.person_outline),
              ),
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Share'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && context.mounted) {
      final journal = context.read<JournalService>();
      await journal.shareEntry(entry.id, result);
      if (context.mounted && journal.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(journal.error!),
            backgroundColor: Colors.red.shade700,
          ),
        );
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Shared with $result'),
            backgroundColor: Colors.green.shade700,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entry'),
        content: const Text(
            'This will permanently delete the entry and all shared access to it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<JournalService>().deleteEntry(entry.id);
      if (context.mounted) Navigator.pop(context);
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
