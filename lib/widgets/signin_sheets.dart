import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../github_service.dart';
import '../main.dart';
import '../theme.dart';

/// Bottom sheet for GitHub device-flow sign-in.
///
/// Shows the one-time code big and center (the code the GitHub page asks
/// for), with copy + open-browser buttons, then waits for authorization and
/// pops when the connection succeeds. Solved the "code is buried in a status
/// line" problem from the old flow.
class GitHubDeviceFlowSheet extends StatefulWidget {
  const GitHubDeviceFlowSheet({super.key});

  /// Runs the device flow and returns true when GitHub is connected.
  static Future<bool> show(BuildContext context) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const GitHubDeviceFlowSheet(),
    );
    return result == true;
  }

  @override
  State<GitHubDeviceFlowSheet> createState() => _GitHubDeviceFlowSheetState();
}

class _GitHubDeviceFlowSheetState extends State<GitHubDeviceFlowSheet> {
  String? _userCode;
  String? _deviceCode;
  String? _verificationUri;
  String? _error;
  bool _copied = false;
  bool _waiting = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      final flow = await githubService.startDeviceFlow();
      if (!mounted) return;
      setState(() {
        _userCode = flow.userCode;
        _deviceCode = flow.deviceCode;
        _verificationUri = flow.verificationUri;
      });
      await _waitForAuthorization();
    } on GitHubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start GitHub sign-in: $e');
    }
  }

  Future<void> _waitForAuthorization() async {
    setState(() => _waiting = true);
    try {
      // completeDeviceFlow stores the token on success and throws on
      // denial/expiry/timeout.
      await githubService.completeDeviceFlow(_deviceCode!);
      if (!mounted) return;
      setState(() {
        _waiting = false;
        _done = true;
      });
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.pop(context, true);
    } on GitHubException catch (e) {
      if (mounted) {
        setState(() {
          _waiting = false;
          _error = e.message;
        });
      }
    }
  }

  /// Copies the one-time code to the clipboard.
  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: _userCode ?? ''));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  /// Copies the code and opens the verification page in the browser.
  Future<void> _openGitHub() async {
    if (_verificationUri == null) return;
    await Clipboard.setData(ClipboardData(text: _userCode ?? ''));
    if (!mounted) return;
    setState(() => _copied = true);
    final opened = await launchUrl(
      Uri.parse(_verificationUri!),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      setState(() => _error = 'Could not open the browser. Visit $_verificationUri and enter the code.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.navyPanel,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: AppTheme.border)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: AppTheme.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Icon(Icons.code, color: AppTheme.glowAccent, size: 32),
            const SizedBox(height: 10),
            Text(
              _done ? 'GitHub connected!' : 'Sign in to GitHub',
              style: const TextStyle(
                  color: AppTheme.text, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              _done
                  ? 'Loading your repositories…'
                  : _waiting
                      ? 'Waiting for authorization…'
                      : 'On the GitHub page, enter this one-time code:',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.muted, fontSize: 13),
            ),
            const SizedBox(height: 18),
            if (_userCode == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(18),
                child: CircularProgressIndicator(),
              )
            else if (_userCode != null) ...[
              // The code itself, huge and readable — this is what GitHub
              // asks for on its "Authorize your device" page.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: AppTheme.bg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.glowAccent, width: 1.5),
                  boxShadow: const [
                    BoxShadow(color: AppTheme.glowSoft, blurRadius: 18),
                  ],
                ),
                child: Text(
                  _userCode!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.text,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 6,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _copyCode,
                    icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
                    label: Text(_copied ? 'Copied' : 'Copy code'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _waiting ? null : _openGitHub,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open GitHub'),
                  ),
                ),
              ]),
              if (_waiting) ...[
                const SizedBox(height: 14),
                const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('Waiting for you to finish on github.com…',
                      style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                ]),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.err, fontSize: 13)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
              ),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel',
                  style: TextStyle(color: AppTheme.muted)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Bottom sheet for the email-OTP sign-in option: enter email → receive a
/// 6-digit code → enter it → signed in. This is CodePilot's own account
/// link (it is NOT GitHub login — GitHub does not offer email OTP).
class EmailOtpSheet extends StatefulWidget {
  const EmailOtpSheet({super.key});

  /// Returns true when the email identity is verified.
  static Future<bool> show(BuildContext context) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const EmailOtpSheet(),
    );
    return result == true;
  }

  @override
  State<EmailOtpSheet> createState() => _EmailOtpSheetState();
}

class _EmailOtpSheetState extends State<EmailOtpSheet> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result =
        await emailOtpService.sendCode(_email.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        _codeSent = true;
      } else {
        _error = result.error;
      }
    });
  }

  Future<void> _verifyCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await emailOtpService.verifyCode(_email.text, _code.text);
    if (!mounted) return;
    if (result.ok) {
      await settingsStore.saveEmailIdentity(_email.text.trim());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = result.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.navyPanel,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: AppTheme.border)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: AppTheme.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Icon(
              _done ? Icons.mark_email_read : Icons.alternate_email,
              color: AppTheme.glowAccent,
              size: 32,
            ),
            const SizedBox(height: 10),
            Text(
              _done
                  ? 'Email verified!'
                  : _codeSent
                      ? 'Enter the code'
                      : 'Sign in with email',
              style: const TextStyle(
                  color: AppTheme.text, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              _done
                  ? 'Your email is linked to CodePilot.'
                  : _codeSent
                      ? 'We sent a 6-digit code to ${_email.text.trim()}'
                      : 'We\'ll email you a one-time code — no password needed.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.muted, fontSize: 13),
            ),
            const SizedBox(height: 18),
            if (!_codeSent) ...[
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                enabled: !_busy,
                style: const TextStyle(color: AppTheme.text),
                cursorColor: AppTheme.glowAccent,
                decoration: const InputDecoration(
                  hintText: 'you@example.com',
                  prefixIcon: Icon(Icons.mail_outline, color: AppTheme.muted),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _sendCode,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send, size: 18),
                  label: Text(_busy ? 'Sending…' : 'Send code'),
                ),
              ),
            ] else ...[
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                enabled: !_busy,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppTheme.text, fontSize: 24, letterSpacing: 10),
                cursorColor: AppTheme.glowAccent,
                decoration: const InputDecoration(
                  hintText: '••••••',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _verifyCode,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.verified_user, size: 18),
                  label: Text(_busy ? 'Verifying…' : 'Verify and continue'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _codeSent = false;
                          _code.clear();
                          _error = null;
                        }),
                child: const Text('Use a different email',
                    style: TextStyle(color: AppTheme.muted, fontSize: 13)),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.err, fontSize: 13)),
            ],
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.muted)),
            ),
          ]),
        ),
      ),
    );
  }
}
