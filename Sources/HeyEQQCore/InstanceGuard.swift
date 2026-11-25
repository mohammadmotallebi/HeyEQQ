import Darwin

/// Two HeyEQQ pipelines (app + spike, or two app copies) each tap the other's output and
/// feed back until the signal saturates into silence. Only one may run at a time.
public enum InstanceGuard {
    static let processNames: Set<String> = ["HeyEQQ", "HeyEQQSpike"]

    public struct Instance: Sendable, CustomStringConvertible {
        public let pid: pid_t
        public let name: String
        public var description: String { "\(name) (pid \(pid))" }
    }

    /// Other running HeyEQQ processes (excluding this one).
    public static func otherInstances() -> [Instance] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        let me = getpid()
        var result: [Instance] = []
        var nameBuffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(max(0, count)) where pid > 0 && pid != me {
            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }
            let name = String(cString: nameBuffer)
            if processNames.contains(name) { result.append(Instance(pid: pid, name: name)) }
        }
        return result
    }
}
