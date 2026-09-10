import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

class EditorPage extends ConsumerStatefulWidget {
  final String title;
  final String? content;
  final List<Language> languages;
  final bool supportRemoteDownload;
  final bool titleEditable;
  final Function(BuildContext context, String title, String content)? onSave;
  final Future<bool> Function(
    BuildContext context,
    String title,
    String content,
  )?
  onPop;

  const EditorPage({
    super.key,
    required this.title,
    required this.content,
    this.titleEditable = false,
    this.onSave,
    this.onPop,
    this.supportRemoteDownload = false,
    this.languages = const [Language.yaml],
  });

  @override
  ConsumerState<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends ConsumerState<EditorPage> {
  late CodeLineEditingController _controller;
  late CodeFindController _findController;
  late TextEditingController _titleController;
  late FocusNode _focusNode;
  late bool readOnly = false;
  late final SelectionToolbarController _toolbarController;

  @override
  void initState() {
    super.initState();
    readOnly = widget.onSave == null;
    _toolbarController = ContextMenuControllerImpl(readOnly);
    _focusNode = FocusNode();
    _controller = CodeLineEditingController.fromText(widget.content);
    _findController = CodeFindController(_controller);
    _titleController = TextEditingController(text: widget.title);
    if (system.isDesktop) {
      return;
    }
    _focusNode.onKeyEvent = ((_, event) {
      final keys = HardwareKeyboard.instance.logicalKeysPressed;
      final key = event.logicalKey;
      if (!keys.contains(key)) {
        return KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _controller.moveCursor(AxisDirection.up);
        return KeyEventResult.handled;
      } else if (key == LogicalKeyboardKey.arrowDown) {
        _controller.moveCursor(AxisDirection.down);
        return KeyEventResult.handled;
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        _controller.selection.endIndex;
        _controller.moveCursor(AxisDirection.left);
        return KeyEventResult.handled;
      } else if (key == LogicalKeyboardKey.arrowRight) {
        _controller.moveCursor(AxisDirection.right);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    });
  }

  @override
  void didUpdateWidget(covariant oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final content = widget.content;
      if (content != null && oldWidget.content != content) {
        _controller.text = content;
        _controller.clearHistory();
      }
    });
  }

  @override
  void dispose() {
    _toolbarController.hide(context);
    _findController.dispose();
    _controller.dispose();
    _titleController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSearch() {
    _findController.findMode();
  }

  Future<void> _handleImportFormFile() async {
    final file = await picker.pickerFile();
    if (file == null) {
      return;
    }
    final res = utf8.decode(await file.readBytes());
    if (!mounted) {
      return;
    }
    _controller.text = res;
  }

  Future<void> _handleImportFormUrl() async {
    final appLocalizations = context.appLocalizations;
    final url = await dialogs.showCommonDialog(
      child: InputDialog(
        title: appLocalizations.import,
        value: '',
        labelText: appLocalizations.url,
        inputFormatters: TextInputLimits.limit(TextInputLimits.url),
        validator: (value) {
          if (value == null || value.isEmpty) {
            return appLocalizations.emptyTip(appLocalizations.value);
          }
          if (!value.isUrl) {
            return appLocalizations.urlTip(appLocalizations.value);
          }
          return null;
        },
      ),
    );
    if (url == null) {
      return;
    }
    try {
      final res = await request.getTextResponseForUrl(url);
      if (!mounted) {
        return;
      }
      _controller.text = res.data ?? '';
    } catch (e) {
      if (!mounted) {
        return;
      }
      final appLocalizations = context.appLocalizations;
      context.showSnackBar(
        networkErrorMessage(e, appLocalizations) ??
            appLocalizations.unknownNetworkError,
      );
    }
  }

  Future<bool> _handlePop(BuildContext context) async {
    final onPop = widget.onPop;
    if (onPop == null) {
      return true;
    }
    final res = await onPop(context, _titleController.text, _controller.text);
    return res && context.mounted;
  }

  @override
  Widget build(BuildContext context) {
    return CommonPopScope(
      onPop: _handlePop,
      child: CommonScaffold(
        appBar: AppBar(
          title: _EditorTitleField(
            controller: _titleController,
            enabled: widget.titleEditable,
          ),
          actions: genActions([
            if (!readOnly)
              _EditorSaveAction(
                controller: _controller,
                titleController: _titleController,
                savedContent: widget.content,
                savedTitle: widget.title,
                onSave: widget.onSave!,
              ),
            _EditorMenuAction(
              controller: _controller,
              readOnly: readOnly,
              supportRemoteDownload: widget.supportRemoteDownload,
              onSearch: _handleSearch,
              onImportFromUrl: _handleImportFormUrl,
              onImportFromFile: _handleImportFormFile,
            ),
          ]),
        ),
        body: _EditorBody(
          controller: _controller,
          findController: _findController,
          toolbarController: _toolbarController,
          focusNode: _focusNode,
          readOnly: readOnly,
          languages: widget.languages,
          isLoading: widget.content == null,
          content: widget.content,
        ),
      ),
    );
  }
}

class _EditorTitleField extends StatelessWidget {
  const _EditorTitleField({required this.controller, required this.enabled});

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      maxLength: 20,
      enabled: enabled,
      controller: controller,
      decoration: InputDecoration(
        border: const NoInputBorder(),
        counter: const SizedBox(),
        hintText: context.appLocalizations.unnamed,
      ),
      style: context.textTheme.titleLarge,
      autofocus: false,
    );
  }
}

