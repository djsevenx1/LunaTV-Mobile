import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 长按文本框弹出的选择菜单（中文）。
///
/// 默认的 [EditableText.contextMenuBuilder] 会把 "Cut/Copy/Paste" 交给
/// Android 系统本地化，但部分 ROM / WebView 容器 / 多语言环境下系统会
/// fallback 到英文。这里用 [AdaptiveTextSelectionToolbar.buttonItems] 自己
/// 渲染一份中文菜单，行为跟系统一致（剪切/复制/粘贴/全选）。
Widget chineseTextSelectionToolbarBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  final value = editableTextState.textEditingValue;
  final selection = value.selection;
  final hasSelection = selection.isValid && !selection.isCollapsed;
  final hasText = value.text.isNotEmpty;

  final buttonItems = <ContextMenuButtonItem>[
    ContextMenuButtonItem(
      label: '剪切',
      onPressed: hasSelection
          ? () {
              ContextMenuController.removeAny();
              editableTextState.hideToolbar(false);
              editableTextState.cutSelection(SelectionChangedCause.toolbar);
            }
          : null,
    ),
    ContextMenuButtonItem(
      label: '复制',
      onPressed: hasSelection
          ? () {
              ContextMenuController.removeAny();
              editableTextState.hideToolbar(false);
              editableTextState.copySelection(SelectionChangedCause.toolbar);
            }
          : null,
    ),
    ContextMenuButtonItem(
      label: '粘贴',
      onPressed: () {
        ContextMenuController.removeAny();
        editableTextState.hideToolbar(false);
        editableTextState.pasteText(SelectionChangedCause.toolbar);
      },
    ),
    ContextMenuButtonItem(
      label: '全选',
      onPressed: hasText
          ? () {
              ContextMenuController.removeAny();
              editableTextState.hideToolbar(false);
              editableTextState.selectAll(SelectionChangedCause.toolbar);
            }
          : null,
    ),
  ];

  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: buttonItems,
  );
}
