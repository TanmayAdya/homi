import 'package:flutter/material.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/session_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.session,
    required this.emailDeliveryEnabled,
    this.deletionStatusScreen,
  });
  final SessionService session;
  final bool emailDeliveryEnabled;
  final Widget? deletionStatusScreen;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController(), _password = TextEditingController();
  bool _busy = false, _passwordVisible = false;
  String? _message;
  int _feedbackRevision = 0;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit({bool recovery = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _feedbackRevision++;
    });
    try {
      if (recovery) {
        await widget.session.requestRecovery(_email.text);
        if (mounted) {
          setState(
            () => _message =
                'If this address can receive beta recovery email, a link will arrive shortly.',
          );
        }
      } else if (widget.session.recoveryRequired) {
        if (_password.text.length < 12) throw const FormatException();
        await widget.session.updatePassword(_password.text);
      } else {
        await widget.session.signIn(_email.text, _password.text);
      }
      if (!mounted) return;
      _password.clear();
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = widget.session.recoveryRequired
              ? 'Use a password with at least 12 characters. If the link expired, request another.'
              : 'Sign-in could not be completed. Check your account details and connection.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _clearFeedback(String _) {
    if (_message != null) setState(() => _message = null);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Safe at Home')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: ExcludeSemantics(
                      child: Icon(
                        Icons.home_outlined,
                        size: 30,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
                SahPageHeader(
                  title: widget.session.recoveryRequired
                      ? 'Choose a new password'
                      : 'Welcome back',
                  description: widget.session.recoveryRequired
                      ? 'Set a new password to return to your private workspace.'
                      : 'Sign in to continue your home assessment and draft preparation.',
                ),
                const SahNotice(
                  title: 'Private team beta',
                  message:
                      'Use fictional resident information during the team beta.',
                  icon: Icons.lock_outline_rounded,
                ),
                const SizedBox(height: 24),
                if (!widget.session.recoveryRequired)
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.none,
                    autofillHints: const [AutofillHints.username],
                    enabled: !_busy,
                    onChanged: _clearFeedback,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.alternate_email_rounded),
                    ),
                  ),
                if (!widget.session.recoveryRequired)
                  const SizedBox(height: 20),
                TextField(
                  controller: _password,
                  obscureText: !_passwordVisible,
                  textInputAction: TextInputAction.done,
                  enableSuggestions: false,
                  autocorrect: false,
                  autofillHints: [
                    widget.session.recoveryRequired
                        ? AutofillHints.newPassword
                        : AutofillHints.password,
                  ],
                  enabled: !_busy,
                  onChanged: _clearFeedback,
                  decoration: InputDecoration(
                    labelText: widget.session.recoveryRequired
                        ? 'New password (12+ characters)'
                        : 'Password',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      tooltip: _passwordVisible
                          ? 'Hide password'
                          : 'Show password',
                      onPressed: _busy
                          ? null
                          : () => setState(
                              () => _passwordVisible = !_passwordVisible,
                            ),
                      icon: Icon(
                        _passwordVisible
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const ValueKey('auth-sign-in'),
                  onPressed: _busy ? null : () => _submit(),
                  child: Text(
                    _busy
                        ? 'Please wait…'
                        : widget.session.recoveryRequired
                        ? 'Save password'
                        : 'Sign in',
                  ),
                ),
                if (widget.emailDeliveryEnabled &&
                    !widget.session.recoveryRequired)
                  TextButton(
                    onPressed: _busy ? null : () => _submit(recovery: true),
                    child: const Text('Forgot password'),
                  ),
                if (_message != null)
                  SahActionFeedback(
                    key: const ValueKey('auth-action-feedback'),
                    message: _message!,
                    revealRevision: _feedbackRevision,
                    tone: SahNoticeTone.warning,
                  ),
                if (!widget.emailDeliveryEnabled)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text(
                      'Sign in with your provisioned team account. Email registration and recovery are not enabled for this beta.',
                    ),
                  ),
                if (widget.deletionStatusScreen != null)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => widget.deletionStatusScreen!,
                      ),
                    ),
                    child: const Text('Check pending account deletion'),
                  ),
                if (widget.session.callbackNotice != null)
                  SahNotice(
                    message: widget.session.callbackNotice!,
                    tone: SahNoticeTone.warning,
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
