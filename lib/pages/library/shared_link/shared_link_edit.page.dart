import 'package:auto_route/auto_route.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/models/shared_link/shared_link.model.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/shared_link.provider.dart';
import 'package:immich_mobile/services/shared_link.service.dart';
import 'package:immich_mobile/utils/url_helper.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:share_plus/share_plus.dart';

@RoutePage()
class SharedLinkEditPage extends HookConsumerWidget {
  static const int maxFutureDate = 365 * 2;

  final SharedLink? existingLink;
  final List<String>? assetsList;
  final String? albumId;

  const SharedLinkEditPage({super.key, this.existingLink, this.assetsList, this.albumId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeData = context.themeData;
    final colorScheme = context.colorScheme;
    final externalDomain = ref.watch(serverInfoProvider.select((s) => s.serverConfig.externalDomain));
    final displayServerUrl = externalDomain.isNotEmpty ? externalDomain : getServerUrl();
    final expiryPresets = <(Duration, String)>[
      (Duration.zero, LocaleKeys.never.tr()),
      (const Duration(minutes: 30), LocaleKeys.shared_link_edit_expire_after_option_minutes.tr(namedArgs: {'count': (30).toString()})),
      (const Duration(hours: 1), LocaleKeys.shared_link_edit_expire_after_option_hour.tr()),
      (const Duration(hours: 6), LocaleKeys.shared_link_edit_expire_after_option_hours.tr(namedArgs: {'count': (6).toString()})),
      (const Duration(days: 1), LocaleKeys.shared_link_edit_expire_after_option_day.tr()),
      (const Duration(days: 7), LocaleKeys.shared_link_edit_expire_after_option_days.tr(namedArgs: {'count': (7).toString()})),
      (const Duration(days: 30), LocaleKeys.shared_link_edit_expire_after_option_days.tr(namedArgs: {'count': (30).toString()})),
      (const Duration(days: 90), LocaleKeys.shared_link_edit_expire_after_option_months.tr(namedArgs: {'count': (3).toString()})),
      (const Duration(days: 365), LocaleKeys.shared_link_edit_expire_after_option_year.tr(namedArgs: {'count': (1).toString()})),
    ];
    final descriptionController = useTextEditingController(text: existingLink?.description ?? "");
    final descriptionFocusNode = useFocusNode();
    final passwordController = useTextEditingController(text: existingLink?.password ?? "");
    final slugController = useTextEditingController(text: existingLink?.slug ?? "");
    final slugFocusNode = useFocusNode();
    useListenable(slugController);
    final showMetadata = useState(existingLink?.showMetadata ?? true);
    final allowDownload = useState(existingLink?.allowDownload ?? true);
    final allowUpload = useState(existingLink?.allowUpload ?? false);
    final expiryAfter = useState<DateTime?>(existingLink?.expiresAt?.toLocal());
    final selectedPresetIndex = useState<int?>(existingLink?.expiresAt == null ? 0 : null);
    final newShareLink = useState("");

    Widget buildSharedLinkRow({required String leading, required String content}) {
      return Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                content,
                style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(leading, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      );
    }

    Widget buildLinkTitle() {
      if (existingLink != null) {
        if (existingLink!.type == SharedLinkSource.album) {
          return buildSharedLinkRow(leading: LocaleKeys.public_album.tr(), content: existingLink!.title);
        }

        if (existingLink!.type == SharedLinkSource.individual) {
          return buildSharedLinkRow(
            leading: LocaleKeys.shared_link_individual_shared.tr(),
            content: existingLink!.description ?? "--",
          );
        }
      }

      return Text(LocaleKeys.create_link_to_share_description.tr(), style: const TextStyle(fontWeight: FontWeight.bold));
    }

    Widget buildDescriptionField() {
      return TextField(
        controller: descriptionController,
        focusNode: descriptionFocusNode,
        textInputAction: TextInputAction.done,
        autofocus: false,
        decoration: InputDecoration(
          labelText: LocaleKeys.description.tr(),
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          border: const OutlineInputBorder(),
          hintText: LocaleKeys.shared_link_edit_description_hint.tr(),
          hintStyle: const TextStyle(fontWeight: FontWeight.normal, fontSize: 14),
        ),
        onTapOutside: (_) => descriptionFocusNode.unfocus(),
      );
    }

    Widget buildPasswordField() {
      return TextField(
        controller: passwordController,
        autofocus: false,
        decoration: InputDecoration(
          labelText: LocaleKeys.password.tr(),
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          border: const OutlineInputBorder(),
          hintText: LocaleKeys.shared_link_edit_password_hint.tr(),
          hintStyle: const TextStyle(fontWeight: FontWeight.normal, fontSize: 14),
        ),
      );
    }

    Widget buildSlugField() {
      return TextField(
        controller: slugController,
        focusNode: slugFocusNode,
        textInputAction: TextInputAction.done,
        autofocus: false,
        decoration: InputDecoration(
          labelText: slugController.text.isNotEmpty ? LocaleKeys.custom_url.tr() : null,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          border: const OutlineInputBorder(),
          hintText: LocaleKeys.custom_url.tr(),
          prefixText: slugController.text.isNotEmpty ? '/s/' : null,
          prefixStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        onTapOutside: (_) => slugFocusNode.unfocus(),
      );
    }

    Widget buildShowMetaButton() {
      return SwitchListTile.adaptive(
        value: showMetadata.value,
        onChanged: (value) => showMetadata.value = value,
        dense: true,
        title: Text(
          LocaleKeys.show_metadata.tr(),
          style: themeData.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
      );
    }

    Widget buildAllowDownloadButton() {
      return SwitchListTile.adaptive(
        value: allowDownload.value,
        onChanged: (value) => allowDownload.value = value,
        dense: true,
        title: Text(
          LocaleKeys.allow_public_user_to_download.tr(),
          style: themeData.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
      );
    }

    Widget buildAllowUploadButton() {
      return SwitchListTile.adaptive(
        value: allowUpload.value,
        onChanged: (value) => allowUpload.value = value,
        dense: true,
        title: Text(
          LocaleKeys.allow_public_user_to_upload.tr(),
          style: themeData.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
      );
    }

    String formatDateTime(DateTime dateTime) => DateFormat.yMMMd(context.locale.toString()).add_Hm().format(dateTime);

    DateTime? getExpiresAtFromPreset(Duration preset) => preset == Duration.zero ? null : DateTime.now().add(preset);

    Future<void> selectDate() async {
      final today = DateTime.now();
      final safeInitialDate = expiryAfter.value ?? today.add(const Duration(days: 7));
      final initialDate = safeInitialDate.isBefore(today) ? today : safeInitialDate;

      final selectedDate = await showDatePicker(
        context: context,
        initialDate: initialDate,
        firstDate: today,
        lastDate: today.add(const Duration(days: maxFutureDate)),
      );

      if (selectedDate != null && context.mounted) {
        final isToday =
            selectedDate.year == today.year && selectedDate.month == today.month && selectedDate.day == today.day;
        final initialTime = isToday ? TimeOfDay.fromDateTime(today) : const TimeOfDay(hour: 12, minute: 0);

        final selectedTime = await showTimePicker(context: context, initialTime: initialTime);

        if (selectedTime != null) {
          final now = DateTime.now();
          var finalDateTime = DateTime(
            selectedDate.year,
            selectedDate.month,
            selectedDate.day,
            selectedTime.hour,
            selectedTime.minute,
          );

          if (finalDateTime.isBefore(now) && isToday) {
            finalDateTime = now;
          }

          selectedPresetIndex.value = null;
          expiryAfter.value = finalDateTime;
        }
      }
    }

    Widget buildExpiryAfterButton() {
      return ExpansionTile(
        title: Text(
          LocaleKeys.expire_after.tr(),
          style: themeData.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          expiryAfter.value == null ? LocaleKeys.shared_link_expires_never.tr() : formatDateTime(expiryAfter.value!),
          style: TextStyle(color: themeData.colorScheme.primary),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(expiryPresets.length, (index) {
                    final preset = expiryPresets[index];
                    return ChoiceChip(
                      label: Text(preset.$2),
                      selected: selectedPresetIndex.value == index,
                      onSelected: (_) {
                        selectedPresetIndex.value = index;
                        expiryAfter.value = getExpiresAtFromPreset(preset.$1);
                      },
                    );
                  }),
                ),
                if (expiryAfter.value != null) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: selectDate,
                      icon: const Icon(Icons.edit_calendar),
                      label: Text(LocaleKeys.edit_date_and_time.tr()),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    Future<void> copyToClipboard(String link) async {
      await Clipboard.setData(ClipboardData(text: link));
      if (!context.mounted) {
        return;
      }
      context.scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(
            LocaleKeys.shared_link_clipboard_copied_massage.tr(),
            style: context.textTheme.bodyLarge?.copyWith(color: context.primaryColor),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    Widget buildLinkCopyField(String link) {
      return TextFormField(
        readOnly: true,
        onTap: () => copyToClipboard(link),
        initialValue: link,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          enabledBorder: themeData.inputDecorationTheme.focusedBorder,
          suffixIcon: IconButton(onPressed: () => Share.share(link), icon: const Icon(Icons.share)),
        ),
      );
    }

    Widget buildNewLinkReadyScreen() {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_link, size: 100, color: themeData.colorScheme.primary),
            const SizedBox(height: 20),
            buildLinkCopyField(newShareLink.value),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => context.maybePop(),
              icon: const Icon(Icons.check),
              label: Text(LocaleKeys.done.tr(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }

    DateTime? calculateExpiry() => expiryAfter.value;

    Future<void> handleNewLink() async {
      final newLink = await ref
          .read(sharedLinkServiceProvider)
          .createSharedLink(
            albumId: albumId,
            assetIds: assetsList,
            showMeta: showMetadata.value,
            allowDownload: allowDownload.value,
            allowUpload: allowUpload.value,
            description: descriptionController.text.isEmpty ? null : descriptionController.text,
            password: passwordController.text.isEmpty ? null : passwordController.text,
            slug: slugController.text.isEmpty ? null : slugController.text,
            expiresAt: calculateExpiry()?.toUtc(),
          );
      if (!context.mounted) {
        return;
      }
      ref.invalidate(sharedLinksStateProvider);

      await ref.read(serverInfoProvider.notifier).getServerConfig();
      if (!context.mounted) {
        return;
      }
      final externalDomain = ref.read(serverInfoProvider.select((s) => s.serverConfig.externalDomain));

      final serverUrl = externalDomain.isNotEmpty ? externalDomain : getServerUrl();

      if (newLink != null) {
        newShareLink.value = buildSharedLinkUrl(baseUrl: serverUrl, slug: newLink.slug, key: newLink.key) ?? '';
        await copyToClipboard(newShareLink.value);
      } else {
        ImmichToast.show(
          context: context,
          gravity: ToastGravity.BOTTOM,
          toastType: ToastType.error,
          msg: LocaleKeys.shared_link_create_error.tr(),
        );
      }
    }

    Future<void> handleEditLink() async {
      bool? download;
      bool? upload;
      bool? meta;
      String? desc;
      String? password;
      String? slug;
      DateTime? expiry;
      bool? changeExpiry;

      if (allowDownload.value != existingLink!.allowDownload) {
        download = allowDownload.value;
      }

      if (allowUpload.value != existingLink!.allowUpload) {
        upload = allowUpload.value;
      }

      if (showMetadata.value != existingLink!.showMetadata) {
        meta = showMetadata.value;
      }

      if (descriptionController.text != existingLink!.description) {
        desc = descriptionController.text;
      }

      if (passwordController.text != existingLink!.password) {
        password = passwordController.text;
      }

      if (slugController.text != (existingLink!.slug ?? "")) {
        slug = slugController.text.isEmpty ? null : slugController.text;
      } else {
        slug = existingLink!.slug;
      }

      final newExpiry = expiryAfter.value;
      if (newExpiry?.toUtc() != existingLink!.expiresAt?.toUtc()) {
        expiry = newExpiry;
        changeExpiry = true;
      }

      await ref
          .read(sharedLinkServiceProvider)
          .updateSharedLink(
            existingLink!.id,
            showMeta: meta,
            allowDownload: download,
            allowUpload: upload,
            description: desc,
            password: password,
            slug: slug,
            expiresAt: expiry?.toUtc(),
            changeExpiry: changeExpiry,
          );
      if (!context.mounted) {
        return;
      }
      ref.invalidate(sharedLinksStateProvider);
      await context.maybePop();
    }

    Future<void> handleDeleteLink() async {
      return showDialog(
        context: context,
        builder: (BuildContext context) => ConfirmDialog(
          title: "delete_shared_link_dialog_title",
          content: "confirm_delete_shared_link",
          onOk: () async {
            await ref.read(sharedLinkServiceProvider).deleteSharedLink(existingLink!.id);
            ref.invalidate(sharedLinksStateProvider);
            if (context.mounted) {
              await context.maybePop();
            }
          },
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(existingLink == null ? LocaleKeys.create_link_to_share.tr() : LocaleKeys.edit_link.tr()),
        elevation: 0,
        leading: const CloseButton(),
        centerTitle: false,
      ),
      body: SafeArea(
        child: newShareLink.value.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ListView(
                  children: [
                    const SizedBox(height: 20),
                    buildLinkTitle(),
                    if (existingLink != null)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const SizedBox(height: 16),
                          buildLinkCopyField(
                            buildSharedLinkUrl(
                                  baseUrl: displayServerUrl,
                                  slug: existingLink!.slug,
                                  key: existingLink!.key,
                                ) ??
                                '',
                          ),
                          const SizedBox(height: 24),
                          const Divider(),
                        ],
                      ),
                    const SizedBox(height: 24),
                    buildDescriptionField(),
                    const SizedBox(height: 16),
                    buildPasswordField(),
                    const SizedBox(height: 16),
                    buildSlugField(),
                    const SizedBox(height: 16),
                    buildShowMetaButton(),
                    const SizedBox(height: 16),
                    buildAllowDownloadButton(),
                    const SizedBox(height: 16),
                    buildAllowUploadButton(),
                    const SizedBox(height: 16),
                    buildExpiryAfterButton(),
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          if (existingLink != null)
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: themeData.colorScheme.error,
                                side: BorderSide(color: themeData.colorScheme.error),
                              ),
                              onPressed: handleDeleteLink,
                              icon: const Icon(Icons.delete_outline),
                              label: Text(
                                LocaleKeys.delete.tr(),
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.check),
                            onPressed: existingLink != null ? handleEditLink : handleNewLink,
                            label: Text(
                              existingLink != null ? LocaleKeys.shared_link_edit_submit_button.tr() : LocaleKeys.create_link.tr(),
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              )
            : Center(child: buildNewLinkReadyScreen()),
      ),
    );
  }
}
