import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_ui/immich_ui.dart';

class PermanentDeleteDialog extends StatelessWidget {
  const PermanentDeleteDialog({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
      title: Text(LocaleKeys.permanently_delete.tr()),
      content: ImmichFormattedText(LocaleKeys.permanently_delete_assets_prompt.tr(namedArgs: {'count': (count).toString()})),
      actions: [
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            onPressed: () => context.pop(false),
            style: FilledButton.styleFrom(
              backgroundColor: context.colorScheme.surfaceDim,
              foregroundColor: context.primaryColor,
            ),
            child: Text(LocaleKeys.cancel.tr(), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 48,

          child: FilledButton(
            onPressed: () => context.pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: context.colorScheme.errorContainer,
              foregroundColor: context.colorScheme.onErrorContainer,
            ),
            child: Text(LocaleKeys.delete.tr(), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}
