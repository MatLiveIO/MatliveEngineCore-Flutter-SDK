// ignore_for_file: overridden_fields

import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:livekit_client/livekit_client.dart';
import 'package:matlive_core_engine/replay_kit_channel.dart';
import 'package:matlive_core_engine/requests/join_request.dart';
import 'package:permission_handler/permission_handler.dart';

enum ParticipantTrackType {
  kUserMedia,
  kScreenShare,
}

class ParticipantTrack {
  ParticipantTrack({
    required this.participant,
    this.type = ParticipantTrackType.kUserMedia,
  });

  Participant participant;
  final ParticipantTrackType type;
}

class MatLiveEngine {
  static final MatLiveEngine instance = MatLiveEngine._internal();

  MatLiveEngine._internal();

  String? get metadata => room?.metadata;
  bool _flagStartedReplayKit = false;
  Room? room;
  LocalAudioTrack? audioTrack;
  EventsListener<RoomEvent>? listener;
  List<ParticipantTrack> participantTracks = [];

  EventsListener<RoomEvent>? get _listener => listener;

  bool get fastConnection => room?.engine.fastConnectOptions != null;

  Future<void> init() async {
    if (lkPlatformIs(PlatformType.android)) {
      await _checkPermissions();
    }
    if (lkPlatformIsMobile()) {
      await LiveKitClient.initialize(bypassVoiceProcessing: true);
    }
    _initLocalAudioTrack();
  }

  Future<void> _checkPermissions() async {
    await Future.wait([
      Permission.bluetooth.request(),
      Permission.bluetoothConnect.request(),
      Permission.microphone.request(),
    ]);
  }

  Future<void> _initLocalAudioTrack() async {
    audioTrack = await LocalAudioTrack.create(const AudioCaptureOptions(
      noiseSuppression: true,
      echoCancellation: true,
    ));
  }

