import AppKit
import Combine
import Foundation
import SQLite3

/// Notices when Antigravity is working.
///
/// Its transcripts are appended to as an agent runs, so a file written moments
/// ago is a turn in progress. The step *statuses* cannot be used for this —
/// every one of them says `DONE`, because a step is only written once it is
/// finished. Recency is the signal there is.
///
/// Without this the Gemini ring never showed the working state that Claude,
/// Cursor and Codex all had, and the store never learned Antigravity was busy,
/// so it stayed on its slow idle poll while usage was actively being spent.
final class AntigravityActivityMonitor: AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let roots: [URL]
    private let interval: TimeInterval
    /// How recently a transcript must have been written to count as live.
    /// Generous, because a model can think for a while between two lines.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(roots: [URL] = AntigravityActivity.transcriptRoots,
         interval: TimeInterval = 2,
         staleAfter: TimeInterval = 25) {
        self.roots = roots
        self.interval = interval
        self.staleAfter = staleAfter
    }

    convenience init(profile: AntigravityProfile,
                     interval: TimeInterval = 2,
                     staleAfter: TimeInterval = 25) {
        let roots = profile.slug == nil ? AntigravityActivity.transcriptRoots : [profile.brainDirectory]
        self.init(roots: roots, interval: interval, staleAfter: staleAfter)
    }

    func start() {
        stop()
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let found = Self.read(roots: roots, staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }

    static func antigravityPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity")
            .first?.processIdentifier
    }

    /// Returns all live turns across every install directory.
    static func read(roots: [URL], staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        let all = roots.flatMap { read(root: $0, staleAfter: staleAfter, now: now) }
        var seen = Set<String>()
        var unique: [AgentSession] = []
        for s in all.sorted(by: { $0.since > $1.since }) {
            if seen.insert(s.id).inserted {
                unique.append(s)
            }
        }
        return unique
    }

    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        // 1. Try reading real-time conversation statuses from conversation_summaries.db
        let dbURL = root.deletingLastPathComponent().appendingPathComponent("conversation_summaries.db")
        if let db = SQLiteStore.open(dbURL) {
            defer { sqlite3_close(db) }
            let sql = "SELECT conversation_id, title, status, last_modified_time, last_user_input_time, workspace_uris, agent_name FROM conversation_summaries WHERE not_fully_idle = 1 AND killed = 0 ORDER BY last_modified_time DESC;"
            let rows = SQLiteStore.rows(in: db, sql: sql, columns: 7)
            var sessions: [AgentSession] = []
            for row in rows {
                let convoID = row[0]
                guard !convoID.isEmpty else { continue }
                let title = row[1]
                let lastModifiedStr = row[3]
                let lastUserInputStr = row[4]
                let workspaceURIsStr = row[5]
                let agentName = row[6]

                let workspace = parseWorkspace(from: workspaceURIsStr)
                let userInputDate = parseDate(lastUserInputStr)

                let transcriptPath = root.appendingPathComponent("\(convoID)/.system_generated/logs/transcript.jsonl")
                var info = stat()
                let modified: Date
                if stat(transcriptPath.path, &info) == 0 {
                    modified = Date(timeIntervalSince1970:
                        TimeInterval(info.st_mtimespec.tv_sec)
                        + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                } else if let parsedDate = parseDate(lastModifiedStr) {
                    modified = parsedDate
                } else {
                    modified = now
                }

                if let sess = session(
                    trajectory: transcriptPath,
                    title: title,
                    workspace: workspace,
                    agentName: agentName,
                    userInputDate: userInputDate,
                    modified: modified,
                    staleAfter: staleAfter,
                    now: now
                ) {
                    sessions.append(sess)
                }
            }
            if !sessions.isEmpty {
                return sessions.sorted(by: { $0.since > $1.since })
            }
        }

        // 2. Fallback: scan all trajectory transcripts in the directory
        let manager = FileManager.default
        guard let trajectories = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        var sessions: [AgentSession] = []
        for trajectory in trajectories {
            let transcriptPath = trajectory.path
                + "/.system_generated/logs/transcript.jsonl"
            var info = stat()
            guard stat(transcriptPath, &info) == 0 else { continue }
            let modified = Date(timeIntervalSince1970:
                TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            if let sess = session(
                trajectory: URL(fileURLWithPath: transcriptPath),
                title: nil,
                workspace: nil,
                agentName: nil,
                userInputDate: nil,
                modified: modified,
                staleAfter: staleAfter,
                now: now
            ) {
                sessions.append(sess)
            }
        }

        return sessions.sorted(by: { $0.since > $1.since })
    }

    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: " ", with: "T")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: normalized) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: normalized) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.date(from: trimmed)
    }

    static func parseWorkspace(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let uris = (try? JSONSerialization.jsonObject(with: data)) as? [String] else {
            return nil
        }
        for uri in uris {
            guard !uri.isEmpty, let url = URL(string: uri) else { continue }
            let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && name != "/" {
                return name
            }
        }
        return nil
    }

    static func tail(of url: URL, bytes: Int = 64 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    static func parseState(inTail data: Data) -> (
        state: AgentSession.State,
        waitingFor: String?,
        lastUserInputDate: Date?,
        workspace: String?,
        latestStepType: String?
    ) {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        
        var isTurnOver = false
        var resolvedState: AgentSession.State?
        var waitingFor: String?
        var lastUserInputDate: Date?
        var workspace: String?
        var latestStepType: String?
        
        for line in lines.reversed() {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            
            if latestStepType == nil,
               type != "EPHEMERAL_MESSAGE",
               type != "CONVERSATION_HISTORY",
               type != "KNOWLEDGE_ARTIFACTS",
               type != "CHECKPOINT" {
                latestStepType = type
            }

            if lastUserInputDate == nil, type == "USER_INPUT" {
                if let createdAt = json["created_at"] as? String {
                    lastUserInputDate = parseDate(createdAt)
                }
            }

            if workspace == nil, let toolCalls = json["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    if let args = call["args"] as? [String: Any] ?? call["arguments"] as? [String: Any],
                       let cwd = (args["Cwd"] as? String)?.replacingOccurrences(of: "\"", with: "") {
                        let name = URL(fileURLWithPath: cwd).lastPathComponent
                        if !name.isEmpty && name != "/" {
                            workspace = name
                            break
                        }
                    }
                }
            }
            
            if resolvedState == nil {
                if type == "USER_INPUT" {
                    if isTurnOver {
                        resolvedState = .idle
                    } else {
                        resolvedState = .busy
                    }
                } else if type == "PLANNER_RESPONSE" {
                    if isTurnOver {
                        continue
                    }
                    if let toolCalls = json["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                        for call in toolCalls {
                            guard let name = call["name"] as? String else { continue }
                            if name.contains("ask_question") {
                                resolvedState = .waiting
                                waitingFor = L10n.t("Question")
                                break
                            }
                            if name.contains("ask_permission") || name.contains("request_permission") {
                                resolvedState = .waiting
                                waitingFor = L10n.t("Permission")
                                break
                            }
                            if name.contains("multi_replace_file_content") || name.contains("write_to_file") || name.contains("replace_file_content") {
                                if let args = call["arguments"] as? [String: Any] ?? call["args"] as? [String: Any],
                                   let meta = args["ArtifactMetadata"] as? [String: Any],
                                   meta["RequestFeedback"] as? Bool == true {
                                    resolvedState = .waiting
                                    waitingFor = L10n.t("Approval")
                                    break
                                }
                            }
                        }
                        if resolvedState == nil {
                            resolvedState = .busy
                        }
                    } else {
                        isTurnOver = true
                    }
                } else if type == "EPHEMERAL_MESSAGE" || type == "CONVERSATION_HISTORY" || type == "KNOWLEDGE_ARTIFACTS" || type == "CHECKPOINT" {
                    continue
                } else {
                    if !isTurnOver {
                        resolvedState = .busy // A tool response
                    }
                }
            }
        }
        
        return (resolvedState ?? .idle, waitingFor, lastUserInputDate, workspace, latestStepType)
    }

    /// Only a transcript written within the window counts. An older one is a
    /// finished turn, and showing it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        trajectory: URL,
        title: String? = nil,
        workspace: String? = nil,
        agentName: String? = nil,
        userInputDate: Date? = nil,
        modified: Date,
        staleAfter: TimeInterval,
        now: Date
    ) -> AgentSession? {
        let (state, waitingFor, parsedUserInputDate, parsedWorkspace, latestStepType) = tail(of: trajectory)
            .map(parseState(inTail:)) ?? (.idle, nil, nil, nil, nil)
        var resolvedState = state
        
        let age = now.timeIntervalSince(modified)
        
        if resolvedState == .idle {
            if age <= 9 {
                resolvedState = .success
            } else {
                return nil
            }
        } else if resolvedState == .busy {
            if latestStepType == "USER_INPUT" {
                // If a turn ended on USER_INPUT with no follow-up, it was cancelled
                // immediately by the user or dropped. Expire quickly.
                guard age <= min(staleAfter, 12) else { return nil }
            } else {
                guard age <= staleAfter else { return nil }
            }
        }
        // If state == .waiting, we do not expire it, it remains indefinitely.

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanAgent = agentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanWorkspace = (workspace ?? parsedWorkspace)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let sessionName: String
        if !cleanTitle.isEmpty {
            sessionName = cleanTitle
        } else if !cleanAgent.isEmpty {
            sessionName = cleanAgent
        } else if !cleanWorkspace.isEmpty {
            sessionName = cleanWorkspace
        } else {
            sessionName = "Antigravity"
        }

        let detail: String
        if !cleanWorkspace.isEmpty {
            if !cleanAgent.isEmpty && sessionName != cleanAgent {
                detail = "\(cleanWorkspace) · \(cleanAgent)"
            } else {
                detail = cleanWorkspace
            }
        } else if !cleanAgent.isEmpty && sessionName != cleanAgent {
            detail = cleanAgent
        } else {
            switch resolvedState {
            case .busy: detail = L10n.t("Working")
            case .waiting: detail = waitingFor ?? L10n.t("Waiting")
            case .success: detail = L10n.t("Complete")
            case .idle: detail = L10n.t("Idle")
            }
        }

        let resolvedUserInputDate = userInputDate ?? parsedUserInputDate
        let sinceDate: Date
        if resolvedState == .busy, let resolvedUserInputDate {
            sinceDate = resolvedUserInputDate
        } else {
            sinceDate = modified
        }

        // The trajectory's own directory names it; the file is always
        // `transcript.jsonl`.
        let id = trajectory.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().lastPathComponent

        return AgentSession(
            id: "antigravity.\(id)",
            name: sessionName,
            detail: detail,
            state: resolvedState,
            waitingFor: waitingFor,
            since: sinceDate,
            processID: antigravityPID()
        )
    }
}
