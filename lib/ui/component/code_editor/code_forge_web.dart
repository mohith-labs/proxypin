/// Web stand-in for package:code_forge (a Rust/FFI editor without web support), covering the API ProxyPin
/// uses: [CodeForgeController], [CodeForge], [FindController], decorations and styles. It is a TextField with
/// re_highlight syntax colouring plus line/character highlights, enough for script editing, rewrite bodies, the
/// JSON/XML/text tools and the diff view.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/re_highlight.dart';

/// code_forge initialises its Rust library here; nothing to do in the browser.
class RustLib {
  static Future<void> init() async {}
}

class CodeSelectionStyle {
  final Color? cursorColor;
  final Color selectionColor;
  final Color cursorBubbleColor;

  const CodeSelectionStyle({
    this.cursorColor,
    this.selectionColor = const Color(0x6E2195F3),
    this.cursorBubbleColor = const Color(0xFF2196F3),
  });
}

class MatchHighlightStyle {
  final TextStyle currentMatchStyle;
  final TextStyle otherMatchStyle;

  const MatchHighlightStyle({required this.currentMatchStyle, required this.otherMatchStyle});
}

class SearchHighlight {
  final int start;
  final int end;
  final bool isCurrentMatch;

  const SearchHighlight({required this.start, required this.end, this.isCurrentMatch = false});
}

enum LineDecorationType { background, leftBorder, underline, wavyUnderline }

class LineDecoration {
  final String id;
  final int startLine;
  final int endLine;
  final LineDecorationType type;
  final Color color;
  final double thickness;
  final int priority;

  const LineDecoration({
    required this.id,
    required this.startLine,
    required this.endLine,
    required this.type,
    required this.color,
    this.thickness = 3.0,
    this.priority = 0,
  });
}

enum GutterDecorationType { colorBar, icon, dot }

class GutterDecoration {
  final String id;
  final int startLine;
  final int endLine;
  final GutterDecorationType type;
  final Color color;
  final IconData? icon;
  final double width;
  final String? tooltip;
  final int priority;

  const GutterDecoration({
    required this.id,
    required this.startLine,
    required this.endLine,
    required this.type,
    required this.color,
    this.icon,
    this.width = 3.0,
    this.tooltip,
    this.priority = 0,
  });
}

/// Text + decorations of one editor. Syntax colouring comes from the [CodeForge] it is attached to.
class CodeForgeController extends TextEditingController {
  /// Highlighting work grows with the text; very large bodies are shown plain.
  static const int maxHighlightLength = 200 * 1024;

  CodeForgeController({super.text});

  List<SearchHighlight> searchHighlights = [];
  bool searchHighlightsChanged = false;
  final List<LineDecoration> _lineDecorations = [];
  final List<GutterDecoration> _gutterDecorations = [];
  int _contentVersion = 0;
  String _lastText = '';

  Mode? _language;
  Map<String, TextStyle> _theme = const {};
  MatchHighlightStyle? _matchStyle;
  final Highlight _highlight = Highlight();
  String? _cachedSource;
  List<_Run>? _cachedRuns;

  /// Increases on every text change (not on selection changes).
  int get contentVersion => _contentVersion;

  List<LineDecoration> get lineDecorations => List.unmodifiable(_lineDecorations);

  List<GutterDecoration> get gutterDecorations => List.unmodifiable(_gutterDecorations);

  @override
  set value(TextEditingValue newValue) {
    if (newValue.text != _lastText) {
      _lastText = newValue.text;
      _contentVersion++;
    }
    super.value = newValue;
  }

  void addLineDecorations(List<LineDecoration> decorations) {
    _lineDecorations.addAll(decorations);
    notifyListeners();
  }

  void clearLineDecorations() {
    _lineDecorations.clear();
    notifyListeners();
  }

  void addGutterDecorations(List<GutterDecoration> decorations) {
    _gutterDecorations.addAll(decorations);
    notifyListeners();
  }

  void clearGutterDecorations() {
    _gutterDecorations.clear();
    notifyListeners();
  }

  @override
  // ignore: unnecessary_overrides
  void notifyListeners() => super.notifyListeners();

  void replaceRange(int start, int end, String replacement) {
    final newText = text.replaceRange(start, end, replacement);
    value = TextEditingValue(text: newText, selection: TextSelection.collapsed(offset: start + replacement.length));
  }

  void setSelectionSilently(TextSelection selection) => this.selection = selection;

