import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/update/update_service.dart';
import '../state/update_controller.dart';

/// Opens a release page in the browser (github.com only).
Future<bool> openReleasePage(Uri url) async {
  if (!isTrustedReleaseUrl(url)) return false;
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}

/// "A new version is available" dialog.
Future<void> showUpdateDialog(BuildContext context, UpdateController updates, ReleaseInfo release) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final notes = release.notes.isEmpty ? '此版本未提供更新说明。' : release.notes;
      return AlertDialog(
        title: Text('发现新版本 ${release.tag}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前版本 ${updates.currentVersion}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(child: SingleChildScrollView(child: SelectableText(notes))),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              updates.skip(release);
              Navigator.pop(ctx);
            },
            child: const Text('忽略此版本'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('稍后')),
          FilledButton(
            onPressed: () {
              openReleasePage(release.pageUrl);
              Navigator.pop(ctx);
            },
            child: const Text('前往下载'),
          ),
        ],
      );
    },
  );
}
