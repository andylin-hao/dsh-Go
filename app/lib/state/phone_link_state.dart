// Agents on computers using this phone, and the phone driving agents there (docs/design/
// remote-agents.md): which computers have access (SSH hosts, and computers paired over the
// network), and the live dsh-go-link attachment for each while phone control is on.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dsh_link/dsh_link.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../remote/link/lan_link.dart';
import '../remote/link/phone_link.dart';
import 'app_info.dart';
import 'connection_state.dart';
import 'hosts_state.dart';
import 'phone_state.dart';

/// Computers (SSH host ids, `lan-…` ids) whose agents may use this phone. Off by default.
class PhoneLinkGrantsController extends Notifier<Set<String>> {
  static const key = 'phone_link_hosts';

  late Future<void> _loaded;

  @override
  Set<String> build() {
    _loaded = _load();
    return const {};
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getStringList(key);
      if (stored != null && ref.mounted) state = stored.toSet();
    } catch (_) {
      // No preferences backend: nothing granted.
    }
  }

  Future<void> set(String id, bool on) async {
    await _loaded;
    if (!ref.mounted) return;
    state = on ? {...state, id} : ({...state}..remove(id));
    try {
      await (await SharedPreferences.getInstance()).setStringList(key, state.toList()..sort());
    } catch (_) {
      // Kept for this run only.
    }
  }
}

final phoneLinkGrantsProvider = NotifierProvider<PhoneLinkGrantsController, Set<String>>(PhoneLinkGrantsController.new);

/// Computers paired over the network (`dsh-go-link pair`). Keys only: nothing secret is stored.
class LanComputersController extends Notifier<List<LanComputer>> {
  static const key = 'phone_link_lan';

  late Future<void> _loaded;

  /// Pairing links' one-time secrets, until their first attach (memory only).
  final Map<String, String> pendingSecrets = {};

  @override
  List<LanComputer> build() {
    _loaded = _load();
    return const [];
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(key);
      if (stored == null || !ref.mounted) return;
      state = [for (final c in jsonDecode(stored) as List) ?LanComputer.fromJson(c)];
    } catch (_) {
      // Unreadable: nothing paired.
    }
  }

  Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, jsonEncode([for (final c in state) c.toJson()]));
    } catch (_) {
      // Kept for this run only.
    }
  }

  /// Adds (or refreshes) the computer in [pairing], keeps its secret for the first attach, grants it.
  Future<LanComputer> pair(LinkPairing pairing) async {
    await _loaded;
    final computer = LanComputer.of(pairing);
    pendingSecrets[computer.id] = pairing.secret;
    state = [
      for (final c in state)
        if (c.id != computer.id) c,
      computer,
    ];
    await _save();
    await ref.read(phoneLinkGrantsProvider.notifier).set(computer.id, true);
    return computer;
  }

  Future<void> forget(String id) async {
    await _loaded;
    pendingSecrets.remove(id);
    state = [
      for (final c in state)
        if (c.id != id) c,
    ];
    await _save();
    await ref.read(phoneLinkGrantsProvider.notifier).set(id, false);
  }
}

final lanComputersProvider = NotifierProvider<LanComputersController, List<LanComputer>>(LanComputersController.new);

/// This phone's network identity (created once, in the secret store).
final linkIdentityProvider = FutureProvider<LinkIdentity>((ref) => LinkIdentity.load(ref.read(secretStoreProvider)));

/// The phone side of the relay: `dsh/phone`'s `remote*` methods.
class PhoneChannelRemote implements PhoneLinkRemote {
  PhoneChannelRemote(this.channel);

  final PhoneChannel channel;

  @override
  Future<Map<String, Object?>> catalog() => channel.remoteCatalog();

  @override
  Future<void> open(String ch, {required String key, String? client, required String host}) async {
    if (!await channel.remoteOpen(ch, key: key, client: client, host: host)) {
      throw StateError('the phone did not open $ch');
    }
  }

  @override
  Future<String?> line(String ch, String line) => channel.remoteLine(ch, line);

  @override
  Future<void> close(String ch) => channel.remoteClose(ch);

  @override
  Future<void> finish(String key) => channel.remoteFinish(key);
}

/// A computer the phone may link with: an SSH host or a network-paired computer.
sealed class LinkTarget {
  const LinkTarget();

  String get id;
  String get name;

  /// Fields that need a new link when they change (a rename doesn't).
  String get connectionKey;
}

final class SshLinkTarget extends LinkTarget {
  const SshLinkTarget(this.config);

  final SshHostConfig config;

  @override
  String get id => config.id;

  @override
  String get name => config.name;

  @override
  String get connectionKey => config.connectionKey;
}

final class LanLinkTarget extends LinkTarget {
  const LanLinkTarget(this.computer);

  final LanComputer computer;

  @override
  String get id => computer.id;

  @override
  String get name => computer.name;

  @override
  String get connectionKey => '${computer.key}\u0000${computer.addresses.join(',')}';
}

typedef PhoneLinkFactory = PhoneLink Function(Ref ref, LinkTarget target);

