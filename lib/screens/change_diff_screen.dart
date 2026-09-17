import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// Change Diff screen: before/after diff for one proposed change.
/// Pops with `true` (apply) or `false` (reject).
class ChangeDiffScreen extends StatelessWidget {
  const ChangeDiffScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final arg = ModalRoute.of(context)?.settings.arguments;
    if (arg is! Map) {
      return Scaffold(appBar: AppBar(title: const Text('Diff')), body: const Center(child: Text('No change provided.')));
    }
    final map = arg as Map;
    final path = map['path'] as String;
    final kind = map['kind'] as String;
    final diff = (map['diff'] as List).cast<DiffLine>();

    return Scaffold(
      appBar: AppBar(title: Text(kind == 'delete' ? 'Delete $path' : 'Modify $path')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(14), child: Align(alignment: Alignment.centerLeft, child:
          Text(kind == 'delete'
              ? 'This will DELETE $path. The previous content is kept in history so you can undo.'
              : 'Proposed change to $path. Review the diff below, then confirm.',
            style: TextStyle(color: AppTheme.warn)))),
        Expanded(child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFF0A0D12), border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(10)),
          child: SingleChildScrollView(child: SelectableText.rich(
            TextSpan(children: [
              for (final l in diff) TextSpan(
                text: '${l.type == 'add' ? '+' : l.type == 'del' ? '-' : ' '}$l\n',
                style: TextStyle(
                  fontFamily: 'monospace', fontSize: 12,
                  color: l.type == 'add' ? const Color(0xFF7EE787) : l.type == 'del' ? const Color(0xFFFFA198) : AppTheme.muted,
                  backgroundColor: l.type == 'add' ? const Color(0x262EA043) : l.type == 'del' ? const Color(0x26F85149) : null,
                ),
              ),
            ]),
          )),
        )),
        SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Reject'))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.check),
            label: const Text('Apply'))),
        ]))),
      ]),
    );
  }
}
