import XCTest
@testable import Spotiglass

final class ProcessAudioTapResolverTests: XCTestCase {
    func testCollectProcessTreeBFSParentThenChildren() {
        let children: [pid_t: [pid_t]] = [
            100: [200, 201],
            200: [300],
            201: [],
            300: [],
        ]
        let list: (pid_t) -> [pid_t] = { children[$0] ?? [] }

        let pids = ProcessAudioTapResolver.collectProcessTreePIDs(rootPID: 100, maxDepth: 4, listChildPIDs: list)

        XCTAssertEqual(pids.first, 100)
        XCTAssertTrue(pids.contains(200))
        XCTAssertTrue(pids.contains(201))
        XCTAssertTrue(pids.contains(300))
        XCTAssertEqual(Set(pids), Set([100, 200, 201, 300]))
    }

    func testCollectProcessTreeRespectsMaxDepth() {
        let children: [pid_t: [pid_t]] = [
            1: [2],
            2: [3],
            3: [4],
            4: [5],
        ]
        let list: (pid_t) -> [pid_t] = { children[$0] ?? [] }

        let shallow = ProcessAudioTapResolver.collectProcessTreePIDs(rootPID: 1, maxDepth: 1, listChildPIDs: list)
        XCTAssertEqual(shallow, [1, 2])

        let deeper = ProcessAudioTapResolver.collectProcessTreePIDs(rootPID: 1, maxDepth: 3, listChildPIDs: list)
        XCTAssertEqual(deeper, [1, 2, 3, 4])
    }

    func testCollectProcessTreeSkipsDuplicateVisit() {
        // Artificial diamond: 1 -> 2,3 and both -> 4 (second path visits 4 twice in queue)
        let children: [pid_t: [pid_t]] = [
            1: [2, 3],
            2: [4],
            3: [4],
            4: [],
        ]
        let list: (pid_t) -> [pid_t] = { children[$0] ?? [] }

        let pids = ProcessAudioTapResolver.collectProcessTreePIDs(rootPID: 1, maxDepth: 4, listChildPIDs: list)
        XCTAssertEqual(pids.filter { $0 == 4 }.count, 1)
    }

    func testMergeChildPIDListsPrefersLibprocOrderThenSortedSysctlExtras() {
        let merged = ProcessAudioTapResolver.mergeChildPIDLists(libproc: [30, 10], sysctl: [50, 10, 30])
        XCTAssertEqual(merged, [30, 10, 50])
    }

    func testMergeUniqueChildListsChainsLayers() {
        let merged = ProcessAudioTapResolver.mergeUniqueChildLists([[1, 2], [9, 1], [5, 2]])
        // Second layer sorted adds 9; third layer sorted [2,5] skips 2, appends 5.
        XCTAssertEqual(merged, [1, 2, 9, 5])
    }

    // MARK: - Extra WebKit tap inclusion

    func testExtraWebKitInclusion_commAndEmptyPathWhenNotDescendantNorPgid() {
        let root = ProcessAudioTapResolver.BsdShortProcSummary(ppid: 1, pgid: 100, uid: 501, comm: "Spotiglass")
        let helper = ProcessAudioTapResolver.BsdShortProcSummary(ppid: 1, pgid: 999, uid: 501, comm: "WebKit.WebCont")
        XCTAssertTrue(
            ProcessAudioTapResolver.shouldIncludeExtraWebKitAudioPID(
                path: "",
                comm: helper.comm,
                rootSummary: root,
                row: helper,
                isDescendantOfRoot: false,
                pgidMatchesRoot: false
            )
        )
    }

    func testExtraWebKitInclusion_rejectsWrongUid() {
        let root = ProcessAudioTapResolver.BsdShortProcSummary(ppid: 1, pgid: 100, uid: 501, comm: "Spotiglass")
        let helper = ProcessAudioTapResolver.BsdShortProcSummary(ppid: 1, pgid: 999, uid: 502, comm: "WebKit.WebCont")
        XCTAssertFalse(
            ProcessAudioTapResolver.shouldIncludeExtraWebKitAudioPID(
                path: "",
                comm: helper.comm,
                rootSummary: root,
                row: helper,
                isDescendantOfRoot: false,
                pgidMatchesRoot: false
            )
        )
    }

    func testExtraWebKitInclusion_descendantEvenWithoutPathMatch() {
        let root = ProcessAudioTapResolver.BsdShortProcSummary(ppid: 1, pgid: 100, uid: 501, comm: "Spotiglass")
        let helper = ProcessAudioTapResolver.BsdShortProcSummary(ppid: 1, pgid: 999, uid: 501, comm: "WebKit.WebCont")
        XCTAssertTrue(
            ProcessAudioTapResolver.shouldIncludeExtraWebKitAudioPID(
                path: "/some/unknown/helper",
                comm: helper.comm,
                rootSummary: root,
                row: helper,
                isDescendantOfRoot: true,
                pgidMatchesRoot: false
            )
        )
    }

    func testExtraWebKitInclusion_sharedPgid() {
        let root = ProcessAudioTapResolver.BsdShortProcSummary(ppid: 1, pgid: 100, uid: 501, comm: "Spotiglass")
        let helper = ProcessAudioTapResolver.BsdShortProcSummary(ppid: 1, pgid: 100, uid: 501, comm: "WebKit.WebCont")
        XCTAssertTrue(
            ProcessAudioTapResolver.shouldIncludeExtraWebKitAudioPID(
                path: "",
                comm: helper.comm,
                rootSummary: root,
                row: helper,
                isDescendantOfRoot: false,
                pgidMatchesRoot: true
            )
        )
    }

    func testLooksLikeWebKitAudioHelperComm_truncatedWebCont() {
        XCTAssertTrue(ProcessAudioTapResolver.looksLikeWebKitAudioHelperComm("WebKit.WebCont"))
    }

    func testLooksLikeWebKitAudioHelperPath_stillRequiresWebKitToken() {
        XCTAssertFalse(ProcessAudioTapResolver.looksLikeWebKitAudioHelperPath("/usr/bin/foo"))
    }
}
