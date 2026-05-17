import Foundation
import Testing
@testable import treeline

/// Verifies the dashboard's user-facing representation for every BranchSync
/// state. The row view reads `displayLabel` directly, so locking these strings
/// in tests guarantees the dashboard tells the user something coherent for
/// each state the parser can produce.
struct BranchSyncDisplayTests {

    @Test func displaysUpToDateLabel() {
        #expect(BranchSync.upToDate.displayLabel == "up to date")
    }

    @Test func displaysAheadLabelWithCount() {
        #expect(BranchSync.ahead(3).displayLabel == "↑3")
    }

    @Test func displaysBehindLabelWithCount() {
        #expect(BranchSync.behind(2).displayLabel == "↓2")
    }

    @Test func displaysDivergedLabelWithBothCounts() {
        #expect(BranchSync.diverged(ahead: 4, behind: 7).displayLabel == "↑4 ↓7")
    }

    @Test func displaysNoUpstreamAsLocalOnly() {
        // "Projects with no upstream branch show an understandable
        // local-only or unknown sync state." — Issue #7
        #expect(BranchSync.noUpstream.displayLabel == "local only")
    }

    @Test func displaysDetachedHeadLabel() {
        #expect(BranchSync.detached.displayLabel == "detached")
    }

    @Test func unknownDashboardLabelWhenSyncStateAbsent() {
        // ProjectHealth.branchSync is nil when the probe failed or hasn't run;
        // the dashboard must render that as "unknown" rather than hiding the
        // information.
        let absent: BranchSync? = nil
        #expect(absent.dashboardDisplayLabel == "unknown")
    }

    @Test func systemImageNamesAreDistinctPerVariant() {
        // The row pairs each label with an SF Symbol; duplicates would
        // collapse two states into the same glyph at a glance.
        let names: [String] = [
            BranchSync.upToDate.systemImageName,
            BranchSync.ahead(1).systemImageName,
            BranchSync.behind(1).systemImageName,
            BranchSync.diverged(ahead: 1, behind: 1).systemImageName,
            BranchSync.noUpstream.systemImageName,
            BranchSync.detached.systemImageName
        ]
        #expect(Set(names).count == names.count)
    }
}
