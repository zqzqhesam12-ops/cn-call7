import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'firebase_options.dart';

import 'services/call_session.dart';
import 'services/firebase_messaging_service.dart';
import 'services/account_api.dart';
import 'services/rtc_call_manager.dart';
import 'screens/incoming_call_screen.dart';
import 'screens/active_call_screen.dart';

import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _telecomChannel = MethodChannel('cn_call/call');
const MethodChannel _telecomEventsChannel =
    MethodChannel('cn_call/telecom_events');

Future<void> _announceCoreTelecomFlutterReady() async {
  try {
    await _telecomChannel.invokeMethod(
      'coreTelecomFlutterReady',
    );

    print(
      '[CN CALL][CORE TELECOM] Flutter ready announced',
    );
  } catch (e) {
    print(
      '[CN CALL][CORE TELECOM] Flutter ready handshake failed: $e',
    );
  }
}

Future<void> _handleCoreTelecomAction(
  Map<Object?, Object?> arguments,
) async {
  final action = arguments['action']?.toString().trim() ?? '';
  final callId = arguments['callId']?.toString().trim() ?? '';
  final peerId = arguments['peerId']?.toString().trim() ?? '';

  if (action.isEmpty || callId.isEmpty || peerId.isEmpty) {
    print(
      '[CN CALL][CORE TELECOM] '
      'ignored Flutter event with incomplete identity',
    );
    return;
  }

  print(
    '[CN CALL][CORE TELECOM][FLUTTER EVENT] '
    'action=$action call_id=$callId peer_id=$peerId',
  );

  switch (action) {
    case 'answer':
      await RtcCallManager.instance.prepareIncomingCall(
        callId: callId,
        callerId: peerId,
      );
      if (RtcCallManager.instance.currentCallId != callId ||
          RtcCallManager.instance.remoteUserId != peerId) {
        print(
          '[CN CALL][CORE TELECOM] '
          'answer identity mismatch call_id=$callId peer_id=$peerId',
        );
        return;
      }
      await RtcCallManager.instance.acceptCall(
        callerId: peerId,
        callId: callId,
        userInitiated: true,
      );
      break;

    case 'reject':
      await RtcCallManager.instance.rejectCall(
        callerId: peerId,
        callId: callId,
      );
      break;

    case 'hangup':
      // The active notification's End action converges on the same Dart
      // terminal path as the custom active-call screen.
      await RtcCallManager.instance.hangupForCall(
        callId: callId,
        peerId: peerId,
      );
      break;

    case 'ended':
      await RtcCallManager.instance.endFromTelecom(
        callId: callId,
        reason: 'ended',
      );
      break;

    default:
      print(
        '[CN CALL][CORE TELECOM] '
        'unknown Flutter action=$action call_id=$callId',
      );
  }
}

Future<void> _handleTelecomAction(Map<Object?, Object?> arguments) async {
  final action = arguments['action']?.toString() ?? '';
  final callId = arguments['callId']?.toString() ?? '';
  final peerId = arguments['peerId']?.toString() ?? '';
  if (callId.isEmpty || peerId.isEmpty) return;
  print('[CN CALL][CALL ACTION RECEIVED] action=$action call_id=$callId');
  if (action == 'outgoing') {
    await RtcCallManager.instance.startCall(targetId: peerId, callId: callId);
  } else if (action == 'reject') {
    await RtcCallManager.instance.rejectCall(callerId: peerId, callId: callId);
  } else if (action == 'ended') {
    await RtcCallManager.instance.endFromTelecom(callId: callId, reason: 'ended');
  }
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('flutter.cn_call_core_telecom_actions_v1') ?? '[]';
  try {
    final queued = jsonDecode(raw);
    if (queued is List) {
      queued.removeWhere((item) => item is Map &&
          item['action']?.toString() == action &&
          item['callId']?.toString() == callId);
      await prefs.setString(
        'flutter.cn_call_core_telecom_actions_v1',
        jsonEncode(queued),
      );
    }
  } catch (_) {
    // The cold-start drain will discard a malformed queue safely.
  }
}

void _installTelecomEventHandler() {
  _telecomEventsChannel.setMethodCallHandler((call) async {
    final arguments = Map<Object?, Object?>.from(call.arguments as Map);
    // Android uses this event only to wake/bring the Flutter activity forward.
    // Rendering and all call decisions remain in Flutter; it must never create
    // a Telecom/InCallUI call.
    if (call.method == 'incomingCall') {
      await CallSession.instance.incomingCallFromNotification(
        Map<String, dynamic>.from(arguments),
      );
      return;
    }
    if (call.method == 'muteChanged') {
      final callId = arguments['callId']?.toString() ?? '';
      if (callId.isNotEmpty && RtcCallManager.instance.currentCallId == callId) {
        await RtcCallManager.instance.mute(arguments['isMuted'] == true);
      }
      return;
    }
    if (call.method == 'callAction') {
      await _handleTelecomAction(arguments);
      return;
    }

    if (call.method == 'coreTelecomAction') {
      await _handleCoreTelecomAction(arguments);
      return;
    }
  });
}

