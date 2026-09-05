import 'package:flutter/material.dart';

/// The one CN CALL incoming-call presentation, shared by the normal UI and
/// the dedicated cold-start call Activity.
class IncomingCallScreen extends StatefulWidget {
  final String name;
  final String id;
  final String callId;
  final Future<void> Function() onAccept;
  final Future<void> Function() onReject;
  final Future<void> Function(bool muted)? onMute;

  const IncomingCallScreen({super.key, required this.name, required this.id, required this.callId, required this.onAccept, required this.onReject, this.onMute});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  bool muted = false;
  bool _busy = false;

  Future<void> _accept() async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await widget.onAccept(); } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _reject() async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await widget.onReject(); } finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF050505),
        body: SafeArea(
          child: Column(children: [
            const SizedBox(height: 50),
            Text('مكالمة واردة', style: TextStyle(color: Colors.grey.shade500, fontSize: 15, fontWeight: FontWeight.w600)),
            const Spacer(),
            Container(width: 140, height: 140, decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF00E676).withValues(alpha: .08), border: Border.all(color: const Color(0xFF00E676).withValues(alpha: .35), width: 2), boxShadow: [BoxShadow(color: const Color(0xFF00E676).withValues(alpha: .12), blurRadius: 40, spreadRadius: 10)]), child: const Icon(Icons.person, size: 68, color: Color(0xFF00E676))),
            const SizedBox(height: 28),
            Text(widget.name, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('ID: ${widget.id}', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const SizedBox(height: 16),
            Text('يتصل بك الآن...', style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
            const Spacer(),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              Column(children: [GestureDetector(onTap: _reject, child: Container(width: 70, height: 70, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.red.shade700, boxShadow: [BoxShadow(color: Colors.red.withValues(alpha: .20), blurRadius: 25, spreadRadius: 3)]), child: const Icon(Icons.call_end, color: Colors.white, size: 32))), const SizedBox(height: 12), Text('رفض', style: TextStyle(color: Colors.grey.shade600, fontSize: 12))]),
              Column(children: [GestureDetector(onTap: _accept, child: Container(width: 70, height: 70, decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF00C853), boxShadow: [BoxShadow(color: const Color(0xFF00E676).withValues(alpha: .22), blurRadius: 25, spreadRadius: 3)]), child: const Icon(Icons.call, color: Colors.white, size: 32))), const SizedBox(height: 12), Text('قبول', style: TextStyle(color: Colors.grey.shade600, fontSize: 12))]),
            ]),
            const SizedBox(height: 20),
            TextButton.icon(onPressed: widget.onMute == null ? null : () async { final next = !muted; await widget.onMute!(next); if (mounted) setState(() => muted = next); }, icon: Icon(muted ? Icons.mic_off : Icons.mic), label: Text(muted ? 'إلغاء الكتم' : 'كتم')),
            const SizedBox(height: 28),
            Text('CN CALL', style: TextStyle(color: Colors.grey.shade800.withValues(alpha: .45), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2)),
            const SizedBox(height: 28),
          ]),
        ),
      ),
    );
  }
}
