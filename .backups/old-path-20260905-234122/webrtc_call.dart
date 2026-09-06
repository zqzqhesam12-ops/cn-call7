import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'server_config.dart';
import 'call_session.dart';

class WebRtcCall {
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _rendererReady = false;

  Function(RTCIceCandidate candidate)? onIceCandidate;
  Function()? onConnected;
  Function()? onDisconnected;
  bool _disconnectSent = false;

  bool get active => _peer != null;

  Future<void> start() async {
    await Helper.setAndroidAudioConfiguration(
      AndroidAudioConfiguration.communication,
    );
    await Helper.setSpeakerphoneOn(false);

    if (!_rendererReady) {
      await remoteRenderer.initialize();
      _rendererReady = true;
    }

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'channelCount': 1,
      },
      'video': false,
    });

    final iceServers = <Map<String, dynamic>>[
      {
        'urls': 'stun:stun.l.google.com:19302',
      },
      {
        'urls': 'stun:stun1.l.google.com:19302',
      },
      {
        'urls': 'stun:stun2.l.google.com:19302',
      },
    ];

    try {
      final response = await http.get(
        Uri.parse('${ServerConfig.httpUrl}/turn-credentials'),
        headers: {
          'Authorization': 'Bearer ${CallSession.instance.accessToken}',
        },
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);

        if (body is Map<String, dynamic> &&
            body['success'] == true &&
            body['iceServers'] is List) {
          for (final server in body['iceServers']) {
            if (server is Map) {
              iceServers.add(
                Map<String, dynamic>.from(server),
              );
            }
          }

          print('[CN CALL][WEBRTC] TURN servers loaded');
        }
      }
    } catch (e) {
      print('[CN CALL][WEBRTC] TURN unavailable: $e');
    }

    _peer = await createPeerConnection({
      'iceServers': iceServers,
    });

    for (final track in _localStream!.getTracks()) {
      await _peer!.addTrack(track, _localStream!);
    }

    _peer!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        onIceCandidate?.call(candidate);
      }
    };

    _peer!.onTrack = (event) {
      if (event.track.kind == 'audio') {
        event.track.enabled = true;

        if (event.streams.isNotEmpty) {
          remoteRenderer.srcObject = event.streams.first;
        }
      }
    };

    _peer!.onConnectionState = (state) {
      print('[CN CALL][WEBRTC] connectionState = $state');

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        print('[CN CALL][WEBRTC] CONNECTED');
        onConnected?.call();
      }

      if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        print('[CN CALL][WEBRTC] DISCONNECTED');
        if (!_disconnectSent) {
          _disconnectSent = true;
          onDisconnected?.call();
        }
      }

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        print('[CN CALL][WEBRTC] FAILED');
        if (!_disconnectSent) {
          _disconnectSent = true;
          onDisconnected?.call();
        }
      }
    };
  }

  Future<RTCSessionDescription> createOffer() async {
    final offer = await _peer!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });

    await _peer!.setLocalDescription(offer);

    return offer;
  }

  Future<RTCSessionDescription> createAnswer() async {
    final answer = await _peer!.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });

    await _peer!.setLocalDescription(answer);

    return answer;
  }

  Future<void> setRemoteDescription(
    String sdp,
    String type,
  ) async {
    await _peer!.setRemoteDescription(
      RTCSessionDescription(sdp, type),
    );
  }

  Future<void> addCandidate({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    await _peer!.addCandidate(
      RTCIceCandidate(
        candidate,
        sdpMid,
        sdpMLineIndex,
      ),
    );
  }

  Future<void> setSpeaker(bool enabled) async {
    await Helper.setSpeakerphoneOn(enabled);
  }

  Future<void> mute(bool value) async {
    for (final track in _localStream?.getAudioTracks() ?? []) {
      track.enabled = !value;
    }
  }

  Future<void> close() async {
    _disconnectSent = true;
    for (final track in _localStream?.getTracks() ?? []) {
      await track.stop();
    }

    await _localStream?.dispose();
    await _peer?.close();

    if (_rendererReady) {
      remoteRenderer.srcObject = null;
    }

    _localStream = null;
    _peer = null;
  }

  Future<void> dispose() async {
    await close();

    if (_rendererReady) {
      await remoteRenderer.dispose();
      _rendererReady = false;
    }
  }
}
