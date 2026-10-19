import Foundation
import Testing
@testable import Nidus

struct ActivityMetadataTests {
    @Test func scienceOriginAndRoutesStayNarrow() {
        #expect(ActivityProbe.isLocalScienceURL("http://localhost:8765/projects/proj_test/frames/4c78e242-fdcd-4de1-8c9c-0618d789de69"))
        #expect(ActivityProbe.isLocalScienceURL("http://127.0.0.1:8765/"))
        for url in ["https://localhost:8765/", "http://evil.example:8765/", "http://localhost:8766/", "http://localhost:8765/other", "http://localhost:8765/projects/no", "http://user@localhost:8765/", "http://localhost:8765/projects/proj_a/frames/not-a-uuid"] {
            #expect(!ActivityProbe.isLocalScienceURL(url))
        }
    }
    @Test func capsidMetadataRequiresMatchingLiveProcessAndFreshTime() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var context = CapsidActivityContext(version: 1, pid: 42, updatedAt: 997, projectName: "Test project", taskName: "Test task")
        func detail(_ value: CapsidActivityContext, pid: Int32 = 42) throws -> ActivityDetail? {
            CapsidActivityContext.detail(data: try JSONEncoder().encode(value), pid: pid, now: now)
        }
        #expect(try detail(context)?.title == "Test project · Test task")
        #expect(try detail(context, pid: 43) == nil)
        context.updatedAt = 984
        #expect(try detail(context) == nil)
        context.updatedAt = 1003
        #expect(try detail(context) == nil)
        context.updatedAt = 1000; context.version = 2
        #expect(try detail(context) == nil)
        context.version = 1; context.taskName = nil
        #expect(try detail(context) == nil)
        #expect(CapsidActivityContext.detail(data: Data(repeating: 32, count: 8193), pid: 42, now: now) == nil)
    }
}
