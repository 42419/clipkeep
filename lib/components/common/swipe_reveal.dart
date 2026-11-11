import 'package:material_ui/material_ui.dart';

/// 控制同一列表内只允许一项展开的滑出操作。
class SwipeRevealController extends ChangeNotifier {
  int? _openIndex;

  /// 当前展开项的下标；没有展开时为 null。
  int? get openIndex => _openIndex;

  /// 展开/收起指定项。
  void toggle(int index) {
    _openIndex = _openIndex == index ? null : index;
    notifyListeners();
  }

  /// 展开指定项。
  void reveal(int index) {
    if (_openIndex == index) {
      return;
    }
    _openIndex = index;
    notifyListeners();
  }

  /// 收起当前项。
  void close() {
    if (_openIndex == null) {
      return;
    }
    _openIndex = null;
    notifyListeners();
  }
}

/// 右侧滑出操作按钮的列表项。
///
/// 向左拖动或点击整行展开，同一列表同一时刻只有一项展开。
/// child 建议自带 Material + InkWell，点击逻辑由调用方通过 controller 控制。
class SwipeRevealItem extends StatefulWidget {
  const SwipeRevealItem({
    super.key,
    required this.controller,
    required this.index,
    required this.child,
    required this.actions,
    this.borderRadius = 28,
    this.actionWidth = 64,
    this.actionGap = 8,
    this.actionPadding = 12,
  });

  /// 列表级控制器。
  final SwipeRevealController controller;

  /// 当前项在列表中的下标。
  final int index;

  /// 主体内容（建议带不透明背景，否则会透出下层操作）。
  final Widget child;

  /// 展开后露出的操作，按从左到右排列。
  final List<Widget> actions;

  /// 整项圆角，需与 child 的背景圆角一致。
  final double borderRadius;

  /// 单个操作按钮宽度。
  final double actionWidth;

  /// 操作按钮之间的间距。
  final double actionGap;

  /// 操作区距右侧的内边距。
  final double actionPadding;

  @override
  State<SwipeRevealItem> createState() => _SwipeRevealItemState();
}

class _SwipeRevealItemState extends State<SwipeRevealItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  bool _dragging = false;
  double _dragStartX = 0;
  double _dragFrom = 0;

  /// 完全展开时主体需要左移的距离。
  double get _revealWidth =>
      widget.actions.length * widget.actionWidth +
      (widget.actions.length - 1) * widget.actionGap +
      widget.actionPadding;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncWithController);
  }

  @override
  void didUpdateWidget(SwipeRevealItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncWithController);
      widget.controller.addListener(_syncWithController);
    }
    _syncWithController();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncWithController);
    _anim.dispose();
    super.dispose();
  }

  void _syncWithController() {
    if (_dragging) {
      return;
    }
    final bool open = widget.controller.openIndex == widget.index;
    final double target = open ? 1 : 0;
    if ((_anim.value - target).abs() < 0.001) {
      return;
    }
    _anim.animateTo(target, curve: Curves.easeOutCubic);
  }

  void _onDragStart(DragStartDetails details) {
    _dragging = true;
    _dragStartX = details.globalPosition.dx;
    _dragFrom = _anim.value;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    // 向左拖为正。
    final double dx = _dragStartX - details.globalPosition.dx;
    _anim.value = (_dragFrom + dx / _revealWidth).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    _dragging = false;
    final double velocity = -(details.primaryVelocity ?? 0);
    final bool open = velocity > 250 || (velocity > -250 && _anim.value > 0.5);
    if (open) {
      widget.controller.reveal(widget.index);
    } else {
      widget.controller.close();
    }
    _syncWithController();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(right: widget.actionPadding),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  for (int i = 0; i < widget.actions.length; i++) ...<Widget>[
                    if (i > 0) SizedBox(width: widget.actionGap),
                    SizedBox(
                      width: widget.actionWidth,
                      height: 56,
                      child: widget.actions[i],
                    ),
                  ],
                ],
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _anim,
            builder: (BuildContext context, Widget? child) {
              return Transform.translate(
                offset: Offset(-_revealWidth * _anim.value, 0),
                child: child,
              );
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: _onDragStart,
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}

/// 滑出操作里的单个按钮，按 64×56 的胶囊渲染。
class SwipeRevealAction extends StatelessWidget {
  const SwipeRevealAction({
    super.key,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Color backgroundColor;
  final Color foregroundColor;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(child: Icon(icon, color: foregroundColor)),
        ),
      ),
    );
  }
}
