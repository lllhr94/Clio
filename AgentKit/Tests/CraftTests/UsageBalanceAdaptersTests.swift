import Craft
import XCTest

final class UsageBalanceAdaptersTests: XCTestCase {
    func testNewProviderRoutes() {
        let routes = [
            "https://open.bigmodel.cn/api/coding/paas/v4": "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
            "https://api.z.ai/api/coding/paas/v4": "https://api.z.ai/api/monitor/usage/quota/limit",
            "https://api.stepfun.com/v1": "https://api.stepfun.com/v1/accounts",
            "https://api.minimaxi.com/v1": "https://api.minimaxi.com/v1/token_plan/remains",
            "https://api.minimax.io/v1": "https://api.minimax.io/v1/token_plan/remains",
            "https://opencode.ai/inference/go/openai/v1": "https://opencode.ai/inference/go/v1/usage",
        ]
        for (base, expected) in routes {
            XCTAssertEqual(Balance.source(baseURL: base)?.url.absoluteString, expected, base)
        }
        for base in ["https://api-inference.modelscope.cn/v1", "https://aihubmix.com/v1", "https://api.aihubmix.com/v1"] {
            XCTAssertNil(Balance.source(baseURL: base), base)
            XCTAssertEqual(Balance.dashboard(baseURL: base)?.scheme, "https", base)
        }
        XCTAssertEqual(Balance.source(baseURL: "https://api.z.ai")?.authorizationValue(for: "fixture"), "fixture")
        XCTAssertEqual(Balance.source(baseURL: "https://api.stepfun.com")?.authorizationValue(for: "fixture"), "Bearer fixture")
        XCTAssertNil(Balance.source(baseURL: "https://opencode.ai/zen/v1"))
    }

    func testNewProviderReadings() {
        assertReading("https://open.bigmodel.cn/api/coding/paas/v4", #"{"balance":"12.5"}"#, 12.5, "¥")
        assertReading("https://api.z.ai/api/coding/paas/v4", #"{"data":{"available_balance":8}}"#, 8, "$")
        assertReading("https://api.z.ai/api/coding/paas/v4", #"{"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":12}]}}"#, 88, "%")
        assertReading("https://api.stepfun.com/v1", #"{"data":{"balance":"3.75"}}"#, 3.75, "¥")
        assertReading("https://api.stepfun.com/v1", #"{"available_balance":0}"#, 0, "¥")
        assertReading("https://api.minimaxi.com/v1", #"{"remain_money":"29"}"#, 29, "¥")
        assertReading("https://api.minimax.io/v1", #"{"data":{"balance":29}}"#, 29, "$")
        assertReading(
            "https://api.minimax.io/v1",
            #"{"model_remains":[{"current_interval_total_count":100,"current_interval_usage_count":68},{"remaining_percent":25}]}"#,
            25, "%"
        )
        let go = "https://opencode.ai/inference/go/openai/v1"
        assertReading(go, #"{"credits":"12.2"}"#, 12.2, "$")
        assertReading(go, #"{"usage":{"rolling":{"percent":30},"weekly":{"percent":60},"monthly":{"percent":20}}}"#, 40, "%")
        XCTAssertEqual(Balance.parse(#"{"usage":{"rolling":{"percent":30}}}"#, baseURL: go)?.shown, "70.00%")
        assertReading("https://api-inference.modelscope.cn/v1", #"{"data":{"remaining_quota":"800"}}"#, 800, "")
        assertReading("https://api-inference.modelscope.cn/v1", #"{"data":{"balance":42}}"#, 42, "")
        assertReading("https://aihubmix.com/v1", #"{"data":{"total_available":31}}"#, 31, "$")
        assertReading("https://api.aihubmix.com/v1", #"{"hard_limit_usd":50,"total_usage":20}"#, 30, "$")
        assertReading("https://api.aihubmix.com/v1", #"{"remain_quota":19}"#, 19, "")
    }

    func testExistingProviderRoutesAndReadings() {
        let providers: [(String, String, String, Double, String)] = [
            ("https://api.deepseek.com/v1", "/user/balance",
             #"{"balance_infos":[{"currency":"CNY","total_balance":"9.24","topped_up_balance":"9.24"}]}"#, 9.24, "¥"),
            ("https://openrouter.ai/api/v1", "/api/v1/credits",
             #"{"data":{"total_credits":20,"total_usage":4.25}}"#, 15.75, "$"),
            ("https://api.moonshot.cn/v1", "/v1/users/me/balance",
             #"{"data":{"available_balance":9.5,"cash_balance":3,"voucher_balance":6.5}}"#, 9.5, "¥"),
            ("https://api.moonshot.ai/v1", "/v1/users/me/balance", #"{"data":{"available_balance":9.5}}"#, 9.5, "$"),
            ("https://api.siliconflow.cn/v1", "/v1/user/info",
             #"{"data":{"totalBalance":"4","chargeBalance":"4","balance":"0"}}"#, 4, "¥"),
            ("https://api.siliconflow.com/v1", "/v1/user/info", #"{"data":{"totalBalance":4}}"#, 4, "$"),
        ]
        for (base, route, body, amount, symbol) in providers {
            XCTAssertEqual(Balance.source(baseURL: base)?.url.path, route, base)
            assertReading(base, body, amount, symbol)
        }
    }

    func testRejectsRelaysAndUnsafeOrigins() {
        let badBases = [
            "https://api.relay.example/v1", "https://api.stepfun.com.relay.example/v1",
            "https://relay.example/api.stepfun.com/v1", "https://api.stepfun.com@relay.example/v1",
            "https://somebody@api.stepfun.com/v1", "http://api.stepfun.com/v1",
            "https://api.stepfun.com:444/v1", "https://api.stepfun.com/v1?relay=1",
            "https://api.deepseek.com.evil.example/v1", "http://api.deepseek.com/v1",
        ]
        for base in badBases {
            XCTAssertNil(Balance.source(baseURL: base), base)
            XCTAssertNil(Balance.dashboard(baseURL: base), base)
            XCTAssertNil(Balance.parse(#"{"balance":100,"balance_infos":[{"total_balance":100}]}"#, baseURL: base), base)
        }
        XCTAssertNil(Balance.parse(#"{"balance":"Infinity"}"#, baseURL: "https://api.stepfun.com/v1"))
        XCTAssertNil(Balance.parse(#"{"base_resp":{"status_code":1004},"remain_money":99}"#, baseURL: "https://api.minimax.io/v1"))
        XCTAssertNil(Balance.parse(#"{"hard_limit_usd":50}"#, baseURL: "https://aihubmix.com/v1"))
    }

    private func assertReading(_ base: String, _ json: String, _ amount: Double, _ symbol: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let result = Balance.parse(json, baseURL: base)
        XCTAssertEqual(result?.symbol, symbol, base, file: file, line: line)
        XCTAssertEqual(result?.amount ?? .nan, amount, accuracy: 0.001, base, file: file, line: line)
    }
}
