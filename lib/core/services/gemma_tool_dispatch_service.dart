/// GemmaToolDispatchService — orchestrates Gemma tool-calling.
///
/// Responsibilities:
/// - Serializes tool schemas into function-calling prompt blocks
/// - Sends chat with tool context via [GemmaRouterService]
/// - Parses tool-call JSON from model output
/// - Dispatches to handler callbacks (registered per tool name)
/// - 2-retry loop with deterministic fallback on parse failure
/// - Validates required fields against schema before dispatch

library;

import 'dart:async';
import 'dart:convert';

import 'gemma_router_service.dart';
import 'tool_schemas.dart';
import 'tool_audit_service.dart';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Result of a single tool dispatch cycle.
class ToolDispatchResult {
  const ToolDispatchResult({
    required this.toolName,
    required this.arguments,
    required this.handlerResult,
    required this.attemptCount,
    required this.usedFallback,
    this.parseError,
  });

  final String toolName;
  final Map<String, Object?> arguments;
  final Object? handlerResult;
  final int attemptCount;
  final bool usedFallback;
  final String? parseError;
}

/// Callback type for a tool handler.
/// Receives validated arguments; returns a JSON-serialisable result.
typedef ToolHandler = Future<Object?> Function(Map<String, Object?> args);

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

class GemmaToolDispatchService {
  GemmaToolDispatchService({
    required GemmaRouterService router,
    ToolAuditService? auditService,
    DateTime Function()? nowProvider,
  })  : _router = router,
        _auditService = auditService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final GemmaRouterService _router;
  final ToolAuditService? _auditService;
  final DateTime Function() _nowProvider;

  /// Registered tool handlers keyed by tool name.
  final Map<String, ToolHandler> _handlers = {};

  /// Register (or replace) a handler for the given tool name.
  ///
  /// Throws [ArgumentError] if [toolName] has no entry in [kAllToolSchemas].
  /// This is a hard runtime guard — asserts are stripped in release builds.
  void registerHandler(String toolName, ToolHandler handler) {
    if (!kAllToolSchemas.any((s) => s['name'] == toolName)) {
      throw ArgumentError(
        'No schema found for tool "$toolName". '
        'Add it to tool_schemas.dart before registering a handler.',
      );
    }
    _handlers[toolName] = handler;
  }

  /// Returns a JSON string of all registered schemas suitable for injection
  /// into a tool-calling prompt.
  String buildToolBlock({List<String>? only}) {
    final schemas = only == null
        ? kAllToolSchemas
        : kAllToolSchemas.where((s) => only.contains(s['name'])).toList();
    return const JsonEncoder.withIndent('  ').convert({'tools': schemas});
  }

