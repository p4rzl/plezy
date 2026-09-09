import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../media/ids.dart';
import '../media/media_item.dart';
import '../providers/multi_server_provider.dart';
import '../services/base_peer_service.dart';
import '../services/music/music_playback_service.dart';
import '../utils/app_logger.dart';
import '../watch_together/models/playback_state.dart';
import '../watch_together/models/sync_message.dart';
import '../watch_together/models/watch_session.dart';
import '../watch_together/providers/watch_together_provider.dart' show ParticipantEvent, ParticipantEventType;
import '../watch_together/services/watch_together_peer_service.dart';
import '../watch_together/services/watch_together_relay_endpoint.dart';

typedef MusicJamPeerServiceFactory = WatchTogetherPeerService Function({WatchTogetherRelayEndpoint? endpoint});

WatchTogetherPeerService _createPeerService({WatchTogetherRelayEndpoint? endpoint}) =>
    WatchTogetherPeerService(endpoint: endpoint);

/// "Listen Together" — a Spotify-Jam-style shared listening session: the
/// host's current track and play/pause state are mirrored onto every
/// participant's device, over the same relay used by Watch Together.
///
/// Reuses that feature's transport and wire models — [WatchTogetherPeerService],
/// [WatchSession]/[Participant] and [PlaybackState] are already media-neutral,
/// keyed by a plain ratingKey/serverId — but not its frame-accurate clock-sync
/// engine. Video needs peers to stay within a fraction of a second of each
/// other for lip-sync; audio drift of a second or two between phones is
/// inaudible, and chasing it with the same aggressive micro-seeks used for
/// video would only add audible glitches. This controller instead keeps
/// everyone on the same track and transport state, with coarse (multi-second)
/// position correction — closer to how a real shared-listening session
/// actually needs to behave.
///
/// Host-controlled only: there is no "anyone controls" mode. A guest who
/// wants to drive playback uses [transferHost] to take over, the same way
/// Watch Together hands off hosting.
class MusicJamProvider with ChangeNotifier {
  MusicJamProvider({
    required MusicPlaybackService musicService,
    required MultiServerProvider multiServer,
    MusicJamPeerServiceFactory peerServiceFactory = _createPeerService,
  }) : _musicService = musicService,
       _multiServer = multiServer,
       _peerServiceFactory = peerServiceFactory {
    _musicService.addListener(_onLocalMusicChanged);
  }

  static const _heartbeatInterval = Duration(seconds: 5);
  static const _driftCorrectionThreshold = Duration(seconds: 4);

  final MusicPlaybackService _musicService;
  final MultiServerProvider _multiServer;
  final MusicJamPeerServiceFactory _peerServiceFactory;

  WatchSession? _session;
  WatchTogetherPeerService? _peerService;
  final List<Participant> _participants = [];
  String _displayName = 'Listener';
  bool _disposed = false;
  int _sessionOperation = 0;
  int _outgoingSeq = 0;
  int _lastAppliedSeq = -1;
  int _switchToken = 0;
  Timer? _heartbeatTimer;

  StreamSubscription<String>? _peerConnectedSub;
  StreamSubscription<String>? _peerDisconnectedSub;
  StreamSubscription<SyncMessage>? _messageSub;
  StreamSubscription<PeerError>? _errorSub;
  StreamSubscription<void>? _sessionEndedSub;
  StreamSubscription<String>? _hostChangedSub;

  final _participantEventController = StreamController<ParticipantEvent>.broadcast();
  Stream<ParticipantEvent> get participantEvents => _participantEventController.stream;

  bool get isInSession => _session != null;
  bool get isHost => _session?.isHost ?? false;
  bool get isConnected => _session?.isConnected ?? false;
  WatchSession? get session => _session;
  List<Participant> get participants => List.unmodifiable(_participants);
  int get participantCount => _participants.length;
  String? get sessionId => _session?.sessionId;
  String? get currentMediaTitle => _session?.mediaTitle;

  /// Only the host drives playback for the room; a guest wanting control
  /// takes over via [transferHost].
  bool canControl() => isHost;

  bool canTransferHostTo(Participant participant) {
    final peerService = _peerService;
    if (peerService == null || !isHost || !isConnected) return false;
    if (participant.isHost || participant.peerId == peerService.myPeerId) return false;
    if (!peerService.connectedPeers.contains(participant.peerId)) return false;
    return peerService.canTransferHostTo(participant.peerId);
  }

