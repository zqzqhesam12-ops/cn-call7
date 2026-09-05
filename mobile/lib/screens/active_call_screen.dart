import 'dart:async';

import 'package:flutter/material.dart';

class ActiveCallScreen extends StatefulWidget {
  final String name;
  final String id;
  final Future<void> Function(bool muted) onMute;
  final Future<void> Function(bool speaker) onSpeaker;
  final Future<void> Function() onEnd;

  const ActiveCallScreen({
    super.key,
    required this.name,
    required this.id,
    required this.onMute,
    required this.onSpeaker,
    required this.onEnd,
  });

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  Timer? _timer;
  int _seconds = 0;
  bool _muted = false;
  bool _speakerEnabled = false;
  bool _busy = false;
  bool _keypad = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() => _seconds++);
      },
    );
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

  Future<void> _mute() async {
    if (_busy) return;
    final next = !_muted;
    await widget.onMute(next);
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _toggleSpeaker() async {
    if (_busy) return;
    final next = !_speakerEnabled;
    await widget.onSpeaker(next);
    if (mounted) setState(() => _speakerEnabled = next);
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
              const SizedBox(height: 22),

              Row(
                children: [
                  IconButton(
                    onPressed: _end,
                    icon: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Colors.white.withValues(alpha: .85),
                      size: 30,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'CN CALL',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
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
                    fontSize: 52,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),

              const SizedBox(height: 24),

              Text(
                safeName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 29,
                  fontWeight: FontWeight.w800,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                _duration,
                style: const TextStyle(
                  color: Color(0xFF35E890),
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                'متصل حاليًا',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: .48),
                  fontSize: 13,
                ),
              ),

              const Spacer(),

              if (_keypad)
                _DialPad(
                  onClose: () => setState(() => _keypad = false),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 22,
                    runSpacing: 18,
                    children: [
                      _Control(
                        icon: _muted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        label: _muted ? 'إلغاء الكتم' : 'كتم',
                        active: _muted,
                        onTap: _mute,
                      ),
                      _Control(
                        icon: _speakerEnabled
                            ? Icons.volume_up_rounded
                            : Icons.volume_down_rounded,
                        label: 'مكبر الصوت',
                        active: _speakerEnabled,
                        onTap: _toggleSpeaker,
                      ),
                      _Control(
                        icon: Icons.dialpad_rounded,
                        label: 'لوحة المفاتيح',
                        onTap: () => setState(() => _keypad = true),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 28),

              GestureDetector(
                onTap: _end,
                child: Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFFF4D5A),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFF4D5A).withValues(alpha: .22),
                        blurRadius: 30,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.call_end_rounded,
                    color: Colors.white,
                    size: 33,
                  ),
                ),
              ),

              const SizedBox(height: 10),

              Text(
                'إنهاء المكالمة',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: .43),
                  fontSize: 12,
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _Control extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _Control({
    required this.icon,
    required this.label,
    this.active = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 94,
      child: Column(
        children: [
          IconButton.filled(
            onPressed: onTap,
            style: IconButton.styleFrom(
              backgroundColor: active
                  ? const Color(0xFF35E890).withValues(alpha: .18)
                  : const Color(0xFF15191B),
              foregroundColor:
                  active ? const Color(0xFF35E890) : Colors.white,
              fixedSize: const Size(58, 58),
            ),
            icon: Icon(icon),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: .48),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _DialPad extends StatelessWidget {
  final VoidCallback onClose;

  const _DialPad({required this.onClose});

  @override
  Widget build(BuildContext context) {
    const keys = <String>[
      '1', '2', '3',
      '4', '5', '6',
      '7', '8', '9',
      '*', '0', '#',
    ];

    return Column(
      children: [
        IconButton(
          onPressed: onClose,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        GridView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: 50),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: keys.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 1.25,
          ),
          itemBuilder: (_, index) {
            return Center(
              child: Text(
                keys[index],
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w400,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