  /// Sends [userMessage] with the full tool-calling context and dispatches
  /// the first valid tool call the model produces.
  ///
  /// Returns null if the model produces no tool call (free-text response).
  /// Throws [ToolDispatchException] if both retries fail and there is no fallback.
  Future<ToolDispatchResult?> sendAndDispatch({
    required String userMessage,
    required String assembledContext,
    List<String>? restrictToTools,
    Map<String, Object?> Function(String toolName)? fallbackArguments,
  }) async {
    final toolBlock = buildToolBlock(only: restrictToTools);
    final toolSchemas = _selectedSchemas(restrictToTools);
    final prompt = _buildPrompt(
      userMessage: userMessage,
      context: assembledContext,
      toolBlock: toolBlock,
    );

    String rawOutput = '';
    String? parseError;
    int attempt = 0;

    while (attempt < 2) {
      attempt++;
      final response = await _router.generateOnce(
        prompt,
        taskType: 'tool_dispatch',
        systemPrompt: _toolSystemHint,
        groundedContext: {
          'assembled_context': assembledContext,
          'tool_schema_mode': 'native_litert_lm_tools_json',
        },
        toolSchemas: toolSchemas,
      );
      rawOutput = response.outputText;

      final parsed = _parseNativeToolCall(response.toolCalls) ??
          _parseSingleToolCall(rawOutput);
      if (parsed != null) {
        final toolName = (parsed['name'] as String?) ?? '';
        final args = (parsed['arguments'] as Map<String, Object?>?) ?? {};

        final validationError = _validateArguments(toolName, args);
        if (validationError != null) {
          parseError = validationError;
          await _auditService?.record(
            toolName: toolName.isEmpty ? 'unknown' : toolName,
            args: args,
            error: validationError,
            retryCount: attempt,
            promptVersion: 'system_v1',
          );
          continue; // retry
        }

        final handler = _handlers[toolName];
        if (handler == null) {
          // Gemma hallucinated a tool name that is not registered.
          // Treat as a parse failure: retry rather than hard-crash, so the
          // deterministic fallback path can still serve the user.
          parseError = 'No handler registered for tool "$toolName" '
              '(hallucinated or unregistered tool name).';
          await _auditService?.record(
            toolName: toolName.isEmpty ? 'unknown' : toolName,
            args: args,
            error: parseError,
            retryCount: attempt,
            promptVersion: 'system_v1',
          );
          continue;
        }

        final started = _nowProvider();
        final handlerResult = await handler(args);
        await _auditService?.record(
          toolName: toolName,
          args: args,
          result: handlerResult,
          latencyMs: _nowProvider().difference(started).inMilliseconds,
          modelRole: 'tool_dispatch',
          promptVersion: 'system_v1',
          validated: true,
          retryCount: attempt - 1,
        );
        return ToolDispatchResult(
          toolName: toolName,
          arguments: args,
          handlerResult: handlerResult,
          attemptCount: attempt,
          usedFallback: false,
        );
      }

      parseError = 'Could not parse tool call from model output';
    }

    // Both attempts failed — try deterministic fallback if provided.
    final toolName = _inferToolName(userMessage, restrictToTools);
    if (toolName != null && fallbackArguments != null) {
      final args = fallbackArguments(toolName);
      final handler = _handlers[toolName];
      if (handler != null) {
        final handlerResult = await handler(args);
        await _auditService?.record(
          toolName: toolName,
          args: args,
          result: handlerResult,
          modelRole: 'tool_dispatch_fallback',
          promptVersion: 'system_v1',
          validated: true,
          retryCount: attempt,
        );
        return ToolDispatchResult(
          toolName: toolName,
          arguments: args,
          handlerResult: handlerResult,
          attemptCount: attempt,
          usedFallback: true,
          parseError: parseError,
        );
      }
    }

    // No fallback available — return null (treat as free-text).
    return null;
  }

