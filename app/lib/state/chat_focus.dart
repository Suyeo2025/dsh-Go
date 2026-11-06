import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How long a request to show one approval / question card waits for that
/// card: a conversation opened from a push or the Live Activity may take a
/// moment to load its requests.
const chatFocusWindow = Duration(seconds: 20);

/// One request to bring the approval / question card of [eventId] in
/// [sessionId] into view and mark it briefly.
class ChatFocus {
  const ChatFocus(this.sessionId, this.eventId, this.serial, this.at);

  final String sessionId;
  final String eventId;

  /// Counts requests, so the same card asked twice is two changes.
  final int serial;

  /// When it was asked (device clock).
  final DateTime at;

  bool freshAt(DateTime now) => now.difference(at) <= chatFocusWindow;
}

final _eventId = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

/// The event id a link names in its fragment (`…#event=<eventId>`, the Live
/// Activity's tap); null when there is none or it isn't an id.
String? linkFocusEventId(Uri uri) {
  if (!uri.hasFragment) return null;
  final Map<String, String> parts;
  try {
    parts = Uri.splitQueryString(uri.fragment);
  } on FormatException {
    return null;
  }
  final id = parts['event'];
  return id != null && _eventId.hasMatch(id) ? id : null;
}

/// Device clock (tests pin it).
final chatFocusClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Set when a push tap or the Live Activity (`dshgo://session/<id>#event=<id>`)
/// opens a conversation for one request. The conversation's list goes to its
/// newest line (pending requests sit there); the card with that event id, once
/// built, scrolls fully into view, lights up once and takes the request
/// ([consume]). A card already answered never shows up: the list just stays
/// at the bottom and the request lapses after [chatFocusWindow].
class ChatFocusController extends Notifier<ChatFocus?> {
  @override
  ChatFocus? build() => null;

  void focus(String sessionId, String eventId) =>
      state = ChatFocus(sessionId, eventId, (state?.serial ?? 0) + 1, ref.read(chatFocusClockProvider)());

  /// The card of request [serial] has shown it.
  void consume(int serial) {
    if (state?.serial == serial) state = null;
  }
}

final chatFocusProvider = NotifierProvider<ChatFocusController, ChatFocus?>(ChatFocusController.new);
