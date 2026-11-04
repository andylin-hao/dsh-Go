import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../ssh/remote_shell.dart';

/// Marker before every structured line, so login banners can't be read as results.
const _tag = 'DSHGOLINK';

/// The running dsh-go-link daemon on a computer, as `start --json` reports it.
class LinkEndpoint {
  const LinkEndpoint({required this.port, required this.token, required this.version, this.pid});

  /// The phone listener on the computer's loopback, reached through the SSH tunnel.
  final int port;

  /// Rotates with every daemon start. Never logged or stored.
  final String token;
  final String version;
  final int? pid;
}

/// How to register the phone tools with one agent, with that computer's paths (`config --json`).
class AgentSetup {
  const AgentSetup({required this.id, required this.name, required this.command, required this.text, this.file});

  static AgentSetup? fromJson(Object? v) {
    if (v is! Map) return null;
    final id = v['id'];
    final name = v['name'];
    final text = v['text'];
    if (id is! String || name is! String || text is! String) return null;
    final file = v['file'];
    return AgentSetup(
      id: id,
      name: name,
      command: v['kind'] == 'command',
      text: text,
      file: file is String ? file : null,
    );
  }

  /// `claude-code`, `codex`, `opencode`, `antigravity`, `other`.
  final String id;
  final String name;

  /// [text] is a command to run (else a config snippet for [file]).
  final bool command;
  final String text;
  final String? file;
}

enum LinkBootstrapFailure { noShell, nodeMissing, nodeOld, install, start }

class LinkBootstrapError implements Exception {
  const LinkBootstrapError(this.failure, {this.detail});

  final LinkBootstrapFailure failure;

  /// Remote output for "details" (never contains the token: `start` prints it only on success).
  final String? detail;

  @override
  String toString() => 'LinkBootstrapError(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// Installs the app's copy of dsh-go-link on a computer and starts its daemon, over any
/// [RemoteShell] (the SSH session). Files live in `~/.dsh-go/link/` (mode 700); the script is
/// rewritten only when its SHA-256 differs, so the usual connect is one round trip, and an update
/// replaces a running daemon of another version — once no agent session is working there: until
/// then the older daemon keeps serving (its caps say what it offers) and retires when they finish.
class LinkBootstrap {
  LinkBootstrap(this.shell, {required this.script, this.environment = const {}})
    : sha = sha256.convert(utf8.encode(script)).toString();

  final RemoteShell shell;

  /// The contents of `dsh-go-link.cjs` this app ships.
  final String script;
  final String sha;

  /// Exported first (tests isolate `HOME` this way).
  final Map<String, String> environment;

  Future<LinkEndpoint> ensure() async {
    var result = await shell.run(startScript(upload: false), timeout: const Duration(seconds: 40));
    if (_lines(result.stdout).any((l) => l == '$_tag-ERR upload')) {
      await _upload();
      result = await shell.run(startScript(upload: true), timeout: const Duration(seconds: 60));
    }
    return parseStart(result);
  }

  /// Base64 of the script per command (one `sh -c` argument each). Linux caps a single argument
  /// at 128 KiB (MAX_ARG_STRLEN) and the script's base64 is past that, so it goes in pieces.
  static const uploadChunk = 48 * 1024;

  /// The script's base64 into `$D/bin/dsh-go-link.b64`, a piece per command; the start script
  /// checks its hash, installs it and removes the file.
  Future<void> _upload() async {
    final b64 = base64.encode(utf8.encode(script));
    for (var i = 0; i < b64.length; i += uploadChunk) {
      final part = b64.substring(i, i + uploadChunk > b64.length ? b64.length : i + uploadChunk);
      final result = await shell.run(
        'umask 077\nD="\$HOME/.dsh-go/link"\nmkdir -p "\$D/bin" && '
        "printf '%s' '$part' ${i == 0 ? '>' : '>>'} \"\$D/bin/dsh-go-link.b64\" && printf '$_tag-OK\\n'\n",
        timeout: const Duration(seconds: 30),
      );
      if (!_lines(result.stdout).contains('$_tag-OK')) {
        throw LinkBootstrapError(LinkBootstrapFailure.install, detail: _tail(result));
      }
    }
  }

  /// What `config --json` prints on that computer: per-agent snippets with its node and script paths.
  Future<List<AgentSetup>> agentSetup() async {
    final result = await shell.run(
      '${_prelude()}"\$N" "\$D/bin/dsh-go-link.cjs" config --json 2>&1\n',
      timeout: const Duration(seconds: 20),
    );
    _checkErrors(result);
    final json = _tagged(result.stdout);
    final agents = json is Map ? json['agents'] : null;
    if (agents is! List) throw LinkBootstrapError(LinkBootstrapFailure.start, detail: _tail(result));
    return [for (final a in agents) ?AgentSetup.fromJson(a)];
  }

