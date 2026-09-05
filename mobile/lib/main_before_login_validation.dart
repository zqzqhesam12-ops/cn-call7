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
        scaffoldBackgroundColor: const Color(0xFF050505),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
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
      MaterialPageRoute(
        builder: (_) => const RegisterScreen(),
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
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 40,
              ),
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

                    _PrimaryButton(
                      text: 'تسجيل الدخول',
                      onPressed: () {},
                    ),

                    const SizedBox(height: 12),

                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton(
                        onPressed: openRegister,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.grey.shade800,
                          ),
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

  void createAccount() {
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

    _message('تم تجهيز الحساب بنجاح', success: true);

    Future.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      Navigator.pop(context);
    });
  }

  void _message(String text, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor:
            success ? const Color(0xFF00A85A) : Colors.red.shade800,
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
                            hideConfirmPassword =
                                !hideConfirmPassword;
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
                        style: TextStyle(
                          color: Color(0xFF00E676),
                        ),
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
        border: Border.all(
          color: const Color(0xFF00E676),
          width: 2,
        ),
      ),
      child: const Icon(
        Icons.call,
        size: 40,
        color: Color(0xFF00E676),
      ),
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
          borderSide: const BorderSide(
            color: Color(0xFF00E676),
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback onPressed;

  const _PrimaryButton({
    required this.text,
    required this.onPressed,
  });

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
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Text(
      'CN CALL',
      style: TextStyle(
        color: Colors.grey.shade700,
        fontSize: 12,
        letterSpacing: 1.5,
      ),
    );
  }
}
