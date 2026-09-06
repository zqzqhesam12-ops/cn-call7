import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'server_config.dart';

class CallSocket {
  WebSocketChannel? _channel;
  String? _userId;
  String? _token;
  Timer? _reconnectTimer;
  bool _connecting = false;
  Completer<void>? _readyCompleter;
  bool _reconnectEnabled = true;
  int _reconnectAttempt = 0;
  int _connectionGeneration = 0;
  bool _ready = false;
  Future<void> Function()? onSessionInvalid;

  /// True only after the WebSocket handshake completed.  A non-null channel
  /// merely means that a connection attempt was created; it cannot carry a
  /// call control message yet.
  bool get connected => _channel != null && _ready;

  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messages.stream;

  Future<void> connect(String userId, String token) async {
    if (connected && _userId == userId && _token == token) return;
    if (_connecting) return _readyCompleter?.future ?? Future<void>.value();
    _userId = userId;
    _token = token;
    _reconnectEnabled = true;

    _connecting = true;
    _readyCompleter = Completer<void>();
    final generation = ++_connectionGeneration;

    final channel = WebSocketChannel.connect(
      Uri.parse('${ServerConfig.websocketUrl(userId)}?token=$token'),
    );

    try {
      await channel.ready;

      // logout/reconnect may have superseded this asynchronous connection
      // attempt while it was waiting for `ready`.
      if (generation != _connectionGeneration ||
          !_reconnectEnabled ||
          _userId != userId ||
          _token != token) {
        await channel.sink.close();
        return;
      }

      _channel = channel;
      _ready = true;
      _connecting = false;
      _reconnectAttempt = 0;
      _readyCompleter?.complete();
      _readyCompleter = null;

      print('SOCKET CONNECTED: ${ServerConfig.websocketUrl(userId)}');
      _flushPendingMessages();

      channel.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message);

            if (data is Map) {
              final parsed = Map<String, dynamic>.from(data);

              if (parsed['type'] == 'session_invalid') {
                _handleSessionInvalid();
                return;
              }

              print(
                'SOCKET RECEIVE: type=${parsed['type']} '
                'call_id=${parsed['call_id']}',
              );

              _messages.add(parsed);
            }
          } catch (e) {
            print('SOCKET JSON ERROR: $e');
          }
        },
        onDone: () {
          print('SOCKET CLOSED');

          if (identical(_channel, channel)) {
            _channel = null;
            _ready = false;
            if (_reconnectEnabled) _scheduleReconnect();
          }
        },
        onError: (error, stackTrace) {
          print('SOCKET ERROR: $error');

          if (identical(_channel, channel)) {
            _channel = null;
            _ready = false;
            if (_reconnectEnabled) _scheduleReconnect();
          }
        },
        cancelOnError: false,
      );
    } catch (e) {
      print('SOCKET CONNECT ERROR: $e');

      await channel.sink.close();

      if (identical(_channel, channel)) {
        _channel = null;
        _ready = false;
      }

      if (generation == _connectionGeneration) {
        _connecting = false;
        _readyCompleter?.completeError(e);
        _readyCompleter = null;
        if (_reconnectEnabled) _scheduleReconnect();
      }

      rethrow;
    }
  }

  void _scheduleReconnect() {
    final userId = _userId;
    final token = _token;
    if (!_reconnectEnabled ||
        userId == null ||
        userId.isEmpty ||
        token == null ||
        token.isEmpty ||
        _reconnectTimer != null) {
      return;
    }

    final delaySeconds = 1 << (_reconnectAttempt.clamp(0, 5));
    _reconnectAttempt++;

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      _reconnectTimer = null;
      try {
        await connect(userId, token);
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  void _flushPendingMessages() {
    // Control messages must not be replayed after reconnect.
  }
  Future<void> sendGuaranteed(Map<String, dynamic> data) async {
    final channel = _channel;

    print('SOCKET SEND: type=${data['type']} call_id=${data['call_id']}');

    if (channel == null || !_ready) {
      throw StateError('CN CALL socket is not ready');
    }
    channel.sink.add(jsonEncode(data));
  }

  /// Non-critical callers may deliberately use best-effort signalling.
  void send(Map<String, dynamic> data) {
    sendGuaranteed(data).catchError((Object error) {
      print('SOCKET SEND FAILED: $error');
    });
  }

  void disconnect() {
    _connectionGeneration++;
    _connecting = false;
    _readyCompleter?.complete();
    _readyCompleter = null;
    _reconnectEnabled = false;
    _userId = null;
    _token = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _channel?.sink.close();
    _channel = null;
    _ready = false;
  }

  Future<void> dispose() async {
    _connectionGeneration++;
    _connecting = false;
    _reconnectEnabled = false;
    await _messages.close();

    _userId = null;
    _token = null;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _ready = false;
  }

  void _handleSessionInvalid() {
    _connectionGeneration++;
    _reconnectEnabled = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connecting = false;
    final channel = _channel;
    _channel = null;
    _ready = false;
    channel?.sink.close();
    onSessionInvalid?.call();
  }
}
