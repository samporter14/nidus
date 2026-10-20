// Release builds retain only the feature checks used by production views.
// Fixtures and render drivers are compiled only in debug builds.
#if !DEBUG
enum RenderSurfaces {
    static let isActive = false
    @MainActor static func run() {}
}

enum CaptureSurfaces {
    static let isActive = false
    @MainActor static func run() {}
}
#endif
