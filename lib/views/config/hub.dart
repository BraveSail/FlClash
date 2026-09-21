import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class HubUrlItem extends ConsumerWidget {
  const HubUrlItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final hubUrl = ref.watch(
      appSettingProvider.select((state) => state.hubUrl),
    );
    return ListItem.input(
      leading: const Icon(Icons.cloud_outlined),
      title: Text(appLocalizations.hubUrl),
      subtitle: Text(hubUrl.takeFirstValid([appLocalizations.none])),
      dialogTitle: appLocalizations.hubUrl,
      value: hubUrl,
      resetValue: '',
      maxLength: TextInputLimits.url,
      validator: (String? value) {
        if (value == null || value.trim().isEmpty) {
          return null;
        }
        if (!value.trim().isUrl) {
          return appLocalizations.urlTip(appLocalizations.hubUrl);
        }
        return null;
      },
      onChanged: (String? value) {
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(hubUrl: (value ?? '').trim()));
        unawaited(
          ref
              .read(profilesActionProvider.notifier)
              .syncHubProfile(notifyMissing: true),
        );
      },
    );
  }
}

class HubTokenItem extends ConsumerWidget {
  const HubTokenItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final hubToken = ref.watch(
      appSettingProvider.select((state) => state.hubToken),
    );
    return ListItem(
      leading: const Icon(Icons.key_outlined),
      title: Text(appLocalizations.hubToken),
      subtitle: Text(hubToken.obscured.takeFirstValid([appLocalizations.none])),
      onTap: () => _handleShowTokenDialog(context, ref),
    );
  }

  Future<void> _handleShowTokenDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final appLocalizations = context.appLocalizations;
    final token = await dialogs.showCommonDialog<String>(
      child: InputDialog(
        title: appLocalizations.hubToken,
        labelText: appLocalizations.hubToken,
        value: ref.read(appSettingProvider).hubToken,
        obscureText: true,
        maxLength: TextInputLimits.url,
      ),
    );
    if (token == null) {
      return;
    }
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(hubToken: token.trim()));
    unawaited(ref.read(profilesActionProvider.notifier).syncHubProfile());
  }
}

class HubViaProxyItem extends ConsumerWidget {
  const HubViaProxyItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return ConfigToggleItem(
      leading: const Icon(Icons.vpn_lock_outlined),
      title: (l) => l.hubViaProxy,
      subtitle: (l) => l.hubViaProxyDesc,
      selector: appSettingProvider.select((state) => state.hubViaProxy),
      onChanged: (ref, value) => ref
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(hubViaProxy: value)),
    );
  }
}
