// screens/journal_list_screen.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/journal_service.dart';
import '../services/crypto_service.dart';
import '../services/emotion_service.dart';
import '../models/journal_entry.dart';
import '../theme.dart';
import 'entry_editor_screen.dart';
import 'entry_detail_screen.dart';

class JournalListScreen extends StatefulWidget {
  const JournalListScreen({super.key});

  @override
  State<JournalListScreen> createState() => _JournalListScreenState();
}

class _JournalListScreenState extends State<JournalListScreen> {
  bool _showMyEntries = true;

  @override
  Widget build(BuildContext context) {
    final journal = context.watch<JournalService>();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTopBar(),
            const SizedBox(height: 28),
            _buildSectionTabs(journal),
            const SizedBox(height: 20),
            Expanded(
              child: journal.loading
                  ? const Center(
                      child:
                          CircularProgressIndicator(color: AppColors.primary),
                    )
                  : _EntryList(
                      entries: _showMyEntries
                          ? journal.entries
                          : journal.sharedWithMe,
                      isOwned: _showMyEntries,
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: _buildFab(),
    );
  }

  // ── Top bar ─────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    final auth = context.watch<AuthService>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          _buildShieldBadge(),
          const SizedBox(width: 10),
          Expanded(child: _buildBrandColumn()),
          Text(
            '@${auth.currentUser?.username ?? ''}',
            style: AppTypography.bodySmall.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          _buildLogoutButton(),
        ],
      ),
    );
  }

  Widget _buildShieldBadge() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        shape: BoxShape.circle,
      ),
      child:
          const Icon(Icons.shield_outlined, size: 20, color: AppColors.primary),
    );
  }

  Widget _buildBrandColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'InnerApple',
          style: GoogleFonts.newsreader(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
          ),
        ),
        Row(
          children: [
            Consumer<CryptoService>(
              builder: (_, crypto, _) => Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color:
                      crypto.hasKeys ? AppColors.primary : AppColors.secondary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'E2EE PROTECTED',
              style: AppTypography.labelSmall.copyWith(
                color: AppColors.onSurfaceVariant.withValues(alpha: 0.6),
                letterSpacing: 2.0,
                fontSize: 9,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLogoutButton() {
    return GestureDetector(
      onTap: () {
        context.read<AuthService>().logout(context.read<CryptoService>());
      },
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.logout, size: 16, color: AppColors.outline),
      ),
    );
  }

  // ── Section tabs ────────────────────────────────────────────────────────

  Widget _buildSectionTabs(JournalService journal) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _SectionTab(
            label: 'My Entries',
            count: journal.entries.length,
            isActive: _showMyEntries,
            onTap: () => setState(() => _showMyEntries = true),
          ),
          const SizedBox(width: 24),
          _SectionTab(
            label: 'Shared with Me',
            count: journal.sharedWithMe.length,
            isActive: !_showMyEntries,
            onTap: () => setState(() => _showMyEntries = false),
          ),
        ],
      ),
    );
  }

  // ── FAB ─────────────────────────────────────────────────────────────────

  Widget _buildFab() {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.primaryContainer],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.2),
            blurRadius: 24,
            spreadRadius: -4,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const EntryEditorScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add, color: AppColors.onPrimary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'New Entry',
                  style: GoogleFonts.manrope(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Section Tab ──

class _SectionTab extends StatelessWidget {
  final String label;
  final int count;
  final bool isActive;
  final VoidCallback onTap;

  const _SectionTab({
    required this.label,
    required this.count,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: isActive ? 1.0 : 0.4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  label,
                  style: GoogleFonts.newsreader(
                    fontSize: isActive ? 20 : 15,
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.w600,
                    color: AppColors.onSurface,
                  ),
                ),
                const SizedBox(width: 8),
                if (count > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count',
                      style: AppTypography.bodySmall.copyWith(
                        color: AppColors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 3,
              width: isActive ? 50 : 0,
              decoration: BoxDecoration(
                color: _isMyEntries(label)
                    ? AppColors.primary
                    : AppColors.secondary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isMyEntries(String l) => l == 'My Entries';
}

// ── Entry List ──

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
              isOwned ? Icons.auto_stories_outlined : Icons.inbox_outlined,
              size: 56,
              color: AppColors.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              isOwned
                  ? 'No entries yet.\nTap the button to write your first.'
                  : 'Nothing shared with you yet.',
              textAlign: TextAlign.center,
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.outline,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: () => context.read<JournalService>().fetchAll(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
        itemCount: entries.length,
        itemBuilder: (ctx, i) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _EntryCard(entry: entries[i], isOwned: isOwned),
        ),
      ),
    );
  }
}

// ── Entry Card ──

class _EntryCard extends StatelessWidget {
  final JournalEntry entry;
  final bool isOwned;

  const _EntryCard({required this.entry, required this.isOwned});

  @override
  Widget build(BuildContext context) {
    final preview = entry.content.length > 160
        ? '${entry.content.substring(0, 160)}\u2026'
        : entry.content;

    return Material(
      color: AppColors.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                EntryDetailScreen(entry: entry, isOwned: isOwned),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 10),
              _buildPreview(preview),
              const SizedBox(height: 14),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _formatDate(entry.updatedAt).toUpperCase(),
              style: AppTypography.labelSmall.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 2.0,
                fontSize: 10,
              ),
            ),
            if (!isOwned)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'from ${entry.authorUsername}',
                  style: AppTypography.bodySmall.copyWith(
                    color: AppColors.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        Icon(
          entry.encryptedBlob != null
              ? Icons.lock
              : Icons.lock_open_outlined,
          size: 18,
          color: entry.encryptedBlob != null
              ? AppColors.primary.withValues(alpha: 0.4)
              : AppColors.outline.withValues(alpha: 0.3),
        ),
      ],
    );
  }

  Widget _buildPreview(String preview) {
    return Text(
      preview.isEmpty ? '(empty)' : preview,
      style: GoogleFonts.newsreader(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: AppColors.onSurface,
        height: 1.4,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildFooter() {
    return Row(
      children: [
        _buildEmotionChip(),
        const Spacer(),
        if (isOwned && entry.sharedWith.isNotEmpty)
          _buildShareCount(),
      ],
    );
  }

  Widget _buildEmotionChip() {
    return Consumer<EmotionService>(
      builder: (_, emotion, _) {
        final result = emotion.cached(entry.id);
        if (result == null) return const SizedBox.shrink();
        const emoji = {
          'anger': '😠',
          'joy': '😊',
          'neutral': '😐',
          'sadness': '😢',
          'surprise': '😮',
        };
        final pct = (result.confidence * 100).toStringAsFixed(0);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.secondaryFixed,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji[result.emotion] ?? '🤔',
                  style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              Text(
                '${result.emotion[0].toUpperCase()}${result.emotion.substring(1)} $pct%',
                style: GoogleFonts.manrope(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSecondaryFixed,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildShareCount() {
    return Row(
      children: [
        Icon(Icons.share_outlined,
            size: 14,
            color: AppColors.onSurfaceVariant.withValues(alpha: 0.5)),
        const SizedBox(width: 4),
        Text(
          '${entry.sharedWith.length}',
          style: AppTypography.bodySmall.copyWith(
            color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const days = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return days[dt.weekday - 1];
    return '${months[dt.month - 1]} ${dt.day}';
  }
}