  void transferHost(Participant participant) {
    if (!canTransferHostTo(participant)) return;
    appLogger.d('MusicJam: Requesting host transfer to ${participant.peerId}');
    _peerService!.transferHost(participant.peerId);
  }

  /// Create a new jam as host, seeded from whatever is currently playing
  /// locally.
  Future<String> createSession({String? displayName, WatchTogetherRelayEndpoint? relayEndpoint}) async {
    final cleanup = leaveSession();
    final operation = _sessionOperation;
    await cleanup;
    if (_disposed || operation != _sessionOperation) throw StateError('Music Jam create became stale');

    final peerService = _peerServiceFactory(endpoint: relayEndpoint);
    _peerService = peerService;
    _listenToPeerService(peerService);

    try {
      final createdSessionId = await peerService.createSession();
      if (!identical(_peerService, peerService) || _disposed) {
        throw StateError('Music Jam create became stale');
      }

      _session = WatchSession.createAsHost(
        sessionId: createdSessionId,
        hostPeerId: peerService.hostPeerId!,
        controlMode: ControlMode.hostOnly,
      ).copyWith(state: SessionState.connected, role: peerService.isHost ? SessionRole.host : SessionRole.guest);

      _displayName = displayName ?? _generateDisplayName();
      _participants.add(
        Participant(peerId: peerService.myPeerId!, displayName: _displayName, isHost: peerService.isHost),
      );
      _startHeartbeat();
      _broadcastState();
      notifyListeners();
      appLogger.d('MusicJam: Session created: $createdSessionId');
      return createdSessionId;
    } catch (e) {
      appLogger.e('MusicJam: Failed to create session', error: e);
      if (identical(_peerService, peerService)) await leaveSession();
      rethrow;
    }
  }

  /// Join an existing jam by its room code.
  Future<void> joinSession(String sessionId, {String? displayName, WatchTogetherRelayEndpoint? relayEndpoint}) async {
    final cleanup = leaveSession();
    final operation = _sessionOperation;
    await cleanup;
    if (_disposed || operation != _sessionOperation) throw StateError('Music Jam join became stale');

    final peerService = _peerServiceFactory(endpoint: relayEndpoint);
    _peerService = peerService;
    _listenToPeerService(peerService);

    _session = WatchSession.joinAsGuest(sessionId: sessionId);
    notifyListeners();

    try {
      await peerService.joinSession(sessionId);
      if (!identical(_peerService, peerService)) throw StateError('Music Jam join became stale');

      _session = _session!.copyWith(
        state: SessionState.connected,
        hostPeerId: peerService.hostPeerId,
        role: peerService.isHost ? SessionRole.host : SessionRole.guest,
      );
      _displayName = displayName ?? _generateDisplayName();
      _participants.add(
        Participant(peerId: peerService.myPeerId!, displayName: _displayName, isHost: peerService.isHost),
      );
      _sendJoin();
      peerService.broadcast(SyncMessage.requestState(peerId: peerService.myPeerId));
      notifyListeners();
      appLogger.d('MusicJam: Joined session successfully');
    } catch (e) {
      appLogger.e('MusicJam: Failed to join session', error: e);
      if (identical(_peerService, peerService)) await leaveSession();
      rethrow;
    }
  }

  /// Leave the current jam. A host leaving ends it for everyone (nobody
  /// promotes automatically — hand off with [transferHost] beforehand to
  /// keep the room alive).
  Future<void> leaveSession() async {
    _sessionOperation++;
    if (_session == null && _peerService == null) return;
    appLogger.d('MusicJam: Leaving session');
    final peerService = _peerService;
    final myPeerId = peerService?.myPeerId;
    if (peerService != null && myPeerId != null) {
      peerService.broadcast(SyncMessage.leave(peerId: myPeerId));
    }
    final detached = _detachLocalSession();
    if (detached != null) {
      try {
        await detached.releaseSession();
      } catch (e, stackTrace) {
        appLogger.e('MusicJam: Failed to release relay ownership', error: e, stackTrace: stackTrace);
      }
      try {
        await detached.disconnect();
      } catch (e, stackTrace) {
        appLogger.e('MusicJam: Failed to disconnect relay transport', error: e, stackTrace: stackTrace);
      } finally {
        detached.dispose();
      }
    }
    appLogger.d('MusicJam: Session left');
  }

