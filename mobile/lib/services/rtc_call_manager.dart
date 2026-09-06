// ignore_for_file: avoid_print

import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';

import 'package:uuid/uuid.dart';

import 'call_session.dart';
import 'call_coordinator.dart';
import 'livekit_call.dart';
import 'livekit_token_service.dart';

enum CallState {
  incoming,
  ringing,
  accepted,
  negotiating,
  rejected,
  cancelled,
  connecting,
  connected,
  ended,
  timeout,
  offline,
}

class RtcCallManager {
  RtcCallManager._();

  static final RtcCallManager instance = RtcCallManager._();

  final CallSession session = CallSession.instance;
  final LiveKitCall livekit = LiveKitCall();
  final AudioPlayer _ringPlayer = AudioPlayer();

  Timer? _ringTimeoutTimer;
  Timer? _negotiationTimeoutTimer;
  Timer? _connectionTimeoutTimer;

  StreamSubscription<Map<String, dynamic>>? _subscription;

  String? remoteUserId;
  String? currentCallId;
  bool? remoteOnline;
  CallState? state;
  bool inCall = false;
  bool caller = false;
  bool _muted = false;

  final List<Map<String, dynamic>> _pendingIceCandidates = [];

  Function()? onConnected;
  Function()? onDisconnected;
  Function(Map<String, dynamic> message)? onIncomingCall;
  Function(String callId)? onRemoteCallCancelled;
  Function(bool online)? onRemoteAvailabilityChanged;

  bool _started = false;
  bool _hangingUp = false;
  Future<void>? _cleanupFuture;
  bool _ringbackPlaying = false;
  bool _incomingRingtonePlaying = false;
  Completer<bool>? _callStartCompleter;
  int? _callStartExpiresAt;

  Future<void> _startRinging({
    required String callId,
    int? expiresAt,
  }) async {
    _ringTimeoutTimer?.cancel();

    Duration duration = const Duration(seconds: 90);

    if (expiresAt != null) {
      final remainingMs = expiresAt - DateTime.now().millisecondsSinceEpoch;

      if (remainingMs <= 0) {
        await _handleRingTimeout(callId);
        return;
      }

      final cappedMs = remainingMs > 90000 ? 90000 : remainingMs;
      duration = Duration(milliseconds: cappedMs);
    }

    _ringTimeoutTimer = Timer(
      duration,
      () => _handleRingTimeout(callId),
    );

    try {
      await _ringPlayer.setReleaseMode(ReleaseMode.loop);

      await _ringPlayer.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(
            usageType: AndroidUsageType.voiceCommunication,
            contentType: AndroidContentType.speech,
            audioFocus: AndroidAudioFocus.gainTransient,
          ),
        ),
      );

      await _ringPlayer.play(
        AssetSource('sounds/ringing.mp3'),
      );
      _ringbackPlaying = true;

