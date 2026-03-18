// screens/entry_editor_screen.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/emotion_result.dart';
import '../models/journal_entry.dart';
import '../services/journal_service.dart';
import '../services/crypto_service.dart';
import '../services/emotion_service.dart';

class EntryEditorScreen extends StatefulWidget {
  final JournalEntry? entry; // null = new entry

  const EntryEditorScreen({super.key, this.entry});

  @override
  State<EntryEditorScreen> createState() => _EntryEditorScreenState();
}

class _EntryEditorScreenState extends State<EntryEditorScreen> {
  late TextEditingController _ctrl;
  bool _saving = false;
  bool _encrypted = true;

  bool get _isEditing => widget.entry != null;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.entry?.content ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final content = _ctrl.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Entry cannot be empty')),
      );
      return;
    }

    setState(() => _saving = true);
    final journal = context.read<JournalService>();

    if (_isEditing) {
      await journal.updateEntry(widget.entry!.id, content);
    } else if (_encrypted) {
      await journal.createEntry(content);
    } else {
      await journal.createEntryPlaintext(content);
    }

    if (mounted) {
      setState(() => _saving = false);
      if (journal.error == null) {
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(journal.error!),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final crypto = context.watch<CryptoService>();

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Entry' : 'New Entry'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white)),
            )
          else
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _save,
              tooltip: 'Save',
            ),
        ],
      ),
      body: Column(
        children: [
          if (_isEditing)
            _ReadOnlyBanner(entry: widget.entry!)
          else
            _EncryptionModeSelector(
              encrypted: _encrypted,
              hasKeys: crypto.hasKeys,
              onChanged: (v) => setState(() => _encrypted = v),
            ),

          // Emotion badge (edit mode only, shows cached result)
          if (_isEditing)
            Consumer<EmotionService>(
              builder: (_, emotion, __) {
                final result = emotion.cached(widget.entry!.id);
                if (!emotion.available || result == null) {
                  return const SizedBox.shrink();
                }
                return _EditorEmotionBar(result: result);
              },
            ),

          // Editor
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  hintText: 'Write your thoughts…',
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 17, height: 1.6),
                textAlignVertical: TextAlignVertical.top,
                autofocus: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Shown when creating a new entry — lets the user pick encrypted vs standard.
class _EncryptionModeSelector extends StatelessWidget {
  final bool encrypted;
  final bool hasKeys;
  final ValueChanged<bool> onChanged;

  const _EncryptionModeSelector({
    required this.encrypted,
    required this.hasKeys,
    required this.onChanged,
  });

  void _showInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What does this mean?'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoSection(
              icon: Icons.lock,
              iconColor: Colors.green,
              title: 'Encrypted',
              body: 'Your entry is scrambled on your device before it ever '
                  'reaches our servers. Only you (and anyone you share it '
                  'with) can read it. Not even we can access it.',
            ),
            SizedBox(height: 16),
            _InfoSection(
              icon: Icons.lock_open,
              iconColor: Colors.orange,
              title: 'Standard',
              body: 'Your entry is stored as-is on our servers. This allows '
                  'us to offer features like search and smart suggestions. '
                  'Your data is kept safe and treated with the utmost care '
                  '— this is how most apps work.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = encrypted ? Colors.green : Colors.orange;
    final bgColor = encrypted ? Colors.green.shade50 : Colors.orange.shade50;
    final label = encrypted
        ? 'Encrypted — only you can read this'
        : 'Standard — stored on our servers';
    final icon = encrypted ? Icons.lock : Icons.lock_open;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      color: bgColor,
      child: Row(
        children: [
          Icon(icon, size: 16, color: color.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color.shade700,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.info_outline, size: 18, color: color.shade700),
            onPressed: () => _showInfoDialog(context),
            tooltip: 'Learn more',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          Switch(
            value: encrypted,
            onChanged: hasKeys ? onChanged : null,
            activeThumbColor: Colors.green.shade700,
          ),
        ],
      ),
    );
  }
}

// Read-only banner shown when editing an existing entry.
class _ReadOnlyBanner extends StatelessWidget {
  final JournalEntry entry;
  const _ReadOnlyBanner({required this.entry});

  @override
  Widget build(BuildContext context) {
    final isEncrypted = entry.encryptedBlob != null;
    final color = isEncrypted ? Colors.green : Colors.orange;
    final label = isEncrypted
        ? 'Encrypted — only you can read this'
        : 'Standard — stored on our servers';
    final icon = isEncrypted ? Icons.lock : Icons.lock_open;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: isEncrypted ? Colors.green.shade50 : Colors.orange.shade50,
      child: Row(
        children: [
          Icon(icon, size: 14, color: color.shade700),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// Thin bar shown at the top of the editor when an emotion result is cached.
class _EditorEmotionBar extends StatelessWidget {
  final EmotionResult result;
  const _EditorEmotionBar({required this.result});

  static const _emoji = {
    'anger': '😠',
    'joy': '😊',
    'neutral': '😐',
    'sadness': '😢',
    'surprise': '😮',
  };

  @override
  Widget build(BuildContext context) {
    final emoji = _emoji[result.emotion] ?? '🤔';
    final pct = (result.confidence * 100).toStringAsFixed(0);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      color: Colors.purple.shade50,
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 6),
          Text(
            '${result.emotion}  $pct%',
            style: TextStyle(
              fontSize: 12,
              color: Colors.purple.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: 'Detected via on-device FHE',
            child: Icon(Icons.shield_outlined,
                size: 12, color: Colors.purple.shade300),
          ),
        ],
      ),
    );
  }
}

// Reusable section inside the info dialog.
class _InfoSection extends StatelessWidget {
  final IconData icon;
  final MaterialColor iconColor;
  final String title;
  final String body;

  const _InfoSection({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: iconColor.shade700),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: iconColor.shade700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(body, style: const TextStyle(fontSize: 14, height: 1.4)),
      ],
    );
  }
}