  void _listenToPeerService(WatchTogetherPeerService peerService) {
    peerService.onReconnected = () {
      if (_disposed || !identical(_peerService, peerService)) return;
      _sendJoin();
      if (!isHost) peerService.broadcast(SyncMessage.requestState(peerId: peerService.myPeerId));
    };

    _peerConnectedSub = peerService.onPeerConnected.listen((peerId) {
      if (_disposed || !identical(_peerService, peerService)) return;
      notifyListeners();
    });

    _peerDisconnectedSub = peerService.onPeerDisconnected.listen((peerId) {
      if (_disposed || !identical(_peerService, peerService)) return;
      final leavingName = _displayNameForPeer(peerId);
      _participants.removeWhere((p) => p.peerId == peerId);
      final wasHost = peerId == _session?.hostPeerId;
      if (leavingName != null && !wasHost) {
        _participantEventController.add(ParticipantEvent(displayName: leavingName, type: ParticipantEventType.left));
      }
      if (!isHost && wasHost) {
        _endSessionLocally(reason: 'host disconnected');
        return;
      }
      notifyListeners();
    });

    _messageSub = peerService.onMessageReceived.listen((message) {
      if (_disposed || !identical(_peerService, peerService)) return;
      _handleMessage(message, peerService);
    });

    _errorSub = peerService.onError.listen((error) {
      if (_disposed || !identical(_peerService, peerService)) return;
      appLogger.w('MusicJam: Peer error: ${error.message}');
    });

    _sessionEndedSub = peerService.onSessionEnded.listen((_) {
      if (_disposed || !identical(_peerService, peerService)) return;
      _endSessionLocally(reason: 'session ended by relay');
    });

    _hostChangedSub = peerService.onHostChanged.listen((newHostPeerId) {
      if (_disposed || !identical(_peerService, peerService)) return;
      _handleHostChanged(newHostPeerId);
    });
  }

  void _handleMessage(SyncMessage message, WatchTogetherPeerService peerService) {
    switch (message.type) {
      case SyncMessageType.join:
        _handleJoinMessage(message, peerService);
        break;
      case SyncMessageType.leave:
        if (message.peerId != null) {
          final leavingName = _displayNameForPeer(message.peerId);
          final wasHost = message.peerId == _session?.hostPeerId;
          _participants.removeWhere((p) => p.peerId == message.peerId);
          if (!isHost && wasHost) {
            _endSessionLocally(reason: 'host left');
            break;
          }
          if (leavingName != null) {
            _participantEventController.add(ParticipantEvent(displayName: leavingName, type: ParticipantEventType.left));
          }
          notifyListeners();
        }
        break;
      case SyncMessageType.requestState:
        if (isHost) _sendStateTo(message.peerId);
        break;
      case SyncMessageType.state:
        if (!isHost && message.state != null) {
          unawaited(
            _applyRemoteState(message.state!).catchError((Object e, StackTrace stackTrace) {
              appLogger.w('MusicJam: Failed to apply remote state', error: e, stackTrace: stackTrace);
            }),
          );
        }
        break;
      default:
        break;
    }
  }

  void _handleJoinMessage(SyncMessage message, WatchTogetherPeerService peerService) {
    final peerId = message.peerId;
    final displayName = message.displayName;
    if (peerId == null || displayName == null) return;

    final existingIndex = _participants.indexWhere((p) => p.peerId == peerId);
    final isNewPeer = existingIndex < 0;
    if (isNewPeer) {
      _participants.add(Participant(peerId: peerId, displayName: displayName, isHost: message.isHost ?? false));
      _participantEventController.add(ParticipantEvent(displayName: displayName, type: ParticipantEventType.joined));
    } else {
      _participants[existingIndex] = Participant(
        peerId: peerId,
        displayName: displayName,
        isHost: message.isHost ?? false,
      );
    }

    // Reply only to new peers — otherwise every join would ping-pong forever.
    if (isNewPeer && peerService.myPeerId != null) {
      peerService.sendTo(peerId, SyncMessage.join(peerId: peerService.myPeerId!, displayName: _displayName, isHost: isHost));
      if (isHost) _sendStateTo(peerId);
    }
    notifyListeners();
  }

