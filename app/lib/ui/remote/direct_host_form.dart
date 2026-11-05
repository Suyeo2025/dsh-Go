import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart' show DshCookie;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../platform/platform_caps.dart';
import '../../remote/direct/direct_google_sign_in.dart';
import '../../remote/direct/direct_link.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';
import '../common/brief_notice.dart';
import '../common/discard_guard.dart';
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'link_progress.dart';
import 'ssh_host_form.dart' show RemoteFormBar, RemoteSmallTextButton;

/// "用 Google 重新登录" for [host] (it has a [DirectHostConfig.signInUrl]): a
/// fresh token replaces the stale one, the old cookie goes, and the host
/// connects again. A failure (not a cancel) shows in a snack bar.
Future<void> reSignInDirectWithGoogle(BuildContext context, WidgetRef ref, DirectHostConfig host) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final signIn = host.signInUrl == null ? null : normalizeSignInUrl(host.signInUrl!);
  if (signIn == null) return;
  final DirectSignInResult result;
  try {
    result = await signInWithGoogle(signIn, authenticate: ref.read(directWebAuthenticatorProvider));
  } on DirectSignInException catch (e) {
    if (e.message case final message?) messenger?.showSnackBar(SnackBar(content: Text(message)));
    return;
  }
  if (!context.mounted) return;
  final saved = await ref
      .read(hostsProvider.notifier)
      .renewDirectToken(host.id, token: result.token, baseUri: result.baseUri);
  if (!saved) {
    messenger?.showSnackBar(SnackBar(content: Text(appL10n.commonSaveFailed)));
    return;
  }
  if (!context.mounted) return;
  ref.read(remoteConnectionProvider(HostRef.direct(host.id)).notifier).retry();
}

/// The stages a direct host goes through (no host key, no tunnel).
const directLinkSteps = [HostLinkStep.connect, HostLinkStep.login];

/// Add or edit a direct-URL host: its address and the `dsh web` launch token
/// (either field takes the whole `https://host/?token=…` launch link). "测试
/// 连接" signs in for real; the cookie that buys is saved with the host, so
/// the first connection needs no second login.
///
/// On a remote-only device (iOS) a "用 Google 登录" block comes first: the
/// server's access gate hands back the address and a fresh token, and the
/// host is tested and saved without typing either.
class DirectHostFormPage extends ConsumerStatefulWidget {
  const DirectHostFormPage({super.key, this.existing, this.signInOnly = false});

  /// Null to add a new host.
  final DirectHostConfig? existing;

  /// Only the Google block (first run); 「手动填写」 shows the rest.
  final bool signInOnly;

  @override
  ConsumerState<DirectHostFormPage> createState() => _DirectHostFormPageState();
}

enum _F { signIn, url, token }

