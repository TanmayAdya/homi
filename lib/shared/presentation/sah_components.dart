import 'package:flutter/material.dart';

class SahContent extends StatelessWidget {
  const SahContent({super.key, required this.child, this.maxWidth = 760});
  final Widget child;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

class SahPageHeader extends StatelessWidget {
  const SahPageHeader({
    super.key,
    required this.title,
    this.description,
    this.eyebrow,
    this.trailing,
  });
  final String title;
  final String? description, eyebrow;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (eyebrow != null) ...[
            Text(
              eyebrow!,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.headlineMedium),
          ),
          if (description != null) ...[
            const SizedBox(height: 12),
            Text(
              description!,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (trailing != null) ...[const SizedBox(height: 16), trailing!],
        ],
      ),
    );
  }
}

class SahSectionHeading extends StatelessWidget {
  const SahSectionHeading({super.key, required this.title, this.description});
  final String title;
  final String? description;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (description != null) ...[
          const SizedBox(height: 6),
          Text(
            description!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}

enum SahNoticeTone { info, warning, error, success }

class SahNotice extends StatelessWidget {
  const SahNotice({
    super.key,
    required this.message,
    this.title,
    this.icon,
    this.tone = SahNoticeTone.info,
  });
  final String message;
  final String? title;
  final IconData? icon;
  final SahNoticeTone tone;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, defaultIcon) = switch (tone) {
      SahNoticeTone.warning => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        Icons.info_outline_rounded,
      ),
      SahNoticeTone.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error_outline,
      ),
      SahNoticeTone.success => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        Icons.check_circle_outline_rounded,
      ),
      SahNoticeTone.info => (
        scheme.surfaceContainerLow,
        scheme.onSurface,
        Icons.info_outline_rounded,
      ),
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Icon(icon ?? defaultIcon, color: foreground, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(
                      title!,
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(color: foreground),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    message,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: foreground),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SahActionFeedback extends StatefulWidget {
  const SahActionFeedback({
    super.key,
    required this.message,
    this.title,
    this.tone = SahNoticeTone.info,
    this.onReview,
    this.revealRevision = 0,
  });
  final String message;
  final String? title;
  final SahNoticeTone tone;
  final VoidCallback? onReview;
  final int revealRevision;

  @override
  State<SahActionFeedback> createState() => _SahActionFeedbackState();
}

class _SahActionFeedbackState extends State<SahActionFeedback> {
  final _anchor = GlobalKey();
  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(SahActionFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revealRevision != widget.revealRevision) {
      _reveal();
    }
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      final target = _anchor.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          alignment: 0.1,
          duration: const Duration(milliseconds: 180),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(key: _anchor, height: 1),
      SahNotice(
        title: widget.title,
        message: widget.message,
        tone: widget.tone,
      ),
      if (widget.onReview != null)
        OutlinedButton(
          onPressed: widget.onReview,
          child: const Text('Review this answer'),
        ),
    ],
  );
}

class SahActionTile extends StatelessWidget {
  const SahActionTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    this.onTap,
    this.trailing,
    this.enabled = true,
  });
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = enabled && onTap != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          button: true,
          enabled: active,
          child: InkWell(
            onTap: active ? onTap : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(
                          icon,
                          color: active
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.titleMedium),
                          if (subtitle != null) ...[
                            const SizedBox(height: 5),
                            Text(
                              subtitle!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    trailing ??
                        ExcludeSemantics(
                          child: Icon(
                            active
                                ? Icons.chevron_right_rounded
                                : Icons.lock_outline_rounded,
                            color: theme.colorScheme.onSurfaceVariant,
                            size: 22,
                          ),
                        ),
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

class SahStepIndicator extends StatelessWidget {
  const SahStepIndicator({
    super.key,
    required this.currentStep,
    required this.labels,
  }) : assert(currentStep >= 0);
  final int currentStep;
  final List<String> labels;
  @override
  Widget build(BuildContext context) {
    assert(currentStep < labels.length);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Semantics(
        label:
            'Step ${currentStep + 1} of ${labels.length}: ${labels[currentStep]}',
        child: ExcludeSemantics(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < labels.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: i == currentStep
                        ? theme.colorScheme.primaryContainer
                        : Colors.transparent,
                    border: Border.all(
                      color: i == currentStep
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${i + 1}  ${labels[i]}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: i == currentStep
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: i == currentStep
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SahEmptyState extends StatelessWidget {
  const SahEmptyState({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    this.action,
  });
  final String title, message;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Icon(
            icon,
            size: 36,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        const SizedBox(height: 8),
        Text(message, style: Theme.of(context).textTheme.bodyLarge),
        if (action != null) ...[const SizedBox(height: 16), action!],
      ],
    ),
  );
}
