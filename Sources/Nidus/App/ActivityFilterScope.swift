import Foundation

/// Decisions about how the Activity page's filters meet the running session
/// and the digest charts. Pure, so they can be tested without the view.
enum ActivityFilterScope {
    /// Whether the session running now belongs in a view filtered to
    /// `projectID`. With no project filter every session counts; with one,
    /// only a session planned under that project does.
    static func includesLive(sessionProjectID: UUID?, filter projectID: UUID?) -> Bool {
        projectID == nil || sessionProjectID == projectID
    }

    /// Whether the week glance, hour heatmap and drift list are showing
    /// more than the filters select. They are built from all activity, so
    /// the page says so whenever any filter is on.
    static func chartsIgnoreFilters(projectID: UUID?, focusOnly: Bool, category: String?) -> Bool {
        projectID != nil || focusOnly || category != nil
    }

    /// The note shown under the headers of the charts that ignore filters.
    static let unfilteredCaption = "All activity, regardless of filters"
}