  int getLineAtOffset(int offset) => '\n'.allMatches(text.substring(0, math.min(offset, text.length))).length;

  void scrollToLine(int line) {}

  void _configure(Mode? language, Map<String, TextStyle>? theme, MatchHighlightStyle? matchStyle) {
    if (!identical(language, _language) || !identical(theme, _theme)) {
      _cachedSource = null;
      _cachedRuns = null;
    }
    _language = language;
    _theme = theme ?? const {};
    _matchStyle = matchStyle;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final source = text;
    var runs = _syntaxRuns(source, style);
    runs = _applyLineBackgrounds(runs, source);
    runs = _applySearchHighlights(runs);
    return TextSpan(style: style, children: [for (final run in runs) TextSpan(text: run.text, style: run.style)]);
  }

  List<_Run> _syntaxRuns(String source, TextStyle? base) {
    if (_cachedSource == source && _cachedRuns != null) return _cachedRuns!;
    List<_Run> runs = [_Run(source, null)];
    final language = _language;
    if (language != null && source.isNotEmpty && source.length <= maxHighlightLength) {
      try {
        _highlight.registerLanguage('code', language);
        final renderer = TextSpanRenderer(null, _theme);
        _highlight.highlight(code: source, language: 'code').render(renderer);
        final span = renderer.span;
        if (span != null) {
          runs = [];
          _flatten(span, null, runs);
        }
      } catch (_) {
        runs = [_Run(source, null)];
      }
    }
    _cachedSource = source;
    _cachedRuns = runs;
    return runs;
  }

  static void _flatten(InlineSpan span, TextStyle? inherited, List<_Run> out) {
    if (span is! TextSpan) return;
    final style = inherited == null ? span.style : inherited.merge(span.style);
    if (span.text != null && span.text!.isNotEmpty) out.add(_Run(span.text!, style));
    for (final child in span.children ?? const <InlineSpan>[]) {
      _flatten(child, style, out);
    }
  }

  List<_Run> _applyLineBackgrounds(List<_Run> runs, String source) {
    if (_lineDecorations.isEmpty) return runs;
    final lineStarts = <int>[0];
    for (var i = 0; i < source.length; i++) {
      if (source.codeUnitAt(i) == 10) lineStarts.add(i + 1);
    }
    final ranges = <(int, int, Color)>[];
    for (final decoration in _lineDecorations) {
      if (decoration.type != LineDecorationType.background) continue;
      if (decoration.startLine >= lineStarts.length) continue;
      final start = lineStarts[decoration.startLine];
      final endLine = decoration.endLine + 1;
      final end = endLine < lineStarts.length ? lineStarts[endLine] : source.length;
      ranges.add((start, end, decoration.color));
    }
    return _overlay(runs, ranges);
  }

  List<_Run> _applySearchHighlights(List<_Run> runs) {
    if (searchHighlights.isEmpty) return runs;
    final current = _matchStyle?.currentMatchStyle.backgroundColor ?? const Color(0xAAFF9800);
    final other = _matchStyle?.otherMatchStyle.backgroundColor ?? const Color(0x66FFEB3B);
    return _overlay(runs, [
      for (final highlight in searchHighlights)
        (highlight.start, highlight.end, highlight.isCurrentMatch ? current : other),
    ]);
  }

  /// Splits [runs] at the range boundaries and paints the ranges' background colour.
  static List<_Run> _overlay(List<_Run> runs, List<(int, int, Color)> ranges) {
    if (ranges.isEmpty) return runs;
    final result = <_Run>[];
    var offset = 0;
    for (final run in runs) {
      final runStart = offset, runEnd = offset + run.text.length;
      final cuts = <int>{runStart, runEnd};
      for (final (start, end, _) in ranges) {
        if (start > runStart && start < runEnd) cuts.add(start);
        if (end > runStart && end < runEnd) cuts.add(end);
      }
      final sorted = cuts.toList()..sort();
      for (var i = 0; i + 1 < sorted.length; i++) {
        final from = sorted[i], to = sorted[i + 1];
        Color? background;
        for (final (start, end, color) in ranges) {
          if (start <= from && to <= end) background = color;
        }
        final style = background == null
            ? run.style
            : (run.style ?? const TextStyle()).copyWith(backgroundColor: background);
        result.add(_Run(run.text.substring(from - runStart, to - runStart), style));
      }
      offset = runEnd;
    }
    return result;
  }
}

