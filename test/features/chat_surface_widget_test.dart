import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/features/home/widgets/chat_surface_widget.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('BUG-067 readability normalization', () {
    test('keeps markdown headings and bullets while normalizing spacing', () {
      final formatted = normalizeAssistantMarkdownForDisplay(
        '## Overview\n- first\n- second\n## Red Flags\n- call care team',
      );

      expect(formatted, contains('## Overview'));
      expect(formatted, contains('- first'));
      expect(formatted, contains('## Red Flags'));
      expect(formatted, isNot(contains('\n\n\n')));
    });

    test('promotes indented markdown markers to valid markdown prefixes', () {
      final formatted = normalizeAssistantMarkdownForDisplay(
        '  ## Questions\n   * item one\n  * item two',
      );

      expect(formatted, startsWith('## Questions'));
      expect(formatted, contains('\n- item one'));
      expect(formatted, contains('\n- item two'));
    });

    test('chunks dense long paragraph into readable blocks', () {
      final formatted = normalizeAssistantMarkdownForDisplay(
        'Signal one is elevated and remained above baseline for two days. '
        'Signal two changed compared to baseline after your recent check-in. '
        'Signal three needs monitoring for the next few days to confirm direction. '
        'Keep logging to improve confidence in trend stability. '
        'If this persists, ask your GI team for guidance.',
      );

      expect(formatted, contains('\n\n'));
      expect(
        formatted,
        contains(
          'Signal one is elevated and remained above baseline for two days.',
        ),
      );
      expect(
        formatted,
        contains('Keep logging to improve confidence in trend stability.'),
      );
    });

    test('normalizes repeated blank lines to bounded spacing', () {
      final formatted = normalizeAssistantMarkdownForDisplay(
        '## Overview\n\n\n\nLine 1\n\n\nLine 2',
      );

      expect(formatted, isNot(contains('\n\n\n')));
      expect(formatted, contains('Line 1'));
      expect(formatted, contains('Line 2'));
    });

    test('normalizes escaped newlines and unicode bullets', () {
      final formatted = normalizeAssistantMarkdownForDisplay(
        r'Overview:\n• HRV down\n• Sleep fragmented\nNext:\n1) Hydrate\n2) Log check-in',
      );

      expect(formatted, contains('Overview:'));
      expect(formatted, contains('\n- HRV down'));
      expect(formatted, contains('\n- Sleep fragmented'));
      expect(formatted, contains('\n1. Hydrate'));
      expect(formatted, contains('\n2. Log check-in'));
    });

    test('adds spacing between prose blocks and list transitions', () {
      final formatted = normalizeAssistantMarkdownForDisplay(
        'Trend summary\n- signal one\n- signal two\nWatch this over 48 hours.',
      );

      expect(formatted, contains('Trend summary\n\n- signal one'));
      expect(formatted, contains('- signal two\n\nWatch this over 48 hours.'));
    });

    test('keeps fenced code blocks unchanged', () {
      const input = '```json\n{"trend":"stable"}\n```';
      final formatted = normalizeAssistantMarkdownForDisplay(input);

      expect(formatted, input);
    });

    test('splits long run-on clause text into readable blocks', () {
      final formatted = normalizeAssistantMarkdownForDisplay(
        'Your symptom and wearable trend moved together for three days; this can happen when recovery load is low, and baseline stress is elevated, and bowel urgency is also increasing, and hydration tolerance is lower than usual, and sleep became fragmented overnight.',
      );

      expect(formatted, contains('\n\n'));
      expect(
        formatted,
        contains('Your symptom and wearable trend moved together'),
      );
    });

    test('splits semicolon-heavy single paragraph for readability', () {
      final formatted = normalizeAssistantMarkdownForDisplay(
        'What to watch: urgency rose and sleep fell and stress rose; check hydration and bowel frequency and energy trend over the next 48 hours, and contact your GI team if two signals stay worse for 2 days.',
      );

      expect(formatted, contains(';\n\n'));
      expect(formatted, contains('What to watch: urgency rose and sleep fell'));
    });

    test('inserts section breaks for dense heading-like prose', () {
      final formatted = normalizeAssistantMarkdownForDisplay(
        'Overview Recent raw check-in data contains high-concern GI symptoms. Lab Results FC 320 ug/g elevated. Check-in Summary urgency mild. Questions for Your GI Doctor ask about escalation. Triage and Red Flags Same-day GI-team contact is appropriate.',
      );

      expect(formatted, contains('Overview\n\nRecent raw check-in data'));
      expect(formatted, contains('\n\nLab Results'));
      expect(formatted, contains('\n\nCheck-in Summary'));
      expect(formatted, contains('\n\nQuestions for Your GI Doctor'));
      expect(formatted, contains('\n\nTriage and Red Flags'));
    });

    test('unwraps single long bullet into paragraph text', () {
      final formatted = normalizeAssistantMarkdownForDisplay(
        '- You have a high probability of entering a flare-like window over the next 7 days based on recent trends and this is a long standalone bullet that should render as paragraph text for readability in chat surfaces.',
      );

      expect(formatted.trimLeft().startsWith('- '), isFalse);
      expect(formatted, contains('You have a high probability of entering'));
    });
  });

  testWidgets('BUG-051 GI summary share button calls share handler', (
    tester,
  ) async {
    ChatMessage? shared;
    final message = ChatMessage(
      role: 'assistant',
      text: 'Overview\nDoctor-ready summary',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: true,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [message],
          onShareMessage: (item) async => shared = item,
        ),
      ),
    );

    await tester.tap(find.text('Share'));
    await tester.pump();

    // Handler was invoked with the correct message — it owns its own feedback
    // (PDF loading snackbar + iOS share sheet), so no widget-level snackbar.
    expect(shared, message);
    expect(find.text('Share sheet opened.'), findsNothing);
  });

  testWidgets('BUG-051 GI summary share failure is visible', (tester) async {
    final message = ChatMessage(
      role: 'assistant',
      text: 'Overview\nDoctor-ready summary',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: true,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [message],
          onShareMessage: (_) async => throw StateError('share unavailable'),
        ),
      ),
    );

    await tester.tap(find.text('Share'));
    await tester.pump();

    expect(
      find.text('Could not open share sheet. Try copying instead.'),
      findsOneWidget,
    );
  });

  testWidgets('BUG-051 share button only appears on GI summaries', (
    tester,
  ) async {
    final nonSummaryMessage = ChatMessage(
      role: 'assistant',
      text: 'General response without summary mode.',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: false,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [nonSummaryMessage],
        ),
      ),
    );

    expect(find.text('Share'), findsNothing);
  });

  testWidgets('share button is hidden for user-authored messages', (
    tester,
  ) async {
    final userMessage = ChatMessage(
      role: 'user',
      text: 'My own note',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: true,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [userMessage],
        ),
      ),
    );

    expect(find.text('Share'), findsNothing);
  });

  testWidgets('share handler receives exact GI summary payload text', (
    tester,
  ) async {
    String? receivedText;
    final message = ChatMessage(
      role: 'assistant',
      text: '## Overview\nLine A\nLine B',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: true,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [message],
          onShareMessage: (item) async => receivedText = item.text,
        ),
      ),
    );

    await tester.tap(find.text('Share'));
    await tester.pump();

    expect(receivedText, '## Overview\nLine A\nLine B');
  });

  testWidgets('share handler can be triggered repeatedly without stale state', (
    tester,
  ) async {
    var calls = 0;
    final message = ChatMessage(
      role: 'assistant',
      text: 'Overview\nDoctor-ready summary',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: true,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [message],
          onShareMessage: (_) async => calls++,
        ),
      ),
    );

    await tester.tap(find.text('Share'));
    await tester.pump();
    await tester.tap(find.text('Share'));
    await tester.pump();

    expect(calls, 2);
  });

  testWidgets('copy action never calls share handler', (tester) async {
    var shareCalls = 0;
    final message = ChatMessage(
      role: 'assistant',
      text: 'GI summary body',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: true,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [message],
          onShareMessage: (_) async => shareCalls++,
        ),
      ),
    );

    await tester.tap(find.text('Copy'));
    await tester.pump();

    expect(shareCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy then share keeps actions isolated and deterministic', (
    tester,
  ) async {
    var shareCalls = 0;
    final message = ChatMessage(
      role: 'assistant',
      text: 'GI summary body',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: true,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [message],
          onShareMessage: (_) async => shareCalls++,
        ),
      ),
    );

    await tester.tap(find.text('Copy'));
    await tester.pump();
    await tester.tap(find.text('Share'));
    await tester.pump();

    expect(shareCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('share failure does not break subsequent copy action', (
    tester,
  ) async {
    final message = ChatMessage(
      role: 'assistant',
      text: 'GI summary body',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: true,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [message],
          onShareMessage: (_) async => throw StateError('share failed'),
        ),
      ),
    );

    await tester.tap(find.text('Share'));
    await tester.pump();
    expect(
      find.text('Could not open share sheet. Try copying instead.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid copy taps do not invoke share handler', (tester) async {
    var shareCalls = 0;
    final message = ChatMessage(
      role: 'assistant',
      text: 'GI summary body',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: true,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [message],
          onShareMessage: (_) async => shareCalls++,
        ),
      ),
    );

    await tester.tap(find.text('Copy'));
    await tester.pump();
    await tester.tap(find.text('Copy'));
    await tester.pump();

    expect(shareCalls, 0);
  });

  testWidgets('GI summary message keeps both copy and share actions visible', (
    tester,
  ) async {
    final message = ChatMessage(
      role: 'assistant',
      text: 'Overview\nDoctor-ready summary',
      timestamp: DateTime.parse('2026-05-12T08:00:00Z'),
      isGiSummary: true,
    );

    await tester.pumpWidget(
      _wrap(
        ChatSurfaceWidget(
          isGenerating: false,
          streamingText: '',
          scrollController: ScrollController(),
          messages: [message],
          onShareMessage: (_) async {},
        ),
      ),
    );

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
  });
}
