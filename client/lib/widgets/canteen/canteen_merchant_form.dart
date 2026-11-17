import 'package:flutter/material.dart';

import '../app_card.dart';
import '../app_page_background.dart';
import 'canteen_theme.dart';

class CanteenMerchantForm extends StatelessWidget {
  const CanteenMerchantForm(
      {super.key,
      required this.title,
      required this.children,
      required this.submitLabel,
      this.onSubmit,
      this.busy = false});

  final String title;
  final List<Widget> children;
  final String submitLabel;
  final VoidCallback? onSubmit;
  final bool busy;

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: (context) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final background =
            AppPageBackground.color(context, CanteenTheme.surfaceBg(dark));
        return Scaffold(
          backgroundColor: background,
          appBar: AppBar(
            title: Text(title, style: Theme.of(context).textTheme.titleMedium),
            backgroundColor: background,
            actions: [
              TextButton(
                key: const ValueKey('merchant-submit'),
                onPressed: busy ? null : onSubmit,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (busy) ...[
                    const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                  ],
                  Text(submitLabel),
                ]),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                child: AppContentSurface(
                    child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: children,
                        ))),
              ),
            ),
          ),
        );
      });
}

class CanteenMerchantNameField extends StatelessWidget {
  const CanteenMerchantNameField(
      {super.key, required this.controller, this.enabled = true});

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
                child: Text('商家名称',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600))),
            Text('${value.text.characters.length}/100',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 10),
          TextFormField(
            controller: controller,
            enabled: enabled,
            maxLength: 100,
            textInputAction: TextInputAction.done,
            style: theme.textTheme.bodyLarge,
            decoration: InputDecoration(
              hintText: '请输入商家名称',
              counterText: '',
              filled: true,
              fillColor: CanteenTheme.surfaceMutedBg(dark)
                  .withValues(alpha: enabled ? .35 : .8),
              border: border,
              enabledBorder: border,
              disabledBorder: border,
              focusedBorder: border.copyWith(
                  borderSide: BorderSide(color: scheme.primary, width: 1.5)),
              errorBorder:
                  border.copyWith(borderSide: BorderSide(color: scheme.error)),
              focusedErrorBorder: border.copyWith(
                  borderSide: BorderSide(color: scheme.error, width: 1.5)),
              errorMaxLines: 2,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      key: const ValueKey('merchant-name-clear'),
                      tooltip: '清空商家名称',
                      onPressed: enabled ? controller.clear : null,
                      icon: const Icon(Icons.cancel_outlined, size: 19)),
            ),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (value) {
              final length = value?.trim().runes.length ?? 0;
              return length < 2 || length > 100 ? '商家名称需为 2–100 个字符' : null;
            },
          ),
        ],
      ),
    );
  }
}

class CanteenLocationFields extends StatelessWidget {
  const CanteenLocationFields(
      {super.key,
      required this.areas,
      required this.floors,
      required this.area,
      required this.floor,
      required this.onAreaChanged,
      required this.onFloorChanged,
      this.allowUnset = false,
      this.enabled = true});

  final List<String> areas;
  final List<String> floors;
  final String area;
  final String floor;
  final ValueChanged<String> onAreaChanged;
  final ValueChanged<String> onFloorChanged;
  final bool allowUnset;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surface = CanteenTheme.surfaceBg(theme.brightness == Brightness.dark);
    Widget options(String title, String key, List<String> values,
            String current, ValueChanged<String> onChanged) =>
        Column(
          key: ValueKey(key),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                  child: Text(title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600))),
              if (allowUnset && current.isEmpty)
                Text('未设置',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final value in values)
                ChoiceChip(
                  label: Text(value),
                  selected: current == value,
                  onSelected: !enabled
                      ? null
                      : (selected) {
                          FocusScope.of(context).unfocus();
                          onChanged(selected || !allowUnset ? value : '');
                        },
                  showCheckmark: true,
                  checkmarkColor: scheme.primary,
                  selectedColor: Color.alphaBlend(
                      scheme.primary.withValues(alpha: .08), surface),
                  backgroundColor: surface,
                  disabledColor: scheme.surfaceContainerHighest,
                  side: BorderSide(
                      color: current == value
                          ? scheme.primary
                          : scheme.outlineVariant),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
                  labelStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: !enabled
                          ? scheme.onSurface.withValues(alpha: .38)
                          : current == value
                              ? scheme.primary
                              : scheme.onSurface,
                      fontWeight:
                          current == value ? FontWeight.w600 : FontWeight.w400),
                  visualDensity: VisualDensity.standard,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
            ]),
          ],
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      options('所在区域', 'merchant-area', areas, area, onAreaChanged),
      if (area == '其他')
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('食堂以外的商家',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        )
      else ...[
        const SizedBox(height: 20),
        options('所在楼层', 'merchant-floor', floors, floor, onFloorChanged),
      ],
    ]);
  }
}

class CanteenFormNotice extends StatelessWidget {
  const CanteenFormNotice(this.message, {super.key, this.error = false});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: error,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: error
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
        ),
      );
}
