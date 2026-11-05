import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hosts_state.dart';

/// The Agent preset picked on the empty state for the next new conversation
/// (null: the host's own default). One-shot: [take] hands it to
/// `session/create` and clears it, and switching host clears it too, since
/// preset ids belong to one host.
final newChatPresetProvider = NotifierProvider<NewChatPresetController, String?>(NewChatPresetController.new);

class NewChatPresetController extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(activeHostProvider);
    return null;
  }

  void select(String? id) => state = id;

  /// The pick for the conversation being created, then cleared.
  String? take() {
    final id = state;
    state = null;
    return id;
  }
}
