import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcCall {
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _rendererReady = false;

  Function(RTCIceCandidate candidate)? onIceCandidate;
  Function()? onConnected;
  Function()? onDisconnected;

  bool get active => _peer != null;

  Future<void> start() async {
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

    _peer = await createPeerConnection({
      'iceServers': [
        {
          'urls': 'stun:stun.l.google.com:19302',
        },
        {
          'urls': 'stun:stun1.l.google.com:19302',
        },
        {
          'urls': 'stun:stun2.l.google.com:19302',
        },
      ],
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
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onConnected?.call();
      }

      if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        onDisconnected?.call();
      }

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onDisconnected?.call();
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
    for (final track in _localStream?.getTracks() ?? []) {
      await track.stop();
    }

    await _localStream?.dispose();
    await _peer?.close();

    remoteRenderer.srcObject = null;

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