  Future<void> connect({
    required JoinRequest request,
    required Function onDisconnect,
    required Function(bool activeRecording) onRoomRecordingStatusChanged,
    required Function(Map<String, dynamic>? data) onDataReceivedEvent,
    required Function(bool isPlaying) onAudioPlaybackStatusChanged,
    required Function(String? metadata) onMetadataChanged,
  }) async {
    try {
      E2EEOptions? e2eeOptions;
      if (request.e2ee && request.e2eeKey != null) {
        final keyProvider = await BaseKeyProvider.create();
        e2eeOptions = E2EEOptions(keyProvider: keyProvider);
        await keyProvider.setKey(request.e2eeKey!);
      }
      room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: request.adaptiveStream,
          dynacast: request.dynacast,
          defaultAudioPublishOptions: const AudioPublishOptions(
            name: 'custom_audio_track_name',
            audioBitrate: 32000,
          ),
          e2eeOptions: e2eeOptions,
        ),
      );
      await room?.prepareConnection(request.url, request.token);
      await room?.connect(
        request.url,
        request.token,
        fastConnectOptions: FastConnectOptions(
          microphone: TrackOption(track: audioTrack),
        ),
      );
      listener = room?.createListener();
      publishStream(false);
      room?.addListener(_onRoomDidUpdate);
      _setUpListeners(
        onDisconnect: onDisconnect,
        onRoomRecordingStatusChanged: onRoomRecordingStatusChanged,
        onDataReceivedEvent: onDataReceivedEvent,
        onAudioPlaybackStatusChanged: onAudioPlaybackStatusChanged,
        onMetadataChanged: onMetadataChanged,
      );
      _sortParticipants();
      if (lkPlatformIs(PlatformType.android)) {
        Hardware.instance.setSpeakerphoneOn(true);
      }
      if (lkPlatformIs(PlatformType.iOS) && room != null) {
        ReplayKitChannel.listenMethodChannel(room!);
      }
    } catch (error) {
      log('Could not connect $error');
    }
  }

  void _setUpListeners({
    required Function onDisconnect,
    required Function(bool activeRecording) onRoomRecordingStatusChanged,
    required Function(Map<String, dynamic>? data) onDataReceivedEvent,
    required Function(bool isPlaying) onAudioPlaybackStatusChanged,
    required Function(String? metadata) onMetadataChanged,
  }) {
    if (_listener != null) {
      _listener!
        ..on<ParticipantEvent>((event) => _sortParticipants())
        ..on<LocalTrackPublishedEvent>((_) => _sortParticipants())
        ..on<LocalTrackUnpublishedEvent>((_) => _sortParticipants())
        ..on<TrackSubscribedEvent>((_) => _sortParticipants())
        ..on<TrackUnsubscribedEvent>((_) => _sortParticipants())
        ..on<TrackE2EEStateEvent>(_onE2EEStateEvent)
        ..on<RoomAttemptReconnectEvent>((event) {
          log('RoomAttemptReconnectEvent ${event.nextRetryDelaysInMs}ms');
        })
        ..on<LocalTrackSubscribedEvent>((event) {
          log('LocalTrackSubscribedEvent: ${event.trackSid}');
        })
        ..on<ParticipantNameUpdatedEvent>((event) {
          log('ParticipantNameUpdatedEvent');
          _sortParticipants();
        })
        ..on<ParticipantMetadataUpdatedEvent>((event) {
          log('ParticipantMetadataUpdatedEvent');
        })
        ..on<RoomMetadataChangedEvent>((event) {
          onMetadataChanged(event.metadata);
        })
        ..on<AudioPlaybackStatusChanged>((event) async {
          if (!room!.canPlaybackAudio) {
            log('AudioPlaybackStatusChanged Audio playback failed');
            await room!.startAudio();
          }
          onAudioPlaybackStatusChanged(event.isPlaying);
        })
        ..on<RoomDisconnectedEvent>((event) async {
          if (event.reason != null) {
            log('RoomDisconnectedEvent ${event.reason}');
          }
          onDisconnect();
        })
        ..on<RoomRecordingStatusChanged>((event) {
          onRoomRecordingStatusChanged(event.activeRecording);
        })
        ..on<DataReceivedEvent>((event) {
          onDataReceivedEvent(jsonDecode(utf8.decode(event.data)));
        });
    }
  }

  Future<void> mute(bool value) async {
    if (value) {
      await room?.localParticipant?.setMicrophoneEnabled(true);
    } else {
      await room?.localParticipant?.setMicrophoneEnabled(false);
    }
  }

  Future<void> publishData(
    List<int> data, {
    bool? reliable,
    List<String>? destinationIdentities,
    String? topic,
  }) async {
    await room?.localParticipant?.publishData(
      data,
      destinationIdentities: destinationIdentities,
      reliable: reliable,
      topic: topic,
    );
  }

  Future<void> publishStream(bool value) async {
    try {
      if (value) {
        audioTrack?.start();
      } else {
        audioTrack?.stop();
      }
    } catch (error) {
      log('could not publish audio: $error');
    }
    await room?.localParticipant?.setMicrophoneEnabled(value);
    await room?.localParticipant?.setCameraEnabled(false);
  }

  void _onRoomDidUpdate() {
    _sortParticipants();
  }

  void _onE2EEStateEvent(TrackE2EEStateEvent e2eeState) {
    log('e2ee state: $e2eeState');
  }

  void _sortParticipants() {
    List<ParticipantTrack> userMediaTracks = [];
    if (room != null) {
      for (var participant in room!.remoteParticipants.values) {
        for (var t in participant.videoTrackPublications) {
          if (!t.isScreenShare) {
            userMediaTracks.add(ParticipantTrack(participant: participant));
          }
        }
      }
      // sort speakers for the grid
      userMediaTracks.sort((a, b) {
        // loudest speaker first
        if (a.participant.isSpeaking && b.participant.isSpeaking) {
          if (a.participant.audioLevel > b.participant.audioLevel) {
            return -1;
          } else {
            return 1;
          }
        }

        // last spoken at
        final aSpokeAt = a.participant.lastSpokeAt?.millisecondsSinceEpoch ?? 0;
        final bSpokeAt = b.participant.lastSpokeAt?.millisecondsSinceEpoch ?? 0;

        if (aSpokeAt != bSpokeAt) {
          return aSpokeAt > bSpokeAt ? -1 : 1;
        }

        // video on
        if (a.participant.hasVideo != b.participant.hasVideo) {
          return a.participant.hasVideo ? -1 : 1;
        }

        // joinedAt
        return a.participant.joinedAt.millisecondsSinceEpoch -
            b.participant.joinedAt.millisecondsSinceEpoch;
      });

      final localParticipantTracks =
          room!.localParticipant?.videoTrackPublications;
      if (localParticipantTracks != null) {
        for (var t in localParticipantTracks) {
          if (t.isScreenShare) {
            if (lkPlatformIs(PlatformType.iOS)) {
              if (!_flagStartedReplayKit) {
                _flagStartedReplayKit = true;

                ReplayKitChannel.startReplayKit();
              }
            }
          } else {
            if (lkPlatformIs(PlatformType.iOS)) {
              if (_flagStartedReplayKit) {
                _flagStartedReplayKit = false;

                ReplayKitChannel.closeReplayKit();
              }
            }
            userMediaTracks
                .add(ParticipantTrack(participant: room!.localParticipant!));
          }
        }
      }
      participantTracks = userMediaTracks;
    }
  }

  Future<void> close() async {
    if (lkPlatformIs(PlatformType.iOS)) {
      ReplayKitChannel.closeReplayKit();
    }
    audioTrack = null;
    await room?.dispose();
    await audioTrack?.stop();
    await _listener?.dispose();
    room?.removeListener(_onRoomDidUpdate);
    await publishStream(false);
  }
}