  String _prelude() {
    final b = StringBuffer()..writeln('umask 077');
    for (final e in environment.entries) {
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(e.key)) continue;
      b.writeln('${e.key}=${shQuote(e.value)}; export ${e.key}');
    }
    b.write(r'''
D="$HOME/.dsh-go/link"
mkdir -p "$D/bin" && chmod 700 "$HOME/.dsh-go" "$D" "$D/bin" 2>/dev/null
N=$(command -v node 2>/dev/null)
if [ -z "$N" ]; then
  for c in /opt/homebrew/bin/node /usr/local/bin/node "$HOME/.volta/bin/node" $(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | tail -n 1); do
    if [ -x "$c" ]; then N=$c; break; fi
  done
fi
if [ -z "$N" ]; then printf 'DSHGOLINK-ERR node_missing\n'; exit 0; fi
V=$("$N" -p 'process.versions.node' 2>/dev/null)
case "$V" in
  ''|[0-9].*|1[0-7].*) printf 'DSHGOLINK-ERR node_old %s\n' "$V"; exit 0;;
esac
''');
    return b.toString();
  }

  /// Finds Node (login PATH, then the usual install places), checks the installed copy's hash,
  /// installs ours when it differs and [upload] (the uploaded base64, see [_upload]) is there,
  /// then `start --json`.
  String startScript({required bool upload}) {
    final b = StringBuffer(_prelude())
      ..write(r'''
F="$D/bin/dsh-go-link.cjs"
H=$("$N" -e 'try{process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))}catch(e){}' "$F")
''')
      ..writeln('if [ "\$H" != "$sha" ]; then');
    if (!upload) {
      b.writeln("  printf 'DSHGOLINK-ERR upload\\n'; exit 0");
    } else {
      b.writeln(
        r'''  "$N" -e 'const fs=require("fs"),c=require("crypto"),u=process.argv[3];'''
        r'''const b=Buffer.from(fs.readFileSync(u,"utf8").replace(/\s+/g,""),"base64");try{fs.unlinkSync(u)}catch(e){}'''
        r'''if(c.createHash("sha256").update(b).digest("hex")!==process.argv[2]){process.stderr.write("hash mismatch\n");process.exit(3)}'''
        r'''const t=process.argv[1]+".tmp";fs.writeFileSync(t,b,{mode:0o700});fs.renameSync(t,process.argv[1])' '''
        '"\$F" "$sha" "\$D/bin/dsh-go-link.b64" || { printf \'DSHGOLINK-ERR install\\n\'; exit 0; }',
      );
    }
    b
      ..writeln('fi')
      ..writeln(r'''"$N" "$F" start --json 2>&1 || printf 'DSHGOLINK-ERR start\n' ''');
    return b.toString();
  }

  LinkEndpoint parseStart(RemoteExecResult result) {
    _checkErrors(result);
    final v = _tagged(result.stdout);
    if (v is Map && v['port'] is int && v['token'] is String) {
      return LinkEndpoint(
        port: v['port'] as int,
        token: v['token'] as String,
        version: v['version'] is String ? v['version'] as String : '',
        pid: v['pid'] is int ? v['pid'] as int : null,
      );
    }
    throw LinkBootstrapError(LinkBootstrapFailure.start, detail: _tail(result));
  }

  void _checkErrors(RemoteExecResult result) {
    final lines = _lines(result.stdout);
    if (!lines.any((l) => l.startsWith(_tag)) &&
        RegExp(r"'sh' is not recognized|sh: (command )?not found|command not found: sh").hasMatch(result.stderr)) {
      throw LinkBootstrapError(LinkBootstrapFailure.noShell, detail: result.stderr.trim());
    }
    for (final l in lines) {
      if (!l.startsWith('$_tag-ERR ')) continue;
      final rest = l.substring(_tag.length + 5).trim();
      final code = rest.split(' ').first;
      final failure = switch (code) {
        'node_missing' => LinkBootstrapFailure.nodeMissing,
        'node_old' => LinkBootstrapFailure.nodeOld,
        'install' => LinkBootstrapFailure.install,
        _ => LinkBootstrapFailure.start,
      };
      final detail = failure == LinkBootstrapFailure.nodeOld ? rest.substring(code.length).trim() : _tail(result);
      throw LinkBootstrapError(failure, detail: detail.isEmpty ? null : detail);
    }
  }

  static Iterable<String> _lines(String out) => const LineSplitter().convert(out).map((l) => l.trim());

  static Object? _tagged(String out) {
    for (final l in _lines(out)) {
      if (!l.startsWith('$_tag ')) continue;
      try {
        return jsonDecode(l.substring(_tag.length + 1));
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  /// The last lines of output, for "details"; tagged lines dropped (they may carry the token).
  static String _tail(RemoteExecResult result) {
    final lines = [
      ..._lines(result.stdout).where((l) => l.isNotEmpty && !l.startsWith(_tag)),
      ..._lines(result.stderr).where((l) => l.isNotEmpty),
    ];
    return lines.skip(lines.length > 8 ? lines.length - 8 : 0).join('\n');
  }
}