  List<Map<String, Object?>> _selectedSchemas(List<String>? only) {
    if (only == null) return kAllToolSchemas;
    return kAllToolSchemas.where((schema) {
      return only.contains(schema['name']);
    }).toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  String _buildPrompt({
    required String userMessage,
    required String context,
    required String toolBlock,
  }) {
    return '''[GROUNDED_CONTEXT]
$context
[/GROUNDED_CONTEXT]

[TOOL_DEFINITIONS]
$toolBlock
[/TOOL_DEFINITIONS]

If the user's message requires a tool call, respond with exactly one JSON object
matching this format and nothing else:
{"name": "<tool_name>", "arguments": { <args> }}

If no tool is needed, respond normally in plain text.

User: $userMessage''';
  }

  /// Attempts to extract a single tool-call JSON object from [raw].
  /// Looks for the first `{` … `}` block that contains `"name"` and `"arguments"`.
  Map<String, Object?>? _parseSingleToolCall(String raw) {
    // Strip optional markdown code fences.
    final cleaned =
        raw.replaceAll(RegExp(r'```json?\s*'), '').replaceAll('```', '').trim();

    // Find first plausible JSON object.
    final start = cleaned.indexOf('{');
    if (start == -1) return null;

    // Walk forward to find matching closing brace.
    int depth = 0;
    int end = -1;
    for (int i = start; i < cleaned.length; i++) {
      if (cleaned[i] == '{') depth++;
      if (cleaned[i] == '}') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    if (end == -1) return null;

    final candidate = cleaned.substring(start, end + 1);
    try {
      final decoded = jsonDecode(candidate) as Map<String, Object?>?;
      if (decoded == null) return null;
      if (!decoded.containsKey('name') || !decoded.containsKey('arguments')) {
        return null;
      }
      return decoded;
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?>? _parseNativeToolCall(
    List<Map<String, Object?>> toolCalls,
  ) {
    for (final call in toolCalls) {
      final name = call['name'] ?? call['tool_name'] ?? call['function_name'];
      Object? rawArguments = call['arguments'] ?? call['args'];
      final function = call['function'];
      if (function is Map) {
        rawArguments ??= function['arguments'];
      }
      if (name == null && function is Map && function['name'] != null) {
        final parsedArgs = _decodeArguments(rawArguments);
        if (parsedArgs != null) {
          return {'name': function['name'].toString(), 'arguments': parsedArgs};
        }
      }
      if (name == null) continue;
      final parsedArgs = _decodeArguments(rawArguments);
      if (parsedArgs == null) continue;
      return {'name': name.toString(), 'arguments': parsedArgs};
    }
    return null;
  }

  Map<String, Object?>? _decodeArguments(Object? rawArguments) {
    if (rawArguments is Map<String, Object?>) return rawArguments;
    if (rawArguments is Map) {
      return rawArguments.map((key, value) => MapEntry(key.toString(), value));
    }
    if (rawArguments is String && rawArguments.trim().isNotEmpty) {
      final decoded = jsonDecode(rawArguments);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    }
    return null;
  }

  /// Validates that all `required` fields from the schema are present in [args]
  /// and that strict schemas do not receive unknown arguments.
  String? _validateArguments(String toolName, Map<String, Object?> args) {
    final schema = kAllToolSchemas.cast<Map<String, Object?>?>().firstWhere(
          (s) => s?['name'] == toolName,
          orElse: () => null,
        );
    if (schema == null) return 'Unknown tool "$toolName"';

    final params = schema['parameters'] as Map<String, Object?>?;
    if (params == null) return null;

    final required =
        (params['required'] as List<Object?>?)?.cast<String>() ?? [];
    for (final field in required) {
      if (!args.containsKey(field) || args[field] == null) {
        return 'Required field "$field" missing in tool call for "$toolName"';
      }
    }

    final additionalProperties =
        params['additionalProperties'] as bool? ?? true;
    final properties = (params['properties'] as Map<Object?, Object?>?) ?? {};
    if (!additionalProperties) {
      for (final field in args.keys) {
        if (!properties.containsKey(field)) {
          return 'Unexpected field "$field" in strict tool call for "$toolName"';
        }
      }
    }
    return null;
  }

  /// Naive tool-name inference from user message keywords for fallback use.
  String? _inferToolName(String message, List<String>? restrictToTools) {
    final lower = message.toLowerCase();
    const hints = <String, List<String>>{
      'log_symptom': [
        'pain',
        'hurts',
        'ache',
        'symptom',
        'feeling',
        'nausea',
        'tired',
      ],
      'log_bm': ['bathroom', 'bowel', 'stool', 'diarrhea', 'bm', 'toilet'],
      'log_checkin': ['check-in', 'checkin', 'how am i', 'daily log'],
      'get_flare_forecast': ['risk', 'flare', 'forecast', 'score'],
      'log_med_event': [
        'medication',
        'medicine',
        'took',
        'forgot',
        'missed dose',
      ],
      'ingest_lab_panel': [
        'lab',
        'crp',
        'calprotectin',
        'result',
        'blood test',
      ],
      'generate_gi_summary': ['summary', 'appointment', 'doctor', 'gi visit'],
    };

    for (final entry in hints.entries) {
      if (restrictToTools != null && !restrictToTools.contains(entry.key)) {
        continue;
      }
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) return entry.key;
      }
    }
    return null;
  }

  static const _toolSystemHint =
      'You are a structured data extraction assistant. '
      'When a tool call is appropriate, output ONLY the JSON tool call object. '
      'Do not add explanations before or after the JSON.';
}

// ---------------------------------------------------------------------------
// Exception
// ---------------------------------------------------------------------------

class ToolDispatchException implements Exception {
  const ToolDispatchException(this.message, {this.rawOutput});
  final String message;
  final String? rawOutput;

  @override
  String toString() => 'ToolDispatchException: $message';
}
