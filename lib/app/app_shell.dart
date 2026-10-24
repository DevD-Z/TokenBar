import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state/update_controller.dart';
import '../ui/pages/accounts_page.dart';
import '../ui/pages/dashboard_page.dart';
import '../ui/pages/settings_page.dart';
import '../ui/update_dialog.dart';

/// Bottom navigation on phones, a macOS-style sidebar on wide screens.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  UpdateController? _updates;

  @override
  void initState() {
    super.initState();
    _updates = context.read<UpdateController>()..addListener(_promptForUpdate);
    // The launch-time check may already have finished.
    WidgetsBinding.instance.addPostFrameCallback((_) => _promptForUpdate());
  }

  @override
  void dispose() {
    _updates?.removeListener(_promptForUpdate);
    super.dispose();
  }

  void _promptForUpdate() {
    final updates = _updates;
    if (updates == null || !mounted) return;
    final release = updates.takePrompt();
    if (release != null) showUpdateDialog(context, updates, release);
  }

  void _go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final destinations = [
      (Icons.speed_outlined, Icons.speed, l.navQuota),
      (Icons.people_outline, Icons.people, l.navAccounts),
      (Icons.settings_outlined, Icons.settings, l.navSettings),
    ];
    final pages = [
      DashboardPage(onOpenSettings: () => _go(2), onOpenAccounts: () => _go(1)),
      const AccountsPage(),
      const SettingsPage(),
    ];
    final body = IndexedStack(index: _index, children: pages);
    final wide = MediaQuery.sizeOf(context).width >= 720;

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            _Sidebar(index: _index, onSelect: _go, destinations: destinations),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _go,
        destinations: [
          for (final d in destinations)
            NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.index, required this.onSelect, required this.destinations});

  final int index;
  final ValueChanged<int> onSelect;
  final List<(IconData, IconData, String)> destinations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;
    return Container(
      width: 208,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF242426) : const Color(0xFFE9E9EE),
        border: Border(right: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 22),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        'assets/icon/tokenbar.png',
                        width: 30,
                        height: 30,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'TokenBar',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              for (var i = 0; i < destinations.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: _SidebarItem(
                    icon: index == i ? destinations[i].$2 : destinations[i].$1,
                    label: destinations[i].$3,
                    selected: index == i,
                    accent: accent,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? accent : theme.colorScheme.onSurface;
    return Material(
      color: selected
          ? accent.withValues(alpha: theme.brightness == Brightness.dark ? 0.22 : 0.13)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
