import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/base_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/trash_bottom_sheet.widget.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';

@RoutePage()
class DriftTrashPage extends StatelessWidget {
  const DriftTrashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        timelineServiceProvider.overrideWith((ref) {
          final user = ref.watch(currentUserProvider);
          if (user == null) {
            throw Exception('User must be logged in to access trash');
          }

          final timelineService = ref.watch(timelineFactoryProvider).trash(user.id);
          ref.onDispose(timelineService.dispose);
          return timelineService;
        }),
      ],
      child: Timeline(
        appBar: SliverAppBar(
          title: Text('trash'.t(context: context)),
          floating: true,
          snap: true,
          pinned: true,
          centerTitle: true,
          elevation: 0,
          actions: [const _TrashKebabMenu()],
        ),
        topSliverWidgetHeight: 24,
        topSliverWidget: Consumer(
          builder: (context, ref, child) {
            final trashDays = ref.watch(serverInfoProvider.select((v) => v.serverConfig.trashDays));

            return SliverPadding(
              padding: const EdgeInsets.all(16.0),
              sliver: SliverToBoxAdapter(child: Text(LocaleKeys.trash_page_info.tr(namedArgs: {'days': (trashDays).toString()}))),
            );
          },
        ),
        bottomSheet: const TrashBottomBar(),
      ),
    );
  }
}

class _TrashKebabMenu extends ConsumerWidget {
  const _TrashKebabMenu();

  Future<void> _confirmAndRun(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String content,
    required Future<ActionResult> Function(String userId) action,
    required String Function(int count) successMsg,
  }) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: title,
        content: content,
        onOk: () async {
          final user = ref.read(currentUserProvider);
          if (user == null) {
            return;
          }
          final result = await action(user.id);
          if (!context.mounted) {
            return;
          }
          ImmichToast.show(
            context: context,
            msg: result.success ? successMsg(result.count) : LocaleKeys.scaffold_body_error_occurred.tr(),
            toastType: result.success ? ToastType.success : ToastType.error,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuAnchor(
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(context.themeData.scaffoldBackgroundColor),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.grey),
        elevation: const WidgetStatePropertyAll(4),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
      menuChildren: [
        BaseActionButton(
          label: LocaleKeys.empty_trash.tr(),
          iconData: Icons.delete_forever_outlined,
          onPressed: () => _confirmAndRun(
            context,
            ref,
            title: LocaleKeys.empty_trash.tr(),
            content: LocaleKeys.empty_trash_confirmation.tr(),
            action: ref.read(actionProvider.notifier).emptyTrash,
            successMsg: (count) => LocaleKeys.assets_permanently_deleted_count.tr(namedArgs: {'count': (count).toString()}),
          ),
          menuItem: true,
        ),
        BaseActionButton(
          label: LocaleKeys.restore_all.tr(),
          iconData: Icons.restore_outlined,
          onPressed: () => _confirmAndRun(
            context,
            ref,
            title: LocaleKeys.restore_all.tr(),
            content: LocaleKeys.assets_restore_confirmation.tr(),
            action: ref.read(actionProvider.notifier).restoreAllTrash,
            successMsg: (count) => LocaleKeys.assets_restored_count.tr(namedArgs: {'count': (count).toString()}),
          ),
          menuItem: true,
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          icon: const Icon(Icons.more_vert_rounded),
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        );
      },
    );
  }
}
