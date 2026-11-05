import Foundation

public struct DesktopDisplayConfiguration: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let fullScreen: Bool
    public let windowX: Int?
    public let windowY: Int?
    public init(width: Int, height: Int, fullScreen: Bool, windowX: Int? = nil, windowY: Int? = nil) {
        self.width = max(320, min(8192, width / 2 * 2))
        self.height = max(320, min(8192, height / 2 * 2))
        self.fullScreen = fullScreen
        self.windowX = windowX; self.windowY = windowY
    }
    public static let windowed1080p = Self(width: 1920, height: 1080, fullScreen: false)
    static func fullScreenForWorkspace(width: Int, height: Int, windowX: Int? = nil, windowY: Int? = nil) -> Self {
        // Fixed desktop render width, preserving the target monitor's aspect ratio.
        // 16:10 MacBook -> 1920x1200; 16:9 external display -> 1920x1080.
        let w = max(1, width); let h = max(1, height)
        let renderWidth = w >= h ? 1920 : Int((1920.0 * Double(w) / Double(h) / 2).rounded()) * 2
        let renderHeight = w >= h ? Int((1920.0 * Double(h) / Double(w) / 2).rounded()) * 2 : 1920
        return Self(width: renderWidth, height: renderHeight, fullScreen: true, windowX: windowX, windowY: windowY)
    }
    var arguments: [String] {
        var args = ["--new-display=\(width)x\(height)/160", "--display-ime-policy=local", "--no-vd-destroy-content", "--max-fps=60", "--keep-active"]
        if fullScreen { args += ["--fullscreen", "--window-borderless"] }
        if let windowX, let windowY {
            args += ["--window-x=\(windowX)", "--window-y=\(windowY)", "--window-width=640", "--window-height=400"]
        }
        return args
    }
}