/// Random per app run: lets a computer's log tell phones apart, identifies nothing else.
final _phoneId = List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();

final phoneLinkFactoryProvider = Provider<PhoneLinkFactory>(
  (ref) => (ref, target) {
    final maker = ref.read(phoneProvider).status.device.manufacturer;
    final LinkDialer dialer = switch (target) {
      SshLinkTarget(:final config) => SshLinkDialer(
        config: config,
        loadSecrets: () => ref.read(hostsProvider.notifier).loadSecrets(config.id),
        transportFactory: ref.read(sshTransportFactoryProvider),
        script: () => rootBundle.loadString('assets/link/dsh-go-link.cjs'),
      ),
      LanLinkTarget(:final computer) => LanLinkDialer(
        computer: computer,
        identity: () => ref.read(linkIdentityProvider.future),
        pairingSecret: ref.read(lanComputersProvider.notifier).pendingSecrets.remove(computer.id),
      ),
    };
    return PhoneLink(
      dialer: dialer,
      remote: PhoneChannelRemote(ref.read(phoneChannelProvider)),
      phone: LinkPhone(id: _phoneId, name: maker == null || maker.isEmpty ? 'Android' : maker, app: AppInfo.version),
      kicks: ref.read(networkKicksProvider),
    );
  },
);

/// One [PhoneLink] per granted computer while phone control is on; their statuses by id. Kept
/// alive by the home shell ([PhoneStopWatcher]), so the computers' agents reach the phone with the
/// app in the background too.
class PhoneLinksController extends Notifier<Map<String, PhoneLinkStatus>> {
  final _links = <String, PhoneLink>{};
  final _subs = <String, StreamSubscription<PhoneLinkStatus>>{};
  final _keys = <String, String>{};

  @override
  Map<String, PhoneLinkStatus> build() {
    ref.onDispose(() {
      for (final id in _links.keys.toList()) {
        _drop(id);
      }
      if (_keeping) unawaited(ref.read(phoneChannelProvider).linkService(false));
    });
    ref.listen(phoneLinkGrantsProvider, (_, _) => _sync());
    ref.listen(hostsProvider, (_, _) => _sync());
    ref.listen(lanComputersProvider, (_, _) => _sync());
    ref.listen(phoneProvider.select((s) => s.loaded && s.status.ready && s.status.enabled), (_, _) => _sync());
    // The person stops the phone task a computer's agent session drives: that session's turn stops
    // too. Screen off or the service going away end the phone task alone; the agent goes on.
    ref.listen(phoneProvider.select((s) => s.status.task), (before, task) {
      final key = task.origin?.key;
      if (key == null || !task.stopped || !task.stoppedByPerson || (before?.stopped ?? false)) return;
      for (final link in _links.values) {
        if (link.owns(key)) unawaited(link.stopOwner(key));
      }
    });
    scheduleMicrotask(_sync);
    return const {};
  }

  PhoneLink? link(String id) => _links[id];

  /// Live links by computer id (the agent cockpit reads their sessions).
  Map<String, PhoneLink> get links => Map.unmodifiable(_links);

  /// Tries a waiting or failed link again now.
  void retry(String id) => _links[id]?.retry();

  Map<String, LinkTarget> _targets() => {
    for (final h in ref.read(hostsProvider).ssh) h.id: SshLinkTarget(h),
    for (final c in ref.read(lanComputersProvider)) c.id: LanLinkTarget(c),
  };

  void _sync() {
    if (!ref.mounted) return;
    final on = ref.read(phoneProvider.select((s) => s.loaded && s.status.ready && s.status.enabled));
    final grants = ref.read(phoneLinkGrantsProvider);
    final targets = _targets();
    final want = on ? grants.where(targets.containsKey).toSet() : const <String>{};
    for (final id in _links.keys.toList()) {
      if (!want.contains(id) || _keys[id] != targets[id]!.connectionKey) _drop(id);
    }
    for (final id in want) {
      final target = targets[id]!;
      final existing = _links[id];
      if (existing != null) {
        final dialer = existing.dialer;
        if (target is SshLinkTarget && dialer is SshLinkDialer) dialer.config = target.config;
        continue;
      }
      final link = ref.read(phoneLinkFactoryProvider)(ref, target);
      _links[id] = link;
      _keys[id] = target.connectionKey;
      _subs[id] = link.statuses.listen((s) {
        if (ref.mounted && _links[id] == link) state = {...state, id: s};
      });
      link.start();
    }
    state = {for (final id in _links.keys) id: _links[id]!.status};
    // Android freezes a backgrounded app within seconds; a link must keep answering its computer.
    final keep = _links.isNotEmpty;
    if (keep != _keeping) {
      _keeping = keep;
      unawaited(ref.read(phoneChannelProvider).linkService(keep));
    }
  }

  bool _keeping = false;

  void _drop(String id) {
    unawaited(_subs.remove(id)?.cancel());
    _keys.remove(id);
    unawaited(_links.remove(id)?.close());
  }
}

final phoneLinksProvider = NotifierProvider<PhoneLinksController, Map<String, PhoneLinkStatus>>(PhoneLinksController.new);
