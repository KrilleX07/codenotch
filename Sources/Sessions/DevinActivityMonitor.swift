import Combine
import Darwin
import Foundation
import SQLite3

/// Follows Devin sessions, whichever app started them.
///
/// Devin Desktop, T3 Code and the terminal all run the same `devin` binary
/// (`devin acp`), and every open session takes a lock file named after its id
/// in `session_locks/` that holds the owning pid. That makes the locks the live
/// registry: a lock whose pid is a running `devin` is an open session. Its
/// state comes from the shared `sessions.db` — a turn is in flight while the
/// newest conversation node is a user message, a tool result or an assistant
/// message that still has tool calls, and over once the assistant has answered
/// without any. Activity is dated from the newest node or subagent update, not
/// `sessions.last_activity_at`, which Devin Desktop leaves behind for the whole
/// run. Only working and just-completed sessions are listed; an open
/// session sitting at its prompt is not an agent doing anything.
@MainActor
final class DevinActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let root: URL
    private let interval: TimeInterval
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        root: URL = DevinActivity.root,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 420
    ) {
        self.root = root
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rescan() {
        let found = DevinActivity.read(root: root, staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }
}

enum DevinActivity {
    static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/devin/cli")
    }

    /// Lock files are named after the session id, a lowercase slug.
    private static func isSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        let locks = root.appendingPathComponent("session_locks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: locks.path)) ?? []
        var pids: [String: pid_t] = [:]
        for name in names where name.hasSuffix(".lock") {
            let id = String(name.dropLast(".lock".count))
            guard isSessionID(id),
                  let text = try? String(contentsOf: locks.appendingPathComponent(name), encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  isDevin(pid: pid)
            else { continue }
            pids[id] = pid
        }
        guard !pids.isEmpty, let db = SQLiteStore.open(root.appendingPathComponent("sessions.db"))
        else { return [] }
        defer { sqlite3_close(db) }

        let list = pids.keys.map { "'\($0)'" }.joined(separator: ",")
        let rows = SQLiteStore.rows(in: db, sql: """
            SELECT s.id, s.working_directory, IFNULL(s.title, ''),
                   MAX(IFNULL((SELECT MAX(m.created_at) FROM message_nodes m WHERE m.session_id = s.id), 0),
                       IFNULL((SELECT MAX(h.updated_at) FROM subagent_heads h WHERE h.session_id = s.id), 0)),
                   IFNULL((SELECT substr(m.chat_message, 1, 200)
                           || CASE WHEN instr(m.chat_message, '"tool_calls":[{') > 0 THEN '"@tools"' ELSE '' END
                           FROM message_nodes m
                           WHERE m.session_id = s.id
                             AND instr(substr(m.chat_message, 1, 200), '"role":"system"') = 0
                           ORDER BY m.node_id DESC LIMIT 1), '')
            FROM sessions s WHERE s.id IN (\(list))
            """, columns: 5)

        return rows.compactMap { row -> AgentSession? in
            guard let pid = pids[row[0]] else { return nil }
            let stamp = Double(row[3]) ?? 0
            let touched = stamp > 0 ? Date(timeIntervalSince1970: stamp) : now
            let folder = URL(fileURLWithPath: row[1]).lastPathComponent
            let name = row[2].isEmpty ? (folder.isEmpty ? "Devin" : folder) : row[2]
            let surface = SessionFocus.owningApp(of: pid)?.localizedName ?? L10n.t("Terminal")
            let age = now.timeIntervalSince(touched)
            let state: AgentSession.State
            switch turn(inLastNode: row[4]) {
            case .inFlight where age <= staleAfter: state = .busy
            case .finished where age <= 10: state = .success
            default: return nil
            }
            return AgentSession(id: "devin.\(row[0])", name: name,
                                detail: folder.isEmpty || folder == name ? surface : "\(folder) · \(surface)",
                                state: state, waitingFor: nil, since: touched, processID: pid)
        }
        .sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    enum Turn { case inFlight, finished }

    /// `head` is the start of the newest non-system node, followed by the
    /// `"@tools"` marker when the message carries tool calls.
    static func turn(inLastNode head: String) -> Turn? {
        if head.contains("\"role\":\"user\"") || head.contains("\"role\":\"tool\"") { return .inFlight }
        guard head.contains("\"role\":\"assistant\"") else { return nil }
        // An assistant node with no text and no tool calls is a step mid-turn,
        // not an answer.
        let silent = head.contains("\"role\":\"assistant\",\"content\":\"\"")
        return head.hasSuffix("\"@tools\"") || silent ? .inFlight : .finished
    }

    /// The lock holds a pid that may since have been handed to something else,
    /// so the process also has to be a `devin` binary.
    static func isDevin(pid: pid_t) -> Bool {
        guard pid > 0, ProcessLiveness.isAlive(pid: pid, startedAt: nil) else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent == "devin"
    }
}
