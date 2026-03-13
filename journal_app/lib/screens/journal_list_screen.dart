// screens/journal_list_screen.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/journal_service.dart';
import '../services/crypto_service.dart';
import '../services/emotion_service.dart';
import '../models/journal_entry.dart';
import 'entry_editor_screen.dart';
import 'entry_detail_screen.dart';

class JournalListScreen extends StatefulWidget {
  const JournalListScreen({super.key});

  @override
  State<JournalListScreen> createState() => _JournalListScreenState();
}

class _JournalListScreenState extends State<JournalListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

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
          // E2EE status badge
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
        bottom: TabBar(
          controller: _tabs,
          labelColor: scheme.surface,
          unselectedLabelColor: scheme.surface.withValues(alpha: 0.6),
          indicatorColor: scheme.secondary,
          tabs: [
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.book_outlined, size: 16),
                  const SizedBox(width: 6),
                  const Text('My Entries'),
                  if (journal.entries.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _Badge('${journal.entries.length}'),
                  ],
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.people_outline, size: 16),
                  const SizedBox(width: 6),
                  const Text('Shared with Me'),
                  if (journal.sharedWithMe.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _Badge('${journal.sharedWithMe.length}'),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      body: journal.loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                _EntryList(
                  entries: journal.entries,
                  isOwned: true,
                ),
                _EntryList(
                  entries: journal.sharedWithMe,
                  isOwned: false,
                ),
              ],
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

class _Badge extends StatelessWidget {
  final String label;
  const _Badge(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 10, color: Colors.white)),
    );
  }
}

class _EntryList extends StatelessWidget {
  final List<JournalEntry> entries;
  final bool isOwned;

  const _EntryList({required this.entries, required this.isOwned});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isOwned ? Icons.book_outlined : Icons.inbox_outlined,
              size: 64,
              color: Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              isOwned
                  ? 'No entries yet.\nTap the button to write your first.'
                  : 'Nothing shared with you yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => context.read<JournalService>().fetchAll(),
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (ctx, i) => _EntryCard(
          entry: entries[i],
          isOwned: isOwned,
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  final JournalEntry entry;
  final bool isOwned;

  const _EntryCard({required this.entry, required this.isOwned});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
            builder: (_) =>
                EntryDetailScreen(entry: entry, isOwned: isOwned),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Encryption indicator
                  Icon(
                    entry.encryptedBlob != null ? Icons.lock : Icons.lock_open,
                    size: 14,
                    color: entry.encryptedBlob != null
                        ? Colors.green.shade600
                        : Colors.orange,
                  ),
                  const SizedBox(width: 6),
                  if (!isOwned)
                    Text(
                      'from ${entry.authorUsername}  ·  ',
                      style: TextStyle(
                          fontSize: 12, color: scheme.secondary),
                    ),
                  Expanded(
                    child: Text(
                      _formatDate(entry.updatedAt),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  if (isOwned && entry.sharedWith.isNotEmpty)
                    Row(
                      children: [
                        Icon(Icons.people_outline,
                            size: 14, color: scheme.secondary),
                        const SizedBox(width: 4),
                        Text(
                          '${entry.sharedWith.length}',
                          style: TextStyle(
                              fontSize: 12, color: scheme.secondary),
                        ),
                      ],
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
              // Emotion chip (shown only when cached)
              Consumer<EmotionService>(
                builder: (_, emotion, __) {
                  final result = emotion.cached(entry.id);
                  if (result == null) return const SizedBox.shrink();
                  const emoji = {
                    'anger': '😠',
                    'joy': '😊',
                    'neutral': '😐',
                    'sadness': '😢',
                    'surprise': '😮',
                  };
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${emoji[result.emotion] ?? '🤔'} ${result.emotion}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  );
                },
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
    if (diff.inDays == 0) return 'Today ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    if (diff.inDays == 1) return 'Yesterday';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
