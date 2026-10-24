import 'package:flutter/material.dart';
import 'theme.dart';

class PrivateContentCover extends StatefulWidget {
  const PrivateContentCover({super.key, required this.child});
  final Widget child;

  @override
  State<PrivateContentCover> createState() => _PrivateContentCoverState();
}

class _PrivateContentCoverState extends State<PrivateContentCover>
    with WidgetsBindingObserver {
  late bool _covered;
  @override
  void initState() {
    super.initState();
    _covered =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final covered = state != AppLifecycleState.resumed;
    if (mounted && covered != _covered) setState(() => _covered = covered);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      ExcludeSemantics(
        excluding: _covered,
        child: IgnorePointer(ignoring: _covered, child: widget.child),
      ),
      if (_covered)
        const Positioned.fill(
          child: BlockSemantics(
            child: ColoredBox(
              color: SafeAtHomeTheme.ivory,
              child: Center(child: Text('Safe at Home')),
            ),
          ),
        ),
    ],
  );
}