      print(
        '[CN CALL][RINGBACK START] call_id=$callId route=earpiece default_ringtone',
      );
    } catch (e) {
      _ringbackPlaying = false;

      print(
        '[CN CALL][RINGBACK FAILED] call_id=$callId error=$e',
      );
    }
  }

  Future<void> _stopRinging() async {
    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = null;

    if (_ringbackPlaying || _incomingRingtonePlaying) {
      try {
        await const MethodChannel('cn_call/call').invokeMethod(
          'stopDefaultRingtone',
        );
      } catch (e) {
        print('[CN CALL][RINGBACK STOP FAILED] error=$e');
      }

      await _ringPlayer.stop();
      _ringbackPlaying = false;
      _incomingRingtonePlaying = false;
      print('[CN CALL][RINGBACK STOP]');
    }
  }

  void _cancelCallTimeouts() {
    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = null;
    _negotiationTimeoutTimer?.cancel();
    _negotiationTimeoutTimer = null;
    _connectionTimeoutTimer?.cancel();
    _connectionTimeoutTimer = null;
  }

  void _startNegotiationTimeout(String callId) {
    _negotiationTimeoutTimer?.cancel();
    _negotiationTimeoutTimer = Timer(
      const Duration(seconds: 30),
      () => _handleNegotiationTimeout(callId),
    );
  }

  void _startConnectionTimeout(String callId) {
    _connectionTimeoutTimer?.cancel();
    _connectionTimeoutTimer = Timer(
      const Duration(seconds: 30),
      () => _handleConnectionTimeout(callId),
    );
  }

  Future<void> _handleNegotiationTimeout(String callId) async {
    if (!_isCurrentCall(callId) ||
        state == CallState.connected ||
        state == CallState.ended) {
      return;
    }

    print('[CN CALL][TIMEOUT] negotiation call_id=$callId');
    await _cleanupCall(
      reason: 'timeout',
      sendSignal: true,
      signalType: 'hangup',
      forceDisconnect: true,
    );
  }

  Future<void> _handleConnectionTimeout(String callId) async {
    if (!_isCurrentCall(callId) ||
        state == CallState.connected ||
        state == CallState.ended) {
      return;
    }

    print('[CN CALL][TIMEOUT] connection call_id=$callId');
    await _cleanupCall(
      reason: 'timeout',
      sendSignal: true,
      signalType: 'hangup',
      forceDisconnect: true,
    );
  }

  Future<void> _handleRingTimeout(String callId) async {
    if (!_isCurrentCall(callId) || !caller || inCall) return;

    print('[CN CALL][RING] timeout reached');

    await _cleanupCall(
      reason: 'timeout',
      sendSignal: true,
      signalType: 'call_cancelled',
      forceDisconnect: true,
    );
  }

  void startListening() {
    if (_started) return;
    _started = true;

    _subscription = session.socket.messages.listen(_handleMessage);

    livekit.onConnected = () {
      final connectedCallId = currentCallId;
      final target = remoteUserId;

      if (_hangingUp || connectedCallId == null || connectedCallId.isEmpty) {
        return;
      }

      _cancelCallTimeouts();
      inCall = true;
      state = CallState.connected;

      print(
        '[CN CALL][LIVEKIT MANAGER] connected '
        'call_id=$connectedCallId',
      );

      if (connectedCallId.isNotEmpty &&
          target != null &&
          target.isNotEmpty &&
          session.loggedIn &&
          session.socket.connected) {
        unawaited(session.socket.sendGuaranteed({
          'type': 'connected',
          'call_id': connectedCallId,
          'target_id': target,
          'from_id': session.userId,
        }));
      }

      onConnected?.call();
    };

    livekit.onDisconnected = () {
      if (_hangingUp) return;

      print('[CN CALL][LIVEKIT CONNECT FAILED] call_id=$currentCallId disconnected');

      unawaited(
        _cleanupCall(reason: 'failed', sendSignal: true, signalType: 'hangup'),
      );
    };
  }

  Future<void> _handleMessage(Map<String, dynamic> message) async {
    final type = message['type']?.toString();
    final messageCallId = message['call_id']?.toString().trim();

    if (type == 'call') {
      if (messageCallId == null ||
          messageCallId.isEmpty ||
          await session.isCallEnded(messageCallId) ||
          currentCallId != null) {
        return;
      }
      if (CallCoordinator.instance.beginIncoming(messageCallId) !=
          CallCommandResult.accepted) {
        return;
      }
      currentCallId = messageCallId;
      await session.markCallActive(messageCallId);
      state = CallState.incoming;
      remoteUserId = message['from_id']?.toString();

      print('[CN CALL][CALL RECEIVE] call_id=$messageCallId from=$remoteUserId');

      onIncomingCall?.call(message);
      return;
    }

    if (type == 'call_started') {
      if (!_isCurrentCall(messageCallId)) return;

      remoteOnline = message['target_online'] == true;
      onRemoteAvailabilityChanged?.call(remoteOnline!);

      // Offline does NOT mean the call failed.
      // The server has already created the call and sent FCM.
      // Keep the caller ringing until the server-provided 90s expiry.
      state = CallState.ringing;
      print('[CN CALL][CALL UI RINGING] call_id=$messageCallId');

      final expiresAtRaw = message['ring_expires_at'];
      _callStartExpiresAt = expiresAtRaw is int
          ? expiresAtRaw
          : int.tryParse(expiresAtRaw?.toString() ?? '');

      await _startRinging(callId: messageCallId!, expiresAt: _callStartExpiresAt);

      // call_started itself confirms that the server accepted the call.
      // target_online only tells us whether the target has a live WebSocket.
      _callStartCompleter?.complete(true);
      _callStartCompleter = null;

      return;
    }

    if (type == 'call_accept') {
      if (!_isCurrentCall(messageCallId)) return;
      print('[CN CALL][CALL ACCEPT FORWARD] call_id=$messageCallId');
      await _handleAccepted();
      return;
    }

    if (type == 'call_cancelled') {
      await handleRemoteTermination(callId: messageCallId, reason: 'cancelled');
      return;
    }

    if (type == 'hangup' || type == 'call_reject') {
      await handleRemoteTermination(
        callId: messageCallId,
        reason: type == 'call_reject' ? 'rejected' : 'ended',
      );
      return;
    }
  }

  /// Handles a terminal event from WebSocket or FCM exactly once at the call
  /// state boundary.  Persisting the tombstone before touching native UI makes
  /// late `incoming_call` pushes, reconnects and pending-call restoration
  /// harmless.
  Future<void> handleRemoteTermination({
    required String? callId,
    required String reason,
  }) async {
    final id = callId?.trim() ?? '';
    if (id.isEmpty) return;

    await session.markCallEnded(id);
    await session.clearPendingIncomingCall(id);

    if (reason == 'cancelled') {
      onRemoteCallCancelled?.call(id);
    }

    if (!_isCurrentCall(id)) return;

    await _cleanupCall(
      reason: reason,
      forceDisconnect: true,
    );
  }

  bool _isCurrentCall(String? callId) {
    return callId != null && callId.isNotEmpty && callId == currentCallId;
  }

  /// Hydrates the same call identity when FCM delivered the invite before the
  /// WebSocket isolate was alive. This keeps ringtone cancellation and accept
  /// on the single manager lifecycle.
  Future<void> prepareIncomingCall({
    required String callId,
    required String callerId,
  }) async {
    if (callId.trim().isEmpty || callerId.trim().isEmpty) return;
    if (currentCallId != null && currentCallId != callId) return;
    if (!CallCoordinator.instance.owns(callId)) {
      if (CallCoordinator.instance.beginIncoming(callId) !=
          CallCommandResult.accepted) return;
    }
    currentCallId = callId;
    remoteUserId = callerId;
    caller = false;
    inCall = false;
    state = CallState.incoming;
    await session.markCallActive(callId);
  }

  Future<void> acceptCall({required String callerId, String? callId, bool userInitiated = false}) {
    // Both custom UI and native Telecom callbacks pass through the
    // coordinator queue. Exactly one call_id may win beginAccept().
    return CallCoordinator.instance.serialize(
      () => _acceptCall(callerId: callerId, callId: callId, userInitiated: userInitiated),
    );
  }

  Future<void> _acceptCall({required String callerId, String? callId, required bool userInitiated}) async {
    final acceptedCallId = callId ?? currentCallId;
    if (acceptedCallId == null ||
        await session.isCallEnded(acceptedCallId) ||
        (currentCallId != null && currentCallId != acceptedCallId)) {
      return;
    }
    if (state == CallState.accepted ||
        state == CallState.connecting ||
        state == CallState.connected) {
      return;
    }
    if (!CallCoordinator.instance.owns(acceptedCallId) ||
        CallCoordinator.instance.beginAccept(acceptedCallId) !=
            CallCommandResult.accepted) {
      return;
    }

    print('[CN CALL][CALL ANSWER RECEIVED] call_id=$acceptedCallId');
    await _stopRinging();
    remoteUserId = callerId;
    currentCallId = callId ?? currentCallId;
    await session.markCallActive(currentCallId!);
    state = CallState.accepted;
    caller = false;
    inCall = false;
    _pendingIceCandidates.clear();

    try {
      // A cold Telecom action has to restore and await the same signalling
      // socket used by outgoing calls. Never silently drop call_accept.
      await session.ensureSocketReady();
      if (!_isCurrentCall(acceptedCallId)) return;

      // Re-check terminal state after socket wait; remote cancellation
      // may have arrived during the wait.
      if (await session.isCallEnded(acceptedCallId)) {
        print('[CN CALL][ACCEPT] Call already ended remotely, aborting accept call_id=$acceptedCallId');
        return;
      }

      // Phase 5 (crossover race): ownership re-check IMMEDIATELY before
      // call_accept. FCM may have reached the device first and become the
      // native WS owner (reserved before addNewIncomingCall), even while the
      // Flutter socket is still open or the session was just restored. If
      // native owns signaling for this call now, Flutter must STOP: it sends
      // no call_accept and never tries to seize ownership back — the accept is
      // left to the single native path (Telecom answer). This is a live read,
      // not the connect()-time guard; a native answer already ran nevertheless
      // clears any stale Flutter accept attempt.
      if (!await session.guardFlutterWsOwnership()) {
        print('[CN CALL][ACCEPT] WS is native-owned; call_accept withheld call_id=$acceptedCallId');
        await _cleanupCall(
          reason: 'failed',
          sendSignal: false,
          forceDisconnect: true,
        );
        return;
      }

      print('[CN CALL][CALL SOCKET READY] call_id=$acceptedCallId');
      await session.socket.sendGuaranteed({
        'type': 'call_accept',
        'call_id': acceptedCallId,
        'target_id': callerId,
      });
      print('[CN CALL][CALL_ACCEPT SENT] call_id=$acceptedCallId');
      state = CallState.negotiating;
      CallCoordinator.instance.beginNegotiation(acceptedCallId);
      _startNegotiationTimeout(acceptedCallId);
      _startConnectionTimeout(acceptedCallId);
      await _connectLiveKit(currentCallId!);
    } catch (e) {
      print('[CN CALL][LIVEKIT CONNECT FAILED] call_id=$acceptedCallId error=$e');
      await _failTelecomAndCleanup(acceptedCallId, reason: 'failed');
    }
  }

  Future<void> _handleAccepted() async {
    if (!caller) return;
    if (state == CallState.connecting || state == CallState.connected) return;

    await _stopRinging();

    final acceptedCallId = currentCallId;
    if (acceptedCallId == null || acceptedCallId.isEmpty) return;

    state = CallState.negotiating;

    try {
      await _connectLiveKit(acceptedCallId);
    } catch (e) {
      print('[CN CALL][LIVEKIT CONNECT FAILED] call_id=$acceptedCallId error=$e');
      await _failTelecomAndCleanup(acceptedCallId, reason: 'failed');
    }
  }

  Future<void> rejectCall({required String callerId, String? callId}) async {
    final rejectedCallId = callId?.trim() ?? '';
    final rejectedCallerId = callerId.trim();
    if (rejectedCallId.isEmpty ||
        rejectedCallerId.isEmpty ||
        await session.isCallEnded(rejectedCallId)) {
      return;
    }
    if (currentCallId != null && currentCallId != rejectedCallId) return;
    if (remoteUserId != null && remoteUserId != rejectedCallerId) return;

    // A Telecom action can launch Flutter after the process was terminated.
    // Rehydrate only this exact call so cleanup sends its reject to the right
    // peer; a stale action can never clean up a newer call.
    currentCallId ??= rejectedCallId;
    remoteUserId ??= rejectedCallerId;
    caller = false;
    inCall = false;
    state = CallState.incoming;
    await session.markCallActive(rejectedCallId);

    await _cleanupCall(
      reason: 'rejected',
      sendSignal: true,
      signalType: 'call_reject',
      forceDisconnect: false,
    );
  }

  Future<void> hangup({bool sendSignal = true}) async {
    final shouldCancel = caller && !inCall;
    await _cleanupCall(
      reason: shouldCancel ? 'cancelled' : 'ended',
      sendSignal: sendSignal,
      signalType: shouldCancel ? 'call_cancelled' : 'hangup',
      forceDisconnect: true,
    );
  }

  Future<void> endForSession({bool sendSignal = true}) {
    return _cleanupCall(
      reason: 'ended',
      sendSignal: sendSignal,
      signalType: 'hangup',
      forceDisconnect: true,
    );
  }

  /// Native-owned outgoing call reached ACTIVE (media ready). Keeps the
  /// in-app CallScreen bound to the same native call without any Flutter
  /// LiveKit/WebSocket of its own for that callId.
  Future<void> onNativeCallActive() async {
    final callId = currentCallId;
    if (callId == null || callId.isEmpty) return;
    _cancelCallTimeouts();
    inCall = true;
    state = CallState.connected;
    print('[CN CALL][NATIVE ACTIVE] call_id=$callId');
    onConnected?.call();
  }

  /// Native-owned call ended (event pushed by CNCallConnection after Telecom
  /// reached setDisconnected). The terminal frame was already sent by the
  /// native engine; Flutter only mirrors local state — one terminal path.
  Future<void> handleNativeCallEnded(String callId) async {
    if (!_isCurrentCall(callId)) return;
    print('[CN CALL][NATIVE ENDED] call_id=$callId');
    await _cleanupCall(
      reason: 'ended',
      sendSignal: false,
      forceDisconnect: true,
    );
  }

  /// App-originated outgoing: end the SAME native Telecom call (the in-app
  /// CallScreen maps to the system connection created by placeCNCall). Never
  /// sends a Flutter WebSocket terminal frame for it — that is the native
  /// engine's single responsibility.
  Future<void> endActiveNativeTelecomCall() async {
    final callId = currentCallId;
    if (callId != null && callId.isNotEmpty) {
      try {
        await const MethodChannel('cn_call/call').invokeMethod(
          'endActiveTelecomCall',
          <String, dynamic>{'callId': callId},
        );
      } catch (error) {
        print('[CN CALL][NATIVE END FAILED] call_id=$callId error=$error');
      }
    }
    await _cleanupCall(
      reason: 'ended',
      sendSignal: false,
      forceDisconnect: true,
    );
  }

  Future<void> _cleanupCall({
    required String reason,
    bool sendSignal = false,
    String? signalType,
    bool forceDisconnect = false,
  }) async {
    if (_hangingUp) return _cleanupFuture ?? Future<void>.value();

    _hangingUp = true;
    final callId = currentCallId;
    final target = remoteUserId;

    final cleanup = () async {
      print('[CN CALL][CALL CLEANUP START] call_id=$callId reason=$reason force=$forceDisconnect');
      try {
      _callStartCompleter?.complete(false);
      _callStartCompleter = null;
      _callStartExpiresAt = null;
      _cancelCallTimeouts();
      await _stopRinging();

      if (sendSignal && callId != null && target != null && session.loggedIn) {
        try {
          // Terminal control messages must get a real ready handshake too;
          // dropping them because a reconnect has just started leaves the
          // other Samsung UI ringing until timeout.
          await session.ensureSocketReady();
          await session.socket.sendGuaranteed({
            'type': signalType ?? 'hangup',
            'call_id': callId,
            'target_id': target,
          });
          print('[CN CALL][CALL TERMINAL] call_id=$callId type=${signalType ?? 'hangup'}');
        } catch (error) {
          print('[CN CALL][CALL TERMINAL SEND FAILED] call_id=$callId error=$error');
        }
      }

      await livekit.disconnect();

      await session.markCallEnded(callId);
      await session.clearPendingIncomingCall(callId);
      if (callId != null) CallCoordinator.instance.markEnded(callId);

      _pendingIceCandidates.clear();
      remoteUserId = null;
      currentCallId = null;
      remoteOnline = null;
      inCall = false;
      caller = false;
      _muted = false;
      state = switch (reason) {
        'cancelled' => CallState.cancelled,
        'rejected' => CallState.rejected,
        'timeout' => CallState.timeout,
        'failed' => CallState.ended,
        _ => CallState.ended,
      };

      if (callId != null) onDisconnected?.call();
      print('[CN CALL][CALL CLEANUP DONE] call_id=$callId reason=$reason');
      } finally {
        _hangingUp = false;
        _cleanupFuture = null;
      }
    }();
    _cleanupFuture = cleanup;
    return cleanup;
  }

  Future<void> mute(bool value) async {
    _muted = value;
    await livekit.mute(value);
  }

  Future<void> startIncomingRingtone() async {
    try {
      await const MethodChannel('cn_call/call').invokeMethod(
        'playDefaultRingtone',
        <String, dynamic>{'earpiece': false},
      );
      _incomingRingtonePlaying = true;
    } catch (error) {
      print('[CN CALL][RINGTONE] start failed: $error');
    }
  }

  Future<void> setSpeaker(bool value) {
    return livekit.setSpeaker(value);
  }

  Future<void> dispose() async {
    await _cleanupCall(reason: 'ended', sendSignal: true);
    await _subscription?.cancel();
    _subscription = null;
    _started = false;

    await livekit.disconnect();
  }

  Future<void> _connectLiveKit(String callId) async {
    print('[CN CALL][LIVEKIT START] call_id=$callId');

    final data = await LiveKitTokenService.getToken(callId: callId);

    final url = data['url']?.toString();
    final token = data['token']?.toString();

    if (url == null || url.isEmpty) {
      throw Exception('LiveKit response missing url');
    }

    if (token == null || token.isEmpty) {
      throw Exception('LiveKit response missing token');
    }

    await livekit.connect(url: url, token: token);
    print('[CN CALL][LIVEKIT CONNECTED] call_id=$callId');

    // Preserve a mute choice made on the incoming CN CALL screen while the
    // LiveKit room was still connecting.
    if (_muted) await livekit.mute(true);

    if (!_isCurrentCall(callId)) {
      await livekit.disconnect();
      throw StateError('LiveKit connected for a stale call');
    }

    livekit.notifyConnected();
  }


  Future<void> _failTelecomAndCleanup(String callId, {required String reason}) async {
    await _cleanupCall(
      reason: reason,
      sendSignal: true,
      signalType: 'hangup',
      forceDisconnect: true,
    );
  }
}
