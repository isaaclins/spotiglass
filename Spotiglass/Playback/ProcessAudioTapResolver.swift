import CoreAudio
import Darwin
import Foundation

/// Declared here because Swift does not ship a `libproc` module; the symbol is in
/// `/usr/lib/libproc.tbd` and is always available on macOS. Renamed to avoid clashing
/// with a same-named symbol visible from the Darwin overlay.
@_silgen_name("proc_listchildpids")
private func libprocListChildPIDs(_ ppid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

@_silgen_name("proc_pidpath")
private func libprocPIDPath(_ pid: pid_t, _ buffer: UnsafeMutablePointer<CChar>?, _ bufferSize: UInt32) -> Int32

@_silgen_name("proc_listallpids")
private func libprocListAllPIDs(_ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pidinfo")
private func libprocPIDInfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

private enum ProcListConstants {
    /// `PROC_PIDT_SHORTBSDINFO` from `<sys/proc_info.h>`.
    static let procPIDTShortBSDInfo: Int32 = 13
    /// `sizeof(struct proc_bsdshortinfo)` on macOS (verified against SDK headers).
    static let procBsdShortInfoBytes: Int32 = 64
    /// `offsetof(struct proc_bsdshortinfo, pbsi_pgid)` — used when WebKit helpers are not linked
    /// to the app by `ppid` alone (XPC / RunningBoard), but still share the process group.
    static let procBsdShortInfoPgidByteOffset: Int = 8
    /// `offsetof(struct proc_bsdshortinfo, pbsi_uid)`.
    static let procBsdShortInfoUidByteOffset: Int = 36
    /// `offsetof(struct proc_bsdshortinfo, pbsi_comm)` — `MAXCOMLEN` (16) bytes, not always NUL-terminated.
    static let procBsdShortInfoCommByteOffset: Int = 16
    static let procBsdShortInfoCommLength: Int = 16
}

/// Walks the current process tree and resolves each PID to a Core Audio ``AudioObjectID``
/// so ``CATapDescription`` can tap **WebKit helper processes** (WebContent, GPU,
/// Networking, …) in addition to the UI process. WKWebView audio does not render in the
/// main app PID on macOS.
enum ProcessAudioTapResolver {
    /// Default maximum BFS depth from the root PID (UI process). WebKit helpers are
    /// typically direct children; a small depth cap avoids scanning unrelated subtrees.
    static let defaultMaxDepth = 6

    /// Returns ordered PIDs: root first, then BFS descendants up to ``maxDepth``.
    /// Used by tests with an injected ``listChildPIDs``; production uses a full
    /// ``proc_listallpids`` + ``proc_pidinfo`` parent map (see ``audioObjectIDsForSpotiglassProcessTree``).
    static func collectProcessTreePIDs(
        rootPID: pid_t,
        maxDepth: Int,
        listChildPIDs: (pid_t) -> [pid_t]
    ) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [(pid: pid_t, depth: Int)] = [(rootPID, 0)]
        var seen = Set<pid_t>()
        var index = 0
        while index < queue.count {
            let (pid, depth) = queue[index]
            index += 1
            if seen.contains(pid) { continue }
            seen.insert(pid)
            result.append(pid)
            guard depth < maxDepth else { continue }
            for child in listChildPIDs(pid) where !seen.contains(child) {
                queue.append((child, depth + 1))
            }
        }
        return result
    }

    /// All Core Audio process objects for Spotiglass playback: root + descendant PIDs
    /// that expose an audio process object. Order matches BFS order.
    static func audioObjectIDsForSpotiglassProcessTree(
        rootPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        maxDepth: Int = defaultMaxDepth,
        listChildPIDs: ((pid_t) -> [pid_t])? = nil
    ) -> [AudioObjectID] {
        var webKitExtraPIDs: [pid_t] = []
        let listChild: (pid_t) -> [pid_t]
        if let injected = listChildPIDs {
            listChild = injected
        } else {
            let scan = fullProcessScan(rootPID: rootPID)
            let childMap = scan.childMap
            webKitExtraPIDs = additionalWebKitAudioPIDs(
                rootPID: rootPID,
                allPIDs: scan.allPIDs,
                summariesByPID: scan.summariesByPID,
                ppidByPid: scan.ppidByPid
            )
#if DEBUG
            let rootChildren = childMap[rootPID, default: []].sorted()
            print(
                "[ProcessAudioTap] fullProcScan: root pid \(rootPID) direct children count=\(rootChildren.count) pids=\(rootChildren); webKitExtras=\(webKitExtraPIDs.sorted())"
            )
#endif
            listChild = { ppid in
                Self.mergeUniqueChildLists([
                    Self.listChildPIDsUsingLibproc(of: ppid),
                    Self.listChildPIDsUsingSysctl(of: ppid),
                    childMap[ppid, default: []],
                ])
            }
        }
        var pids = collectProcessTreePIDs(rootPID: rootPID, maxDepth: maxDepth, listChildPIDs: listChild)
        if !webKitExtraPIDs.isEmpty {
            let seen = Set(pids)
            pids.append(contentsOf: webKitExtraPIDs.filter { !seen.contains($0) }.sorted())
        }
#if DEBUG
        logCollectedPIDsAndResolution(pids: pids)
#endif
        var ids: [AudioObjectID] = []
        ids.reserveCapacity(pids.count)
        for pid in pids {
            if let objectID = audioProcessObjectID(forPID: pid) {
                ids.append(objectID)
            }
        }
        return ids
    }

#if DEBUG
    private static func logCollectedPIDsAndResolution(pids: [pid_t]) {
        let pidSummaries = pids.map { pid -> String in
            let path = executablePathForPID(pid) ?? "(unknown path)"
            return "\(pid):\(path)"
        }
        print("[ProcessAudioTap] collected \(pids.count) PID(s) in BFS order: \(pidSummaries.joined(separator: ", "))")

        var resolved = 0
        var webKitMentionInTree = false
        for pid in pids {
            let path = executablePathForPID(pid) ?? ""
            let lower = path.lowercased()
            if lower.contains("webkit") || lower.contains("com.apple.webkit") {
                webKitMentionInTree = true
            }
            let (objectID, status) = audioProcessObjectIDWithStatus(forPID: pid)
            if objectID != nil {
                resolved += 1
                print("[ProcessAudioTap] PID \(pid) -> AudioObjectID OK (status \(status))")
            } else {
                print("[ProcessAudioTap] PID \(pid) -> AudioObjectID FAILED status=\(status) \(Self.osStatusFourCC(status))")
            }
        }
        print(
            "[ProcessAudioTap] translatePIDToProcessObject: \(resolved)/\(pids.count) succeeded; WebKit-related path seen in tree: \(webKitMentionInTree)"
        )
    }

    private static func osStatusFourCC(_ status: OSStatus) -> String {
        guard status != 0 else { return "noErr" }
        let b0 = UInt8(truncatingIfNeeded: (status >> 24) & 0xff)
        let b1 = UInt8(truncatingIfNeeded: (status >> 16) & 0xff)
        let b2 = UInt8(truncatingIfNeeded: (status >> 8) & 0xff)
        let b3 = UInt8(truncatingIfNeeded: status & 0xff)
        let bytes = [b0, b1, b2, b3]
        let fourcc = String(bytes: bytes, encoding: .ascii).map { " '\($0)'" } ?? ""
        return "(fourCC\(fourcc) hex=0x\(String(UInt32(bitPattern: status), radix: 16)))"
    }

#endif

    // MARK: - libproc

    static func listChildPIDsUsingLibproc(of ppid: pid_t) -> [pid_t] {
        let bytesNeeded = Int(libprocListChildPIDs(ppid, nil, 0))
        guard bytesNeeded > 0 else { return [] }
        let pidStride = MemoryLayout<pid_t>.stride
        let pidCount = bytesNeeded / pidStride
        guard pidCount > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: pidCount)
        let bytesStored: Int = buffer.withUnsafeMutableBytes { raw in
            Int(libprocListChildPIDs(ppid, raw.baseAddress, UInt32(bytesNeeded)))
        }
        guard bytesStored > 0 else { return [] }
        let count = min(bytesStored / pidStride, pidCount)
        return Array(buffer.prefix(count)).filter { $0 != 0 }
    }

    /// Preserves the first list’s order, then appends sorted unique PIDs from each following list.
    static func mergeUniqueChildLists(_ layers: [[pid_t]]) -> [pid_t] {
        guard let first = layers.first else { return [] }
        var seen = Set(first)
        var result = first
        for other in layers.dropFirst() {
            for pid in other.sorted() where !seen.contains(pid) {
                result.append(pid)
                seen.insert(pid)
            }
        }
        return result
    }

    /// Two-layer merge; kept for unit tests and call sites that only combine libproc + sysctl.
    static func mergeChildPIDLists(libproc: [pid_t], sysctl: [pid_t]) -> [pid_t] {
        mergeUniqueChildLists([libproc, sysctl])
    }

    struct BsdShortProcSummary: Equatable {
        let ppid: pid_t
        let pgid: pid_t
        let uid: uid_t
        /// Command name from ``proc_bsdshortinfo.pbsi_comm`` (up to 16 bytes).
        let comm: String
    }

    /// Executable path for ``pid`` (same backing as ``proc_pidpath``); available in all build configs.
    private static func executablePathForPID(_ pid: pid_t) -> String? {
        let maxSize = 4 * 1024
        var buffer = [CChar](repeating: 0, count: maxSize)
        let ret = buffer.withUnsafeMutableBufferPointer { raw in
            libprocPIDPath(pid, raw.baseAddress, UInt32(maxSize))
        }
        guard ret > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Fills ``proc_bsdshortinfo`` once; used to build the parent map and to match WebKit helpers.
    private static func shortBSDSummary(forPID pid: pid_t) -> BsdShortProcSummary? {
        var info = [UInt8](repeating: 0, count: Int(ProcListConstants.procBsdShortInfoBytes))
        let written = info.withUnsafeMutableBytes { raw -> Int32 in
            libprocPIDInfo(
                Int32(pid),
                ProcListConstants.procPIDTShortBSDInfo,
                0,
                raw.baseAddress,
                ProcListConstants.procBsdShortInfoBytes
            )
        }
        guard written == ProcListConstants.procBsdShortInfoBytes else { return nil }
        let ppid = info.withUnsafeBytes { $0.load(fromByteOffset: MemoryLayout<UInt32>.stride, as: UInt32.self) }
        let pgid = info.withUnsafeBytes {
            $0.load(fromByteOffset: ProcListConstants.procBsdShortInfoPgidByteOffset, as: UInt32.self)
        }
        let uid = info.withUnsafeBytes {
            $0.load(fromByteOffset: ProcListConstants.procBsdShortInfoUidByteOffset, as: uid_t.self)
        }
        let commSlice = info[ProcListConstants.procBsdShortInfoCommByteOffset..<(ProcListConstants.procBsdShortInfoCommByteOffset + ProcListConstants.procBsdShortInfoCommLength)]
        let comm = String(decoding: commSlice.prefix { $0 != 0 }, as: UTF8.self)
        return BsdShortProcSummary(
            ppid: pid_t(truncatingIfNeeded: ppid),
            pgid: pid_t(truncatingIfNeeded: pgid),
            uid: uid,
            comm: comm
        )
    }

    /// ``proc_listallpids`` can require more bytes than a single sizing call reports; grow until the
    /// listing fits so parent/child edges are not silently dropped.
    private static func allActivePIDsFromProcList() -> [pid_t] {
        let initial = Int(libprocListAllPIDs(nil, 0))
        var capacity = max(initial, 16_384)
        for _ in 0..<10 {
            var buffer = [UInt8](repeating: 0, count: capacity)
            let filled = buffer.withUnsafeMutableBytes { raw -> Int32 in
                libprocListAllPIDs(raw.baseAddress, Int32(raw.count))
            }
            guard filled > 0 else { return [] }
            if Int(filled) > capacity {
                capacity = Int(filled) + MemoryLayout<pid_t>.stride * 512
                continue
            }
            // A return size equal to the buffer may mean the table was truncated; grow once more.
            if Int(filled) == capacity {
                capacity += 8192
                continue
            }
            let stride = MemoryLayout<pid_t>.stride
            let usableBytes = Int(filled) - (Int(filled) % stride)
            let count = usableBytes / stride
            guard count > 0 else { return [] }
            return buffer.withUnsafeBytes { raw in
                let pids = raw.bindMemory(to: pid_t.self)
                return (0..<count).map { pids[$0] }.filter { $0 > 0 }
            }
        }
        return []
    }

    static func looksLikeWebKitAudioHelperPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.contains("webkit") else { return false }
        if lower.contains("webcontent") { return true }
        if lower.contains("webkit.networking") { return true }
        if lower.contains("webkit.gpu") { return true }
        if lower.contains("com.apple.webkit.webcontent") { return true }
        if lower.contains("com.apple.webkit.networking") { return true }
        if lower.contains("com.apple.webkit.gpu") { return true }
        return false
    }

    /// Heuristic on ``proc_bsdshortinfo.pbsi_comm`` (16 chars) for WebKit roles that may carry WKWebView audio.
    static func looksLikeWebKitAudioHelperComm(_ comm: String) -> Bool {
        let lower = comm.lowercased()
        if lower.contains("webcontent") { return true }
        // `pbsi_comm` is truncated at 16 chars; "WebKit.WebContent" often becomes "WebKit.WebCont".
        if lower.contains("webcont") { return true }
        if lower.contains("webkit") && lower.contains("network") { return true }
        if lower.contains("webkit") && lower.contains("gpu") { return true }
        if lower.contains("com.apple.webkit") { return true }
        return false
    }

    private static func isDescendantOfRoot(pid: pid_t, rootPID: pid_t, ppidByPid: [pid_t: pid_t]) -> Bool {
        var current = pid
        for _ in 0..<64 {
            guard let parent = ppidByPid[current] else { return false }
            if parent == rootPID { return true }
            if parent <= 1 { return false }
            current = parent
        }
        return false
    }

    /// Whether an extra WebKit-shaped PID should join the process tap (same euid as root), for tests and diagnostics.
    static func shouldIncludeExtraWebKitAudioPID(
        path: String,
        comm: String,
        rootSummary: BsdShortProcSummary,
        row: BsdShortProcSummary,
        isDescendantOfRoot: Bool,
        pgidMatchesRoot: Bool
    ) -> Bool {
        guard row.uid == rootSummary.uid else { return false }
        let pathMatch = looksLikeWebKitAudioHelperPath(path)
        let commMatch = looksLikeWebKitAudioHelperComm(comm)
        guard pathMatch || commMatch else { return false }
        if isDescendantOfRoot { return true }
        if pgidMatchesRoot, rootSummary.pgid > 0 { return true }
        // Reparented helpers: `proc_pidpath` can fail (empty path) while `pbsi_comm` still identifies WebKit audio roles.
        if commMatch, path.isEmpty { return true }
        return false
    }

    /// WebKit helper PIDs that should participate in the tap when they are not reachable via ``ppid``
    /// edges from the UI process (common with XPC / RunningBoard), but still belong to this user and
    /// either descend from ``rootPID`` on the best-effort map, share its process group, or match the
    /// comm-based fallback when executable path resolution fails.
    private static func additionalWebKitAudioPIDs(
        rootPID: pid_t,
        allPIDs: [pid_t],
        summariesByPID: [pid_t: BsdShortProcSummary],
        ppidByPid: [pid_t: pid_t]
    ) -> [pid_t] {
        guard let rootSummary = summariesByPID[rootPID] else { return [] }
        var extras: [pid_t] = []
        for pid in allPIDs {
            guard pid != rootPID else { continue }
            guard let row = summariesByPID[pid] else { continue }
            let path = executablePathForPID(pid) ?? ""
            let descendant = isDescendantOfRoot(pid: pid, rootPID: rootPID, ppidByPid: ppidByPid)
            let pgidMatches = row.pgid == rootSummary.pgid
            guard shouldIncludeExtraWebKitAudioPID(
                path: path,
                comm: row.comm,
                rootSummary: rootSummary,
                row: row,
                isDescendantOfRoot: descendant,
                pgidMatchesRoot: pgidMatches
            ) else { continue }
            extras.append(pid)
        }
        return extras
    }

    /// Builds ``ppid -> [child pid]`` by scanning every live PID from ``proc_listallpids`` and
    /// reading each row’s parent via ``proc_pidinfo(PROC_PIDT_SHORTBSDINFO)``. This survives cases
    /// where ``proc_listchildpids`` and ``sysctl(KERN_PROC_ALL)`` omit rows that still exist in
    /// the global pid table (nested WebKit helpers under intermediate children).
    static func childrenByParentUsingFullProcScan() -> [pid_t: [pid_t]] {
        fullProcessScan(rootPID: ProcessInfo.processInfo.processIdentifier).childMap
    }

    private static func fullProcessScan(rootPID: pid_t) -> (
        allPIDs: [pid_t],
        childMap: [pid_t: [pid_t]],
        summariesByPID: [pid_t: BsdShortProcSummary],
        ppidByPid: [pid_t: pid_t]
    ) {
        let allPIDs = allActivePIDsFromProcList()
        var childMap: [pid_t: [pid_t]] = [:]
        var summariesByPID: [pid_t: BsdShortProcSummary] = [:]
        var ppidByPid: [pid_t: pid_t] = [:]
        childMap.reserveCapacity(64)
        summariesByPID.reserveCapacity(allPIDs.count)
        for pid in allPIDs {
            guard let summary = shortBSDSummary(forPID: pid) else { continue }
            summariesByPID[pid] = summary
            ppidByPid[pid] = summary.ppid
            if summary.ppid > 0 {
                childMap[summary.ppid, default: []].append(pid)
            }
        }
        return (allPIDs, childMap, summariesByPID, ppidByPid)
    }

    private static func ppidForPIDUsingProcInfo(pid: pid_t) -> pid_t? {
        shortBSDSummary(forPID: pid)?.ppid
    }

    /// Uses ``kern.proc.all`` so children are visible when ``proc_listchildpids`` returns nothing
    /// (common under the App Sandbox). WKWebView helpers such as WebContent remain direct children
    /// of the host process in the sysctl snapshot.
    static func listChildPIDsUsingSysctl(of ppid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length: size_t = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: length,
            alignment: MemoryLayout<kinfo_proc>.alignment
        )
        defer { buffer.deallocate() }
        var copyLength = length
        guard sysctl(&mib, 3, buffer, &copyLength, nil, 0) == 0 else { return [] }
        let count = Int(copyLength) / MemoryLayout<kinfo_proc>.stride
        guard count > 0 else { return [] }
        let rows = buffer.assumingMemoryBound(to: kinfo_proc.self)
        var children: [pid_t] = []
        for i in 0..<count {
            let kp = rows[i]
            guard kp.kp_eproc.e_ppid == ppid else { continue }
            children.append(kp.kp_proc.p_pid)
        }
        return children
    }

    // MARK: - HAL

    static func audioProcessObjectID(forPID pid: pid_t) -> AudioObjectID? {
        audioProcessObjectIDWithStatus(forPID: pid).objectID
    }

    /// Underlying HAL translate call; used by ``audioProcessObjectID(forPID:)`` and DEBUG diagnostics.
    static func audioProcessObjectIDWithStatus(forPID pid: pid_t) -> (objectID: AudioObjectID?, status: OSStatus) {
        var pidValue = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &processObjectID
        )
        guard status == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            return (nil, status)
        }
        return (processObjectID, noErr)
    }
}
