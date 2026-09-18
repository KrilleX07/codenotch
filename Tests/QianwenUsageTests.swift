import XCTest
import SwiftUI
@testable import Codenotch

/// Guards the QianwenAI Token Plan answer and the site that fetches it.
///
/// **Provisional fixtures — these must be replaced by a real recording.** No
/// authenticated response has ever been captured from this platform: every key
/// below is read out of the console's own shipped JavaScript, and every number
/// is made up. The console publishes no usage API, no schema and no
/// documentation, so
/// after the first live sign-in these bodies have to be swapped for what the
/// platform actually sends — the app logs that response verbatim on the first
/// refresh (`Log.usage`, "usage -> …"), which is where the recording comes
/// from. Until then these tests pin the shape the code was written against,
/// not the platform's real one.
@MainActor
final class QianwenUsageTests: XCTestCase {
    /// The tests run inside the app, so this is the installed app's own
    /// preference — saved and put back rather than left clobbered.
    private let signedInKey = "qianwenai.signedIn"
    private var savedSignedIn: Any?

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        savedSignedIn = UserDefaults.standard.object(forKey: signedInKey)
        UserDefaults.standard.removeObject(forKey: signedInKey)
    }

    override func tearDown() {
        if let savedSignedIn {
            UserDefaults.standard.set(savedSignedIn, forKey: signedInKey)
        } else {
            UserDefaults.standard.removeObject(forKey: signedInKey)
        }
        super.tearDown()
    }

    /// A success envelope in the dialect the console's own extractor reads:
    /// `data.DataV2.data`, with `code` and `successResponse` on the wrapper.
    private func envelope(payload: String) -> String {
        """
        { "code": "200", "successResponse": true,
          "data": { "success": true, "DataV2": { "data": \(payload) } } }
        """
    }

    func testEnvelopeUnwrapsDataV2AndOneNestedData() throws {
        let flat = try QianwenUsage.payload(fromJSON: envelope(
            payload: #"{"per1WeekPercentage":0.25}"#
        ))
        XCTAssertEqual(flat["per1WeekPercentage"] as? Double, 0.25)

        // The console's extractor goes one level further when the object it
        // reached carries a `data` of its own.
        let nested = try QianwenUsage.payload(fromJSON: envelope(
            payload: #"{"data":{"per1WeekPercentage":0.25}}"#
        ))
        XCTAssertEqual(nested["per1WeekPercentage"] as? Double, 0.25)
        XCTAssertNil(nested["data"])
    }

    /// `per1WeekPercentage` is the fraction of the 7-day allowance already
    /// spent — the console draws remaining as `1 - it` — and both ends are
    /// clamped, because the platform stops the work at the limit instead of
    /// reporting past it.
    func testPercentageIsTheSpentFractionAndIsClamped() throws {
        let window = try XCTUnwrap(try QianwenUsage.windows(
            fromJSON: envelope(payload: #"{"per1WeekPercentage":0.42}"#), now: now
        ).first)

        XCTAssertEqual(window.id, "week")
        XCTAssertEqual(window.label, "Weekly limit")
        XCTAssertEqual(window.duration, 7 * 86_400)
        XCTAssertEqual(window.usedFraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertNil(window.resetsAt, "this payload names no reset")
        XCTAssertNil(window.remaining, "no credits in the payload, so no count to invent")
        XCTAssertNil(window.used)

        for (percentage, expected) in [(1.4, 1.0), (-0.3, 0.0)] {
            let clamped = try QianwenUsage.windows(
                fromJSON: envelope(payload: #"{"per1WeekPercentage":\#(percentage)}"#), now: now
            )
            XCTAssertEqual(clamped.first?.usedFraction ?? -1, expected, accuracy: 0.0001)
        }
    }

    func testResetTimeReadsEpochMillisecondsAndSeconds() throws {
        let expected = Date(timeIntervalSince1970: 1_700_179_200)
        for value in ["1700179200000", "1700179200"] {
            let windows = try QianwenUsage.windows(
                fromJSON: envelope(
                    payload: #"{"per1WeekPercentage":0.5,"per1WeekResetTime":\#(value)}"#
                ),
                now: now
            )
            XCTAssertEqual(try XCTUnwrap(windows.first).resetsAt, expected, value)
        }
    }

    func testResetTimeReadsISO8601WithAndWithoutFractionalSeconds() throws {
        let formatter = ISO8601DateFormatter()
        let expected = try XCTUnwrap(formatter.date(from: "2023-11-17T00:00:00Z"))
        for value in ["2023-11-17T00:00:00Z", "2023-11-17T00:00:00.000Z"] {
            let windows = try QianwenUsage.windows(
                fromJSON: envelope(
                    payload: #"{"per1WeekPercentage":0.5,"per1WeekResetTime":"\#(value)"}"#
                ),
                now: now
            )
            XCTAssertEqual(try XCTUnwrap(windows.first).resetsAt, expected, value)
        }
    }

    /// A reset behind `now` is stale data, not a countdown, and a countdown to
    /// a moment that has passed is worse than no countdown at all.
    func testAPastResetIsLeftAsNoCountdown() throws {
        for payload in [
            #"{"per1WeekPercentage":0.5,"per1WeekResetTime":"2023-11-01T00:00:00Z"}"#,
            #"{"per1WeekPercentage":0.5,"per1WeekResetTime":1698796800000}"#,
            #"{"per1WeekPercentage":0.5,"per1WeekResetTime":1698796800}"#
        ] {
            let windows = try QianwenUsage.windows(fromJSON: envelope(payload: payload), now: now)
            XCTAssertNil(try XCTUnwrap(windows.first).resetsAt, payload)
        }
    }

    /// Credits are the fallback: they reach the console's model as decimal
    /// strings, and a payload that carries them without a fraction still states
    /// the allowance.
    func testCreditsFallBackToCountArithmetic() throws {
        let window = try XCTUnwrap(try QianwenUsage.windows(
            fromJSON: envelope(
                payload: #"{"totalCredits":"10000.00","remainingCredits":"4000.00"}"#
            ),
            now: now
        ).first)

        XCTAssertEqual(window.usedFraction ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(window.used, 6_000)
        XCTAssertEqual(window.remaining, 4_000)

        // The quota spelling, and a plan that has spent nothing yet.
        let quota = try XCTUnwrap(try QianwenUsage.windows(
            fromJSON: envelope(payload: #"{"totalQuota":2500,"availableQuota":2500}"#),
            now: now
        ).first)
        XCTAssertEqual(quota.usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(quota.remaining, 2_500)
        XCTAssertEqual(quota.used, 0)

        // Both present: the console's own fraction wins, the counts still show.
        let both = try XCTUnwrap(try QianwenUsage.windows(
            fromJSON: envelope(
                payload: #"{"per1WeekPercentage":0.75,"totalCredits":2500,"remainingCredits":625}"#
            ),
            now: now
        ).first)
        XCTAssertEqual(both.usedFraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(both.remaining, 625)
        XCTAssertEqual(both.used, 1_875)
    }

    func testAPayloadWithoutAnAllowanceIsNothingMetered() {
        for payload in [
            "{}",
            #"{"plan":"lite"}"#,
            #"{"totalCredits":0,"remainingCredits":0}"#,
            #"{"totalCredits":"0.00","remainingCredits":"0.00"}"#
        ] {
            XCTAssertThrowsError(try QianwenUsage.windows(fromJSON: envelope(payload: payload))) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("expected nothingMetered for \(payload), got \(error)")
                }
            }
        }
    }

    /// The signed-out body is HTTP 200 on this platform, so the envelope — not
    /// the transport — is what fails. All of these are business failures.
    func testBusinessFailuresAndGarbageAreBadResponses() {
        for json in [
            #"{"code":"ConsoleNeedLogin","message":"请登录","successResponse":false}"#,
            #"{"code":"500","successResponse":true,"data":{"success":true,"DataV2":{"data":{"per1WeekPercentage":0.5}}}}"#,
            #"{"code":"200","successResponse":false,"data":{"success":true,"DataV2":{"data":{"per1WeekPercentage":0.5}}}}"#,
            #"{"code":"200","successResponse":true,"data":{"success":false,"DataV2":{"data":{"per1WeekPercentage":0.5}}}}"#,
            #"{"code":"200","successResponse":true,"data":{"success":true}}"#,
            #"{"code":"200","successResponse":true}"#,
            "not json",
            "[]"
        ] {
            XCTAssertThrowsError(try QianwenUsage.windows(fromJSON: json)) { error in
                guard case UsageProviderError.badResponse(let status) = error, status == 0 else {
                    return XCTFail("expected badResponse(0), got \(error)")
                }
            }
        }
    }

    func testTheSiteIsTheConsoleTheUserSignsInto() throws {
        let site = Sites.qianwen
        XCTAssertEqual(site.id, "qianwenai")
        XCTAssertEqual(site.displayName, "QianwenAI")
        // The platform's own mark, not the Lobe Icons model brand: a local
        // Qwen model cell and this ring have to be tellable apart.
        XCTAssertEqual(site.glyph, .qianwenAI)
        XCTAssertNotEqual(site.glyph, .qwen)
        XCTAssertEqual(site.origin, try XCTUnwrap(URL(string: "https://platform.qianwenai.com/")))
        // A console session we hold, not a published API — the same reading
        // MiniMax's cookie path gets.
        XCTAssertEqual(site.fidelity, .derived)
        XCTAssertEqual(site.associatedHosts,
                       ["platform-home.qianwenai.com", "cs-data.qianwenai.com",
                        "account.qianwenai.com", "account.aliyun.com"])
        XCTAssertEqual(WebSessionProvider.websiteDataHosts(for: site),
                       ["platform.qianwenai.com", "platform-home.qianwenai.com",
                        "cs-data.qianwenai.com", "account.qianwenai.com", "account.aliyun.com"])
    }

    func testTheScriptPostsTheTokenPlanCallToTheGateway() {
        let script = Sites.qianwen.script
        XCTAssertTrue(script.contains("https://cs-data.qianwenai.com/data/api.json"))
        XCTAssertTrue(script.contains("zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"),
                      "the Api inside params is what routes the call")
        XCTAssertTrue(script.contains("credentials: 'include'"))
        XCTAssertTrue(script.contains("'sfm_bailian'"))
        XCTAssertTrue(script.contains("'BroadScopeAspnGateway'"))
        XCTAssertTrue(script.contains("'cn-beijing'"))
        // Only the console's own not-signed-in answer may become 401. 401 turns
        // into `needsAuth`, which discards the remembered reading, so mapping a
        // server fault to it would blank the ring and tell a signed-in user to
        // sign in. Everything else has to reach the parser, which renders an
        // error the store keeps the last reading through.
        XCTAssertTrue(script.contains("String(envelope.code) === 'ConsoleNeedLogin'"),
                      "the not-signed-in marker is what becomes 401")
        XCTAssertTrue(script.contains("status = 401"))
        XCTAssertFalse(script.contains("successResponse === false ||"),
                       "a plain business failure must keep its status, not become 401")
        XCTAssertFalse(script.contains("String(envelope.code) !== '200'"),
                       "a non-200 code is not the same thing as a dead session")
        // The console caches its own token on `window`; a stale one would look
        // like an expired session on every call.
        XCTAssertFalse(script.contains("__QWEN_CONSOLE_SHARED_SEC_TOKEN__"))
    }

    func testTheProbeReadsTheSessionHostAndFingerprintsTheToken() throws {
        let probe = try XCTUnwrap(Sites.qianwen.authProbeScript)
        XCTAssertTrue(probe.contains("https://platform-home.qianwenai.com/tool/user/info.json"))
        XCTAssertTrue(probe.contains("credentials: 'include'"))
        XCTAssertTrue(probe.contains("crypto.subtle.digest('SHA-256'"))
        XCTAssertTrue(probe.contains("fingerprint"),
                      "a switch needs a session identity, not just a boolean")
        XCTAssertTrue(probe.contains("authenticated: false"))
    }

    func testASiteWithAProbeWaitsForItToConfirm() {
        WebSessionProvider(site: Sites.qianwen).signInSheetDidOpen()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: signedInKey),
                       "opening the sheet is not a sign-in for a site that can confirm one")
    }

    func testTheSiteParseIsWiredToTheTokenPlanParser() throws {
        let json = envelope(payload: #"{"per1WeekPercentage":0.3}"#)
        XCTAssertEqual(try Sites.qianwen.parse(json).map(\.id), ["week"])
    }

    /// The asset draws the mark, not the plate it came on.
    ///
    /// This mark's ink covers about 0.40 of the box; the plate version — the
    /// blue rounded square the favicon puts behind it — covers about 0.70. Both
    /// are under the 0.85 ceiling the older glyph tests use, so that ceiling
    /// would not have caught the plate coming back; these bounds are what
    /// separate the two.
    func testTheGlyphAssetRendersAsAMarkNotASquare() throws {
        XCTAssertEqual(ProviderGlyph.qianwenAI.assetName, "glyph-qianwenai")
        let asset = try XCTUnwrap(NSImage(named: ProviderGlyph.qianwenAI.assetName))
        XCTAssertGreaterThan(asset.size.width, 0)
        XCTAssertGreaterThan(asset.size.height, 0)

        let renderer = ImageRenderer(
            content: ProviderGlyphView(glyph: .qianwenAI, size: 32).foregroundStyle(.white)
        )
        let data = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var ink = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                ink += 1
            }
        }
        let coverage = Double(ink) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        XCTAssertGreaterThan(coverage, 0.15, "a plate or an empty box, not a mark")
        XCTAssertLessThan(coverage, 0.60, "the favicon's plate is back — the mark cannot show through it")
    }
}