@pragma('vm:entry-point')
Future<void> telecomBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  _installTelecomEventHandler();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    RtcCallManager.instance.startListening();

    final restored = await CallSession.instance.restoreCredentialsOnly();

    if (!restored) {
      print('[CN CALL][TELECOM] background session restore failed');
      return;
    }

    await _announceCoreTelecomFlutterReady();

    final prefs = await SharedPreferences.getInstance();
    final queued = prefs.getString('flutter.cn_call_core_telecom_actions_v1') ?? '[]';
    final actions = <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(queued);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) actions.add(Map<String, dynamic>.from(item));
        }
      }
    } catch (_) {
      print('[CN CALL][TELECOM] invalid persisted action queue');
    }

    for (final actionData in actions) {
      final telecomAction = actionData['action']?.toString() ?? '';
      final telecomCallId = actionData['callId']?.toString() ?? '';
      final telecomPeerId = actionData['peerId']?.toString() ?? '';
      if (telecomCallId.isEmpty || telecomPeerId.isEmpty) continue;
      print('[CN CALL][TELECOM ACTION DEQUEUED] action=$telecomAction call_id=$telecomCallId');
      if (telecomAction == 'outgoing') {
      await RtcCallManager.instance.startCall(
        targetId: telecomPeerId,
        callId: telecomCallId,
      );
      } else if (telecomAction == 'reject') {
      await RtcCallManager.instance.rejectCall(
        callerId: telecomPeerId,
        callId: telecomCallId,
      );
      } else if (telecomAction == 'answer') {
      if (await CallSession.instance.isCallEnded(telecomCallId)) {
        continue;
      }
      await RtcCallManager.instance.prepareIncomingCall(
        callId: telecomCallId,
        callerId: telecomPeerId,
      );
      if (RtcCallManager.instance.currentCallId != telecomCallId ||
          RtcCallManager.instance.remoteUserId != telecomPeerId) {
        print(
          '[CN CALL][TELECOM] '
          'answer identity mismatch call_id=$telecomCallId '
          'peer_id=$telecomPeerId',
        );
        continue;
      }
      await RtcCallManager.instance.acceptCall(
        callerId: telecomPeerId,
        callId: telecomCallId,
        userInitiated: true,
      );
      } else if (telecomAction == 'ended') {
      await RtcCallManager.instance.endFromTelecom(
        callId: telecomCallId,
        reason: 'ended',
      );
      }
    }

    // Actions are removed only after credential restore and the Dart lifecycle
    // handlers have run.  Duplicate delivery is harmless because
    // RtcCallManager gates every action by call_id/state.
    await prefs.remove('flutter.cn_call_core_telecom_actions_v1');

    print(
      '[CN CALL][TELECOM] background call action processed',
    );
  } catch (e, stackTrace) {
    print(
      '[CN CALL][TELECOM] background entrypoint error: $e\n$stackTrace',
    );
  }
}

/// Entry point hosted only by CNCallIncomingActivity.  It deliberately avoids
/// CNCallApp and the normal login/home navigation stack.
@pragma('vm:entry-point')
Future<void> incomingCallUiMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  _installTelecomEventHandler();
  RtcCallManager.instance.startListening();

  Map<Object?, Object?> bootstrap;
  try {
    bootstrap = Map<Object?, Object?>.from(
      await _telecomChannel.invokeMethod<Map<Object?, Object?>>('incomingCallBootstrap') ?? const <Object?, Object?>{},
    );
  } on PlatformException {
    runApp(const MaterialApp(home: SizedBox.shrink()));
    return;
  }
  // These values come from CNCallIncomingActivity's launching Intent, not
  // shared preferences.  That Intent is the sole cold-start UI handoff.
  final callId = bootstrap['callId']?.toString().trim() ?? '';
  final callerId = bootstrap['callerId']?.toString().trim() ?? '';
  final callerName = bootstrap['callerName']?.toString() ?? 'مستخدم CN CALL';
  if (callId.isEmpty || callerId.isEmpty || await CallSession.instance.isCallEnded(callId)) {
    runApp(const MaterialApp(home: SizedBox.shrink()));
    return;
  }
  if (!await CallSession.instance.restoreSession()) {
    runApp(const MaterialApp(home: SizedBox.shrink()));
    return;
  }
  await RtcCallManager.instance.prepareIncomingCall(callId: callId, callerId: callerId);
  await RtcCallManager.instance.startIncomingRingtone();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: _DedicatedIncomingCallFlow(callId: callId, callerId: callerId, callerName: callerName),
  ));
}

class _DedicatedIncomingCallFlow extends StatelessWidget {
  final String callId;
  final String callerId;
  final String callerName;
  const _DedicatedIncomingCallFlow({required this.callId, required this.callerId, required this.callerName});

