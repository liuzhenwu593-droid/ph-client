import 'package:flutter/material.dart';

import '../settings.dart';

/// Video-list layout toggle (v0.2.2): one tap cycles 1 -> 2 -> 3 columns.
/// The icon shows the current layout; the choice is persisted in
/// [AppSettings] and survives restart. Shown on video lists only —
/// never on the category-name grid or the Settings tab.
class GridColumnsButton extends StatelessWidget {
  const GridColumnsButton({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final columns = settings.gridColumns;
    return IconButton(
      icon: Icon(
        columns == 1
            ? Icons.view_list
            : columns == 2
            ? Icons.view_module
            : Icons.grid_view,
      ),
      tooltip: '布局：$columns 列（点按切换）',
      onPressed: () {
        settings.setGridColumns(columns % 3 + 1);
      },
    );
  }
}
