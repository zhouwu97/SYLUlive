import 'package:flutter/material.dart';

import 'competition_module_theme.dart';
import 'competition_ui_tokens.dart';

class CompetitionPageScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final bool resizeToAvoidBottomInset;

  const CompetitionPageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.resizeToAvoidBottomInset = true,
  });

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: CompetitionModuleTheme.of(context),
      child: Builder(
        builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Scaffold(
            backgroundColor: CompetitionUiTokens.pageBg(isDark),
            resizeToAvoidBottomInset: resizeToAvoidBottomInset,
            appBar: AppBar(
              title: Text(
                title,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              actions: actions,
            ),
            body: body,
            bottomNavigationBar: bottomNavigationBar,
            floatingActionButton: floatingActionButton,
            floatingActionButtonLocation: floatingActionButtonLocation,
          );
        },
      ),
    );
  }
}
