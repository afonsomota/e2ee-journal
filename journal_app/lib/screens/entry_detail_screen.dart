// screens/entry_detail_screen.dart
//
// Shows a single entry and (for owned entries) the sharing UI.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/journal_entry.dart';
import '../services/journal_service.dart';
import '../models/emotion_result.dart';
import '../services/emotion_service.dart';
import 'entry_editor_screen.dart';

class EntryDetailScreen extends StatefulWidget {
  final JournalEntry entry;
  final bool isOwned;

  const EntryDetailScreen({
    super.key,
    required this.entry,
    required this.isOwned,
  });

  @override
  State<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends State<EntryDetailScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final emotion = context.read<EmotionService>();
      if (emotion.available && widget.entry.content.isNotEmpty) {
        emotion.classifyEntry(widget.entry.id, widget.entry.content);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entry = widget.entry;
    final isOwned = widget.isOwned;

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
                          ? 'Hybrid E2EE'
                          : 'Symmetric E2EE'
                      : 'No encryption',
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

            // Emotion badge
            Consumer<EmotionService>(
              builder: (_, emotion, __) {
                final result = emotion.cached(entry.id);
                if (!emotion.available) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: result == null
                      ? _EmotionBadgeLoading()
                      : _EmotionBadge(result: result),
                );
              },
            ),

            // Shared-with list
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

  Future<void> _showShareDialog(BuildContext context) async {
    final isEncrypted = widget.entry.encryptedContentKey != null;
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(isEncrypted ? Icons.lock_outline : Icons.lock_open,
                size: 20),
            const SizedBox(width: 8),
            const Text('Share Entry'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isEncrypted
                  ? 'The entry content key will be re-encrypted with the '
                    'recipient\'s public key. The server cannot read either.'
                  : 'This is a standard entry. The recipient will be able to '
                    'read it directly.',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
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
      await journal.shareEntry(widget.entry.id, result);
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
      await context.read<JournalService>().deleteEntry(widget.entry.id);
      if (context.mounted) Navigator.pop(context);
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ── Emotion badge widgets ──────────────────────────────────────────────────

class _EmotionBadgeLoading extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: Colors.grey.shade400,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'Analysing emotion…',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
        ),
      ],
    );
  }
}

class _EmotionBadge extends StatelessWidget {
  final EmotionResult result;
  const _EmotionBadge({required this.result});

  static const _emoji = {
    'anger': '😠',
    'joy': '😊',
    'neutral': '😐',
    'sadness': '😢',
    'surprise': '😮',
  };

  static const Map<String, MaterialColor> _color = {
    'anger': Colors.red,
    'joy': Colors.amber,
    'neutral': Colors.blueGrey,
    'sadness': Colors.indigo,
    'surprise': Colors.purple,
  };

  @override
  Widget build(BuildContext context) {
    final emoji = _emoji[result.emotion] ?? '🤔';
    final color = _color[result.emotion] ?? Colors.grey;
    final pct = (result.confidence * 100).toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Text(
            result.emotion,
            style: TextStyle(
              fontSize: 12,
              color: color.shade700,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '$pct%',
            style: TextStyle(fontSize: 11, color: color.shade400),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: 'Detected via on-device FHE — the server never sees your text',
            child: Icon(Icons.shield_outlined, size: 12, color: color.shade400),
          ),
        ],
      ),
    );
  }
}
