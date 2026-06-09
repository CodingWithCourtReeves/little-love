import 'package:flutter/material.dart';

import 'theme/hearth.dart';
import 'wire/message.dart';

typedef SendCallback = void Function(String text);

class ConversationPage extends StatefulWidget {
  const ConversationPage({
    super.key,
    required this.meUsername,
    required this.contactDisplayName,
    required this.messages,
    required this.onSend,
  });

  final String meUsername;
  final String contactDisplayName;
  final List<Msg> messages;
  final SendCallback onSend;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleSubmit(String value) {
    final text = value.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.messages]
      ..sort((a, b) => a.ts.compareTo(b.ts));
    return Scaffold(
      backgroundColor: HearthColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: HearthColors.bgSurface,
        elevation: 0,
        title: Text(
          widget.contactDisplayName,
          style: const TextStyle(color: HearthColors.textPrimary),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: sorted.length,
              itemBuilder: (_, i) => _bubble(sorted[i]),
            ),
          ),
          _composer(),
        ],
      ),
    );
  }

  Widget _bubble(Msg m) {
    final mine = m.from == widget.meUsername;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: mine ? HearthColors.bubbleUserBg : HearthColors.bubblePartnerBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: HearthColors.borderSoft),
        ),
        child: Text(
          m.body,
          style: TextStyle(
            color: mine ? HearthColors.bubbleUserText : HearthColors.textPrimary,
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  Widget _composer() {
    return Container(
      color: HearthColors.bgSurface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('composer'),
              controller: _controller,
              textInputAction: TextInputAction.send,
              onSubmitted: _handleSubmit,
              decoration: InputDecoration(
                hintText: 'Message ${widget.contactDisplayName}',
                filled: true,
                fillColor: HearthColors.bgSurfaceAlt,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: () => _handleSubmit(_controller.text),
            icon: const Icon(Icons.send, color: HearthColors.accentUser),
          ),
        ],
      ),
    );
  }
}
