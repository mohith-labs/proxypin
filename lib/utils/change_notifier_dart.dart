/// Minimal stand-in for Flutter's `ChangeNotifier` used by engine managers on the headless server.
class ChangeNotifier {
  final List<void Function()> _listeners = [];

  bool get hasListeners => _listeners.isNotEmpty;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notifyListeners() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void dispose() => _listeners.clear();
}
