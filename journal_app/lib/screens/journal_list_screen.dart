import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/journal_service.dart';
import '../services/crypto_service.dart';
import '../models/journal_entry.dart';
import 'entry_editor_screen.dart';
import 'entry_detail_screen.dart';

class JournalListScreen extends StatelessWidget {
  const JournalListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final journal = context.watch<JournalService>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Private Journal'),
            Text(
              auth.currentUser?.username ?? '',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w300),
            ),
          ],
        ),
        actions: [
          // E2EE status badge — reflects whether keypair is loaded
          Consumer<CryptoService>(
            builder: (_, crypto, __) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                avatar: Icon(
                  crypto.hasKeys ? Icons.lock : Icons.lock_open,
                  size: 14,
                  color: crypto.hasKeys ? Colors.green.shade300 : Colors.orange,
                ),
                label: Text(
                  crypto.hasKeys ? 'E2EE' : 'Encrypted',
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
                backgroundColor: scheme.primary.withValues(alpha: 0.7),
                padding: EdgeInsets.zero,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => context.read<JournalService>().fetchAll(),
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              context.read<AuthService>().logout(context.read<CryptoService>());
            },
            tooltip: 'Logout',
          ),
        ],
      ),
      body: journal.loading
          ? const Center(child: CircularProgressIndicator())
          : journal.entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.book_outlined,
                          size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text(
                        'No entries yet.\nTap the button to write your first.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => context.read<JournalService>().fetchAll(),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: journal.entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) =>
                        _EntryCard(entry: journal.entries[i]),
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const EntryEditorScreen()),
        ),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New Entry'),
        backgroundColor: scheme.primary,
        foregroundColor: scheme.surface,
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  final JournalEntry entry;
  const _EntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final preview = entry.content.length > 120
        ? '${entry.content.substring(0, 120)}…'
        : entry.content;

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => EntryDetailScreen(entry: entry),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    entry.encryptedBlob != null ? Icons.lock : Icons.lock_open,
                    size: 14,
                    color: entry.encryptedBlob != null
                        ? Colors.green.shade600
                        : Colors.orange,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _formatDate(entry.updatedAt),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                preview.isEmpty ? '(empty)' : preview,
                style: const TextStyle(fontSize: 15, height: 1.4),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return 'Today ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (diff.inDays == 1) return 'Yesterday';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
