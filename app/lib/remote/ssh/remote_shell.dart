import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of one non-interactive remote command.
class RemoteExecResult {
  const RemoteExecResult(this.exitCode, this.stdout, this.stderr);

  final int? exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

/// Something that can run a POSIX `sh` script on the remote: the SSH
/// session in production, a local `sh` in tests.
abstract class RemoteShell {
  /// Runs [script] with `sh -lc` (login shell, so `~/.profile` PATH tweaks
  /// apply whatever the account's own shell is).
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)});
}

/// Single-quotes [value] for POSIX sh.
String shQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// `sh -lc '<script>'`: works under bash, zsh, fish and busybox accounts alike.
String loginShell(String script) => 'sh -lc ${shQuote(script)}';

/// The second try, for a host where `sh -l` dies before the script starts: a profile it can't
/// parse, such as bash syntax in `/etc/profile.d` read by dash ("Syntax error: "(" unexpected").
/// bash reads that profile fine (and brings its PATH); without bash, no profile at all.
String fallbackShell(String script) =>
    'sh -c ${shQuote(r'if command -v bash >/dev/null 2>&1; then exec bash -lc "$1"; fi; exec sh -c "$1"')} sh '
    '${shQuote(script)}';

/// The line every script run by [runScript] prints first: without it, its shell never got there.
const shellStarted = 'DSHGO-SHELL-STARTED';

/// Runs [script] on a host through [exec] (one remote command each): with [loginShell], and when
/// that shell never reached the script, once more with [fallbackShell]. The result has the start
/// line taken out; when neither try got there, it is the first one's (its stderr says why).
Future<RemoteExecResult> runScript(String script, Future<RemoteExecResult> Function(String command) exec) async {
  final announced = "printf '%s\\n' $shellStarted\n$script";
  final first = await exec(loginShell(announced));
  if (_started(first) case final ok?) return ok;
  final second = await exec(fallbackShell(announced));
  return _started(second) ?? first;
}

RemoteExecResult? _started(RemoteExecResult r) {
  final i = r.stdout.indexOf('$shellStarted\n');
  if (i < 0) return null;
  return RemoteExecResult(r.exitCode, r.stdout.substring(0, i) + r.stdout.substring(i + shellStarted.length + 1), r.stderr);
}

/// Runs scripts with the local `/bin/sh` (tests, and a "remote" that is this
/// machine).
class LocalProcessShell implements RemoteShell {
  LocalProcessShell({this.environment, this.workingDirectory});

  final Map<String, String>? environment;
  final String? workingDirectory;

  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) async {
    final process = await Process.start(
      '/bin/sh',
      ['-c', script],
      environment: environment,
      workingDirectory: workingDirectory,
    );
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    return RemoteExecResult(code, await out, await err);
  }
}
