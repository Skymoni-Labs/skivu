import 'package:flutter/material.dart';
import 'relay_account.dart';
import 'state.dart';

class NativeLoginForm extends StatefulWidget {
  const NativeLoginForm({super.key, required this.browserLogin});
  final VoidCallback browserLogin;
  @override
  State<NativeLoginForm> createState() => _NativeLoginFormState();
}

class _NativeLoginFormState extends State<NativeLoginForm> {
  final username = TextEditingController(),
      password = TextEditingController(),
      code = TextEditingController();
  bool reveal = false;
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> login() async {
    if (relayAccount.verificationFlow != null) {
      await relayAccount.verifySignIn(code.text);
      if (mounted) code.clear();
    } else {
      try {
        await relayAccount.signIn(username.text, password.text);
      } finally {
        if (mounted) password.clear();
      }
    }
    if (relayAccount.signedIn) {
      demo.useAccount = true;
      demo.useBeta = false;
      demo.changed();
      await demo.saveChats();
    }
  }

  @override
  Widget build(BuildContext context) => AutofillGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (relayAccount.verificationFlow == null) ...[
          TextField(
            key: const ValueKey('account-username'),
            controller: username,
            enabled: !relayAccount.busy,
            autofillHints: const [AutofillHints.username],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '账号',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('account-password'),
            controller: password,
            enabled: !relayAccount.busy,
            obscureText: !reveal,
            enableSuggestions: false,
            autocorrect: false,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => login(),
            decoration: InputDecoration(
              labelText: '密码',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                tooltip: reveal ? '隐藏密码' : '显示密码',
                onPressed: () => setState(() => reveal = !reveal),
                icon: Icon(
                  reveal
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
        ] else ...[
          const Text('完成账号安全验证'),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('account-mfa'),
            controller: code,
            enabled: !relayAccount.busy,
            autofocus: true,
            autofillHints: const [AutofillHints.oneTimeCode],
            decoration: const InputDecoration(labelText: '动态验证码或备用码'),
            onSubmitted: (_) => login(),
          ),
        ],
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed:
              relayAccount.busy ||
                  (relayAccount.verificationFlow != null &&
                      relayAccount.needsBrowser)
              ? null
              : login,
          icon: const Icon(Icons.login),
          label: Text(
            relayAccount.busy
                ? '正在登录'
                : relayAccount.verificationFlow != null
                ? '验证并登录'
                : '登录中转站账号',
          ),
        ),
        const SizedBox(height: 8),
        if (relayAccount.verificationFlow != null)
          TextButton(
            onPressed: relayAccount.busy
                ? null
                : () {
                    relayAccount.cancelVerification();
                    code.clear();
                  },
            child: const Text('换个账号登录'),
          ),
        TextButton(
          onPressed: relayAccount.busy ? null : widget.browserLogin,
          child: Text(relayAccount.needsBrowser ? '在网页完成额外安全验证' : '其他方式：网页登录'),
        ),
        const Text(
          '密码仅用于本次登录，不保存到 App；登录会话存入系统安全存储。',
          style: TextStyle(fontSize: 11, color: ink),
        ),
      ],
    ),
  );
}
