import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/token_budget_service.dart';

const _channel = MethodChannel('com.gutguard/litert_lm');

void _setHandler(
  Future<Object?> Function(MethodCall)? handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, handler);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TokenBudgetService', () {
    test('returns native LiteRT-LM tokenizer count when available', () async {
      final calls = <MethodCall>[];
      _setHandler((call) async {
        calls.add(call);
        return 17;
      });

      final count = await TokenBudgetService().countTokens('abdominal pain');

      expect(count, equals(17));
      expect(calls.single.method, equals('litert_lm_count_tokens'));
      expect(calls.single.arguments, equals({'text': 'abdominal pain'}));
    });

    test('falls back conservatively when native tokenizer is absent', () async {
      _setHandler(null);

      final count = await TokenBudgetService().countTokens('x' * 35);

      expect(count, equals(10));
    });

    test('falls back conservatively when native tokenizer throws', () async {
      _setHandler((_) async {
        throw PlatformException(code: 'tokenizer_unavailable');
      });

      final count = await TokenBudgetService().countTokens('x' * 36);

      expect(count, equals(11));
    });

    test('falls back conservatively when native tokenizer returns null',
        () async {
      _setHandler((_) async => null);

      final count = await TokenBudgetService().countTokens('x' * 8);

      expect(count, equals(3));
    });

    test('empty text is always zero without channel work', () async {
      var called = false;
      _setHandler((_) async {
        called = true;
        return 1;
      });

      final count = await TokenBudgetService().countTokens('');

      expect(count, equals(0));
      expect(called, isFalse);
    });
  });
}