class _DirectHostFormPageState extends ConsumerState<DirectHostFormPage> {
  late final String _id = widget.existing?.id ?? DirectHostConfig.newId();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.baseUrl ?? '');
  final _token = TextEditingController();
  late final _signIn = TextEditingController(text: widget.existing?.signInUrl ?? '');
  late final String _clean;
  late final Listenable _edits = Listenable.merge([_name, _url, _token, _signIn]);

  /// The Google block is offered (remote-only devices have the system web
  /// authentication session).
  final bool _google = isRemoteOnlyPlatform;

  /// The URL and token fields show (always, unless [DirectHostFormPage.signInOnly]
  /// until 「手动填写」).
  late bool _manual = !(widget.signInOnly && _google);
  bool _signingIn = false;

  bool _obscure = true;
  bool _saving = false;
  bool _hasSavedToken = false;
  String? _formError;
  Map<_F, String> _errors = const {};

  DirectHostLink? _test;
  StreamSubscription<HostLinkStatus>? _testSub;
  HostLinkStatus? _testStatus;

  /// What the last test was run with, whether it got through, and the
  /// cookie it bought.
  String? _testedWith;
  bool _testedOk = false;
  DshCookie? _testedCookie;

  bool get _editing => widget.existing != null;

  String _signature() =>
      jsonEncode({'name': _name.text, 'url': _url.text, 'token': _token.text, 'signIn': _signIn.text});

  @override
  void initState() {
    super.initState();
    _clean = _signature();
    _url.addListener(() => _splitLaunchLink(_url));
    _token.addListener(() => _splitLaunchLink(_token));
    if (_editing) unawaited(_loadSecrets());
  }

  Future<void> _loadSecrets() async {
    final secrets = await ref.read(hostsProvider.notifier).loadDirectSecrets(_id);
    if (mounted) setState(() => _hasSavedToken = secrets.hasToken);
  }

  @override
  void dispose() {
    unawaited(_testSub?.cancel());
    unawaited(_test?.close());
    for (final c in [_name, _url, _token, _signIn]) {
      c.dispose();
    }
    super.dispose();
  }

  /// A whole launch link pasted into either field: URL to the URL field,
  /// token to the token field.
  void _splitLaunchLink(TextEditingController field) {
    final text = field.text;
    if (!text.contains('token=')) return;
    final DirectHostInput input;
    try {
      input = parseDirectHostInput(url: field == _url ? text : '', token: field == _token ? text : '');
    } on DirectInputException {
      return;
    }
    final token = input.token;
    if (token == null) return;
    // After this listener returns: editing a controller inside its own
    // notification would re-enter it.
    scheduleMicrotask(() {
      if (!mounted) return;
      _url.text = input.baseUri.toString();
      _token.text = token;
      setState(() => _errors = const {});
      showBriefNotice(context, context.l10n.directLinkSplit);
    });
  }

  /// The host and token as typed; null (with [_errors] set) when incomplete.
  (DirectHostConfig, String?)? _draft() {
    final l10n = context.l10n;
    DirectHostInput? input;
    String? urlError;
    try {
      input = parseDirectHostInput(url: _url.text, token: _token.text);
    } on DirectInputException catch (e) {
      urlError = e.problem == DirectInputProblem.urlMissing ? l10n.directUrlRequired : l10n.directUrlInvalid;
    }
    final token = input?.token;
    final signInText = _signIn.text.trim();
    final signIn = signInText.isEmpty ? null : normalizeSignInUrl(signInText);
    final errors = <_F, String>{
      if (_google && signInText.isNotEmpty && signIn == null) _F.signIn: l10n.directSignInUrlInvalid,
      _F.url: ?urlError,
      if (input != null && token == null && !_hasSavedToken) _F.token: l10n.directTokenRequired,
    };
    setState(() {
      _errors = errors;
      _formError = null;
    });
    if (errors.isNotEmpty || input == null) return null;
    final base = input.baseUri.toString();
    final name = _name.text.trim();
    final config = DirectHostConfig(id: _id, name: '', baseUrl: base, signInUrl: signIn?.toString());
    return (config.copyWith(name: name.isEmpty ? config.address : name), token);
  }

  /// Signs in for real with what's typed (or the saved token when the field
  /// is empty); true when it got through.
  Future<bool> _runTest() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final draft = _draft();
    if (draft == null) return false;
    final (config, typedToken) = draft;
    await _testSub?.cancel();
    await _test?.close();
    final saved = _editing ? await ref.read(hostsProvider.notifier).loadDirectSecrets(_id) : const DirectSecrets();
    if (!mounted) return false;
    final sameUrl = widget.existing?.connectionKey == config.connectionKey;
    final secrets = DirectSecrets(
      token: typedToken ?? saved.token,
      // A new token is what's being tested: no cookie to hide behind.
      cookie: typedToken == null && sameUrl ? saved.cookie : null,
    );
    DshCookie? minted;
    final link = DirectHostLink(
      config: config,
      loadSecrets: () async => secrets,
      saveCookie: (cookie) async => minted = cookie,
      clientFactory: ref.read(directClientFactoryProvider),
      retryFirstOpen: false,
    );
    _test = link;
    final signature = _signature();
    setState(() {
      _testStatus = const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect);
      _testedWith = signature;
      _testedOk = false;
      _testedCookie = null;
    });
    _testSub = link.statuses.listen((s) {
      if (mounted && s.phase != HostLinkPhase.idle) setState(() => _testStatus = s);
    });
    var ok = false;
    try {
      await link.open();
      ok = true;
    } catch (_) {
      // Shown in the progress card.
    } finally {
      await _testSub?.cancel();
      _testSub = null;
      if (identical(_test, link)) _test = null;
      await link.close();
    }
    if (mounted) {
      setState(() {
        _testedOk = ok;
        _testedCookie = ok ? minted : null;
      });
    }
    return ok;
  }

  /// Tests first (unless these exact inputs were just tested); a failed test
  /// keeps the form open, and a second 保存 with the same inputs saves anyway
  /// (the host may just be down right now).
  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final draft = _draft();
    if (draft == null) return;
    if (_testedWith != _signature()) {
      if (!await _runTest() || !mounted) return;
    }
    final (config, token) = draft;
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(hostsProvider.notifier)
          .saveDirect(config, token: token, cookie: _testedOk ? _testedCookie : null);
      if (!mounted) return;
      if (!saved) {
        setState(() => _formError = context.l10n.commonSaveFailed);
        return;
      }
      // A failed active connection tries again with what was just saved.
      final host = HostRef.direct(_id);
      if (ref.read(activeHostProvider) == host &&
          ref.read(hostLinkStatusProvider(host)).value?.phase == HostLinkPhase.failed) {
        ref.read(remoteConnectionProvider(host).notifier).retry();
      }
      Navigator.of(context).pop(config);
    } catch (_) {
      if (mounted) setState(() => _formError = context.l10n.commonSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Google sign-in at the gate, then the same test-and-save as 保存.
  Future<void> _googleSignIn() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final l10n = context.l10n;
    final origin = normalizeSignInUrl(_signIn.text);
    if (origin == null) {
      final problem = _signIn.text.trim().isEmpty ? l10n.directSignInUrlRequired : l10n.directSignInUrlInvalid;
      setState(() => _errors = {..._errors, _F.signIn: problem});
      return;
    }
    setState(() {
      _signingIn = true;
      _formError = null;
    });
    final DirectSignInResult result;
    try {
      result = await signInWithGoogle(origin, authenticate: ref.read(directWebAuthenticatorProvider));
    } on DirectSignInException catch (e) {
      if (mounted) {
        setState(() {
          _signingIn = false;
          _formError = e.message;
        });
      }
      return;
    }
    if (!mounted) return;
    _signIn.text = origin.toString();
    _url.text = result.baseUri.toString();
    _token.text = result.token;
    setState(() {
      _signingIn = false;
      _errors = const {};
    });
    await _save();
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.remoteDeleteHostTitle(widget.existing!.name)),
        content: Text(l10n.directDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(hostsProvider.notifier).removeDirect(_id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted || text == null || text.isEmpty) return;
    _token.text = text;
    if (_errors.containsKey(_F.token)) setState(() => _errors = {..._errors}..remove(_F.token));
  }

  void _edited(_F field) {
    if (_errors.containsKey(field)) setState(() => _errors = {..._errors}..remove(field));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final testing = _test != null;
    final busy = testing || _saving || _signingIn;
    final mono = AppType.mono(size: 15, color: scheme.onSurface, height: 1.4);

    final page = AppPage.list(
      title: _editing ? l10n.remoteEditHost : l10n.directAdd,
      subtitle: _editing ? null : Text(l10n.directFormIntro),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_google)
              SettingsSection(
                title: l10n.directGoogleSection,
                footer: Text(l10n.directGoogleFooter),
                children: [
                  FormFieldGroup(
                    children: [
                      FormFieldBlock(
                        error: _errors[_F.signIn],
                        label: l10n.directSignInUrlLabel,
                        child: TextField(
                          key: const ValueKey('direct-sign-in-url'),
                          controller: _signIn,
                          autofocus: !_manual && _signIn.text.isEmpty,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.go,
                          style: mono,
                          onChanged: (_) => _edited(_F.signIn),
                          onSubmitted: busy ? null : (_) => unawaited(_googleSignIn()),
                          decoration: InputDecoration(
                            hintText: l10n.directUrlHint,
                            error: _errors[_F.signIn] == null ? null : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: FilledButton.icon(
                          key: const ValueKey('direct-google'),
                          onPressed: busy ? null : () => unawaited(_googleSignIn()),
                          icon: _signingIn
                              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(AppIcons.account, size: 18),
                          label: Text(_signingIn ? l10n.directGoogleSigningIn : l10n.directGoogleSignIn),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            if (!_manual)
              Center(
                child: TextButton(
                  key: const ValueKey('direct-manual'),
                  style: TextButton.styleFrom(foregroundColor: colors.textTertiary),
                  onPressed: busy ? null : () => setState(() => _manual = true),
                  child: Text(l10n.directManualEntry),
                ),
              ),
            if (_manual)
              SettingsSection(
                title: l10n.remoteHostBasicInfo,
                footer: Text(l10n.directTokenHelp),
                children: [
                  FormFieldGroup(
                    children: [
                      FormFieldBlock(
                        label: l10n.commonName,
                        child: TextField(
                          controller: _name,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(hintText: l10n.remoteHostNameHint),
                        ),
                      ),
                      FormFieldBlock(
                        error: _errors[_F.url],
                        label: l10n.directUrlLabel,
                        child: TextField(
                          key: const ValueKey('direct-url'),
                          controller: _url,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.next,
                          style: mono,
                          onChanged: (_) => _edited(_F.url),
                          decoration: InputDecoration(
                            hintText: l10n.directUrlHint,
                            error: _errors[_F.url] == null ? null : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                      FormFieldBlock(
                        error: _errors[_F.token],
                        label: l10n.directTokenLabel,
                        helper: _hasSavedToken ? l10n.directTokenSaved : null,
                        trailing: RemoteSmallTextButton(label: l10n.commonPaste, onPressed: _paste),
                        child: TextField(
                          key: const ValueKey('direct-token'),
                          controller: _token,
                          obscureText: _obscure,
                          obscuringCharacter: '•',
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          keyboardType: TextInputType.visiblePassword,
                          style: mono,
                          onChanged: (_) => _edited(_F.token),
                          decoration: InputDecoration(
                            hintText: l10n.directTokenHint,
                            error: _errors[_F.token] == null ? null : const SizedBox.shrink(),
                            suffixIcon: IconButton(
                              tooltip: _obscure ? l10n.remoteShow : l10n.commonHide,
                              icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                              onPressed: () => setState(() => _obscure = !_obscure),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            if (_testStatus case final status?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: LinkProgressCard(
                  status: status,
                  steps: directLinkSteps,
                  onRetry: testing ? null : () => unawaited(_runTest()),
                ),
              ),
            if (_formError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
              ),
            if (_editing)
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.danger),
                  onPressed: _delete,
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.remoteDeleteHost),
                ),
              ),
            SizedBox(height: _manual ? RemoteFormBar.height : 24),
          ],
        ),
      ],
    );

    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && _signature() != _clean,
      child: Stack(
        children: [
          page,
          if (_manual)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.viewInsetsOf(context).bottom,
              child: RemoteFormBar(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: busy ? null : () => unawaited(_runTest()),
                      icon: testing
                          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(AppIcons.testConnection, size: 19),
                      label: Text(testing ? l10n.remoteTesting : l10n.remoteTestConnection),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('direct-save'),
                      onPressed: busy ? null : _save,
                      child: Text(l10n.commonSave),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