class _Run {
  final String text;
  final TextStyle? style;

  _Run(this.text, this.style);
}

/// Find / replace state for one editor, compatible with ProxyPin's FindPanelView.
class FindController extends ChangeNotifier {
  final CodeForgeController _codeController;

  List<Match> _matches = [];
  int _currentMatchIndex = -1;
  bool _isRegex = false;
  bool _caseSensitive = false;
  bool _matchWholeWord = false;
  String _lastQuery = '';
  bool _isActive = false;
  bool _isReplaceMode = false;
  String _lastText = '';

  final TextEditingController findInputController = TextEditingController();
  final TextEditingController replaceInputController = TextEditingController();
  final FocusNode findInputFocusNode = FocusNode();
  final FocusNode replaceInputFocusNode = FocusNode();

  FindController(this._codeController) {
    _lastText = _codeController.text;
    _codeController.addListener(_onCodeChanged);
    findInputController.addListener(() => find(findInputController.text));
  }

  int get matchCount => _matches.length;

  int get currentMatchIndex => _currentMatchIndex;

  bool get caseSensitive => _caseSensitive;

  bool get isRegex => _isRegex;

  bool get matchWholeWord => _matchWholeWord;

  bool get isActive => _isActive;

  bool get isReplaceMode => _isReplaceMode;

  set caseSensitive(bool value) {
    _caseSensitive = value;
    _research();
  }

  set isRegex(bool value) {
    _isRegex = value;
    _research();
  }

  set matchWholeWord(bool value) {
    _matchWholeWord = value;
    _research();
  }

  set isActive(bool value) {
    if (_isActive == value) return;
    _isActive = value;
    if (value) {
      Future.microtask(() => findInputFocusNode.requestFocus());
      if (_lastQuery.isNotEmpty) _research();
    } else {
      _clearMatches();
    }
    notifyListeners();
  }

  set isReplaceMode(bool value) {
    _isReplaceMode = value;
    notifyListeners();
  }

  void toggleReplaceMode() => isReplaceMode = !_isReplaceMode;

  void toggleActive() => isActive = !_isActive;

  void toggleCaseSensitive() => caseSensitive = !_caseSensitive;

  void toggleRegex() => isRegex = !_isRegex;

  void toggleMatchWholeWord() => matchWholeWord = !_matchWholeWord;

  void _onCodeChanged() {
    if (!_isActive && _lastQuery.isEmpty) return;
    if (_codeController.text != _lastText) {
      _lastText = _codeController.text;
      _research();
    }
  }

  void _research() {
    find(_lastQuery, scrollToMatch: false);
  }

  RegExp? _pattern(String query) {
    if (query.isEmpty) return null;
    var pattern = _isRegex ? query : RegExp.escape(query);
    if (_matchWholeWord) pattern = '\\b$pattern\\b';
    try {
      return RegExp(pattern, caseSensitive: _caseSensitive);
    } catch (_) {
      return null;
    }
  }

  void find(String query, {bool scrollToMatch = true}) {
    _lastQuery = query;
    final pattern = _pattern(query);
    if (pattern == null) {
      _clearMatches();
      return;
    }
    _matches = pattern.allMatches(_codeController.text).where((m) => m.end > m.start).toList();
    _currentMatchIndex = _matches.isEmpty ? -1 : 0;
    _update(scrollToMatch);
  }

  void next() {
    if (_matches.isEmpty) return;
    _currentMatchIndex = (_currentMatchIndex + 1) % _matches.length;
    _update(true);
  }

  void previous() {
    if (_matches.isEmpty) return;
    _currentMatchIndex = (_currentMatchIndex - 1 + _matches.length) % _matches.length;
    _update(true);
  }

  void clear() {
    _lastQuery = '';
    _clearMatches();
  }

  void replace() {
    if (_currentMatchIndex < 0 || _currentMatchIndex >= _matches.length) return;
    final match = _matches[_currentMatchIndex];
    _codeController.replaceRange(match.start, match.end, replaceInputController.text);
  }

  void replaceAll() {
    final pattern = _pattern(_lastQuery);
    if (pattern == null || _matches.isEmpty) return;
    final text = _codeController.text;
    _codeController.replaceRange(0, text.length, text.replaceAll(pattern, replaceInputController.text));
  }

