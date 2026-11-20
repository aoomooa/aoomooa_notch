//
//  AoomooaProcessGuard.swift — 管住刘海自己启动的 mediaremote-adapter.pl
//
//  · 启动子进程后保存 Process 引用，并写 PID 文件（子进程 PID + 本 App PID）
//  · App 退出（正常退出或收到 SIGTERM）时 terminate()，超时再 SIGKILL
//  · 下次启动时只清理同时满足下面三条的进程：
//      PID 文件里有它 · 进程参数里确实是 mediaremote-adapter.pl · 它的父进程已经不在了（已被 launchd 收养）
//  · 绝不按名字 killall，不会误杀别的 App（包括原版 Boring Notch）的进程
//

import AppKit
import Darwin
import Foundation

final class AoomooaProcessGuard: @unchecked Sendable {
    static let shared = AoomooaProcessGuard()

    /// 只认这个脚本
    static let marker = "mediaremote-adapter.pl"
    /// terminate() 之后最多等多久，再强制结束（秒）
    static let terminateTimeout: TimeInterval = 1.0

    private struct Entry: Equatable {
        let pid: Int32
        let parent: Int32
    }

    private let lock = NSLock()
    private var tracked: [Int32: Process] = [:]
    private var signalSource: DispatchSourceSignal?

    private init() {}

    /// 本 App 当前管着的子进程数量（诊断页显示）
    var trackedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tracked.values.filter { $0.isRunning }.count
    }

    // MARK: - 启动 / 退出

    /// App 启动时调用一次
    func start() {
        cleanupLeftoversFromLastRun()
        installSIGTERMHandler()
    }

    /// 子进程 run() 之后调用
    func register(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        tracked[pid] = process
        var entries = readEntries().filter { $0.pid != pid }
        entries.append(Entry(pid: pid, parent: getpid()))
        writeEntries(entries)
    }

    /// 子进程自己结束了
    func unregister(_ process: Process) {
        let pid = process.processIdentifier
        lock.lock(); defer { lock.unlock() }
        tracked[pid] = nil
        writeEntries(readEntries().filter { $0.pid != pid })
    }

    /// App 退出时调用：先 terminate()，超时再 SIGKILL
    func terminateAll() {
        lock.lock()
        let processes = Array(tracked.values)
        tracked.removeAll()
        lock.unlock()

        for p in processes where p.isRunning { p.terminate() }
        let deadline = Date().addingTimeInterval(Self.terminateTimeout)
        while Date() < deadline, processes.contains(where: { $0.isRunning }) {
            usleep(20_000)
        }
        for p in processes where p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }

        lock.lock()
        writeEntries(readEntries().filter { $0.parent != getpid() })
        lock.unlock()
    }

    // MARK: - 清理残留

    /// 启动时：只看 PID 文件里“别的（已退出的）本 App 实例”留下的记录
    private func cleanupLeftoversFromLastRun() {
        lock.lock()
        let all = readEntries()
        let stale = all.filter { $0.parent != getpid() }
        writeEntries(all.filter { $0.parent == getpid() })
        lock.unlock()

        let pids = stale.map(\.pid)
        guard !pids.isEmpty else { return }
        Task.detached(priority: .utility) {
            let n = await AoomooaProcessGuard.shared.reap(pids)
            if n > 0 { NSLog("aoomooa: cleaned \(n) leftover \(AoomooaProcessGuard.marker) process(es)") }
        }
    }

    /// 设置 → aoomooa → 诊断：扫一遍所有“父进程已不在”的 mediaremote-adapter.pl
    /// 返回清理掉的数量（nil = 没法检查）
    func cleanupOrphansNow() async -> Int? {
        if let n = await XPCHelperClient.shared.terminateOrphanedAdapters(pids: [], marker: Self.marker) {
            return n
        }
        let candidates = AoomooaProcessInspector.userProcessIDs()
        guard !candidates.isEmpty else { return nil }
        return localReap(candidates)
    }

    /// 交给不在沙盒里的 XPC 助手检查并结束；助手不可用时在本进程里检查
    private func reap(_ pids: [Int32]) async -> Int {
        if let n = await XPCHelperClient.shared.terminateOrphanedAdapters(pids: pids, marker: Self.marker) {
            return n
        }
        return localReap(pids)
    }

    /// 只有能确认“名字对得上 + 父进程已不在”时才结束
    private func localReap(_ pids: [Int32]) -> Int {
        var n = 0
        for pid in pids where AoomooaProcessInspector.isOrphanedAdapter(pid, marker: Self.marker) {
            if AoomooaProcessInspector.terminate(pid, timeout: Self.terminateTimeout) { n += 1 }
        }
        return n
    }

    // MARK: - SIGTERM（比如被 kill 命令结束）也要带走子进程

    private func installSIGTERMHandler() {
        guard signalSource == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            AoomooaProcessGuard.shared.terminateAll()
            exit(0)
        }
        source.resume()
        signalSource = source
    }

    // MARK: - PID 文件（每行：子进程PID 父进程PID）

    private var pidFileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("aoomooa", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("child-processes.pid")
    }

    /// PID 文件的位置（诊断页显示）
    var pidFilePath: String { pidFileURL?.path ?? "—" }

    private func readEntries() -> [Entry] {
        guard let url = pidFileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
            return Entry(pid: pid, parent: parent)
        }
    }

    private func writeEntries(_ entries: [Entry]) {
        guard let url = pidFileURL else { return }
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let text = entries.map { "\($0.pid) \($0.parent)" }.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 读进程信息（sysctl），沙盒里读不到别的进程时返回 nil / 空
enum AoomooaProcessInspector {
    /// 父进程 PID 和所属用户
    static func info(of pid: Int32) -> (ppid: Int32, uid: uid_t)? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
        return (kinfo.kp_eproc.e_ppid, kinfo.kp_eproc.e_ucred.cr_uid)
    }

    /// 进程的命令行参数
    static func arguments(of pid: Int32) -> [String]? {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibMax, UInt32(mibMax.count), &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var size = Int(argmax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // 可执行文件路径
        while index < size && buffer[index] == 0 { index += 1 }   // 补齐用的 0
        var args: [String] = []
        var start = index
        while index < size && args.count < Int(argc) {
            if buffer[index] == 0 {
                args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return args
    }

    /// 名字对得上 · 属于当前用户 · 父进程已不在（被 launchd 收养，PPID = 1）
    static func isOrphanedAdapter(_ pid: Int32, marker: String) -> Bool {
        guard pid > 1, let info = info(of: pid), info.uid == getuid(), info.ppid == 1,
              let args = arguments(of: pid) else { return false }
        return args.contains { $0.hasSuffix("/" + marker) || $0 == marker }
    }

    /// SIGTERM，超时再 SIGKILL；返回进程是否已经不在
    static func terminate(_ pid: Int32, timeout: TimeInterval) -> Bool {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            usleep(20_000)
        }
        kill(pid, SIGKILL)
        usleep(20_000)
        return kill(pid, 0) != 0
    }

    /// 当前用户的所有进程 PID
    static func userProcessIDs() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }
    }
}
