// dsh-go-link over the local network (no sshd needed): `dsh-go-link pair` on the computer shows a
// QR code with a `dshgo://link?…` pairing link; the phone scans it, dials the computer, and runs
// Noise IK against the daemon's key from the link. The phone's own key is pinned on the computer
// at the first connection, which carries the link's one-time secret. Design:
// docs/design/remote-agents.md §6.2.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_remote/dsh_remote.dart' show NoiseIkSession, NoiseRole, X25519KeyPair, formatFingerprint, identityFingerprint;

import '../secret_store.dart';

/// Agrees with host/dsh-go-link (`LINK_PROLOGUE`).
final List<int> linkPrologue = [...utf8.encode('DSH-GO-LINK'), 0, ...utf8.encode('v=1')];

/// What a pairing link carries.
class LinkPairing {
  const LinkPairing({required this.name, required this.key, required this.secret, required this.addresses});

  /// `dshgo://link?v=1&n=<name>&k=<daemon key>&s=<one-time secret>&a=<host:port,…>`; null when malformed.
  static LinkPairing? parse(Uri uri) {
    if (uri.scheme != 'dshgo' || uri.host != 'link') return null;
    final q = uri.queryParameters;
    if (q['v'] != '1') return null;
    final key = q['k'] ?? '';
    final secret = q['s'] ?? '';
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(key) || !RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(secret)) return null;
    final addresses = [
      for (final a in (q['a'] ?? '').split(',')) ?LanAddress.tryParse(a.trim()),
    ];
    if (addresses.isEmpty) return null;
    final name = (q['n'] ?? '').replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return LinkPairing(name: name.isEmpty ? addresses.first.host : name, key: key, secret: secret, addresses: addresses);
  }

  final String name;
  final String key;
  final String secret;
  final List<LanAddress> addresses;
}

class LanAddress {
  const LanAddress(this.host, this.port);

  static LanAddress? tryParse(String text) {
    final at = text.lastIndexOf(':');
    if (at <= 0) return null;
    final port = int.tryParse(text.substring(at + 1));
    final host = text.substring(0, at).replaceAll('[', '').replaceAll(']', '');
    if (port == null || port <= 0 || port > 65535 || host.isEmpty || host.length > 253) return null;
    return LanAddress(host, port);
  }

  final String host;
  final int port;

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

/// A computer paired over the network.
class LanComputer {
  const LanComputer({required this.id, required this.name, required this.key, required this.addresses, this.pairedAt});

  factory LanComputer.of(LinkPairing p) => LanComputer(
    id: 'lan-${p.key.substring(0, 12)}',
    name: p.name,
    key: p.key,
    addresses: p.addresses,
    pairedAt: DateTime.now(),
  );

  static LanComputer? fromJson(Object? v) {
    if (v is! Map) return null;
    final id = v['id'];
    final name = v['name'];
    final key = v['key'];
    final addresses = v['addresses'];
    if (id is! String || name is! String || key is! String || addresses is! List) return null;
    return LanComputer(
      id: id,
      name: name,
      key: key,
      addresses: [
        for (final a in addresses)
          if (a is String) ?LanAddress.tryParse(a),
      ],
      pairedAt: DateTime.tryParse('${v['pairedAt'] ?? ''}'),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'key': key,
    'addresses': [for (final a in addresses) '$a'],
    if (pairedAt != null) 'pairedAt': pairedAt!.toIso8601String(),
  };

  /// `lan-` and the start of the daemon's key: stable, and never the same as an SSH host's id.
  final String id;
  final String name;

  /// The daemon's X25519 public key (base64url): pinned, the only computer this phone talks to here.
  final String key;
  final List<LanAddress> addresses;
  final DateTime? pairedAt;

  /// `ABCD EF01 2345`, to compare with `dsh-go-link status` on the computer.
  String get fingerprint => formatFingerprint(identityFingerprint(key));

  LanComputer withAddresses(List<LanAddress> next) => LanComputer(id: id, name: name, key: key, addresses: next, pairedAt: pairedAt);
}

/// This phone's network identity (X25519), kept in the secret store.
class LinkIdentity {
  LinkIdentity._(this.privateKey, this.publicKey);

  static const _storeKey = 'link.phone.x25519';

  static Future<LinkIdentity> load(SecretStore store) async {
    final stored = await store.read(_storeKey);
    if (stored != null && stored.isNotEmpty) {
      try {
        final pair = X25519KeyPair.fromPrivateKey(base64Url.decode(base64Url.normalize(stored)));
        return LinkIdentity._(pair.privateKeyBase64Url, pair.publicKeyBase64Url);
      } catch (_) {
        // Unreadable: a new identity (the computers ask to pair again).
      }
    }
    final pair = X25519KeyPair.generate();
    await store.write(_storeKey, pair.privateKeyBase64Url);
    return LinkIdentity._(pair.privateKeyBase64Url, pair.publicKeyBase64Url);
  }

