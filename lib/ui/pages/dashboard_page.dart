import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/settings.dart';
import '../format.dart';
import '../widgets/account_card.dart';
import 'account_detail_page.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, this.onOpenSettings, this.onOpenAccounts});

  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenAccounts;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = context.watch<AppController>();
    final snapshots = c.snapshots;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.navQuota, style: Theme.of(context).textTheme.headlineSmall),
        actions: [
          if (c.lastRefresh != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ValueListenableBuilder(
                valueListenable: c.now,
                builder: (_, now, _) => Text(
                  agoLabel(l, c.lastRefresh!, now),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: l.refresh,
            onPressed: c.refreshing ? null : c.refresh,
            icon: c.refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: c.refresh,
        child: ValueListenableBuilder(
          valueListenable: c.now,
          builder: (context, now, _) => CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (c.syncError != null && c.settings.syncMode.usesServer)
                SliverToBoxAdapter(
                  child: _Banner(text: c.syncError!, onTap: onOpenSettings),
                ),
              if (snapshots.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyState(
                    refreshing: c.refreshing,
                    serverMode: c.settings.syncMode.usesServer,
                    onOpenSettings: onOpenSettings,
                    onOpenAccounts: onOpenAccounts,
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  sliver: SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.crossAxisExtent;
                      final columns = width >= 1200 ? 3 : (width >= 760 ? 2 : 1);
                      return SliverToBoxAdapter(
                        child: _Masonry(
                          columns: columns,
                          spacing: 14,
                          children: [
                            for (final s in snapshots)
                              AccountCard(
                                key: ValueKey(s.accountId),
                                snapshot: s,
                                now: now,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => AccountDetailPage(accountId: s.accountId),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Simple column-balanced layout: cards have different heights.
class _Masonry extends StatelessWidget {
  const _Masonry({required this.columns, required this.spacing, required this.children});

  final int columns;
  final double spacing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (columns == 1) {
      return Column(
        children: [
          for (final child in children)
            Padding(
              padding: EdgeInsets.only(bottom: spacing),
              child: child,
            ),
        ],
      );
    }
    final cols = List.generate(columns, (_) => <Widget>[]);
    for (var i = 0; i < children.length; i++) {
      cols[i % columns].add(
        Padding(
          padding: EdgeInsets.only(bottom: spacing),
          child: children[i],
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < columns; i++) ...[
          if (i > 0) SizedBox(width: spacing),
          Expanded(child: Column(children: cols[i])),
        ],
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.onTap});

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.cloud_off, color: theme.colorScheme.onErrorContainer, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(text, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.refreshing,
    required this.serverMode,
    this.onOpenSettings,
    this.onOpenAccounts,
  });

  final bool refreshing;
  final bool serverMode;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenAccounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (refreshing) return const Center(child: CircularProgressIndicator());
    final l = AppLocalizations.of(context);
    final message = kIsWeb
        ? l.webEmptyMessage
        : isDesktopPlatform
        ? l.desktopEmptyMessage
        : l.mobileEmptyMessage;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.speed, size: 56, color: theme.colorScheme.primary.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text(l.noQuotaDataYet, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (!kIsWeb)
                  FilledButton.icon(
                    onPressed: onOpenAccounts,
                    icon: const Icon(Icons.add),
                    label: Text(l.addAccount),
                  ),
                if (kIsWeb || serverMode)
                  OutlinedButton.icon(
                    onPressed: onOpenSettings,
                    icon: const Icon(Icons.dns_outlined),
                    label: Text(l.serverSettings),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
