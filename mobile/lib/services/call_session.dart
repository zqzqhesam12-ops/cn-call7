import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'call_socket.dart';
import 'rtc_call_manager.dart';

class CallSession {
  static final CallSession instance = CallSession._();

  final CallSocket socket = CallSocket();
  Function()? onSessionInvalidated;

  CallSession._() {
    socket.onSessionInvalid = invalidateSession;
  }

  final StreamController<Map<String, dynamic>> _incomingCalls =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get incomingCalls => _incomingCalls.stream;

  StreamSubscription<Map<String, dynamic>>? _messageSubscription;

  String? userId;
  String? displayName;
  String? accessToken;

  bool get loggedIn => userId != null;

  // This is a JSON string rather than a StringList. Android native code must
  // read the exact same representation from FlutterSharedPreferences.
  static const _endedCallIdsKey = 'cn_call_ended_call_ids_v2';
  static const _activeCallIdKey = 'cn_call_active_call_id';
  static const _activeCallAtKey = 'cn_call_active_call_at';

  Future<bool> hasActiveCall() async {
    final prefs = await SharedPreferences.getInstance();
    final activeId = prefs.getString(_activeCallIdKey);

    // لا تنتهي حالة المكالمة تلقائيًا بعد 90 ثانية.
    // المكالمة تبقى نشطة حتى يتم استدعاء markCallEnded().
    // هذا يمنع استقبال/بدء مكالمة ثانية أثناء وجود مكالمة فعلية.
    return activeId != null && activeId.isNotEmpty;
  }

  Future<void> markCallActive(String callId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeCallIdKey, callId);
    await prefs.setInt(_activeCallAtKey, DateTime.now().millisecondsSinceEpoch);
  }

  Future<bool> isCallEnded(String? callId) async {
    final id = callId?.trim() ?? '';
    if (id.isEmpty) return true;

    final prefs = await SharedPreferences.getInstance();
    return _readEndedCallIds(prefs).contains(id);
  }

  Future<void> markCallEnded(String? callId) async {
    final id = callId?.trim() ?? '';
    if (id.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final ids = _readEndedCallIds(prefs);
    ids.remove(id);
    ids.add(id);
    if (ids.length > 32) ids.removeRange(0, ids.length - 32);
    await prefs.setString(_endedCallIdsKey, jsonEncode(ids));
    if (prefs.getString(_activeCallIdKey) == id) {
      await prefs.remove(_activeCallIdKey);
      await prefs.remove(_activeCallAtKey);
    }
  }

  List<String> _readEndedCallIds(SharedPreferences prefs) {
    final encoded = prefs.getString(_endedCallIdsKey);
    if (encoded == null || encoded.isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is List) {
        return decoded
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // A malformed tombstone must never crash an incoming-call handler.
    }
    return <String>[];
  }

  Future<void> login({
    required String id,
    required String name,
    required String token,
  }) async {
    userId = id;
    displayName = name;
    accessToken = token;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cn_call_user_id', id);
    await prefs.setString('cn_call_display_name', name);
    await prefs.setString('cn_call_access_token', token);

    socket.connect(id, token).then(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        print('BACKGROUND SOCKET CONNECT ERROR: $error');
      },
    );

    // استقبال رسائل المكالمات يتم الآن بواسطة RtcCallManager.
  }

  Future<void> invalidateSession() async {
    await RtcCallManager.instance.endForSession(sendSignal: false);
    socket.disconnect();
    userId = null;
    displayName = null;
    accessToken = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cn_call_user_id');
    await prefs.remove('cn_call_display_name');
    await prefs.remove('cn_call_access_token');

    onSessionInvalidated?.call();
  }

  Future<bool> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();

    final id = prefs.getString('cn_call_user_id');
    final name = prefs.getString('cn_call_display_name');
    final token = prefs.getString('cn_call_access_token');

    if (id == null ||
        id.isEmpty ||
        name == null ||
        name.isEmpty ||
        token == null ||
        token.isEmpty) {
      return false;
    }

    userId = id;
    displayName = name;
    accessToken = token;

    await socket.connect(id, token);

    // Telecom actions are restored explicitly by telecomBackgroundMain after
    // the WebSocket is connected.

    return true;
  }

  Future<bool> restoreCredentialsOnly() async {
    final prefs = await SharedPreferences.getInstance();

    final id = prefs.getString('cn_call_user_id')?.trim();
    final name = prefs.getString('cn_call_display_name')?.trim();
    final token = prefs.getString('cn_call_access_token')?.trim();

    if (id == null ||
        id.isEmpty ||
        name == null ||
        name.isEmpty ||
        token == null ||
        token.isEmpty) {
      return false;
    }

    userId = id;
    displayName = name;
    accessToken = token;
    return true;
  }

  /// Restores the authenticated WebSocket before a Telecom background action
  /// emits any signalling. This is shared by accepted incoming and outgoing.
  Future<void> ensureSocketReady() async {
    final id = userId;
    final token = accessToken;
    if (id == null || id.isEmpty || token == null || token.isEmpty) {
      throw StateError('No authenticated CN CALL session');
    }
    if (!socket.connected) await socket.connect(id, token);
    if (!socket.connected) throw StateError('CN CALL WebSocket is not ready');
  }

  Future<void> incomingCallFromNotification(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final callId = data['call_id']?.toString().trim() ?? '';
      if (callId.isEmpty || await isCallEnded(callId)) return;

      await prefs.setString('pending_incoming_call', jsonEncode(data));

      // FCM data messages can be delivered after a cancellation message.  Do
      // not re-publish a call that was cancelled while this write was pending.
      if (await isCallEnded(callId)) {
        await clearPendingIncomingCall(callId);
        return;
      }

      _incomingCalls.add(data);
    } catch (e) {
      print('SAVE INCOMING CALL ERROR: $e');
    }
  }

  Future<Map<String, dynamic>?> takePendingIncomingCall() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final pending = prefs.getString('pending_incoming_call');

      if (pending == null || pending.isEmpty) {
        return null;
      }

      await prefs.remove('pending_incoming_call');

      final data = jsonDecode(pending);

      if (data is Map) {
        final call = Map<String, dynamic>.from(data);
        final callId = call['call_id']?.toString().trim() ?? '';
        final callerId = (call['caller_id']?.toString().trim().isNotEmpty == true)
            ? call['caller_id'].toString().trim()
            : call['from_id']?.toString().trim() ?? '';
        if (callId.isEmpty ||
            callerId.isEmpty ||
            await isCallEnded(callId) ||
            await hasActiveCall()) {
          return null;
        }
        call['call_id'] = callId;
        call['caller_id'] = callerId;
        return call;
      }
    } catch (e) {
      print('TAKE PENDING CALL ERROR: $e');
    }

    return null;
  }

  Future<void> clearPendingIncomingCall(String? callId) async {
    if (callId == null || callId.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getString('pending_incoming_call');
    if (pending == null || pending.isEmpty) return;

    try {
      final data = jsonDecode(pending);
      final pendingId = data is Map ? data['call_id']?.toString() : null;
      if (pendingId == callId) {
        await prefs.remove('pending_incoming_call');
      }
    } catch (_) {
      await prefs.remove('pending_incoming_call');
    }
  }

  Future<void> logout() async {
    await _messageSubscription?.cancel();
    _messageSubscription = null;
    await RtcCallManager.instance.endForSession();
    socket.disconnect();

    userId = null;
    displayName = null;
    accessToken = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cn_call_user_id');
    await prefs.remove('cn_call_display_name');
    await prefs.remove('cn_call_access_token');
  }

  Future<void> dispose() async {
    socket.disconnect();
  }
}