  @override
  Widget build(BuildContext context) => IncomingCallScreen(
    name: callerName, id: callerId, callId: callId,
    onAccept: () async {
      final permissionGranted = await const MethodChannel('cn_call/call').invokeMethod<bool>(
        'recordAudioPermissionGranted',
      ) ?? false;
      if (!permissionGranted) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('يلزم السماح باستخدام الميكروفون لقبول المكالمة'),
            ),
          );
        }
        return;
      }
      final answerClaimed = await const MethodChannel('cn_call/call').invokeMethod<bool>(
        'claimCoreTelecomAnswer',
        <String, dynamic>{'callId': callId},
      ) ?? false;
      if (!answerClaimed) {
        // If claim failed, check if a native runtime exists.
        // For cold-start (CNCallIncomingActivity), a native runtime SHOULD exist.
        // If it exists and claim failed, another native path (onAnswer/CallStyle)
        // already owns the answer - do not proceed.
        final hasRuntime = await const MethodChannel('cn_call/call').invokeMethod<bool>(
          'hasNativeRuntime',
          <String, dynamic>{'callId': callId},
        ) ?? false;
        if (hasRuntime) {
          print('[CN CALL][COLD START] Answer already claimed by native path, aborting Flutter accept call_id=$callId');
          return;
        }
        // No native runtime (should not happen for cold start, but safe fallback): proceed.
        print('[CN CALL][COLD START] No native runtime, proceeding with Flutter accept call_id=$callId');
      }
      await RtcCallManager.instance.acceptCall(callerId: callerId, callId: callId, userInitiated: true);
      if (!context.mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => Builder(
          builder: (activeContext) => ActiveCallScreen(
            name: callerName, id: callerId,
            onMute: RtcCallManager.instance.mute,
            onSpeaker: RtcCallManager.instance.setSpeaker,
            onEnd: () async {
              await RtcCallManager.instance.hangup();
              if (activeContext.mounted) {
                Navigator.of(activeContext).pop();
              }
            },
          ),
        ),
      ));
    },
    onReject: () async {
      print('[CN CALL][REJECT DIAGNOSTIC] before rejectCall call_id=$callId');
      await RtcCallManager.instance.rejectCall(callerId: callerId, callId: callId);
      print('[CN CALL][REJECT DIAGNOSTIC] after rejectCall call_id=$callId');
      if (context.mounted) {
        print('[CN CALL][REJECT DIAGNOSTIC] before Navigator.pop call_id=$callId');
        Navigator.of(context).pop();
        print('[CN CALL][REJECT DIAGNOSTIC] after Navigator.pop call_id=$callId');
      }
    },
    onMute: RtcCallManager.instance.mute,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await FirebaseMessagingService.instance.initialize();

  _installTelecomEventHandler();

  RtcCallManager.instance.startListening();

  runApp(const CNCallApp());
}

class CNCallApp extends StatefulWidget {
  const CNCallApp({super.key});

  @override
  State<CNCallApp> createState() => _CNCallAppState();
}

class _CNCallAppState extends State<CNCallApp> {
  bool _loading = true;
  bool _hasSession = false;

  @override
  void initState() {
    super.initState();

    CallSession.instance.onSessionInvalidated = _handleSessionInvalidated;
    _restoreSession();
  }

  void _handleSessionInvalidated() {
    if (!mounted) return;
    setState(() {
      _hasSession = false;
    });
  }

  @override
  void dispose() {
    CallSession.instance.onSessionInvalidated = null;
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final restored = await CallSession.instance.restoreSession();

    if (restored) {
      await FirebaseMessagingService.instance.refreshTokenForCurrentUser();
    }

    if (!mounted) return;

    setState(() {
      _hasSession = restored;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CN CALL',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF050505),
        useMaterial3: true,
      ),
      home: _loading
          ? const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: Color(0xFF00E676)),
              ),
            )
          : _hasSession
          ? const HomeScreen()
          : const LoginScreen(),
    );
  }
}

