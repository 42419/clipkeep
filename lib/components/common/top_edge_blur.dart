import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:soft_edge_blur/soft_edge_blur.dart';

/// 页面顶部（状态栏 + app bar 区域）的渐进模糊。
///
/// 使用前提：页面内容已经 edge-to-edge 铺到 y=0，且滚动内容顶部留出
/// [topInset] + [extra] 的空白。滚动时内容经过该区域会逐渐虚化，
/// 而 AppBar 的标题/返回按钮在 SoftEdgeBlur 之外，保持清晰。
class TopEdgeBlur extends StatelessWidget {
  const TopEdgeBlur({
    super.key,
    required this.child,
    this.extra = 12,
    this.sigma = 12,
  });

  final Widget child;

  /// 状态栏下方额外模糊的高度（通常是 app bar 的高度或标题区留白）。
  final double extra;

  final double sigma;

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.paddingOf(context).top;
    if (topInset <= 0) {
      return child;
    }
    return SoftEdgeBlur(
      edges: <EdgeBlur>[
        EdgeBlur(
          type: EdgeType.topEdge,
          size: topInset + extra,
          sigma: sigma,
          controlPoints: <ControlPoint>[
            ControlPoint(position: 0, type: ControlPointType.visible),
            ControlPoint(position: 0.55, type: ControlPointType.visible),
            ControlPoint(position: 1, type: ControlPointType.transparent),
          ],
        ),
      ],
      child: child,
    );
  }
}

/// 页面滚动内容顶部应留出的安全区高度（状态栏 + app bar）。
double topEdgeBlurPadding(BuildContext context, {double extra = 12}) {
  return MediaQuery.paddingOf(context).top + extra;
}
