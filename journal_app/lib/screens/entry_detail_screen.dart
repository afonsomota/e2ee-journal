// screens/entry_detail_screen.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/journal_entry.dart';
import '../models/emotion_result.dart';
import '../services/journal_service.dart';
import '../services/emotion_service.dart';
import '../theme.dart';
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
    final entry = widget.entry;
    final isOwned = widget.isOwned;

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
                  // Back
                  IconButton(
                    icon: const Icon(Icons.arrow_back,
                        color: AppColors.primary),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      isOwned
                          ? 'My Entry'
                          : 'Shared by ${entry.authorUsername}',
                      style: GoogleFonts.newsreader(
                        fontSize: 22,
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  if (isOwned) ...[
                    _AppBarAction(
                      icon: Icons.edit_outlined,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => EntryEditorScreen(entry: entry),
                        ),
                      ),
                    ),
                    _AppBarAction(
                      icon: Icons.share_outlined,
                      onTap: () => _showShareDialog(context),
                    ),
                  ],
                ],
              ),
            ),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Date + encryption pill
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDate(entry.updatedAt).toUpperCase(),
                          style: AppTypography.labelSmall.copyWith(
                            color: AppColors.outline,
                            letterSpacing: 2.5,
                          ),
                        ),
                        // Encrypted pill
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceContainerLowest,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color:
                                  AppColors.outlineVariant.withValues(alpha: 0.15),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: entry.encryptedBlob != null
                                      ? AppColors.primary
                                      : AppColors.outline,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                entry.encryptedBlob != null
                                    ? 'End-to-end Encrypted'
                                    : 'Standard',
                                style: GoogleFonts.manrope(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Title (first line of content as headline)
                    Text(
                      _extractTitle(entry.content),
                      style: GoogleFonts.newsreader(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface,
                        height: 1.2,
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Emotion badge
                    Consumer<EmotionService>(
                      builder: (_, emotion, _) {
                        if (!emotion.available) return const SizedBox.shrink();
                        final result = emotion.cached(entry.id);
                        if (result != null) {
                          return _EmotionBadge(result: result);
                        }
                        if (emotion.isClassifying(entry.id)) {
                          return _EmotionBadgeLoading();
                        }
                        return const SizedBox.shrink();
                      },
                    ),

                    const SizedBox(height: 28),

                    // Entry body
                    SelectableText(
                      entry.content.isEmpty
                          ? '(empty entry)'
                          : entry.content,
                      style: GoogleFonts.manrope(
                        fontSize: 17,
                        height: 1.8,
                        color: AppColors.onSurface,
                      ),
                    ),

                    // Shared-with section
                    if (isOwned && entry.sharedWith.isNotEmpty) ...[
                      const SizedBox(height: 40),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerLow
                              .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Shared Access',
                                  style: AppTypography.headlineSmall,
                                ),
                                Text(
                                  '${entry.sharedWith.length} collaborator${entry.sharedWith.length == 1 ? '' : 's'}',
                                  style: AppTypography.labelSmall.copyWith(
                                    color: AppColors.outline,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            ...entry.sharedWith.map(
                              (u) => Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceContainerLowest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 18,
                                      backgroundColor:
                                          AppColors.primaryContainer,
                                      child: Text(
                                        u[0].toUpperCase(),
                                        style: GoogleFonts.manrope(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.onPrimaryContainer,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        u,
                                        style: GoogleFonts.manrope(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.onSurface,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Delete button
                    if (isOwned) ...[
                      const SizedBox(height: 40),
                      Center(
                        child: TextButton.icon(
                          onPressed: () => _confirmDelete(context),
                          icon: Icon(Icons.delete_outline,
                              size: 16,
                              color: AppColors.error.withValues(alpha: 0.6)),
                          label: Text(
                            'PERMANENTLY DELETE ENTRY',
                            style: AppTypography.labelSmall.copyWith(
                              color: AppColors.error.withValues(alpha: 0.6),
                              letterSpacing: 2.0,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _extractTitle(String content) {
    if (content.isEmpty) return '(empty entry)';
    final firstLine = content.split('\n').first;
    if (firstLine.length > 60) return '${firstLine.substring(0, 60)}\u2026';
    return firstLine;
  }

  Future<void> _showShareDialog(BuildContext context) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Share this thought',
                  style: AppTypography.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'They will receive an invitation to view this encrypted entry.',
                style: AppTypography.bodyMedium,
              ),
              const SizedBox(height: 20),
              Text('USERNAME OR EMAIL',
                  style: AppTypography.labelSmall),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'e.g. apple_lover_92',
                  filled: true,
                  fillColor: AppColors.surfaceContainerLow,
                ),
                style: AppTypography.bodyLarge,
                textInputAction: TextInputAction.done,
                onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.verified_user_outlined,
                        size: 18, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Encryption keys will be automatically rotated for shared access.',
                        style: AppTypography.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Material(
                      color: AppColors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.pop(ctx),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Center(
                            child: Text('Cancel',
                                style: GoogleFonts.manrope(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.onSurface,
                                )),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _GradientButtonSmall(
                      label: 'Send Invite',
                      onTap: () => Navigator.pop(ctx, ctrl.text.trim()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (result != null && result.isNotEmpty && context.mounted) {
      final journal = context.read<JournalService>();
      await journal.shareEntry(widget.entry.id, result);
      if (context.mounted && journal.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(journal.error!),
            backgroundColor: AppColors.error,
          ),
        );
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Shared with $result'),
            backgroundColor: AppColors.primary,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.errorContainer,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.delete_forever,
                    size: 28, color: Color(0xFF93000A)),
              ),
              const SizedBox(height: 20),
              Text('Are you sure?',
                  style: AppTypography.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'This entry will be wiped from our secure vault forever. This action cannot be undone.',
                textAlign: TextAlign.center,
                style: AppTypography.bodyMedium.copyWith(height: 1.5),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                    foregroundColor: AppColors.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text('Yes, Delete Forever',
                      style: GoogleFonts.manrope(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      )),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    'Keep My Entry',
                    style: GoogleFonts.manrope(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.outline,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<JournalService>().deleteEntry(widget.entry.id);
      if (context.mounted) Navigator.pop(context);
    }
  }

  String _formatDate(DateTime dt) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
}

// ── Supporting Widgets ──

class _AppBarAction extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _AppBarAction({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        margin: const EdgeInsets.only(left: 4),
        decoration: const BoxDecoration(shape: BoxShape.circle),
        child: Icon(icon, size: 20, color: AppColors.outline),
      ),
    );
  }
}

class _EmotionBadgeLoading extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.secondaryFixed,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.secondary.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Analysing emotion\u2026',
            style: GoogleFonts.manrope(
              fontSize: 12,
              color: AppColors.onSecondaryFixed,
            ),
          ),
        ],
      ),
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

  @override
  Widget build(BuildContext context) {
    final emoji = _emoji[result.emotion] ?? '🤔';
    final pct = (result.confidence * 100).toStringAsFixed(0);
    final label =
        '${result.emotion[0].toUpperCase()}${result.emotion.substring(1)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.secondaryFixed,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.manrope(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSecondaryFixed,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$pct% confidence',
                style: GoogleFonts.manrope(
                  fontSize: 11,
                  color: AppColors.onSecondaryFixed.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.lock,
                  size: 12,
                  color: AppColors.onSecondaryFixed.withValues(alpha: 0.5)),
            ],
          ),
          // Confidence underline bar
          Positioned(
            bottom: -8,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: result.confidence,
                minHeight: 3,
                backgroundColor: Colors.transparent,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(AppColors.secondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GradientButtonSmall extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _GradientButtonSmall({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primary, AppColors.primaryContainer],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text(
                label,
                style: GoogleFonts.manrope(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
