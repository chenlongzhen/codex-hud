import Foundation
import CSQLite

/// Read-only, unverified fallback. Persisted inProgress is never promoted to a runtime state.
public enum LocalTasks {
    public static func unfinished(home: URL) throws -> [HUDTask] {
        let history = try open(home.appendingPathComponent("thread_history_1.sqlite"))
        defer { sqlite3_close(history) }
        let state = try open(home.appendingPathComponent("state_5.sqlite"))
        defer { sqlite3_close(state) }
        var titles: [String: String] = [:]
        try rows(state, "SELECT id, COALESCE(name,title) FROM threads WHERE archived=0 AND agent_nickname IS NULL") { statement in
            titles[string(statement, 0)] = string(statement, 1)
        }
        var tasks: [HUDTask] = []
        try rows(history, """
        SELECT t.thread_id,t.started_at FROM thread_turns t
        WHERE t.status='inProgress' AND t.completed_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM thread_turns n WHERE n.thread_id=t.thread_id AND n.rollout_ordinal>t.rollout_ordinal)
        ORDER BY t.started_at DESC
        """
        ) { statement in
            let id = string(statement, 0)
            guard let title = titles[id] else { return }
            tasks.append(HUDTask(id: id, title: title, status: ThreadStatus(type: "unverified"),
                                 updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)))))
        }
        return tasks
    }
    private static func open(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw HUDError.message("本地任务记录不可读")
        }
        sqlite3_busy_timeout(database, 500)
        return database
    }
    private static func rows(_ database: OpaquePointer, _ sql: String, body: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw HUDError.message("本地任务记录版本不支持") }
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { body(statement); status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw HUDError.message("本地任务记录读取失败") }
    }
    private static func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
}