  final String privateKey;
  final String publicKey;
}

/// The daemon's key isn't the pinned one (message 2 didn't authenticate), or the network refused.
class LanLinkError implements Exception {
  const LanLinkError(this.code, [this.detail]);

  /// `unreachable` (no address answered), `key_mismatch`, `handshake`.
  final String code;
  final String? detail;

  @override
  String toString() => 'LanLinkError($code${detail == null ? '' : ': $detail'})';
}

/// The link's byte stream inside Noise transport messages over TCP.
class NoiseLinkStream {
  NoiseLinkStream._(this._socket, this._noise, this.address);

  final Socket _socket;
  final NoiseIkSession _noise;
  final LanAddress address;
  final _plain = StreamController<List<int>>();
  late final StreamSink<List<int>> output = _EncryptingSink(this);
  bool _closed = false;

  /// Decrypted bytes; ends when the socket does, or with an error on a forged message.
  Stream<List<int>> get input => _plain.stream;

  static const _chunk = 65535 - 16;
  static const connectTimeout = Duration(seconds: 4);

  /// Tries [computer]'s addresses in order; the first that completes the handshake wins.
  static Future<NoiseLinkStream> dial(LanComputer computer, LinkIdentity identity) async {
    Object? last;
    for (final address in computer.addresses) {
      Socket socket;
      try {
        socket = await Socket.connect(address.host, address.port, timeout: connectTimeout);
      } catch (e) {
        last = e;
        continue;
      }
      try {
        return await _handshake(socket, computer, identity, address);
      } on LanLinkError {
        socket.destroy();
        rethrow;
      } catch (e) {
        socket.destroy();
        last = e;
      }
    }
    throw LanLinkError('unreachable', '$last');
  }

  static Future<NoiseLinkStream> _handshake(Socket socket, LanComputer computer, LinkIdentity identity, LanAddress address) async {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final noise = NoiseIkSession(
      role: NoiseRole.initiator,
      localPrivateKey: identity.privateKey,
      localPublicKey: identity.publicKey,
      remotePublicKey: computer.key,
      prologue: linkPrologue,
    );
    final stream = NoiseLinkStream._(socket, noise, address);
    final reader = _FrameReader();
    final first = Completer<Uint8List>();
    late final StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (data) {
        for (final frame in reader.add(data)) {
          if (!first.isCompleted) {
            first.complete(frame);
          } else {
            stream._onFrame(frame);
          }
        }
      },
      onError: (Object e) {
        if (!first.isCompleted) first.completeError(e);
        stream._fail(e);
      },
      onDone: () {
        if (!first.isCompleted) first.completeError(const LanLinkError('handshake', 'closed'));
        stream._end();
      },
      cancelOnError: true,
    );
    stream._sub = sub;
    socket.add(_frame(noise.writeHandshake()));
    final msg2 = await first.future.timeout(const Duration(seconds: 8));
    try {
      noise.readHandshake(msg2);
    } catch (e) {
      // Message 2 is sealed with keys only the pinned daemon key can produce.
      throw LanLinkError('key_mismatch', '$e');
    }
    return stream;
  }

  StreamSubscription<Uint8List>? _sub;

  void _onFrame(Uint8List frame) {
    if (_closed) return;
    try {
      _plain.add(_noise.decrypt(frame));
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (_closed) return;
    _plain.addError(e);
    close();
  }

  void _end() {
    if (_closed) return;
    close();
  }

  void _write(List<int> data) {
    if (_closed) return;
    for (var i = 0; i < data.length; i += _chunk) {
      final end = i + _chunk > data.length ? data.length : i + _chunk;
      _socket.add(_frame(_noise.encrypt(data.sublist(i, end))));
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_sub?.cancel());
    _socket.destroy();
    _noise.destroy();
    unawaited(_plain.close());
  }

  static Uint8List _frame(List<int> msg) {
    final out = Uint8List(2 + msg.length);
    out[0] = msg.length >> 8;
    out[1] = msg.length & 0xff;
    out.setRange(2, out.length, msg);
    return out;
  }
}

class _EncryptingSink implements StreamSink<List<int>> {
  _EncryptingSink(this._stream);

  final NoiseLinkStream _stream;
  final _done = Completer<void>();

  @override
  void add(List<int> data) => _stream._write(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() {
    _stream.close();
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }

  @override
  Future<void> get done => _done.future;
}

/// 2-byte big-endian length frames.
class _FrameReader {
  final _buf = BytesBuilder(copy: false);

  List<Uint8List> add(List<int> data) {
    _buf.add(data);
    var bytes = _buf.takeBytes();
    final out = <Uint8List>[];
    var at = 0;
    while (bytes.length - at >= 2) {
      final len = (bytes[at] << 8) | bytes[at + 1];
      if (bytes.length - at - 2 < len) break;
      out.add(Uint8List.sublistView(bytes, at + 2, at + 2 + len));
      at += 2 + len;
    }
    if (at < bytes.length) {
      bytes = Uint8List.sublistView(bytes, at);
      _buf.add(bytes);
    }
    return out;
  }
}
