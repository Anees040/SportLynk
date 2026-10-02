import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import 'scout_chips.dart';
import 'scout_theme.dart';

/// What Scout can do, with the one-line description of each.
///
/// The in-chat capability card shows the same abilities as bare chips; this sheet is
/// where the glosses live, because sixteen descriptions would push the sentence that
/// prompted them off the top of the chat. Reachable from the app bar at any time, so
/// "what can this thing even do" never requires guessing a phrase first.
///
/// It stays a bottom sheet because it is a lookup rather than a destination: the
/// conversation underneath is still the subject, and a push/pop would lose the scroll
/// position of the transcript being read. The chat list, which used to sit beside it
/// here, is a destination and now lives in `scout_drawer.dart`.
///
/// Every row is a button that posts its action. That is the mechanism that makes the
/// abilities the released classifier has no label for — finding players, opening a
/// route in Maps — fully usable: a tap runs the action and never consults the model.
Future<void> showScoutHelpSheet(
  BuildContext context, {
  required List<ScoutCapability> capabilities,
  required void Function(ScoutChip chip) onPick,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ScoutTheme.of(context).card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final t = ScoutTheme.of(sheetContext);
      final groups = ScoutCapability.grouped(capabilities);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.78,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'What I can do',
                  style: TextStyle(
                    color: t.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Tap one, or just type it in your own words — English, Roman Urdu, either.',
                  style: TextStyle(color: t.inkFaint, fontSize: 11.5, height: 1.35),
                ),
                const SizedBox(height: 14),
                if (capabilities.isEmpty)
                  Text(
                    'I could not load the list just now. Ask me anything anyway — grounds, '
                    'bookings, teams, your wallet.',
                    style: TextStyle(color: t.inkSoft, fontSize: 12.5, height: 1.4),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final g in groups) ...[
                          Padding(
                            padding: EdgeInsets.only(top: g == groups.first ? 0 : 16, bottom: 6),
                            child: Text(
                              g.group.toUpperCase(),
                              style: TextStyle(
                                color: t.inkFaint,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                              ),
                            ),
                          ),
                          for (final c in g.items)
                            _CapabilityRow(
                              capability: c,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                onPick(ScoutChip(label: c.label, action: c.action));
                              },
                            ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _CapabilityRow extends StatelessWidget {
  final ScoutCapability capability;
  final VoidCallback onTap;

  const _CapabilityRow({required this.capability, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = ScoutTheme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(ScoutChipIcons.of(capability.action), size: 16, color: t.accent),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    capability.label,
                    style: TextStyle(
                      color: t.ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (capability.gloss.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      capability.gloss,
                      style: TextStyle(
                        color: t.inkFaint,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 17, color: t.inkFaint),
          ],
        ),
      ),
    );
  }
}
