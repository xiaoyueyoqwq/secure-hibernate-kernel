import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/core.dart';

class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key});

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  bool mokBusy = false;
  bool actionBusy = false;

  Future<void> inspectMok() async {
    setState(() => mokBusy = true);
    await context.manager.inspectProjectMok();
    if (!mounted) return;
    setState(() => mokBusy = false);
  }

  Future<void> handleMokAction() async {
    final manager = context.manager;
    final replaceLegacyPassword =
        usesLegacyMokPassword(manager.mokOneTimePassword);
    if (manager.projectMokStatus != ProjectMokStatus.missing &&
        !replaceLegacyPassword) {
      await inspectMok();
      return;
    }
    setState(() => actionBusy = true);
    await manager.runManagerAction(
      const ManagerActionRequest(ManagerActionType.prepareMok),
    );
    if (!mounted) return;
    setState(() => actionBusy = false);
  }

  Future<void> handleTpmAction() async {
    final manager = context.manager;
    if (!manager.native) {
      manager.addLog(
        manager.tpmConfigured
            ? '[System] Test backend requested TPM verification'
            : '[System] Test backend requested TPM binding',
      );
      return;
    }
    final action = manager.tpmConfigured
        ? ManagerActionType.verifyTpm
        : ManagerActionType.enrollTpm;
    final recoveryPassword = action == ManagerActionType.enrollTpm
        ? await showLuksRecoveryPasswordDialog(context)
        : null;
    if (action == ManagerActionType.enrollTpm && recoveryPassword == null) {
      return;
    }
    if (!mounted) {
      recoveryPassword?.fillRange(0, recoveryPassword.length, 0);
      return;
    }
    setState(() => actionBusy = true);
    try {
      final result = await manager.runManagerAction(
        ManagerActionRequest(
          action,
          recoveryPassword: recoveryPassword,
        ),
      );
      if (result.status == ManagerActionStatus.success) {
        await manager.refreshSnapshot();
      }
    } finally {
      recoveryPassword?.fillRange(0, recoveryPassword.length, 0);
      if (mounted) setState(() => actionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.manager;
    final t = context.t;
    final mokKnown = manager.projectMokStatus == ProjectMokStatus.enrolled ||
        manager.projectMokStatus == ProjectMokStatus.missing ||
        manager.projectMokStatus == ProjectMokStatus.pendingEnrollment;
    final waitingForAuthorization =
        manager.projectMokStatus == ProjectMokStatus.pendingConfirmation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: t.text('security.title'),
          description: t.text('security.description'),
        ),
        const SizedBox(height: 32),
        SectionTitle(t.text('security.secureBootMok')),
        const SizedBox(height: 16),
        StatusRow(
          label: t.text('security.lockdownMode'),
          value: Text(manager.lockdown
              ? t.text('security.integrityEnabled')
              : t.text('security.disabled')),
          status: manager.lockdown ? StatusKind.ok : StatusKind.warning,
          description: t.text('security.lockdownDescription'),
        ),
        const SizedBox(height: 12),
        StatusRow(
          label: t.text('security.projectCertificate'),
          value: Text(waitingForAuthorization
              ? t.text('common.checkingStatus')
              : !mokKnown
                  ? t.text('overview.unknown')
                  : manager.projectMokStatus == ProjectMokStatus.enrolled
                      ? t.text('security.enrolled')
                      : manager.projectMokStatus ==
                              ProjectMokStatus.pendingEnrollment
                          ? usesLegacyMokPassword(manager.mokOneTimePassword)
                              ? t.text('wizard.passwordUpdateRequired')
                              : t.text('wizard.restartRequired')
                          : t.text('security.missing')),
          status: !mokKnown
              ? StatusKind.info
              : manager.projectMokStatus == ProjectMokStatus.enrolled
                  ? StatusKind.ok
                  : StatusKind.warning,
          description: t.text('security.certificateDescription'),
          action: manager.projectMokStatus == ProjectMokStatus.enrolled ||
                  (manager.projectMokStatus ==
                          ProjectMokStatus.pendingEnrollment &&
                      !usesLegacyMokPassword(manager.mokOneTimePassword))
              ? null
              : AppButton(
                  label: mokBusy || waitingForAuthorization
                      ? t.text('wizard.awaitingAuthorization')
                      : manager.projectMokStatus == ProjectMokStatus.missing
                          ? t.text('common.prepareEnrollment')
                          : usesLegacyMokPassword(manager.mokOneTimePassword)
                              ? t.text('common.regeneratePassword')
                              : t.text('common.checkStatus'),
                  busy: mokBusy || actionBusy || waitingForAuthorization,
                  onPressed: handleMokAction,
                ),
        ),
        if (manager.mokOneTimePassword != null) ...[
          const SizedBox(height: 12),
          StatusRow(
            label: t.text('wizard.details.mokOneTimePassword'),
            value: SelectableText(
              manager.mokOneTimePassword!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontFamily: 'Ubuntu',
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            status: StatusKind.warning,
            statusIcon: LucideIcons.lock,
            statusColor: Theme.of(context).colorScheme.error,
            description: t.text('wizard.details.mokOneTimePasswordDescription'),
          ),
        ],
        const SizedBox(height: 32),
        SectionTitle(t.text('security.diskEncryption')),
        const SizedBox(height: 16),
        StatusRow(
          label: t.text('security.luksState'),
          value: Text(manager.luks
              ? t.text('security.encrypted')
              : '${t.text('security.notEncrypted')} · '
                  '${t.text('wizard.details.recommended')}'),
          status: manager.luks ? StatusKind.ok : StatusKind.warning,
          description: manager.luks ? null : t.text('wizard.details.luksHelp'),
        ),
        const SizedBox(height: 12),
        StatusRow(
          label: t.text('security.tpmBinding'),
          value: Text(!manager.luks
              ? t.text('wizard.details.notApplicable')
              : manager.tpmConfigured
                  ? t.text('security.tpmConfigured')
                  : t.text('security.notConfigured')),
          status: !manager.luks
              ? StatusKind.warning
              : manager.tpmConfigured
                  ? StatusKind.ok
                  : StatusKind.info,
          description: manager.luks
              ? t.text('security.tpmDescription')
              : t.text('wizard.details.tpmUnavailableWithoutLuks'),
          action: manager.luks
              ? AppButton(
                  label: manager.tpmConfigured
                      ? t.text('security.verifyTpm')
                      : t.text('security.bindTpm'),
                  tone: ButtonTone.ghost,
                  busy: actionBusy,
                  disabled:
                      manager.backendConnection == BackendConnection.loading ||
                          manager.backendConnection == BackendConnection.error,
                  onPressed: handleTpmAction,
                )
              : null,
        ),
        const SizedBox(height: 12),
        AppCard(
          color: context.palette.dark
              ? Colors.black
              : Neutral.n50.withValues(alpha: 0.50),
          padding: const EdgeInsets.all(12),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${t.text('security.note')} ',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: t.text('security.recoveryNote')),
              ],
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