  void _handleHostChanged(String newHostPeerId) {
    final session = _session;
    final peerService = _peerService;
    if (session == null || peerService == null) return;

    final wasHost = session.isHost;
    final amHost = newHostPeerId == peerService.myPeerId;
    _session = session.copyWith(role: amHost ? SessionRole.host : SessionRole.guest, hostPeerId: newHostPeerId);

    for (var i = 0; i < _participants.length; i++) {
      final isHostNow = _participants[i].peerId == newHostPeerId;
      if (_participants[i].isHost != isHostNow) {
        _participants[i] = _participants[i].copyWith(isHost: isHostNow);
      }
    }

    if (amHost && !wasHost) {
      _startHeartbeat();
      _sendJoin();
      _broadcastState();
      _participantEventController.add(
        ParticipantEvent(displayName: _displayName, type: ParticipantEventType.becameHost),
      );
    } else if (!amHost) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _participantEventController.add(
        ParticipantEvent(displayName: _displayNameForPeer(newHostPeerId) ?? '?', type: ParticipantEventType.hostChanged),
      );
    }

    appLogger.d('MusicJam: Host changed to $newHostPeerId (self: $amHost)');
    notifyListeners();
  }

  void _sendJoin() {
    final peerService = _peerService;
    if (peerService?.myPeerId == null) return;
    peerService!.broadcast(SyncMessage.join(peerId: peerService.myPeerId!, displayName: _displayName, isHost: isHost));
  }

  void _onLocalMusicChanged() {
    if (_disposed || !isHost) return;
    _broadcastState();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_disposed || !isHost) return;
      _broadcastState();
    });
  }

  PlaybackState? _buildState() {
    final peerService = _peerService;
    final track = _musicService.currentTrack;
    final serverId = track?.serverId;
    if (peerService == null || track == null || serverId == null) return null;
    _outgoingSeq++;
    return PlaybackState(
      seq: _outgoingSeq,
      ratingKey: track.id,
      serverId: serverId,
      mediaTitle: track.displayTitle,
      phase: _musicService.isPlaying ? PlaybackPhase.playing : PlaybackPhase.paused,
      anchorPositionMs: _musicService.position.inMilliseconds,
      anchorHostTimeMs: DateTime.now().millisecondsSinceEpoch,
      rate: 1.0,
      controlMode: ControlMode.hostOnly,
      actorPeerId: peerService.myPeerId,
    );
  }

  void _broadcastState() {
    final peerService = _peerService;
    final state = _buildState();
    if (peerService == null || state == null) return;
    peerService.broadcast(SyncMessage.state(state, peerId: peerService.myPeerId));

    final session = _session;
    if (session != null &&
        (session.mediaRatingKey != state.ratingKey ||
            session.mediaServerId != state.serverId ||
            session.mediaTitle != state.mediaTitle)) {
      _session = session.copyWith(
        mediaRatingKey: state.ratingKey,
        mediaServerId: state.serverId,
        mediaTitle: state.mediaTitle,
      );
      notifyListeners();
    }
  }

  void _sendStateTo(String? peerId) {
    if (peerId == null) return;
    final peerService = _peerService;
    // Reuse the outgoing sequence rather than minting a new one: a targeted
    // resend must never look newer than what the room already agreed on.
    final track = _musicService.currentTrack;
    final serverId = track?.serverId;
    if (peerService == null || track == null || serverId == null) return;
    final state = PlaybackState(
      seq: _outgoingSeq,
      ratingKey: track.id,
      serverId: serverId,
      mediaTitle: track.displayTitle,
      phase: _musicService.isPlaying ? PlaybackPhase.playing : PlaybackPhase.paused,
      anchorPositionMs: _musicService.position.inMilliseconds,
      anchorHostTimeMs: DateTime.now().millisecondsSinceEpoch,
      rate: 1.0,
      controlMode: ControlMode.hostOnly,
      actorPeerId: peerService.myPeerId,
    );
    peerService.sendTo(peerId, SyncMessage.state(state, peerId: peerService.myPeerId));
  }

  /// Apply the host's broadcast state (guest only): switch track when it
  /// differs, otherwise just match play/pause and nudge position back in
  /// line once drift crosses [_driftCorrectionThreshold].
  ///
  /// Positions are compared without any clock-offset correction — unlike
  /// Watch Together's ping/pong clock sync, a jam has no need for
  /// millisecond accuracy, and treating [PlaybackState.anchorPositionMs] as
  /// the target directly (rather than extrapolating from
  /// [PlaybackState.anchorHostTimeMs]) avoids depending on host and guest
  /// wall clocks agreeing.
  Future<void> _applyRemoteState(PlaybackState state) async {
    if (_lastAppliedSeq != -1 && state.seq <= _lastAppliedSeq) return;
    _lastAppliedSeq = state.seq;

    final session = _session;
    if (session != null &&
        (session.mediaRatingKey != state.ratingKey ||
            session.mediaServerId != state.serverId ||
            session.mediaTitle != state.mediaTitle)) {
      _session = session.copyWith(
        mediaRatingKey: state.ratingKey,
        mediaServerId: state.serverId,
        mediaTitle: state.mediaTitle,
      );
      notifyListeners();
    }

    final targetPositionMs = state.anchorPositionMs;
    final currentTrack = _musicService.currentTrack;
    final onTrack = currentTrack != null && currentTrack.id == state.ratingKey && currentTrack.serverId == state.serverId;

    if (!onTrack) {
      final token = ++_switchToken;
      final serverId = serverIdOrNull(state.serverId);
      if (serverId == null) return;
      final client = _multiServer.getClientForServer(serverId);
      if (client == null) {
        appLogger.w('MusicJam: Server ${state.serverId} unavailable for track switch');
        return;
      }
      MediaItem? track;
      try {
        track = await client.fetchItem(state.ratingKey);
      } catch (e, stackTrace) {
        appLogger.w('MusicJam: Could not fetch track ${state.ratingKey}', error: e, stackTrace: stackTrace);
        return;
      }
      if (_disposed || token != _switchToken || track == null) return;
      await _musicService.playFromList(
        tracks: [track],
        playContext: MusicPlayContext(title: state.mediaTitle ?? track.displayTitle, kind: MusicPlayContextKind.tracks),
        initialPosition: Duration(milliseconds: targetPositionMs),
      );
      if (_disposed || token != _switchToken) return;
      if (state.phase == PlaybackPhase.paused) await _musicService.pause();
      return;
    }

    if (state.phase == PlaybackPhase.playing && !_musicService.isPlaying) {
      await _musicService.play();
    } else if (state.phase == PlaybackPhase.paused && _musicService.isPlaying) {
      await _musicService.pause();
    }

    final drift = (_musicService.position.inMilliseconds - targetPositionMs).abs();
    if (drift > _driftCorrectionThreshold.inMilliseconds) {
      await _musicService.seek(Duration(milliseconds: targetPositionMs));
    }
  }

  void _endSessionLocally({required String reason}) {
    appLogger.d('MusicJam: Ending local session ($reason)');
    final peerService = _detachLocalSession();
    if (peerService != null) {
      unawaited(
        peerService
            .disconnect()
            .catchError((Object e, StackTrace stackTrace) {
              appLogger.e('MusicJam: Failed to disconnect after remote end', error: e, stackTrace: stackTrace);
            })
            .whenComplete(peerService.dispose),
      );
    }
  }

  WatchTogetherPeerService? _detachLocalSession() {
    _sessionOperation++;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    final peerService = _peerService;
    if (peerService != null) peerService.onReconnected = null;

    unawaited(_peerConnectedSub?.cancel());
    unawaited(_peerDisconnectedSub?.cancel());
    unawaited(_messageSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_sessionEndedSub?.cancel());
    unawaited(_hostChangedSub?.cancel());
    _peerConnectedSub = null;
    _peerDisconnectedSub = null;
    _messageSub = null;
    _errorSub = null;
    _sessionEndedSub = null;
    _hostChangedSub = null;

    _peerService = null;
    _session = null;
    _participants.clear();
    _lastAppliedSeq = -1;

    if (!_disposed) notifyListeners();
    return peerService;
  }

  String? _displayNameForPeer(String? peerId) {
    if (peerId == null) return null;
    for (final participant in _participants) {
      if (participant.peerId == peerId) return participant.displayName;
    }
    return null;
  }

  static String _generateDisplayName() {
    const adjectives = ['Happy', 'Sunny', 'Chill', 'Cozy', 'Groovy', 'Jazzy', 'Mellow', 'Funky'];
    const nouns = ['Panda', 'Fox', 'Otter', 'Owl', 'Wolf', 'Finch', 'Koala', 'Robin'];
    final random = Random();
    return '${adjectives[random.nextInt(adjectives.length)]} ${nouns[random.nextInt(nouns.length)]}';
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _musicService.removeListener(_onLocalMusicChanged);
    final peerService = _detachLocalSession();
    unawaited(_participantEventController.close());
    super.dispose();
    if (peerService != null) {
      unawaited(
        peerService.releaseSession().catchError((Object e, StackTrace stackTrace) {
          appLogger.e('MusicJam: Failed to release session during dispose', error: e, stackTrace: stackTrace);
        }).whenComplete(() async {
          try {
            await peerService.disconnect();
          } finally {
            peerService.dispose();
          }
        }),
      );
    }
  }
}
