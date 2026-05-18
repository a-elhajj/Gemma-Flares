import 'dart:async';
import 'dart:collection';

/// Single-writer mutex that serializes all access to the on-device runtime
/// (LiteRT-LM production runtime).
///
/// The native runtime ([LocalModelRuntime]) is single-instance, but multiple
/// Dart consumers (chat generation, embedding, RAG, OCR follow-ups, vision
/// captions) can race to use it. Concurrent calls into a single native runtime
/// handle either contend on internal locks (slow) or, worse, fight over the
/// same KV cache (wrong). This actor enforces strict FIFO ordering with
/// optional priority preemption so the user-visible chat path beats
/// background embedding work without starving anyone.
///
/// Usage:
///   final value = await actor.run(
///     LocalModelTaskKind.generate,
///     () async => runtime.generate(...),
///   );
///
/// Tasks of priority [LocalModelTaskPriority.userInteractive] jump the queue
/// ahead of [LocalModelTaskPriority.background] tasks but never preempt a
/// task that is already running. The task itself decides cancellation
/// semantics.
class LocalModelActor {
  LocalModelActor();

  final ListQueue<_QueuedTask<dynamic>> _interactive = ListQueue();
  final ListQueue<_QueuedTask<dynamic>> _background = ListQueue();
  bool _running = false;
  // Telemetry-friendly counters; cheap to read for diagnostics.
  int _completedCount = 0;
  int _peakDepth = 0;

  int get queueDepth => _interactive.length + _background.length;
  int get peakQueueDepth => _peakDepth;
  int get completedCount => _completedCount;

  Future<T> run<T>(
    LocalModelTaskKind kind,
    FutureOr<T> Function() task, {
    LocalModelTaskPriority priority = LocalModelTaskPriority.userInteractive,
    String? label,
  }) {
    final completer = Completer<T>();
    final queued = _QueuedTask<T>(
      kind: kind,
      priority: priority,
      label: label,
      task: task,
      completer: completer,
    );
    if (priority == LocalModelTaskPriority.userInteractive) {
      _interactive.addLast(queued);
    } else {
      _background.addLast(queued);
    }
    final depth = queueDepth;
    if (depth > _peakDepth) _peakDepth = depth;
    _drain();
    return completer.future;
  }

  void _drain() {
    if (_running) return;
    final next = _interactive.isNotEmpty
        ? _interactive.removeFirst()
        : (_background.isNotEmpty ? _background.removeFirst() : null);
    if (next == null) return;
    _running = true;
    _execute(next);
  }

  Future<void> _execute<T>(_QueuedTask<T> queued) async {
    try {
      final result = await Future<T>.sync(queued.task);
      if (!queued.completer.isCompleted) {
        queued.completer.complete(result);
      }
    } catch (error, stack) {
      if (!queued.completer.isCompleted) {
        queued.completer.completeError(error, stack);
      }
    } finally {
      _completedCount += 1;
      _running = false;
      // Allow the microtask queue to flush before draining the next task so
      // recently-resolved callers can themselves enqueue follow-ups
      // (typical for chat -> embed -> rag pipelines) without unbounded
      // recursion.
      scheduleMicrotask(_drain);
    }
  }
}

enum LocalModelTaskKind {
  generate,
  embed,
  tokenize,
  ragQuery,
  load,
  unload,
  status,
  other,
}

enum LocalModelTaskPriority { userInteractive, background }

class _QueuedTask<T> {
  _QueuedTask({
    required this.kind,
    required this.priority,
    required this.label,
    required this.task,
    required this.completer,
  });

  final LocalModelTaskKind kind;
  final LocalModelTaskPriority priority;
  final String? label;
  final FutureOr<T> Function() task;
  final Completer<T> completer;
}