// ============================================================
// LOGIN
// ============================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final userIdController = TextEditingController();
  final passwordController = TextEditingController();

  bool hidePassword = true;

  @override
  void dispose() {
    userIdController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  void openRegister() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RegisterScreen()),
    );
  }

  Future<void> login() async {
    final userId = userIdController.text.trim();
    final password = passwordController.text;

    if (userId.isEmpty) {
      _message('أدخل ID المستخدم');
      return;
    }

    if (int.tryParse(userId) == null) {
      _message('ID المستخدم يجب أن يكون أرقامًا فقط');
      return;
    }

    if (password.isEmpty) {
      _message('أدخل كلمة المرور');
      return;
    }

    final result = await AccountApi.login(userId: userId, password: password);

    if (!mounted) return;

    final success = result['success'] == true;

    if (!success) {
      _message(
        result['message']?.toString() ?? 'ID المستخدم أو كلمة المرور غير صحيحة',
      );
      return;
    }

    final user = result['user'];

    if (user is! Map) {
      _message('بيانات المستخدم غير صالحة');
      return;
    }

    final loggedUserId = user['user_id']?.toString();
    final username = user['username']?.toString();
    final accessToken = result['access_token']?.toString();

    if (loggedUserId == null ||
        loggedUserId.isEmpty ||
        username == null ||
        username.isEmpty ||
        accessToken == null ||
        accessToken.isEmpty) {
      _message('بيانات المستخدم ناقصة');
      return;
    }

    await CallSession.instance.login(
      id: loggedUserId,
      name: username,
      token: accessToken,
    );

    await FirebaseMessagingService.instance.refreshTokenForCurrentUser();

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  void _message(String text, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: success
            ? const Color(0xFF00A85A)
            : Colors.red.shade800,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: Column(
                  children: [
                    _Logo(),

                    const SizedBox(height: 24),

                    const Text(
                      'CN CALL',
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      'مكالمات صوتية بدون أرقام هاتف',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 14,
                      ),
                    ),

                    const SizedBox(height: 42),

                    _Field(
                      controller: userIdController,
                      label: 'ID المستخدم',
                      hint: 'أدخل ID المستخدم',
                      icon: Icons.badge_outlined,
                      keyboardType: TextInputType.number,
                    ),

                    const SizedBox(height: 16),

                    _Field(
                      controller: passwordController,
                      label: 'كلمة المرور',
                      hint: 'أدخل كلمة المرور',
                      icon: Icons.lock_outline,
                      obscureText: hidePassword,
                      suffix: IconButton(
                        onPressed: () {
                          setState(() {
                            hidePassword = !hidePassword;
                          });
                        },
                        icon: Icon(
                          hidePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    _PrimaryButton(text: 'تسجيل الدخول', onPressed: login),

                    const SizedBox(height: 12),

                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton(
                        onPressed: openRegister,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: Colors.grey.shade800),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: const Text(
                          'إنشاء حساب جديد',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 28),

                    _Footer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// HOME
// ============================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  final callIdController = TextEditingController();

  final List<Map<String, String>> _contacts = [];
  final List<Map<String, dynamic>> _callHistory = [];

  bool _loadingData = true;

  bool _incomingCallScreenOpen = false;
  String? _incomingCallScreenCallId;
  bool _canUseFullScreenIntent = true;

  void _closeIncomingCallScreen() {
    if (!_incomingCallScreenOpen) return;

    if (!mounted) {
      _incomingCallScreenOpen = false;
      return;
    }

    final navigator = Navigator.of(context);

    if (navigator.canPop()) {
      navigator.pop();
    }

    _incomingCallScreenOpen = false;
    _incomingCallScreenCallId = null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshFullScreenIntentAvailability();

    _loadLocalData();
    _loadMissedCalls();

    final rtcManager = RtcCallManager.instance;
    rtcManager.startListening();

    Future<void> showIncomingCall(Map<String, dynamic> call) async {
      if (!mounted) return;

      final callId = call['call_id']?.toString().trim() ?? '';
      if (callId.isEmpty || await CallSession.instance.isCallEnded(callId)) {
        return;
      }

      final callerId =
          call['caller_id']?.toString() ?? call['from_id']?.toString() ?? '';

      final callerName = call['caller_name']?.toString() ?? 'مستخدم CN CALL';

      if (callerId.isEmpty) return;
      if (_incomingCallScreenOpen) return;

      await RtcCallManager.instance.prepareIncomingCall(
        callId: callId,
        callerId: callerId,
      );
      await RtcCallManager.instance.startIncomingRingtone();
      _addHistory(name: callerName, id: callerId, incoming: true);

      _incomingCallScreenOpen = true;
      _incomingCallScreenCallId = callId;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => IncomingCallScreen(
            name: callerName,
            id: callerId,
            callId: callId,
            onAccept: () async {
              final _ = await const MethodChannel('cn_call/call').invokeMethod<bool>(
                'claimCoreTelecomAnswer',
                <String, dynamic>{'callId': callId},
              ) ?? false;
              // Open-app incoming calls arrive over the live WebSocket and never
              // create a Core-Telecom runtime, so this claim is best-effort: a
              // false result must not abort the normal accept lifecycle. When a
              // valid native runtime does exist the claim may still return true.
              await RtcCallManager.instance.acceptCall(callerId: callerId, callId: callId, userInitiated: true);
              if (context.mounted) Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => CallScreen(name: callerName, id: callerId)));
            },
            onReject: () async {
              await RtcCallManager.instance.rejectCall(callerId: callerId, callId: callId);
              if (context.mounted) Navigator.of(context).pop();
            },
            onMute: RtcCallManager.instance.mute,
          ),
        ),
      ).whenComplete(() {
        if (mounted) {
          _incomingCallScreenOpen = false;
          _incomingCallScreenCallId = null;
        }
      });
    }

    // المكالمات القادمة مباشرة عبر WebSocket.
    rtcManager.onIncomingCall = showIncomingCall;

    rtcManager.onRemoteCallCancelled = (callId) async {
      if (_incomingCallScreenCallId != callId) return;
      _closeIncomingCallScreen();
    };

    // المكالمات التي وصلت عبر FCM أثناء إغلاق التطبيق.
    CallSession.instance.incomingCalls.listen(showIncomingCall);

    Future.microtask(() async {
      final pendingCall =
          await CallSession.instance.takePendingIncomingCall();
      if (mounted && pendingCall != null) {
        await showIncomingCall(pendingCall);
      }
    });

    rtcManager.onDisconnected = () {
      _closeIncomingCallScreen();
    };

  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshFullScreenIntentAvailability();
    }
  }

  Future<void> _refreshFullScreenIntentAvailability() async {
    try {
      final available = await _telecomChannel.invokeMethod<bool>(
        'canUseFullScreenIntent',
      );
      if (!mounted) return;
      setState(() {
        _canUseFullScreenIntent = available ?? true;
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _canUseFullScreenIntent = true;
      });
    }
  }

  Future<void> _openFullScreenIntentSettings() async {
    if (_incomingCallScreenOpen) return;
    await _telecomChannel.invokeMethod<bool>('openFullScreenIntentSettings');
  }

  Future<void> _loadLocalData() async {
    final prefs = await SharedPreferences.getInstance();

    // تنظيف بيانات التجارب القديمة مرة واحدة.
    const cleanupKey = 'cn_call_real_data_cleanup_v1';
    final cleaned = prefs.getBool(cleanupKey) ?? false;

    if (!cleaned) {
      await prefs.remove('cn_call_contacts');
      await prefs.remove('cn_call_history');
      await prefs.setBool(cleanupKey, true);
    }

    final contacts = prefs.getStringList('cn_call_contacts') ?? [];

    final loadedContacts = <Map<String, String>>[];

    for (final item in contacts) {
      final parts = item.split('|');

      if (parts.length >= 2) {
        loadedContacts.add({
          'id': parts[0],
          'name': parts.sublist(1).join('|'),
        });
      }
    }

    final history = prefs.getStringList('cn_call_history') ?? [];

    final loadedHistory = <Map<String, dynamic>>[];

    for (final item in history) {
      final parts = item.split('|');

      if (parts.length >= 4) {
        loadedHistory.add({
          'id': parts[0],
          'name': parts[1],
          'incoming': parts[2] == '1',
          'time': parts.sublist(3).join('|'),
        });
      }
    }

    if (!mounted) return;

    setState(() {
      _contacts
        ..clear()
        ..addAll(loadedContacts);

      _callHistory
        ..clear()
        ..addAll(loadedHistory);

      _loadingData = false;
    });
  }

  Future<void> _loadMissedCalls() async {
    final userId = CallSession.instance.userId;
    if (userId == null || userId.isEmpty) return;

    final missed = await AccountApi.missedCalls(userId: userId);
    if (!mounted || missed.isEmpty) return;

    for (final call in missed) {
      final callerId = call['caller_id']?.toString() ?? '';
      final callerName = call['caller_name']?.toString() ?? 'مستخدم CN CALL';
      if (callerId.isEmpty) continue;
      await _addHistory(name: callerName, id: callerId, incoming: true);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('لديك مكالمة فائتة')),
    );
  }

  Future<void> _saveContacts() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setStringList(
      'cn_call_contacts',
      _contacts
          .map((contact) => '${contact['id']!}|${contact['name']!}')
          .toList(),
    );
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setStringList(
      'cn_call_history',
      _callHistory
          .map(
            (item) =>
                '${item['id']}|${item['name']}|${item['incoming'] == true ? '1' : '0'}|${item['time']}',
          )
          .toList(),
    );
  }

  Future<void> _addHistory({
    required String name,
    required String id,
    required bool incoming,
  }) async {
    final now = DateTime.now();

    final time =
        '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';

    final item = <String, dynamic>{
      'id': id,
      'name': name,
      'incoming': incoming,
      'time': time,
    };

    if (mounted) {
      setState(() {
        _callHistory.insert(0, item);

        if (_callHistory.length > 50) {
          _callHistory.removeLast();
        }
      });
    }

    await _saveHistory();
  }

  Future<void> _addContact() async {
    final result = await _showAddContactDialog(context);

    if (result == null) return;

    final id = result['id']!;
    final name = result['name']!;

    if (_contacts.any((contact) => contact['id'] == id)) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('جهة الاتصال موجودة بالفعل')),
      );

      return;
    }

    if (!mounted) return;

    setState(() {
      _contacts.add({'id': id, 'name': name});
    });

    await _saveContacts();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('تمت إضافة $name إلى جهات الاتصال'),
        backgroundColor: const Color(0xFF00A85A),
      ),
    );
  }

  Future<void> _deleteContact(String id) async {
    setState(() {
      _contacts.removeWhere((contact) => contact['id'] == id);
    });

    await _saveContacts();
  }

  Future<void> _clearHistory() async {
    setState(() {
      _callHistory.clear();
    });

    await _saveHistory();
  }

  Future<void> startCall() async {
    final id = callIdController.text.trim();

    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل ID المستخدم الذي تريد الاتصال به')),
      );
      return;
    }

    if (int.tryParse(id) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ID المستخدم يجب أن يكون أرقامًا فقط')),
      );
      return;
    }

    final session = CallSession.instance;

    if (!session.loggedIn) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('يجب تسجيل الدخول أولًا')));
      return;
    }

    if (id == session.userId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الاتصال بالنفس غير مسموح')),
      );
      return;
    }

    final name = 'المستخدم $id';

    await _addHistory(name: name, id: id, incoming: false);

    final callId = const Uuid().v4();
    final started = await RtcCallManager.instance.startCall(
      targetId: id,
      callId: callId,
    );

    print('[CN CALL][OUTGOING SIGNAL RESULT] started=$started call_id=$callId');
    if (!started) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر بدء المكالمة')),
      );
      return;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CallScreen(name: name, id: id)),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    callIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF050505),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text(
            'CN CALL',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5),
          ),
          actions: [
            if (!_canUseFullScreenIntent && !_incomingCallScreenOpen)
              IconButton(
                tooltip: 'فعّل المكالمات بملء الشاشة',
                onPressed: _openFullScreenIntentSettings,
                icon: const Icon(Icons.fullscreen_rounded),
              ),
            IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: () async {
                final navigator = Navigator.of(context);

                final shouldLogout = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) {
                    return AlertDialog(
                      backgroundColor: const Color(0xFF151515),
                      title: const Text(
                        'تسجيل الخروج',
                        textDirection: TextDirection.rtl,
                      ),
                      content: const Text(
                        'هل تريد تسجيل الخروج من الحساب الحالي؟',
                        textDirection: TextDirection.rtl,
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('إلغاء'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          child: const Text('تسجيل الخروج'),
                        ),
                      ],
                    );
                  },
                );

                if (shouldLogout != true || !mounted) return;

                await CallSession.instance.logout();

                if (!mounted) return;

                navigator.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              },
              icon: const Icon(Icons.logout_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: _loadingData
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 30),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151515),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: const Color(0xFF00E676)
                                .withValues(alpha: .18),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 58,
                              height: 58,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF00E676)
                                    .withValues(alpha: .12),
                              ),
                              child: const Icon(
                                Icons.person,
                                color: Color(0xFF00E676),
                                size: 30,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'مرحبًا بك',
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    CallSession.instance.displayName ??
                                        'مستخدم CN CALL',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'ID: ${CallSession.instance.userId ?? ''}',
                                    style: const TextStyle(
                                      color: Color(0xFF00E676),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 28),

                      const Text(
                        'إجراء مكالمة',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),

                      const SizedBox(height: 8),

                      Text(
                        'أدخل ID المستخدم الذي تريد الاتصال به',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 14,
                        ),
                      ),

                      const SizedBox(height: 16),

                      _Field(
                        controller: callIdController,
                        label: 'ID المستخدم',
                        hint: 'مثال: 2',
                        icon: Icons.badge_outlined,
                        keyboardType: TextInputType.number,
                      ),

                      const SizedBox(height: 14),

                      _PrimaryButton(
                        text: 'بدء المكالمة',
                        onPressed: startCall,
                      ),

                      const SizedBox(height: 30),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'جهات الاتصال',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _addContact,
                            icon: const Icon(Icons.person_add_alt_1, size: 18),
                            label: const Text('إضافة'),
                          ),
                        ],
                      ),

                      const SizedBox(height: 8),

                      if (_contacts.isEmpty)
                        _EmptyState(
                          icon: Icons.contacts_outlined,
                          text: 'لا توجد جهات اتصال',
                        )
                      else
                        ..._contacts.map(
                          (contact) => _ContactItem(
                            name: contact['name']!,
                            id: contact['id']!,
                            online: false,
                            onDelete: () => _deleteContact(contact['id']!),
                            onCall: () async {
                              callIdController.text = contact['id']!;

                              await startCall();
                            },
                          ),
                        ),

                      const SizedBox(height: 24),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'آخر المكالمات',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (_callHistory.isNotEmpty)
                            TextButton(
                              onPressed: _clearHistory,
                              child: const Text('مسح السجل'),
                            ),
                        ],
                      ),

                      const SizedBox(height: 8),

                      if (_callHistory.isEmpty)
                        _EmptyState(
                          icon: Icons.history,
                          text: 'لا يوجد سجل مكالمات',
                        )
                      else
                        ..._callHistory
                            .take(20)
                            .map(
                              (item) => _CallHistoryItem(
                                name:
                                    item['name']?.toString() ??
                                    'مستخدم CN CALL',
                                id: item['id']?.toString() ?? '',
                                time: item['time']?.toString() ?? '',
                                incoming: item['incoming'] == true,
                              ),
                            ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;

  const _EmptyState({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(icon, size: 36, color: Colors.grey.shade700),
          const SizedBox(height: 10),
          Text(text, style: TextStyle(color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}

Future<Map<String, String>?> _showAddContactDialog(BuildContext context) async {
  final idController = TextEditingController();
  final nameController = TextEditingController();

  final result = await showDialog<Map<String, String>>(
    context: context,
    builder: (dialogContext) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: const Color(0xFF151515),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text(
            'إضافة جهة اتصال',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: idController,
                keyboardType: TextInputType.number,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: 'ID المستخدم',
                  hintText: 'مثال: 2',
                  prefixIcon: const Icon(Icons.badge_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'اسم المستخدم',
                  hintText: 'مثال: هشام',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton.icon(
              onPressed: () {
                final id = idController.text.trim();
                final name = nameController.text.trim();

                if (id.isEmpty || int.tryParse(id) == null || name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('أدخل ID صحيحًا واسم المستخدم'),
                    ),
                  );
                  return;
                }

                Navigator.pop(dialogContext, {'id': id, 'name': name});
              },
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('إضافة'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
      );
    },
  );

  idController.dispose();
  nameController.dispose();

  return result;
}

class _ContactItem extends StatelessWidget {
  final String name;
  final String id;
  final bool online;
  final VoidCallback onDelete;
  final VoidCallback onCall;

  const _ContactItem({
    required this.name,
    required this.id,
    required this.online,
    required this.onDelete,
    required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: .04)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF00E676).withValues(alpha: .10),
            ),
            child: const Icon(Icons.person, color: Color(0xFF00E676)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'ID: $id',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'اتصال',
            onPressed: onCall,
            icon: const Icon(Icons.call, color: Color(0xFF00E676)),
          ),
          IconButton(
            tooltip: 'حذف',
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dialogContext) {
                  return AlertDialog(
                    backgroundColor: const Color(0xFF151515),
                    title: const Text(
                      'حذف جهة الاتصال',
                      textDirection: TextDirection.rtl,
                    ),
                    content: Text(
                      'هل تريد حذف $name؟',
                      textDirection: TextDirection.rtl,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('إلغاء'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade800,
                        ),
                        child: const Text('حذف'),
                      ),
                    ],
                  );
                },
              );

              if (confirmed == true) {
                onDelete();
              }
            },
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          ),
        ],
      ),
    );
  }
}

