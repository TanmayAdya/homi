import 'package:flutter/material.dart';
import 'sah_components.dart';

class StartupErrorScreen extends StatelessWidget {
  const StartupErrorScreen.startup({super.key})
    : title = 'Could not start',
      message =
          'Safe at Home could not start. Close and reopen the app. If this keeps happening, ask your project owner for help. No case has been opened.',
      onSignOut = null,
      onRetry = null,
      signingOut = false,
      error = null;

  const StartupErrorScreen.storage({
    super.key,
    required this.onSignOut,
    this.signingOut = false,
    this.error,
  }) : title = 'Private storage',
       onRetry = null,
       message =
           'Private storage could not be opened. Unlock your phone and restart the app.';

  const StartupErrorScreen.cleanup({super.key, required this.onRetry})
    : title = 'Finish private cleanup',
      message =
          'Sign-out is not complete. Saved sign-in data or other requested private cleanup could not be confirmed. Unlock this device and retry before signing in again. Retrying finishes only the cleanup you already requested.',
      onSignOut = null,
      signingOut = false,
      error = null;

  final String title, message;
  final VoidCallback? onSignOut, onRetry;
  final bool signingOut;
  final String? error;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Safe at Home')),
    body: SafeArea(
      child: SahContent(
        maxWidth: 680,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SahPageHeader(title: title, description: message),
              if (onRetry != null)
                FilledButton(
                  key: const ValueKey('startup-retry-cleanup'),
                  onPressed: onRetry,
                  child: const Text('Retry private cleanup'),
                ),
              if (onSignOut != null) ...[
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Encrypted drafts will remain on this device. To remove them, unlock your phone, sign in to this account, and use Settings after private storage opens.',
                  ),
                ),
                OutlinedButton(
                  key: const ValueKey('startup-sign-out'),
                  onPressed: signingOut ? null : onSignOut,
                  child: const Text('Sign out and keep device drafts'),
                ),
                if (signingOut)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(
                      semanticsLabel: 'Finishing sign-out',
                    ),
                  ),
                if (error != null)
                  SahActionFeedback(
                    key: const ValueKey('startup-exit-feedback'),
                    message: error!,
                    tone: SahNoticeTone.warning,
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
