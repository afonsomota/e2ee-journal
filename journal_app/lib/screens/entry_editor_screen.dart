// screens/entry_editor_screen.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/emotion_result.dart';
import '../models/journal_entry.dart';
import '../services/journal_service.dart';
import '../services/crypto_service.dart';
import '../services/emotion_service.dart';
import '../theme.dart';

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
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final crypto = context.watch<CryptoService>();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
              child: Row(
                children: [
                  // Close
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.onSurface),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'InnerApple',
                          style: GoogleFonts.newsreader(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                        Text(
                          _isEditing ? 'EDITING ENTRY' : 'DRAFTING ENTRY',
                          style: AppTypography.labelSmall.copyWith(
                            color: AppColors.outline,
                            fontSize: 9,
                            letterSpacing: 2.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Save button (gradient)
                  _saving
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          ),
                        )
                      : Material(
                          borderRadius: BorderRadius.circular(12),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: _save,
                            child: Ink(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    AppColors.primary,
                                    AppColors.primaryContainer,
                                  ],
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 10),
                                child: Text(
                                  'Save',
                                  style: GoogleFonts.manrope(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.onPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                ],
              ),
            ),

            // Content area
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Date
                    Text(
                      _formatDate(widget.entry?.updatedAt ?? DateTime.now())
                          .toUpperCase(),
                      style: GoogleFonts.manrope(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2.0,
                        color: AppColors.tertiary,
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Encryption pill
                    if (_isEditing)
                      _EncryptionPill(
                        isEncrypted: widget.entry!.encryptedBlob != null,
                        isToggleable: false,
                      )
                    else
                      _EncryptionPill(
                        isEncrypted: _encrypted,
                        isToggleable: crypto.hasKeys,
                        onToggle: () =>
                            setState(() => _encrypted = !_encrypted),
                      ),

                    const SizedBox(height: 20),

                    // Emotion badge (edit mode, cached)
                    if (_isEditing)
                      Consumer<EmotionService>(
                        builder: (_, emotion, __) {
                          final result = emotion.cached(widget.entry!.id);
                          if (!emotion.available || result == null) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: _EditorEmotionChip(result: result),
                          );
                        },
                      ),

                    // Text input
                    TextField(
                      controller: _ctrl,
                      maxLines: null,
                      decoration: InputDecoration(
                        hintText: 'Write your thoughts\u2026',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        hintStyle: GoogleFonts.manrope(
                          fontSize: 17,
                          color: AppColors.onSurfaceVariant.withValues(alpha: 0.3),
                        ),
                      ),
                      style: GoogleFonts.manrope(
                        fontSize: 17,
                        height: 1.8,
                        color: AppColors.onSurfaceVariant,
                      ),
                      autofocus: true,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
}

// ── Encryption Pill ──

class _EncryptionPill extends StatelessWidget {
  final bool isEncrypted;
  final bool isToggleable;
  final VoidCallback? onToggle;

  const _EncryptionPill({
    required this.isEncrypted,
    required this.isToggleable,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isToggleable ? onToggle : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.outlineVariant.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.shield_outlined,
              size: 16,
              color: isEncrypted ? AppColors.primary : AppColors.outline,
            ),
            const SizedBox(width: 8),
            Text(
              isEncrypted ? 'ENCRYPTED ENTRY' : 'STANDARD ENTRY',
              style: GoogleFonts.manrope(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.0,
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: isEncrypted ? AppColors.primary : AppColors.outline,
                shape: BoxShape.circle,
              ),
            ),
            if (isToggleable) ...[
              const SizedBox(width: 8),
              Icon(Icons.swap_horiz,
                  size: 14, color: AppColors.outline.withValues(alpha: 0.5)),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Editor Emotion Chip ──

class _EditorEmotionChip extends StatelessWidget {
  final EmotionResult result;
  const _EditorEmotionChip({required this.result});

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
    final label =
        '${result.emotion[0].toUpperCase()}${result.emotion.substring(1)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.secondaryFixed,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.manrope(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.onSecondaryFixed,
            ),
          ),
          const SizedBox(width: 4),
          // Mini confidence bar
          SizedBox(
            width: 32,
            height: 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: result.confidence,
                backgroundColor: AppColors.surfaceContainer,
                valueColor: const AlwaysStoppedAnimation<Color>(
                    AppColors.secondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