class CallScreen extends StatefulWidget {
  final String name;
  final String id;

  const CallScreen({super.key, required this.name, required this.id});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool muted = false;
  bool speaker = false;
  bool connected = false;
  bool? remoteOnline;
  int seconds = 0;

  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();

    final manager = RtcCallManager.instance;
    remoteOnline = manager.remoteOnline;

    manager.onRemoteAvailabilityChanged = (online) {
      if (!mounted) return;
      setState(() => remoteOnline = online);
    };

    manager.onConnected = () {
      if (!mounted) return;

      setState(() {
        connected = true;
      });

      _startTimer();
    };

    manager.onDisconnected = () {
      if (_closing) return;

      _closing = true;

      if (!mounted) return;

      _timer?.cancel();

      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    };

    if (manager.inCall) {
      connected = true;
      _startTimer();
    }
  }

  void _startTimer() {
    if (_timer != null) return;

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !connected) return;

      setState(() {
        seconds++;
      });
    });
  }

  String get durationText {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }

  Future<void> toggleMute() async {
    final value = !muted;

    await RtcCallManager.instance.mute(value);

    if (!mounted) return;

    setState(() {
      muted = value;
    });
  }

  Future<void> toggleSpeaker() async {
    final value = !speaker;

    await RtcCallManager.instance.setSpeaker(value);

    if (!mounted) return;

    setState(() {
      speaker = value;
    });
  }

  Future<void> endCall() async {
    if (_closing) return;

    _closing = true;

    await RtcCallManager.instance.hangup();

    if (!mounted) return;

    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();

    RtcCallManager.instance.onConnected = null;
    RtcCallManager.instance.onDisconnected = null;
    RtcCallManager.instance.onRemoteAvailabilityChanged = null;

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF050505),
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  const SizedBox(height: 24),

                  Row(
                    children: [
                      IconButton(
                        onPressed: endCall,
                        icon: const Icon(
                          Icons.keyboard_arrow_down,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                      const Expanded(
                        child: Center(
                          child: Text(
                            'CAFEE NET',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),

                  const Spacer(),

                  Container(
                    width: 128,
                    height: 128,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF00E676).withValues(alpha: .08),
                      border: Border.all(
                        color: const Color(0xFF00E676).withValues(alpha: .35),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00E676).withValues(alpha: .12),
                          blurRadius: 35,
                          spreadRadius: 8,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.person,
                      size: 62,
                      color: Color(0xFF00E676),
                    ),
                  ),

                  const SizedBox(height: 28),

                  Text(
                    widget.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 27,
                      fontWeight: FontWeight.w800,
                    ),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    'ID: ${widget.id}',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),

                  const SizedBox(height: 18),

                  Text(
                    durationText,
                    style: const TextStyle(
                      color: Color(0xFF00E676),
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),

                  const SizedBox(height: 8),

                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      connected
                          ? 'متصل حاليًا'
                          : 'يتم الاستقبال',
                      key: ValueKey('$connected-$remoteOnline'),
                      style: TextStyle(
                        color: connected
                            ? const Color(0xFF00E676)
                            : Colors.grey.shade500,
                        fontSize: 14,
                        fontWeight: connected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),

                  const Spacer(),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 34),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _CallControlButton(
                          icon: muted ? Icons.mic_off : Icons.mic_none,
                          label: muted ? 'إلغاء الكتم' : 'كتم',
                          active: muted,
                          onPressed: toggleMute,
                        ),
                        _CallControlButton(
                          icon: speaker ? Icons.volume_up : Icons.volume_down,
                          label: 'مكبر الصوت',
                          active: speaker,
                          onPressed: toggleSpeaker,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 34),

                  GestureDetector(
                    onTap: endCall,
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.red.shade700,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.red.withValues(alpha: .22),
                            blurRadius: 25,
                            spreadRadius: 3,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.call_end,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  Text(
                    'إنهاء المكالمة',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),

                  const SizedBox(height: 38),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;

  const _CallControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        IconButton(
          onPressed: onPressed,
          style: IconButton.styleFrom(
            backgroundColor: active
                ? const Color(0xFF00E676).withValues(alpha: .18)
                : const Color(0xFF151515),
            foregroundColor: active ? const Color(0xFF00E676) : Colors.white,
            fixedSize: const Size(58, 58),
          ),
          icon: Icon(icon),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
        ),
      ],
    );
  }
}

