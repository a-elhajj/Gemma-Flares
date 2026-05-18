// local_model_token_stream.dart
// Per-requestId subscriber facade over LocalModelTokenBroker.
//
// The original implementation read events from an iOS native EventChannel
// ("com.gutguard/litert_lm_stream") that the hand-written Swift bridge pushed
// to. That bridge is gone — LiteRT-LM streaming now runs inside Dart via the
// flutter_litert_lm package. This class is kept so call sites in
// gemma_router_service do not have to change: they still call
// LocalModelTokenStream().subscribe(requestId) and iterate the returned
// Stream<LocalModelTokenEvent>.

import 'dart:async';

import 'local_model_token_broker.dart';

class LocalModelTokenStream {
  LocalModelTokenStream();

  final List<StreamSubscription<LocalModelTokenEvent>> _subs = [];

  Stream<LocalModelTokenEvent> subscribe(String requestId) {
    return LocalModelTokenBroker.instance.subscribe(requestId);
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}

class LocalModelTokenEvent {
  LocalModelTokenEvent.token({required this.token, this.tokenId})
      : kind = LocalModelTokenEventKind.token,
        text = null;
  LocalModelTokenEvent.complete({required this.text})
      : kind = LocalModelTokenEventKind.complete,
        token = null,
        tokenId = null;

  final LocalModelTokenEventKind kind;
  final String? token;
  final int? tokenId;
  final String? text;
}

enum LocalModelTokenEventKind { token, complete }

class LocalModelStreamException implements Exception {
  const LocalModelStreamException({required this.code, required this.message});
  final String code;
  final String message;
  @override
  String toString() => 'LocalModelStreamException($code): $message';
}
