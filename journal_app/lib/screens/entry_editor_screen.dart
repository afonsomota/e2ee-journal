// screens/entry_editor_screen.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/journal_entry.dart';
import '../services/journal_service.dart';
import '../services/crypto_service.dart';

class EntryEditorScreen extends StatefulWidget {
  final JournalEntry? entry; // null = new entry

  const EntryEditorScreen({super.key, this.entry});

  @override
  State<EntryEditorScreen> createState() => _EntryEditorScreenState();
}

class _EntryEditorScreenState extends State<EntryEditorScreen> {
  late TextEditingController _ctrl;
  bool _saving = false;

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
    } else {
      await journal.createEntry(content);
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
          // Crypto status banner
          _CryptoBanner(hasKeys: crypto.hasKeys),

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

class _CryptoBanner extends StatelessWidget {
  final bool hasKeys;
  const _CryptoBanner({required this.hasKeys});

  @override
  Widget build(BuildContext context) {
    if (hasKeys) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        color: Colors.green.shade50,
        child: Row(
          children: [
            Icon(Icons.lock, size: 14, color: Colors.green.shade700),
            const SizedBox(width: 8),
            Text(
              'Hybrid E2EE — encrypted before leaving this device',
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.green.shade700,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: Colors.blue.shade50,
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 14, color: Colors.blue.shade700),
          const SizedBox(width: 8),
          Text(
            'Symmetric E2EE — encrypted before leaving this device',
            style: TextStyle(
                fontSize: 12,
                color: Colors.blue.shade700,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
