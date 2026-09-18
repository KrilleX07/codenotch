import Foundation

/// Reads the QianwenAI Token Plan (个人版) numbers out of the platform
/// console's own gateway response.
///
/// The platform publishes model-call APIs but no usage API: the Token Plan is
/// only readable through the console's own RPC gateway, one POST per read to
/// `cs-data.qianwenai.com/data/api.json`, with the session riding in cookies.
/// So this parser only ever sees the body the site script already mapped onto a
/// status — a signed-out console answers HTTP 200 with
/// `{"code":"ConsoleNeedLogin"}`, the site script turns *that* into 401, and
/// `WebSessionProvider` turns *that* into `needsAuth` before parsing. Every
/// other failure keeps its status and reaches this parser, which rejects it as
/// `badResponse` so the store keeps the last reading instead of blanking it.
///
/// The numbers sit one unwrap down, in the object the console's own
/// individual-plan card reads:
///
/// ```json
/// { "code": "200", "successResponse": true,
///   "data": { "success": true,
///             "DataV2": { "data": { "per1WeekPercentage": 0.42,
///                                   "per1WeekResetTime": 1758124800000 } } } }
/// ```
enum QianwenUsage {
    /// The personal plan's 7-day credit window: a fixed window that starts at
    /// the first call of the cycle, allowance by tier (Lite 2 500, Standard
    /// 10 000, Pro 40 000 credits), and unused credits do not roll over.
    static func windows(fromJSON json: String, now: Date = Date()) throws -> [LimitWindow] {
        let payload = try payload(fromJSON: json)

        // The console renders remaining as `(1 - per1WeekPercentage)`, clamped,
        // because the platform stops the work at the limit rather than
        // reporting past it. Same reading, same clamp.
        var usedFraction = number(payload["per1WeekPercentage"]).map { min(max($0, 0), 1) }
        var remaining: Int?
        var used: Int?

        // Credits are the fallback reading, not a derivation: a payload that
        // carries counts instead of a fraction still states the allowance, and
        // one that carries neither has nothing to divide by.
        if let total = int(payload["totalCredits"]) ?? int(payload["totalQuota"]),
           let left = int(payload["remainingCredits"]) ?? int(payload["availableQuota"]),
           total > 0, left >= 0 {
            let spent = max(0, total - left)
            remaining = left
            used = spent
            if usedFraction == nil {
                usedFraction = min(max(Double(spent) / Double(total), 0), 1)
            }
        }

        guard let usedFraction else {
            throw UsageProviderError.nothingMetered(L10n.t("QianwenAI reported no Token Plan usage"))
        }

        return [LimitWindow(
            id: "week",
            label: L10n.t("Weekly limit"),
            usedFraction: usedFraction,
            remaining: remaining,
            used: used,
            resetsAt: reset(payload["per1WeekResetTime"], now: now),
            duration: 7 * 86_400
        )]
    }

    /// The console's own extractor: `data.DataV2.data`, then one level further
    /// when the object it reached carries a `data` of its own.
    static func payload(fromJSON json: String) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              // A business failure, not a transport one: `code` is how this
              // dialect reports a dead session under HTTP 200.
              int(root["code"]) == 200,
              let data = root["data"] as? [String: Any],
              let dataV2 = data["DataV2"] as? [String: Any],
              let payload = dataV2["data"] as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        // Both flags are read: the console sets `successResponse` on the
        // wrapper and `success` on the data, and a failure that flipped only
        // one of them would otherwise look like a happy empty answer.
        guard root["successResponse"] as? Bool != false, data["success"] as? Bool != false
        else { throw UsageProviderError.badResponse(status: 0) }

        return (payload["data"] as? [String: Any]) ?? payload
    }

    /// `per1WeekResetTime` is whatever dayjs accepts: an epoch (milliseconds
    /// past 1e12, seconds past 1e9), or the ISO-8601 string the console sends.
    /// A reset in the past is stale data, not a countdown — it is dropped
    /// rather than drawn as a moment that has already happened.
    private static func reset(_ value: Any?, now: Date) -> Date? {
        guard let date = date(from: value), date > now else { return nil }
        return date
    }

    private static func date(from value: Any?) -> Date? {
        if let raw = number(value), raw > 1_000_000_000 {
            return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
        }
        guard let text = value as? String else { return nil }
        // Two formatters, because one with fractional-second support refuses a
        // string without them and vice versa.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Credits reach the console's own model as decimal strings ("10000.00"),
    /// so both spellings have to count.
    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(trimmed) { return value }
        if let value = Double(trimmed) { return Int(value) }
        return nil
    }
}
