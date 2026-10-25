import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;
import '../../app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/session_service.dart';
import '../settings/language_section.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.session,
    required this.emailDeliveryEnabled,
    this.publicSignupEnabled = false,
    this.deletionStatusScreen,
  });
  final SessionService session;
  final bool emailDeliveryEnabled;
  final bool publicSignupEnabled;
  final Widget? deletionStatusScreen;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController(),
      _password = TextEditingController(),
      _confirmation = TextEditingController();
  bool _busy = false, _passwordVisible = false;
  bool _signingUp = false, _confirmationRequested = false;
  bool _success = false;
  bool _emailInstructions = false;
  Timer? _cooldown;
  int _secondsRemaining = 0;
  bool get _signupAvailable =>
      widget.publicSignupEnabled && widget.emailDeliveryEnabled;
  String? _message;
  int _feedbackRevision = 0;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    _cooldown?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    _cooldown?.cancel();
    setState(() => _secondsRemaining = 60);
    _cooldown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _secondsRemaining <= 1) {
        timer.cancel();
        if (mounted) setState(() => _secondsRemaining = 0);
      } else {
        setState(() => _secondsRemaining--);
      }
    });
  }

  Future<void> _submit({bool recovery = false, bool resend = false}) async {
    if (_busy) return;
    final creating =
        _signingUp && !widget.session.recoveryRequired && !resend && !recovery;
    final emailAction = recovery || resend || creating;
    if (emailAction && _secondsRemaining > 0) return;
    setState(() {
      _busy = true;
      _message = null;
      _success = false;
      _emailInstructions = false;
      _feedbackRevision++;
    });
    try {
      FocusScope.of(context).unfocus();
      if (emailAction && !isAccountEmail(_email.text)) {
        throw const FormatException('email');
      }
      if (creating &&
          (_password.text.length < 12 ||
              _password.text != _confirmation.text)) {
        throw const FormatException('password');
      }
      if (recovery) {
        await widget.session.requestRecovery(_email.text);
        if (mounted) {
          setState(
            () => _message =
                'If an account can receive email at this address, a password reset link will arrive shortly.',
          );
        }
      } else if (resend || creating) {
        if (!_signupAvailable) throw StateError('Signup is unavailable.');
        if (resend) {
          await widget.session.resendConfirmation(_email.text);
        } else {
          await widget.session.createAccount(_email.text, _password.text);
        }
        if (mounted) {
          setState(() {
            _confirmationRequested = true;
            _message =
                'Check your email for a confirmation link. If you already have an account, sign in or reset your password.';
          });
        }
      } else if (widget.session.recoveryRequired) {
        if (_password.text.length < 12) throw const FormatException();
        await widget.session.updatePassword(_password.text);
      } else {
        await widget.session.signIn(_email.text, _password.text);
      }
      if (!mounted) return;
      if (emailAction) _startCooldown();
      setState(() {
        _success = true;
        _emailInstructions = emailAction;
      });
      _password.clear();
      _confirmation.clear();
    } catch (error) {
      if (mounted) {
        final throttled =
            error is AuthEmailCooldownException ||
            (error is AuthException &&
                (error.statusCode == '429' ||
                    error.code == 'over_email_send_rate_limit' ||
                    error.code == 'over_request_rate_limit'));
        if (throttled) _startCooldown();
        setState(() {
          if (error is FormatException && error.message == 'email') {
            _message = 'Enter a valid email address.';
          } else if (error is FormatException && creating) {
            _message =
                'Use at least 12 characters and make sure both passwords match.';
          } else if (throttled) {
            _message = 'Please wait before requesting another email.';
          } else if (error is AuthException &&
              error.code == 'email_not_confirmed' &&
              _signupAvailable) {
            _confirmationRequested = true;
            _message =
                'Confirm your email before signing in. You can request a new confirmation link below.';
          } else {
            _message = widget.session.recoveryRequired
                ? 'Use a password with at least 12 characters. If the link expired, request another.'
                : creating || resend
                ? 'Account creation could not be completed. Check your details and connection, or try signing in.'
                : recovery
                ? 'Password reset could not be requested. Check your email address and connection.'
                : 'Sign-in could not be completed. Check your account details and connection.';
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _clearFeedback(String _) {
    if (_message != null || _emailInstructions) {
      setState(() {
        _message = null;
        _emailInstructions = false;
      });
    }
  }

  void _switchMode() {
    setState(() {
      _signingUp = !_signingUp;
      _confirmationRequested = false;
      _message = null;
      _emailInstructions = false;
      _passwordVisible = false;
      _password.clear();
      _confirmation.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recovering = widget.session.recoveryRequired;
    final awaitingConfirmation =
        _confirmationRequested && _signingUp && !recovering;
    return Scaffold(
      appBar: AppBar(
        actions: const [LanguageButton()],
        title: Row(
          children: [
            const SahBrandMark(size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Safe at Home',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: SahContent(
          maxWidth: 480,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final showIllustration =
                        !recovering &&
                        constraints.maxWidth >= 330 &&
                        MediaQuery.textScalerOf(context).scale(16) <= 22.4;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.6,
                            child: Semantics(
                              header: true,
                              child: Text(
                                recovering
                                    ? context.tr('Choose a new password')
                                    : _signingUp
                                    ? context.tr('Create your account')
                                    : context.tr('Welcome back'),
                                style: theme.textTheme.headlineLarge,
                              ),
                            ),
                          ),
                        ),
                        if (showIllustration) ...[
                          const SizedBox(width: 12),
                          const SizedBox(
                            width: 80,
                            child: SahHomeIllustration(height: 72),
                          ),
                        ],
                      ],
                    );
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  recovering
                      ? context.tr('Choose a new password.')
                      : _signingUp
                      ? context.tr(
                          'Create an account to save and return to your home plan.',
                        )
                      : context.tr('Sign in to continue.'),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(SahRadius.large),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 2.0,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!recovering)
                          TextField(
                            key: const ValueKey('login-email'),
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            autocorrect: false,
                            textCapitalization: TextCapitalization.none,
                            autofillHints: const [AutofillHints.username],
                            enabled: !_busy,
                            onChanged: (value) {
                              _clearFeedback(value);
                              if (_confirmationRequested) {
                                setState(() => _confirmationRequested = false);
                              }
                            },
                            decoration: InputDecoration(
                              label: Text(context.tr('Email')),
                              prefixIcon: Icon(Icons.alternate_email_rounded),
                            ),
                          ),
                        if (!recovering) const SizedBox(height: 20),
                        if (!awaitingConfirmation)
                          TextField(
                            key: const ValueKey('login-password'),
                            controller: _password,
                            obscureText: !_passwordVisible,
                            textInputAction: TextInputAction.done,
                            enableSuggestions: false,
                            autocorrect: false,
                            autofillHints: [
                              recovering || _signingUp
                                  ? AutofillHints.newPassword
                                  : AutofillHints.password,
                            ],
                            enabled: !_busy,
                            onChanged: _clearFeedback,
                            decoration: InputDecoration(
                              label: Text(
                                recovering
                                    ? context.tr(
                                        'New password (12+ characters)',
                                      )
                                    : _signingUp
                                    ? context.tr('Password (12+ characters)')
                                    : context.tr('Password'),
                              ),
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                              ),
                              suffixIcon: IconButton(
                                tooltip: _passwordVisible
                                    ? context.tr('Hide password')
                                    : context.tr('Show password'),
                                onPressed: _busy
                                    ? null
                                    : () => setState(
                                        () => _passwordVisible =
                                            !_passwordVisible,
                                      ),
                                icon: Icon(
                                  _passwordVisible
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                              ),
                            ),
                            onSubmitted: _signingUp && !recovering
                                ? null
                                : (_) => _submit(),
                          ),
                        if (_signingUp &&
                            !recovering &&
                            !awaitingConfirmation) ...[
                          const SizedBox(height: 20),
                          TextField(
                            key: const ValueKey('signup-confirm-password'),
                            controller: _confirmation,
                            obscureText: !_passwordVisible,
                            enableSuggestions: false,
                            autocorrect: false,
                            autofillHints: const [AutofillHints.newPassword],
                            textInputAction: TextInputAction.done,
                            enabled: !_busy,
                            onChanged: _clearFeedback,
                            onSubmitted: (_) => _submit(),
                            decoration: InputDecoration(
                              label: Text(context.tr('Confirm password')),
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        if (!awaitingConfirmation)
                          FilledButton(
                            key: const ValueKey('auth-sign-in'),
                            onPressed:
                                _busy ||
                                    (_signingUp &&
                                        !recovering &&
                                        _secondsRemaining > 0)
                                ? null
                                : () => _submit(),
                            child: Text(
                              _busy
                                  ? context.tr('Please wait…')
                                  : recovering
                                  ? context.tr('Save password')
                                  : _signingUp
                                  ? context.tr('Create account')
                                  : context.tr('Sign in'),
                            ),
                          ),
                        if (widget.emailDeliveryEnabled &&
                            !recovering &&
                            !_signingUp)
                          TextButton(
                            onPressed: _busy || _secondsRemaining > 0
                                ? null
                                : () => _submit(recovery: true),
                            child: Text(context.tr('Forgot password')),
                          ),
                        if (_signupAvailable && !recovering) ...[
                          if (_confirmationRequested ||
                              widget.session.callbackNotice != null)
                            TextButton(
                              key: const ValueKey('auth-resend-confirmation'),
                              onPressed: _busy || _secondsRemaining > 0
                                  ? null
                                  : () => _submit(resend: true),
                              child: Text(
                                context.tr('Resend confirmation email'),
                              ),
                            ),
                          TextButton(
                            key: const ValueKey('auth-switch-mode'),
                            onPressed: _busy ? null : _switchMode,
                            child: Text(
                              context.tr(
                                _signingUp
                                    ? 'Back to sign in'
                                    : 'Create account',
                              ),
                            ),
                          ),
                        ],
                        if (_secondsRemaining > 0 && !recovering)
                          Text(
                            context.tr(
                              'You can request another email in {seconds} seconds.',
                              {'seconds': _secondsRemaining},
                            ),
                          ),
                        if (!recovering &&
                            (_confirmationRequested || _emailInstructions))
                          Text(
                            context.tr(
                              'Open the newest email link on this device. Check spam or junk mail too.',
                            ),
                          ),
                        if (_message != null)
                          SahActionFeedback(
                            key: const ValueKey('auth-action-feedback'),
                            message: context.tr(_message!),
                            revealRevision: _feedbackRevision,
                            tone: _success
                                ? SahNoticeTone.info
                                : SahNoticeTone.warning,
                          ),
                      ],
                    ),
                  ),
                ),
                if (!_signupAvailable && !recovering)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: ExpansionTile(
                      key: const ValueKey('auth-get-account'),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 12),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      title: Text(context.tr('How do I get an account?')),
                      children: [
                        Text(
                          context.tr(
                            'During the beta, the project team creates accounts by invitation. Ask the team if you need one.',
                          ),
                        ),
                        if (!widget.emailDeliveryEnabled) ...[
                          const SizedBox(height: 8),
                          Text(
                            context.tr(
                              'If you forget your password, ask the project team. Password reset appears here once email is turned on.',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  context.tr('Team beta: use fictional information only.'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),

                if (widget.deletionStatusScreen != null) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => widget.deletionStatusScreen!,
                      ),
                    ),
                    child: Text(context.tr('Check pending account deletion')),
                  ),
                ],
                if (widget.session.callbackNotice != null)
                  SahNotice(
                    message: context.tr(widget.session.callbackNotice!),
                    tone: SahNoticeTone.warning,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
