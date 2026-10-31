import UIKit

// The view the renderer draws into. The Obj-C core only sees it through GameSurfaceView.h (a UIView host).
@objc(GameSurfaceView)
class GameSurfaceView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.drawsAsynchronously = true
        layer.isOpaque = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.drawsAsynchronously = true
        layer.isOpaque = true
    }

    override class var layerClass: AnyClass {
        let renderer = PLProfiles.resolveKeyForCurrentProfile("renderer") as? String
        if let renderer = renderer, ame_renderer_from_name(renderer) == AME_RENDERER_ZINK {
            return CALayer.self
        } else {
            return CAMetalLayer.self
        }
    }
}
