// local_model_token_broker.dart
// In-process event broker for streamed token events from the on-device runtime.
//
// Replaces the deleted iOS native EventChannel ("com.gutguard/litert_lm_stream")
// that the old hand-written Swift bridge used. Now that LiteRT-LM streaming
// runs entirely inside Dart (via the flutter_litert_lm package's
// LiteLmConversation.sendMessageStream), the producer and consumer live in the
// same isolate. A simple Map<requestId, StreamController> is sufficient.
//
// Lifecycle:
//   1. Consumer calls subscribe(requestId) before producer starts.
//   2. Producer calls openProducer(requestId) once, then pushToken/pushError,
//      and finally pushComplete which closes the controller and unregisters.
//   3. Late subscribers (after pushComplete) get an empty closed stream.

import 'dart:async';

import 'local_model_token_stream.dart';

class LocalModelTokenBroker {
  LocalModelTokenBroker._();
  static final LocalModelTokenBroker instance = LocalModelTokenBroker._();

  final Map<String, StreamController<LocalModelTokenEvent>> _controllers = {};

  Stream<LocalModelTokenEvent> subscribe(String requestId) {
    final controller = _controllers.putIfAbsent(
      requestId,
      () => StreamController<LocalModelTokenEvent>.broadcast(),
    );
    return controller.stream;
  }

  void openProducer(String requestId) {
    _controllers.putIfAbsent(
      requestId,
      () => StreamController<LocalModelTokenEvent>.broadcast(),
    );
  }

  void pushToken(String requestId, String token) {
    final c = _controllers[requestId];
    if (c == null || c.isClosed) return;
    c.add(LocalModelTokenEvent.token(token: token));
  }

  void pushComplete(String requestId, String fullText) {
    final c = _controllers.remove(requestId);
    if (c == null || c.isClosed) return;
    c.add(LocalModelTokenEvent.complete(text: fullText));
    c.close();
  }

  void pushError(String requestId, Object error, [StackTrace? stack]) {
    final c = _controllers.remove(requestId);
    if (c == null || c.isClosed) return;
    c.addError(error, stack);
    c.close();
  }
}
