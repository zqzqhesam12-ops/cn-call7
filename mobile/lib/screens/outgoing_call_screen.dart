import 'dart:async';

import 'package:flutter/material.dart';

class OutgoingCallScreen extends StatefulWidget {
  final String name;
  final String id;
  final Future<void> Function() onEnd;
  final bool connected;
  final bool remoteOnline;

  const OutgoingCallScreen({
    super.key,
    required this.name,
    required this.id,
    required this.onEnd,
    this.connected = false,
    this.remoteOnline = false,
  });

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  Timer? _timer;
  int _seconds = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _duration {
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  Future<void> _end() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onEnd();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeName = widget.name.trim().isEmpty ? widget.id : widget.name;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF050607),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 42),
              Text(
                widget.connected ? 'متصل' : 'جارٍ الاتصال',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: .65),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),

              Hero(
                tag: 'outgoing-avatar-${widget.id}',
                child: Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF15191B),
                    border: Border.all(
                      color: const Color(0xFF35E890).withValues(alpha: .28),
                      width: 2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    safeName.characters.first.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 54,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              Text(
                safeName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                widget.id,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: .4),
                  fontSize: 14,
                ),
              ),

              const SizedBox(height: 18),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  widget.connected
                      ? _duration
                      : widget.remoteOnline
                          ? 'يرن الآن...'
                          : 'جاري الوصول للطرف الآخر...',
                  key: ValueKey(
                    '${widget.connected}-${widget.remoteOnline}-$_duration',
                  ),
                  style: const TextStyle(
                    color: Color(0xFF35E890),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),

              const Spacer(),

              GestureDetector(
                onTap: _end,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFFF4D5A),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFF4D5A).withValues(alpha: .22),
                        blurRadius: 28,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.call_end_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),

              const SizedBox(height: 12),

              Text(
                'إنهاء',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: .45),
                  fontSize: 12,
                ),
              ),

              const SizedBox(height: 42),
            ],
          ),
        ),
      ),
    );
  }
}
