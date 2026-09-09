import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../profiles/active_profile_provider.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/snackbar_helper.dart';
import '../watch_together/models/watch_session.dart';
import '../watch_together/services/watch_together_relay_endpoint.dart';
import 'music_jam_provider.dart';

/// Top-bar entry point for Listen Together: a plain icon when idle, a
/// participant-count badge once a jam is active. Tapping opens the matching
/// sheet (start/join, or the live session's roster).
class MusicJamButton extends StatelessWidget {
  const MusicJamButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MusicJamProvider>(
      builder: (context, jam, child) {
        if (!jam.isInSession) {
          return IconButton(
            icon: const Icon(Symbols.group_add_rounded),
            tooltip: 'Listen Together',
            onPressed: () => _showStartOrJoinSheet(context),
          );
        }
        return _JamBadge(
          participantCount: jam.participantCount,
          isHost: jam.isHost,
          onTap: () => _showSessionSheet(context, jam),
        );
      },
    );
  }
}

class _JamBadge extends StatelessWidget {
  final int participantCount;
  final bool isHost;
  final VoidCallback onTap;

  const _JamBadge({required this.participantCount, required this.isHost, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(20)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          borderRadius: const BorderRadius.all(Radius.circular(20)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.groups_rounded, size: 16, color: isHost ? colorScheme.primary : colorScheme.onPrimaryContainer),
            const SizedBox(width: 4),
            Text(
              '$participantCount',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colorScheme.onPrimaryContainer),
            ),
          ],
        ),
      ),
    );
  }
}

void _showStartOrJoinSheet(BuildContext context) {
  final jam = context.read<MusicJamProvider>();
  unawaited(
    showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (sheetContext) => _StartOrJoinSheet(jam: jam)),
  );
}

void _showSessionSheet(BuildContext context, MusicJamProvider jam) {
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ListenableBuilder(listenable: jam, builder: (context, _) => _SessionSheet(jam: jam)),
    ),
  );
}

class _StartOrJoinSheet extends StatefulWidget {
  final MusicJamProvider jam;
  const _StartOrJoinSheet({required this.jam});

  @override
  State<_StartOrJoinSheet> createState() => _StartOrJoinSheetState();
}

class _StartOrJoinSheetState extends State<_StartOrJoinSheet> {
  bool _busy = false;

  String? get _displayName => context.read<ActiveProfileProvider>().active?.displayName;

  WatchTogetherRelayEndpoint get _relayEndpoint =>
      WatchTogetherRelayEndpoint.resolve(SettingsService.instanceOrNull?.read(SettingsService.customRelayUrl));

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      await widget.jam.createSession(displayName: _displayName, relayEndpoint: _relayEndpoint);
      if (mounted) Navigator.of(context).pop();
    } catch (e, stackTrace) {
      appLogger.e('MusicJam: Failed to start jam from sheet', error: e, stackTrace: stackTrace);
      if (mounted) showErrorSnackBar(context, 'Could not start the jam. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    final code = await showDialog<String>(context: context, builder: (_) => const _JoinCodeDialog());
    if (code == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.jam.joinSession(code, displayName: _displayName, relayEndpoint: _relayEndpoint);
      if (mounted) Navigator.of(context).pop();
    } catch (e, stackTrace) {
      appLogger.e('MusicJam: Failed to join jam from sheet', error: e, stackTrace: stackTrace);
      if (mounted) showErrorSnackBar(context, 'Could not join that jam. Check the code and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Symbols.groups_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Text('Listen Together', style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "Share what you're listening to in real time with friends on other devices.",
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Symbols.add_rounded),
              label: const Text('Start a Jam'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _join,
              icon: const Icon(Symbols.group_add_rounded),
              label: const Text('Join a Jam'),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoinCodeDialog extends StatefulWidget {
  const _JoinCodeDialog();

  @override
  State<_JoinCodeDialog> createState() => _JoinCodeDialogState();
}

class _JoinCodeDialogState extends State<_JoinCodeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _controller.text.trim().toUpperCase();
    if (code.length != 5) return;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join a Jam'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        maxLength: 5,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]'))],
        decoration: const InputDecoration(labelText: 'Session code', hintText: 'Enter 5-character code'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Join')),
      ],
    );
  }
}

class _SessionSheet extends StatelessWidget {
  final MusicJamProvider jam;
  const _SessionSheet({required this.jam});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = jam.session;
    if (session == null) return const SizedBox.shrink();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(jam.isHost ? Symbols.star_rounded : Symbols.groups_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(jam.isHost ? 'Hosting a Jam' : 'In a Jam', style: theme.textTheme.titleLarge)),
              ],
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: () => _copyCode(context, session.sessionId),
              borderRadius: const BorderRadius.all(Radius.circular(4)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Code: ${session.sessionId}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Symbols.content_copy_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Divider(),
            Text('Participants (${jam.participantCount})', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ...jam.participants.map(
              (participant) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: participant.isHost
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    participant.isHost ? Symbols.star_rounded : Symbols.person_rounded,
                    color: participant.isHost ? Colors.white : theme.colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                ),
                title: Text(participant.displayName),
                trailing: jam.canTransferHostTo(participant)
                    ? TextButton(onPressed: () => _confirmTransfer(context, jam, participant), child: const Text('Make host'))
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error),
              ),
              onPressed: () => _confirmLeave(context, jam),
              icon: Icon(jam.isHost ? Symbols.close_rounded : Symbols.logout_rounded),
              label: Text(jam.isHost ? 'End Jam' : 'Leave Jam'),
            ),
          ],
        ),
      ),
    );
  }

  void _copyCode(BuildContext context, String code) {
    Clipboard.setData(ClipboardData(text: code));
    showSnackBar(context, 'Session code copied');
  }

  Future<void> _confirmTransfer(BuildContext context, MusicJamProvider jam, Participant participant) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Make host?'),
        content: Text('${participant.displayName} will control playback for everyone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Make host')),
        ],
      ),
    );
    if (confirmed == true) jam.transferHost(participant);
  }

  Future<void> _confirmLeave(BuildContext context, MusicJamProvider jam) async {
    final isHost = jam.isHost;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isHost ? 'End Jam?' : 'Leave Jam?'),
        content: Text(isHost ? 'This will end the jam for everyone.' : 'You will stop listening together.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(isHost ? 'End' : 'Leave')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (context.mounted) Navigator.of(context).pop();
    unawaited(
      jam.leaveSession().catchError((Object e, StackTrace stackTrace) {
        appLogger.e('MusicJam: Leave from sheet failed', error: e, stackTrace: stackTrace);
      }),
    );
  }
}
