@testable import Clio
import XCTest

final class Batch5CoreStabilityTests: XCTestCase {
    func testBrandIconBlocksPrivateLANLoopbackAndRawIPHosts() {
        let blocked = [
            "",
            "localhost",
            "api.localhost",
            "127.0.0.1",
            "192.168.1.50",
            "10.0.0.2",
            "172.16.0.9",
            "100.64.0.12",
            "169.254.169.254",
            "ollama.local",
            "nas.lan",
            "llm.internal",
            "box.home.arpa",
            "macbook.tail1234.ts.net",
            "intranet",
            "http://example.com/icon.png",
            "https://192.168.1.1/icon.png",
            "https://nas.local/icon.png",
        ]
        for host in blocked {
            XCTAssertFalse(BrandIcons.isPublicIconDomain(host), "Expected private/invalid host '\(host)' to be blocked from public favicon services")
        }

        let allowed = [
            "deepseek.com",
            "openai.com",
            "api.anthropic.com",
            "https://www.gstatic.com/images/branding/product/2x/googleg_96dp.png",
        ]
        for host in allowed {
            XCTAssertTrue(BrandIcons.isPublicIconDomain(host), "Expected public host '\(host)' to be allowed")
        }
    }
}