  void _clearMatches() {
    _matches = [];
    _currentMatchIndex = -1;
    _codeController.searchHighlights = [];
    _codeController.notifyListeners();
    notifyListeners();
  }

  void _update(bool scrollToMatch) {
    _codeController.searchHighlights = [
      for (var i = 0; i < _matches.length; i++)
        SearchHighlight(start: _matches[i].start, end: _matches[i].end, isCurrentMatch: i == _currentMatchIndex),
    ];
    if (scrollToMatch && _currentMatchIndex >= 0) {
      final match = _matches[_currentMatchIndex];
      _codeController.selection = TextSelection(baseOffset: match.start, extentOffset: match.end);
    }
    _codeController.notifyListeners();
    notifyListeners();
  }

  @override
  void dispose() {
    _codeController.removeListener(_onCodeChanged);
    findInputController.dispose();
    replaceInputController.dispose();
    findInputFocusNode.dispose();
    replaceInputFocusNode.dispose();
    super.dispose();
  }
}

/// Editor widget with the CodeForge constructor (unsupported options are accepted and ignored).
class CodeForge extends StatefulWidget {
  final CodeForgeController? controller;
  final Map<String, TextStyle>? editorTheme;
  final Mode? language;
  final String? initialText;
  final FocusNode? focusNode;
  final ScrollController? verticalScrollController;
  final TextStyle? textStyle;
  final EdgeInsets? innerPadding;
  final bool readOnly;
  final bool autoFocus;
  final bool lineWrap;
  final bool enableGuideLines;
  final bool enableGutter;
  final CodeSelectionStyle? selectionStyle;
  final MatchHighlightStyle? matchHighlightStyle;
  final PreferredSizeWidget Function(BuildContext context, FindController findController)? finderBuilder;
  final FindController? findController;

  const CodeForge({
    super.key,
    this.controller,
    this.editorTheme,
    this.language,
    this.initialText,
    this.focusNode,
    this.verticalScrollController,
    this.textStyle,
    this.innerPadding,
    this.readOnly = false,
    this.autoFocus = false,
    this.lineWrap = false,
    this.enableGuideLines = true,
    this.enableGutter = true,
    this.selectionStyle,
    this.matchHighlightStyle,
    this.finderBuilder,
    this.findController,
  });

  @override
  State<CodeForge> createState() => _CodeForgeState();
}

class _CodeForgeState extends State<CodeForge> {
  late CodeForgeController _controller;
  bool _ownsController = false;
  late FindController _findController;
  bool _ownsFindController = false;
  late FocusNode _focusNode;
  bool _ownsFocusNode = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? CodeForgeController(text: widget.initialText ?? '');
    _ownsFindController = widget.findController == null;
    _findController = widget.findController ?? FindController(_controller);
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
  }

  @override
  void didUpdateWidget(covariant CodeForge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || oldWidget.findController != widget.findController) {
      _detach();
      _attach();
    }
  }

  void _detach() {
    if (_ownsFindController) _findController.dispose();
    if (_ownsController) _controller.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
  }

  @override
  void dispose() {
    _detach();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.editorTheme;
    _controller._configure(widget.language, theme, widget.matchHighlightStyle);

    final root = theme?['root'];
    final textStyle = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Consolas', 'Courier New', 'monospace'],
      fontSize: 13,
      height: 1.4,
      color: root?.color,
    ).merge(widget.textStyle);

    Widget editor = TextField(
      controller: _controller,
      focusNode: _focusNode,
      scrollController: widget.verticalScrollController ?? _scrollController,
      readOnly: widget.readOnly,
      autofocus: widget.autoFocus,
      maxLines: null,
      expands: true,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      style: textStyle,
      cursorColor: widget.selectionStyle?.cursorColor,
      decoration: InputDecoration.collapsed(hintText: null).copyWith(contentPadding: EdgeInsets.zero),
    );

    editor = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _findController.isActive = true,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () => _findController.isActive = true,
        const SingleActivator(LogicalKeyboardKey.escape): () => _findController.isActive = false,
      },
      child: editor,
    );

    final finder = widget.finderBuilder;
    return Container(
      color: root?.backgroundColor,
      padding: widget.innerPadding ?? const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (finder != null)
            ListenableBuilder(
              listenable: _findController,
              builder: (context, _) => _findController.isActive ? finder(context, _findController) : const SizedBox.shrink(),
            ),
          Expanded(child: editor),
        ],
      ),
    );
  }
}
