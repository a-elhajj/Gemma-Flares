import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class ResearchLink extends StatelessWidget {
  const ResearchLink({super.key});

  static final Uri mountSinaiPaperUri = Uri.parse(
    'https://www.gastrojournal.org/article/S0016-5085(25)00013-7/fulltext',
  );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Read the Mount Sinai research paper',
      child: TextButton.icon(
        onPressed: () => _open(context),
        icon: const Icon(Icons.open_in_new_rounded, size: 16),
        label: const Text('Read the research'),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final opened = await launchUrl(
      mountSinaiPaperUri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('The research link could not be opened right now.'),
        ),
      );
    }
  }
}