class _EditorSaveAction extends StatelessWidget {
  const _EditorSaveAction({
    required this.controller,
    required this.titleController,
    required this.savedContent,
    required this.savedTitle,
    required this.onSave,
  });

  final CodeLineEditingController controller;
  final TextEditingController titleController;
  final String? savedContent;
  final String savedTitle;
  final Function(BuildContext context, String title, String content) onSave;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (_, _, _) => ValueListenableBuilder(
        valueListenable: titleController,
        builder: (context, _, _) {
          final isDirty =
              controller.text != savedContent ||
              titleController.text != savedTitle;
          return IconButton(
            tooltip: context.appLocalizations.save,
            onPressed: isDirty
                ? () => onSave(context, titleController.text, controller.text)
                : null,
            icon: const Icon(Icons.save),
          );
        },
      ),
    );
  }
}

class _EditorMenuAction extends ConsumerWidget {
  const _EditorMenuAction({
    required this.controller,
    required this.readOnly,
    required this.supportRemoteDownload,
    required this.onSearch,
    required this.onImportFromUrl,
    required this.onImportFromFile,
  });

  final CodeLineEditingController controller;
  final bool readOnly;
  final bool supportRemoteDownload;
  final VoidCallback onSearch;
  final VoidCallback onImportFromUrl;
  final VoidCallback onImportFromFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (_, _, _) {
        return CommonPopupBox(
          targetBuilder: (open) {
            return IconButton(
              tooltip: context.appLocalizations.more,
              onPressed: () {
                final isMobile = ref.read(isMobileViewProvider);
                open(offset: Offset(0, isMobile ? 0 : 20));
              },
              icon: const Icon(Icons.more_vert),
            );
          },
          popupBuilder: (_) => CommonPopupMenu(
            items: [
              CommonPopupMenuItem(
                icon: Icons.search,
                label: appLocalizations.search,
                onPressed: onSearch,
              ),
              CommonPopupMenuItem(
                icon: Icons.undo,
                label: appLocalizations.undo,
                onPressed: controller.canUndo ? controller.undo : null,
              ),
              CommonPopupMenuItem(
                icon: Icons.redo,
                label: appLocalizations.redo,
                onPressed: controller.canRedo ? controller.redo : null,
              ),
              if (supportRemoteDownload && !readOnly)
                CommonPopupMenuItem(
                  icon: Icons.arrow_downward,
                  label: appLocalizations.externalFetch,
                  subItems: [
                    CommonPopupMenuItem(
                      label: appLocalizations.importUrl,
                      onPressed: onImportFromUrl,
                    ),
                    CommonPopupMenuItem(
                      label: appLocalizations.importFile,
                      onPressed: onImportFromFile,
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _EditorBody extends ConsumerWidget {
  const _EditorBody({
    required this.controller,
    required this.findController,
    required this.toolbarController,
    required this.focusNode,
    required this.readOnly,
    required this.languages,
    required this.isLoading,
    required this.content,
  });

  final CodeLineEditingController controller;
  final CodeFindController findController;
  final SelectionToolbarController toolbarController;
  final FocusNode focusNode;
  final bool readOnly;
  final List<Language> languages;
  final bool isLoading;
  final String? content;

  CodeHighlightTheme get _highlightTheme {
    return CodeHighlightTheme(
      languages: {
        if (languages.contains(Language.yaml))
          'yaml': CodeHighlightThemeMode(mode: langYaml),
        if (languages.contains(Language.javaScript))
          'javascript': CodeHighlightThemeMode(mode: langJavascript),
        if (languages.contains(Language.json))
          'json': CodeHighlightThemeMode(mode: langJson),
      },
      theme: atomOneLightTheme,
    );
  }

  /// The highlighter registers everything the editor knows about and then picks
  /// from this list, so it matches what the editor mode would colour.
  List<String> get _previewLanguages => [
    if (languages.contains(Language.yaml)) 'yaml',
    if (languages.contains(Language.javaScript)) 'javascript',
    if (languages.contains(Language.json)) 'json',
  ];

  Widget _buildEditor(BuildContext context, bool isMobileView) {
    return CodeEditor(
      readOnly: readOnly,
      autofocus: false,
      showCursorWhenReadOnly: false,
      findController: findController,
      findBuilder: (context, controller, readOnly) => FindPanel(
        controller: controller,
        readOnly: readOnly,
        isMobileView: isMobileView,
      ),
      padding: const EdgeInsets.only(right: 16),
      autocompleteSymbols: true,
      focusNode: focusNode,
      scrollbarBuilder: (context, child, details) {
        return CommonScrollBar(
          controller: details.controller,
          thumbVisibility: system.isDesktop,
          child: child,
        );
      },
      toolbarController: toolbarController,
      indicatorBuilder:
          (context, editingController, chunkController, notifier) {
            return _EditorGutter(
              controller: editingController,
              chunkController: chunkController,
              notifier: notifier,
            );
          },
      shortcutsActivatorsBuilder: const DefaultCodeShortcutsActivatorsBuilder(),
      controller: controller,
      style: CodeEditorStyle(
        fontSize: context.textTheme.bodyLarge?.fontSize?.ap,
        fontFamily: FontFamily.jetBrainsMono.value,
        codeTheme: _highlightTheme,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMobileView = ref.watch(isMobileViewProvider);
    return Stack(
      children: [
        if (readOnly)
          Column(
            children: [
              ValueListenableBuilder<CodeFindValue?>(
                valueListenable: findController,
                builder: (context, _, _) => FindPanel(
                  controller: findController,
                  readOnly: readOnly,
                  isMobileView: isMobileView,
                ),
              ),
              Expanded(
                child: _PreviewBody(
                  text: content ?? '',
                  languages: _previewLanguages,
                  findController: findController,
                ),
              ),
            ],
          )
        else
          _buildEditor(context, isMobileView),
        FadeBox(
          child: isLoading
              ? Container(
                  color: context.colorScheme.surface,
                  alignment: Alignment.center,
                  child: const SizedBox.square(
                    dimension: 200,
                    child: CommonCircleLoading(),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _PanScrollbarThumb extends StatelessWidget {
  const _PanScrollbarThumb({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final radius = (width < height ? width : height) / 2;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.colorScheme.outlineVariant,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Read-only view of a whole document.
///
/// re_editor virtualises by the height it is given: `_CodeField` stops laying
/// lines out as soon as they fill `size.height`, and paints only those. The
/// panning preview this replaces sized the field to the whole document so the
/// inner scrollables would drop their drag recognizers — which turned that
/// viewport into the document itself, so every frame laid out and painted every
/// line and any long profile froze the UI. Here the field stays at viewport
/// size, panning moves the scroll position instead of the layout size, only the
/// visible lines are built, and highlighting runs off the UI isolate.
class _PreviewBody extends StatefulWidget {
  const _PreviewBody({
    required this.text,
    required this.languages,
    required this.findController,
  });

  final String text;
  final List<String> languages;
  final CodeFindController findController;

  @override
  State<_PreviewBody> createState() => _PreviewBodyState();
}

class _PreviewBodyState extends State<_PreviewBody>
    with TickerProviderStateMixin {
  /// A line is cut here before the text engine ever sees it: Skia's line layout
  /// crawls on very long lines (reqable/re-editor#14), and only visible lines
  /// are built anyway.
  static const int _maxLineRunes = 1000;
  static const String _ellipsis = '…';
  static const double _gutterGap = 8;
  static const double _paddingLeft = 12;
  static const double _paddingRight = 20;
  static const double _paddingVertical = 8;
  static const double _scrollbarThickness = 8;
  static const double _scrollbarGap = 2;
  static const double _minThumb = 48;

  final ScrollController _verticalController = ScrollController();
  final ValueNotifier<double> _horizontalOffset = ValueNotifier<double>(0);
  late final AnimationController _verticalAnimator;
  late final AnimationController _horizontalAnimator;

  /// Horizontal overflow of the current layout, kept for the fling bounds.
  double _maxHorizontal = 0;

  /// Highlight styles already merged into the current base style, keyed by the
  /// highlighter's class name.
  final Map<String, TextStyle> _classStyles = {};

  TextStyle? _style;
  String? _preparedText;
  List<String> _lines = const [];
  double _lineHeight = 1;
  double _contentWidth = 0;
  double _gutterWidth = 0;

  /// Per-line syntax ranges, produced off the UI isolate once per document.
  List<List<_HighlightRange>>? _highlightRanges;
  String? _highlightPendingText;

  /// Search hits of the current query, as `[start, end, start, end, …]` per
  /// line index.
  Map<int, List<int>>? _matchRanges;
  int? _currentMatchLine;
  int? _currentMatchOffset;

  @override
  void initState() {
    super.initState();
    _verticalAnimator = AnimationController.unbounded(vsync: this)
      ..addListener(_handleVerticalAnimator);
    _horizontalAnimator = AnimationController.unbounded(vsync: this)
      ..addListener(_handleHorizontalAnimator);
    widget.findController.addListener(_handleFindChanged);
    _handleFindChanged();
  }

  @override
  void didUpdateWidget(covariant _PreviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.findController != widget.findController) {
      oldWidget.findController.removeListener(_handleFindChanged);
      widget.findController.addListener(_handleFindChanged);
      _handleFindChanged();
    }
  }

  @override
  void dispose() {
    widget.findController.removeListener(_handleFindChanged);
    _verticalAnimator.dispose();
    _horizontalAnimator.dispose();
    _verticalController.dispose();
    _horizontalOffset.dispose();
    super.dispose();
  }

  void _handleFindChanged() {
    final List<CodeLineSelection>? matches =
        widget.findController.allMatchSelections;
    final CodeLineSelection? current =
        widget.findController.currentMatchSelection;
    final Map<int, List<int>> ranges = {};
    if (matches != null) {
      for (final CodeLineSelection match in matches) {
        if (match.baseIndex != match.extentIndex) {
          continue;
        }
        ranges.putIfAbsent(match.baseIndex, () => <int>[]).addAll([
          match.baseOffset,
          match.extentOffset,
        ]);
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _matchRanges = ranges.isEmpty ? null : ranges;
      _currentMatchLine = current?.baseIndex;
      _currentMatchOffset = current?.baseOffset;
    });
    final int? line = current?.baseIndex;
    if (line != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLine(line));
    }
  }

  void _scrollToLine(int line) {
    if (!mounted) {
      return;
    }
    final ScrollPosition? position = _verticalPosition;
    if (position == null) {
      return;
    }
    _verticalController.jumpTo(
      (line * _lineHeight - position.viewportDimension / 2).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  static bool _isWideRune(int rune) {
    return rune >= 0x1100 &&
        (rune <= 0x115f ||
            rune == 0x2329 ||
            rune == 0x232a ||
            (rune >= 0x2e80 && rune <= 0xa4cf && rune != 0x303f) ||
            (rune >= 0xac00 && rune <= 0xd7a3) ||
            (rune >= 0xf900 && rune <= 0xfaff) ||
            (rune >= 0xfe30 && rune <= 0xfe6f) ||
            (rune >= 0xff00 && rune <= 0xff60) ||
            (rune >= 0xffe0 && rune <= 0xffe6) ||
            (rune >= 0x20000 && rune <= 0x3fffd));
  }

  static String _displayLine(String line) {
    if (line.runes.length <= _maxLineRunes) {
      return line;
    }
    return '${String.fromCharCodes(line.runes.take(_maxLineRunes))}$_ellipsis';
  }

  /// Measures the document once per content/style change. Everything here is
  /// O(characters) with no text engine work, so it stays off the frame budget
  /// even for long files.
  void _prepare(TextStyle style) {
    _style = style;
    _preparedText = widget.text;
    _lines = widget.text.split('\n').map(_displayLine).toList(growable: false);
    _classStyles.clear();
    _highlightRanges = null;

    final TextPainter unitPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(text: '0', style: style),
    )..layout();
    final double unit = unitPainter.width;
    final double lineHeight = unitPainter.preferredLineHeight;
    unitPainter.dispose();
    _lineHeight = lineHeight > 0 ? lineHeight : 1;

    _gutterWidth = '${_lines.length}'.length * unit + _gutterGap;
    int widest = 0;
    for (final String line in _lines) {
      int width = 0;
      for (final int rune in line.runes) {
        width += _isWideRune(rune) ? 2 : 1;
      }
      if (width > widest) {
        widest = width;
      }
    }
    _contentWidth = _paddingLeft + _gutterWidth + widest * unit + _paddingRight;

    _runHighlight();
  }

  /// Highlighting a whole document is far too much to do on the UI isolate, so
  /// it runs on a worker and lands a frame or two later; until it does the
  /// preview is plain text.
  Future<void> _runHighlight() async {
    final String text = widget.text;
    if (widget.languages.isEmpty || _highlightPendingText == text) {
      return;
    }
    _highlightPendingText = text;
    final List<List<_HighlightRange>> ranges;
    try {
      ranges = await compute(
        _highlightDocument,
        _HighlightRequest(text, widget.languages),
      );
    } catch (_) {
      _highlightPendingText = null;
      return;
    }
    _highlightPendingText = null;
    if (!mounted || _preparedText != text) {
      return;
    }
    setState(() => _highlightRanges = ranges);
  }

  TextStyle _styleForClass(String className, TextStyle base) {
    final TextStyle? cached = _classStyles[className];
    if (cached != null) {
      return cached;
    }
    String name = className;
    TextStyle? highlight = atomOneLightTheme[name];
    while (highlight == null) {
      final int pieceIndex = name.indexOf('-');
      if (pieceIndex < 0) {
        break;
      }
      name = name.substring(pieceIndex + 1);
      if (name.isEmpty) {
        break;
      }
      highlight = atomOneLightTheme[name];
    }
    final TextStyle resolved = highlight == null ? base : base.merge(highlight);
    _classStyles[className] = resolved;
    return resolved;
  }

  /// The vertical scroll position, or null until the list has actually laid
  /// out. `hasClients` alone is not enough: `minScrollExtent`/`maxScrollExtent`
  /// are null until the first layout and reading them then throws.
  ScrollPosition? get _verticalPosition {
    if (!_verticalController.hasClients) {
      return null;
    }
    final ScrollPosition position = _verticalController.position;
    return position.hasContentDimensions ? position : null;
  }

  void _handleVerticalAnimator() {
    final ScrollPosition? position = _verticalPosition;
    if (position == null) {
      _verticalAnimator.stop();
      return;
    }
    final double value = _verticalAnimator.value;
    final double clamped = value.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _verticalController.jumpTo(clamped);
    if (clamped != value) {
      _verticalAnimator.stop();
    }
  }

  void _handleHorizontalAnimator() {
    final double value = _horizontalAnimator.value;
    final double clamped = value.clamp(0.0, _maxHorizontal);
    _horizontalOffset.value = clamped;
    if (clamped != value) {
      _horizontalAnimator.stop();
    }
  }

  void _handlePanDown(DragDownDetails details) {
    _verticalAnimator.stop();
    _horizontalAnimator.stop();
  }

  /// Flings run through the same physics the rest of the app's lists use, so
  /// the preview glides exactly like every other scrollable in FlClash.
  void _handlePanEnd(DragEndDetails details) {
    const ScrollPhysics physics = NextClampingScrollPhysics();
    final Offset velocity = details.velocity.pixelsPerSecond;
    final ScrollPosition? vertical = _verticalPosition;
    if (vertical != null) {
      final Simulation? simulation = physics.createBallisticSimulation(
        vertical,
        -velocity.dy,
      );
      if (simulation != null) {
        _verticalAnimator
          ..value = vertical.pixels
          ..animateWith(simulation);
      }
    }
    final double dx = -velocity.dx;
    if (dx.abs() > 1 && _maxHorizontal > 0) {
      // The horizontal axis is not a Scrollable, so the metrics a physics would
      // ask for are reproduced from the current offset instead.
      final double pixelRatio = vertical?.devicePixelRatio ?? 1;
      _horizontalAnimator
        ..value = _horizontalOffset.value
        ..animateWith(
          ClampingScrollSimulation(
            position: _horizontalOffset.value,
            velocity: dx,
            tolerance: Tolerance(velocity: 1 / pixelRatio, distance: 0.5),
          ),
        );
    }
  }

  void _handlePan(Offset delta, double maxHorizontal) {
    if (maxHorizontal > 0) {
      _horizontalOffset.value = (_horizontalOffset.value - delta.dx).clamp(
        0.0,
        maxHorizontal,
      );
    }
    final ScrollPosition? position = _verticalPosition;
    if (position == null) {
      return;
    }
    _verticalController.jumpTo(
      (position.pixels - delta.dy).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  /// Cuts a line into syntax- and search-styled runs. The two ranges overlap, so
  /// the line is split at every boundary and each piece takes the style of the
  /// run containing it.
  List<InlineSpan> _buildSpans(
    BuildContext context,
    int lineIndex,
    String text,
    TextStyle base,
  ) {
    final List<_HighlightRange>? ranges = _highlightRanges?[lineIndex];
    final List<int>? matches = _matchRanges?[lineIndex];
    final bool hasRanges = ranges != null && ranges.isNotEmpty;
    if (!hasRanges && matches == null) {
      return [TextSpan(text: text, style: base)];
    }
    final int length = text.length;
    final Set<int> boundaries = {0, length};
    if (hasRanges) {
      for (final _HighlightRange range in ranges) {
        if (range.start >= length) {
          continue;
        }
        boundaries.add(range.start.clamp(0, length));
        boundaries.add(range.end.clamp(0, length));
      }
    }
    if (matches != null) {
      for (final int offset in matches) {
        boundaries.add(offset.clamp(0, length));
      }
    }
    final List<int> sorted = boundaries.toList()..sort();
    final Color matchColor = context.colorScheme.primary.withValues(alpha: 0.2);
    final Color currentMatchColor = context.colorScheme.primary.withValues(
      alpha: 0.4,
    );
    final List<TextSpan> spans = [];
    for (int i = 0; i + 1 < sorted.length; i++) {
      final int start = sorted[i];
      final int end = sorted[i + 1];
      if (end <= start) {
        continue;
      }
      TextStyle spanStyle = base;
      if (hasRanges) {
        for (final _HighlightRange range in ranges) {
          if (range.start <= start && end <= range.end) {
            final String? className = range.className;
            if (className != null) {
              spanStyle = _styleForClass(className, base);
            }
            break;
          }
        }
      }
      if (matches != null) {
        for (int j = 0; j + 1 < matches.length; j += 2) {
          if (matches[j] <= start && end <= matches[j + 1]) {
            final bool isCurrent =
                lineIndex == _currentMatchLine &&
                matches[j] == _currentMatchOffset;
            spanStyle = spanStyle.copyWith(
              backgroundColor: isCurrent ? currentMatchColor : matchColor,
            );
            break;
          }
        }
      }
      final String piece = text.substring(start, end);
      // Merging equal neighbours keeps the span count near the token count
      // rather than the boundary count.
      final TextSpan? previous = spans.isEmpty ? null : spans.last;
      if (previous != null && previous.style == spanStyle) {
        spans[spans.length - 1] = TextSpan(
          text: '${previous.text}$piece',
          style: spanStyle,
        );
      } else {
        spans.add(TextSpan(text: piece, style: spanStyle));
      }
    }
    if (spans.isEmpty) {
      return [TextSpan(text: text, style: base)];
    }
    return spans;
  }

  Widget _buildLine(BuildContext context, int index, TextStyle style) {
    final String text = _lines[index];
    return Row(
      children: [
        SizedBox(
          width: _gutterWidth,
          child: Text(
            '${index + 1}',
            maxLines: 1,
            textAlign: TextAlign.right,
            style: style.copyWith(color: context.colorScheme.outline),
          ),
        ),
        Expanded(
          child: Text.rich(
            TextSpan(children: _buildSpans(context, index, text, style)),
            style: style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
          ),
        ),
      ],
    );
  }

  Widget _buildHorizontalScrollbar(Size viewport, double maxHorizontal) {
    if (maxHorizontal <= 0) {
      return const SizedBox.shrink();
    }
    final double track = viewport.width - _scrollbarGap * 2;
    if (track <= 0) {
      return const SizedBox.shrink();
    }
    final double thumb = (track * viewport.width / _contentWidth).clamp(
      _minThumb,
      track,
    );
    final double travel = track - thumb;
    return Positioned(
      left: _scrollbarGap,
      bottom: _scrollbarGap,
      child: ValueListenableBuilder<double>(
        valueListenable: _horizontalOffset,
        builder: (context, offset, _) {
          final double fraction = travel > 0
              ? (offset / maxHorizontal).clamp(0.0, 1.0)
              : 0.0;
          return Padding(
            padding: EdgeInsets.only(left: fraction * travel),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) {
                if (travel <= 0) {
                  return;
                }
                _horizontalOffset.value =
                    (_horizontalOffset.value +
                            details.delta.dx / travel * maxHorizontal)
                        .clamp(0.0, maxHorizontal);
              },
              child: _PanScrollbarThumb(
                width: thumb,
                height: _scrollbarThickness,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildVerticalScrollbar(Size viewport) {
    return Positioned(
      right: _scrollbarGap,
      top: _scrollbarGap,
      bottom: _scrollbarGap,
      child: AnimatedBuilder(
        animation: _verticalController,
        builder: (context, _) {
          final ScrollPosition? position = _verticalPosition;
          if (position == null) {
            return const SizedBox.shrink();
          }
          final double extent = position.maxScrollExtent;
          final double track = viewport.height - _scrollbarGap * 4;
          if (extent <= 0 || track <= 0) {
            return const SizedBox.shrink();
          }
          final double contentHeight = extent + position.viewportDimension;
          final double thumb =
              (track * position.viewportDimension / contentHeight).clamp(
                _minThumb,
                track,
              );
          final double travel = track - thumb;
          final double fraction = travel > 0
              ? (position.pixels / extent).clamp(0.0, 1.0)
              : 0.0;
          return Padding(
            padding: EdgeInsets.only(top: fraction * travel),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) {
                if (travel <= 0) {
                  return;
                }
                _verticalController.jumpTo(
                  (position.pixels + details.delta.dy / travel * extent).clamp(
                    0.0,
                    extent,
                  ),
                );
              },
              child: _PanScrollbarThumb(
                width: _scrollbarThickness,
                height: thumb,
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: context.textTheme.bodyLarge?.fontSize?.ap,
      fontFamily: FontFamily.jetBrainsMono.value,
      color: context.textTheme.bodyLarge?.color,
    );
    if (_preparedText != widget.text || _style != style) {
      _prepare(style);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final double maxHorizontal = (_contentWidth - viewport.width).clamp(
          0.0,
          double.infinity,
        );
        _maxHorizontal = maxHorizontal;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: _handlePanDown,
          onPanUpdate: (details) => _handlePan(details.delta, maxHorizontal),
          onPanEnd: _handlePanEnd,
          child: ClipRect(
            child: Stack(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: _horizontalOffset,
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: 0,
                    maxWidth: double.infinity,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: SizedBox(
                      width: _contentWidth > viewport.width
                          ? _contentWidth
                          : viewport.width,
                      height: viewport.height,
                      // Selectable so long-press (and drag, on desktop) can
                      // copy text out of the preview.
                      child: SelectionArea(
                        child: ListView.builder(
                          controller: _verticalController,
                          // Never scrollable, so the list drops its drag
                          // recognizer and the pan keeps every gesture. The
                          // fling is simulated explicitly, so it does not need
                          // the list's own physics.
                          physics: const NeverScrollableScrollPhysics(),
                          itemExtent: _lineHeight,
                          padding: const EdgeInsets.only(
                            left: _paddingLeft,
                            top: _paddingVertical,
                            bottom: _paddingVertical,
                          ),
                          itemCount: _lines.length,
                          itemBuilder: (context, index) =>
                              _buildLine(context, index, style),
                        ),
                      ),
                    ),
                  ),
                  builder: (context, offset, child) => Transform.translate(
                    offset: Offset(-offset, 0),
                    child: child,
                  ),
                ),
                if (system.isDesktop) ...[
                  _buildHorizontalScrollbar(viewport, maxHorizontal),
                  _buildVerticalScrollbar(viewport),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EditorGutter extends StatelessWidget {
  const _EditorGutter({
    required this.controller,
    required this.chunkController,
    required this.notifier,
  });

  final CodeLineEditingController controller;
  final CodeChunkController chunkController;
  final CodeIndicatorValueNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        DefaultCodeLineNumber(controller: controller, notifier: notifier),
        DefaultCodeChunkIndicator(
          width: 20,
          controller: chunkController,
          notifier: notifier,
        ),
      ],
    );
  }
}

const double _kDefaultFindPanelHeight = 52;

class FindPanel extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;
  final bool readOnly;
  final bool isMobileView;
  final double height;

  const FindPanel({
    super.key,
    required this.controller,
    required this.readOnly,
    required this.isMobileView,
  }) : height =
           (isMobileView
               ? _kDefaultFindPanelHeight * 2
               : _kDefaultFindPanelHeight) +
           8;

  @override
  Size get preferredSize =>
      Size(double.infinity, controller.value == null ? 0 : height);

  @override
  Widget build(BuildContext context) {
    if (controller.value == null) {
      return const SizedBox(width: 0, height: 0);
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      margin: const EdgeInsets.only(bottom: 8),
      color: context.colorScheme.surface,
      alignment: Alignment.centerLeft,
      height: height,
      child: _buildFindInputView(context),
    );
  }

  Widget _buildFindInputView(BuildContext context) {
    final CodeFindValue value = controller.value!;
    final String result;
    if (value.result == null) {
      result = context.appLocalizations.none;
    } else {
      result = '${value.result!.index + 1}/${value.result!.matches.length}';
    }
    final bar = CommonMinIconButtonTheme(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (!isMobileView) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: _buildFindInput(context, value),
            ),
            const SizedBox(width: 12),
          ],
          Text(result, style: context.textTheme.bodyMedium),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 2,
              children: [
                _buildIconButton(
                  onPressed: value.result == null
                      ? null
                      : () {
                          controller.previousMatch();
                        },
                  icon: Icons.arrow_upward,
                  tooltip: context.appLocalizations.previousMatch,
                ),
                _buildIconButton(
                  onPressed: value.result == null
                      ? null
                      : () {
                          controller.nextMatch();
                        },
                  icon: Icons.arrow_downward,
                  tooltip: context.appLocalizations.nextMatch,
                ),
                const SizedBox(width: 2),
                IconButton.filledTonal(
                  tooltip: context.appLocalizations.close,
                  onPressed: controller.close,
                  icon: const Icon(Icons.close, size: 16),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (isMobileView) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          bar,
          const SizedBox(height: 12),
          _buildFindInput(context, value),
        ],
      );
    }
    return bar;
  }

  Widget _buildFindInput(BuildContext context, CodeFindValue value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: 8,
      children: [
        Flexible(
          child: _buildTextField(
            context: context,
            onSubmitted: () {
              if (value.result == null) {
                return;
              }
              controller.nextMatch();
              controller.findInputFocusNode.requestFocus();
            },
            controller: controller.findInputController,
            focusNode: controller.findInputFocusNode,
          ),
        ),
        _buildCheckText(
          context: context,
          text: 'Aa',
          isSelected: value.option.caseSensitive,
          onPressed: () {
            controller.toggleCaseSensitive();
          },
        ),
        _buildCheckText(
          context: context,
          text: '.*',
          isSelected: value.option.regex,
          onPressed: () {
            controller.toggleRegex();
          },
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildTextField({
    required BuildContext context,
    required TextEditingController controller,
    required FocusNode focusNode,
    required VoidCallback onSubmitted,
  }) {
    return SizedBox(
      height: globalState.measure.bodyMediumHeight + 8 * 2,
      child: TextField(
        maxLines: 1,
        focusNode: focusNode,
        inputFormatters: TextInputLimits.limit(TextInputLimits.search),
        style: context.textTheme.bodyMedium,
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 12),
        ),
        onSubmitted: (_) {
          onSubmitted();
        },
        controller: controller,
      ),
    );
  }

  Widget _buildCheckText({
    required BuildContext context,
    required String text,
    required bool isSelected,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 28,
      height: 28,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: isSelected
            ? IconButton.filledTonal(
                onPressed: onPressed,
                padding: const EdgeInsets.all(2),
                icon: Text(text, style: context.textTheme.bodySmall),
              )
            : IconButton(
                onPressed: onPressed,
                padding: const EdgeInsets.all(2),
                icon: Text(text, style: context.textTheme.bodySmall),
              ),
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
    );
  }
}

class ContextMenuControllerImpl implements SelectionToolbarController {
  OverlayEntry? _overlayEntry;
  bool _isFirstRender = true;
  bool readOnly = false;

  ContextMenuControllerImpl(this.readOnly);

  void _removeOverLayEntry() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _isFirstRender = true;
  }

  @override
  void hide(BuildContext context) {
    _removeOverLayEntry();
  }

  @override
  void show({
    required context,
    required controller,
    required anchors,
    renderRect,
    required layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    _removeOverLayEntry();
    _overlayEntry ??= OverlayEntry(
      builder: (context) => CodeEditorTapRegion(
        child: ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, _, child) {
            final appLocalizations = context.appLocalizations;
            final isNotEmpty = controller.selectedText.isNotEmpty;
            final isAllSelected = controller.isAllSelected;
            final hasSelected = controller.selectedText.isNotEmpty;
            final List<CommonPopupMenuItem> menus = [
              if (isNotEmpty)
                CommonPopupMenuItem(
                  label: appLocalizations.copy,
                  onPressed: controller.copy,
                ),
              if (!readOnly)
                CommonPopupMenuItem(
                  label: appLocalizations.paste,
                  onPressed: controller.paste,
                ),
              if (isNotEmpty && !readOnly)
                CommonPopupMenuItem(
                  label: appLocalizations.cut,
                  onPressed: controller.cut,
                ),
              if (hasSelected && !isAllSelected)
                CommonPopupMenuItem(
                  label: appLocalizations.selectAll,
                  onPressed: controller.selectAll,
                ),
            ];
            if (_isFirstRender) {
              _isFirstRender = false;
            } else if (controller.selectedText.isEmpty) {
              _removeOverLayEntry();
            }
            if (menus.isEmpty) {
              _removeOverLayEntry();
              return const SizedBox();
            }
            return TextSelectionToolbar(
              anchorAbove: anchors.primaryAnchor,
              anchorBelow: anchors.secondaryAnchor ?? Offset.zero,
              children: menus.asMap().entries.map((
                MapEntry<int, CommonPopupMenuItem> entry,
              ) {
                return TextSelectionToolbarTextButton(
                  padding: TextSelectionToolbarTextButton.getPadding(
                    entry.key,
                    menus.length,
                  ),
                  alignment: AlignmentDirectional.centerStart,
                  onPressed: () {
                    if (entry.value.onPressed == null) {
                      return;
                    }
                    entry.value.onPressed!();
                    _removeOverLayEntry();
                  },
                  child: Text(entry.value.label),
                );
              }).toList(),
            );
          },
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }
}

/// One syntax-highlighted range of a single line, in UTF-16 offsets.
class _HighlightRange {
  const _HighlightRange(this.start, this.end, this.className);

  final int start;
  final int end;
  final String? className;
}

class _HighlightRequest {
  const _HighlightRequest(this.code, this.languages);

  final String code;
  final List<String> languages;
}

/// Turns a whole document's highlight result into per-line token ranges.
class _LineHighlightRenderer implements HighlightRenderer {
  final List<List<_HighlightRange>> ranges = [[]];
  final List<String?> _classNames = [];
  int _offset = 0;

  @override
  void addText(String text) {
    final String? className = _classNames.isEmpty ? null : _classNames.last;
    final List<String> lines = text.split('\n');
    final String first = lines.first;
    if (first.isNotEmpty) {
      ranges.last.add(
        _HighlightRange(_offset, _offset + first.length, className),
      );
      _offset += first.length;
    }
    for (int i = 1; i < lines.length; i++) {
      ranges.add([]);
      _offset = 0;
      final String line = lines[i];
      if (line.isNotEmpty) {
        ranges.last.add(_HighlightRange(0, line.length, className));
        _offset = line.length;
      }
    }
  }

  @override
  void openNode(DataNode node) {
    final String? parent = _classNames.isEmpty ? null : _classNames.last;
    final String? scope = node.scope;
    final String? name;
    if (parent == null || scope == null) {
      name = scope;
    } else {
      name = '$parent-$scope';
    }
    _classNames.add(name?.split('.').first);
  }

  @override
  void closeNode(DataNode node) {
    if (_classNames.isNotEmpty) {
      _classNames.removeLast();
    }
  }
}

/// Runs on a worker isolate. The languages are top-level, so the isolate
/// initialises them itself rather than receiving a highlight grammar graph.
List<List<_HighlightRange>> _highlightDocument(_HighlightRequest request) {
  final Highlight highlight = Highlight()
    ..registerLanguages({
      'yaml': langYaml,
      'javascript': langJavascript,
      'json': langJson,
    });
  final HighlightResult result = request.languages.length == 1
      ? highlight.highlight(
          code: request.code,
          language: request.languages.first,
        )
      : highlight.highlightAuto(request.code, request.languages);
  final _LineHighlightRenderer renderer = _LineHighlightRenderer();
  result.render(renderer);
  return renderer.ranges;
}
