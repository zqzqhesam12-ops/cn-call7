import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/call_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'terminal tombstone rejects a late incoming call with the same id',
    () async {
      const callId = 'cancelled-call';
      await CallSession.instance.markCallEnded(callId);

      await CallSession.instance.incomingCallFromNotification(<String, dynamic>{
        'call_id': callId,
        'caller_id': 'caller-a',
      });

      final prefs = await SharedPreferences.getInstance();
      expect(await CallSession.instance.isCallEnded(callId), isTrue);
      expect(prefs.getString('pending_incoming_call'), isNull);
    },
  );

  test('terminal state removes only matching pending incoming state', () async {
    const oldCallId = 'old-call';
    const newCallId = 'new-call';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'pending_incoming_call',
      jsonEncode(<String, dynamic>{
        'call_id': newCallId,
        'caller_id': 'caller-b',
      }),
    );

    await CallSession.instance.markCallEnded(oldCallId);
    await CallSession.instance.clearPendingIncomingCall(oldCallId);

    final pending = jsonDecode(prefs.getString('pending_incoming_call')!);
    expect(pending['call_id'], newCallId);
    expect(await CallSession.instance.isCallEnded(oldCallId), isTrue);
    expect(await CallSession.instance.isCallEnded(newCallId), isFalse);
  });

  test('a stale CallKit action is cleared instead of being restored', () async {
    const callId = 'cancelled-callkit-call';
    final prefs = await SharedPreferences.getInstance();
    await CallSession.instance.markCallEnded(callId);
    await prefs.setString('cn_call_pending_callkit_action', 'reject');
    await prefs.setString('cn_call_pending_callkit_caller_id', 'caller-c');
    await prefs.setString('cn_call_pending_callkit_call_id', callId);
    await prefs.setString('cn_call_pending_callkit_target_id', 'callee-c');
    await prefs.setString(
      'pending_incoming_call',
      jsonEncode(<String, dynamic>{'call_id': callId}),
    );

    await CallSession.instance.processPendingCallKitAction();

    expect(prefs.getString('cn_call_pending_callkit_action'), isNull);
    expect(prefs.getString('cn_call_pending_callkit_call_id'), isNull);
    expect(prefs.getString('pending_incoming_call'), isNull);
  });
}