class _CallHistoryItem extends StatelessWidget {
  final String name;
  final String id;
  final String time;
  final bool incoming;

  const _CallHistoryItem({
    required this.name,
    required this.id,
    required this.time,
    required this.incoming,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF00E676).withValues(alpha: .10),
            ),
            child: Icon(
              incoming ? Icons.call_received : Icons.call_made,
              color: const Color(0xFF00E676),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'ID: $id',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            time,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// REGISTER
// ============================================================

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final userIdController = TextEditingController();

  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  bool hidePassword = true;
  bool hideConfirmPassword = true;

  @override
  void dispose() {
    userIdController.dispose();

    usernameController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> createAccount() async {
    final userId = userIdController.text.trim();
    final username = usernameController.text.trim();
    final password = passwordController.text;
    final confirmPassword = confirmPasswordController.text;

    if (userId.isEmpty ||
        username.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty) {
      _message('أكمل جميع البيانات');
      return;
    }

    if (int.tryParse(userId) == null) {
      _message('ID المستخدم يجب أن يكون أرقامًا فقط');
      return;
    }

    if (username.length < 3) {
      _message('اسم المستخدم يجب أن يكون 3 أحرف على الأقل');
      return;
    }

    if (password.length < 6) {
      _message('كلمة المرور يجب أن تكون 6 أحرف على الأقل');
      return;
    }

    if (password != confirmPassword) {
      _message('كلمتا المرور غير متطابقتين');
      return;
    }

    final result = await AccountApi.register(
      userId: userId,
      username: username,
      password: password,
    );

    if (!mounted) return;

    final success = result['success'] == true;
    final message =
        result['message']?.toString() ??
        (success ? 'تم إنشاء الحساب بنجاح' : 'تعذر إنشاء الحساب');

    _message(message, success: success);

    if (!success) return;

    await Future.delayed(const Duration(milliseconds: 700));

    if (!mounted) return;

    Navigator.pop(context);
  }

  void _message(String text, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: success
            ? const Color(0xFF00A85A)
            : Colors.red.shade800,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 40),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: Column(
                  children: [
                    _Logo(),

                    const SizedBox(height: 22),

                    const Text(
                      'إنشاء حساب',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                      ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      'أنشئ حسابك في CN CALL',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 14,
                      ),
                    ),

                    const SizedBox(height: 34),

                    _Field(
                      controller: userIdController,
                      label: 'ID المستخدم',
                      hint: 'الرقم الذي تستخدمه لتسجيل الدخول والتواصل',
                      icon: Icons.badge_outlined,
                      keyboardType: TextInputType.number,
                    ),

                    const SizedBox(height: 16),

                    _Field(
                      controller: usernameController,
                      label: 'اسم المستخدم',
                      hint: 'الاسم الذي سيظهر للآخرين أثناء المكالمة',
                      icon: Icons.person_outline,
                    ),

                    const SizedBox(height: 16),

                    _Field(
                      controller: passwordController,
                      label: 'كلمة المرور',
                      hint: '6 أحرف على الأقل',
                      icon: Icons.lock_outline,
                      obscureText: hidePassword,
                      suffix: IconButton(
                        onPressed: () {
                          setState(() {
                            hidePassword = !hidePassword;
                          });
                        },
                        icon: Icon(
                          hidePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    _Field(
                      controller: confirmPasswordController,
                      label: 'تأكيد كلمة المرور',
                      hint: 'أعد كتابة كلمة المرور',
                      icon: Icons.lock_reset_outlined,
                      obscureText: hideConfirmPassword,
                      suffix: IconButton(
                        onPressed: () {
                          setState(() {
                            hideConfirmPassword = !hideConfirmPassword;
                          });
                        },
                        icon: Icon(
                          hideConfirmPassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    _PrimaryButton(
                      text: 'إنشاء الحساب',
                      onPressed: createAccount,
                    ),

                    const SizedBox(height: 16),

                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'لدي حساب بالفعل',
                        style: TextStyle(color: Color(0xFF00E676)),
                      ),
                    ),

                    const SizedBox(height: 20),

                    _Footer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SHARED UI
// ============================================================

class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF00E676).withValues(alpha: .10),
        border: Border.all(color: const Color(0xFF00E676), width: 2),
      ),
      child: const Icon(Icons.call, size: 40, color: Color(0xFF00E676)),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final Widget? suffix;

  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textDirection: TextDirection.ltr,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFF151515),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Color(0xFF00E676)),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback onPressed;

  const _PrimaryButton({required this.text, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF00E676),
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'CAFEE NET',
          style: TextStyle(
            color: Colors.grey.shade800.withValues(alpha: .45),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.2,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          'هشام الريمي',
          style: TextStyle(
            color: Colors.grey.shade800.withValues(alpha: .35),
            fontSize: 9,
            fontWeight: FontWeight.w500,
            letterSpacing: .8,
          ),
        ),
      ],
    );
  }
}
