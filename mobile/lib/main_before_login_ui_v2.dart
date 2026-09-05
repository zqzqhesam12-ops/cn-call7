import 'package:flutter/material.dart';

void main() {
  runApp(const CNCallApp());
}

class CNCallApp extends StatelessWidget {
  const CNCallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CN CALL',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF05070A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  bool obscurePassword = true;

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  void login() {
    final username = usernameController.text.trim();

    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل اسم المستخدم')),
      );
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => HomeScreen(username: username),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF00E676).withValues(alpha: .12),
                    border: Border.all(
                      color: const Color(0xFF00E676),
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    Icons.call,
                    color: Color(0xFF00E676),
                    size: 44,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'CN CALL',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'مكالمات صوتية بدون أرقام هاتف',
                  style: TextStyle(
                    color: Colors.grey.shade400,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 40),
                TextField(
                  controller: usernameController,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: 'اسم المستخدم',
                    prefixIcon: const Icon(Icons.person_outline),
                    filled: true,
                    fillColor: const Color(0xFF12161B),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: passwordController,
                  obscureText: obscurePassword,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: 'كلمة المرور',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() {
                          obscurePassword = !obscurePassword;
                        });
                      },
                      icon: Icon(
                        obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                    ),
                    filled: true,
                    fillColor: const Color(0xFF12161B),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton(
                    onPressed: login,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00E676),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: const Text(
                      'تسجيل الدخول',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextButton(
                  onPressed: () {},
                  child: const Text('إنشاء حساب جديد'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  final String username;

  const HomeScreen({super.key, required this.username});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'CN CALL',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF12161B),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: const Color(0xFF00E676).withValues(alpha: .25),
              ),
            ),
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 28,
                  backgroundColor: Color(0xFF00E676),
                  child: Icon(
                    Icons.person,
                    color: Colors.black,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        username,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Row(
                        children: [
                          Icon(
                            Icons.circle,
                            color: Color(0xFF00E676),
                            size: 10,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'متصل الآن',
                            style: TextStyle(
                              color: Color(0xFF00E676),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'الأصدقاء',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),
          _friend(
            context,
            'أحمد',
            'CN000001',
            true,
          ),
          _friend(
            context,
            'صديق جديد',
            'CN000002',
            false,
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('إضافة مستخدم'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              side: const BorderSide(color: Color(0xFF00E676)),
              foregroundColor: const Color(0xFF00E676),
            ),
          ),
        ],
      ),
    );
  }

  Widget _friend(
    BuildContext context,
    String name,
    String id,
    bool online,
  ) {
    return Card(
      color: const Color(0xFF12161B),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 5,
        ),
        leading: CircleAvatar(
          backgroundColor: Colors.grey.shade800,
          child: Text(name.substring(0, 1)),
        ),
        title: Text(name),
        subtitle: Text(id),
        trailing: IconButton(
          onPressed: online
              ? () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CallScreen(name: name),
                    ),
                  );
                }
              : null,
          icon: const Icon(Icons.call),
          color: const Color(0xFF00E676),
        ),
      ),
    );
  }
}

class CallScreen extends StatelessWidget {
  final String name;

  const CallScreen({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            const CircleAvatar(
              radius: 65,
              backgroundColor: Color(0xFF12161B),
              child: Icon(
                Icons.person,
                size: 70,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              name,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'جاري الاتصال...',
              style: TextStyle(color: Colors.grey),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(30),
              child: FloatingActionButton.large(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                onPressed: () => Navigator.pop(context),
                child: const Icon(Icons.call_end),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
