import Foundation
import XCTest
@testable import AgentKit

final class WebSearchTests: XCTestCase {
    // MARK: - Ad & Tracking Redirect Stripping

    func testBingStripsSponsoredAdContainersAndTrackingRedirects() {
        let html = """
        <ol id="b_results">
          <li class="b_ad">
            <ul><li><span class="b_adSlug">广告</span></li></ul>
            <h2><a href="https://promo.example/ad1">顶部广告</a></h2>
            <p>推广内容</p>
          </li>
          <li class="b_adTop">
            <h2><a href="https://promo.example/ad2">顶部推广</a></h2>
            <p>赞助链接</p>
          </li>
          <li class="b_algo b_ad">
            <h2><a href="https://promo.example/ad3">伪装成自然结果的广告</a></h2>
            <p>推广</p>
          </li>
          <li class="b_algo">
            <h2><a href="https://www.bing.com/aclick?ld=xyz123">Bing Aclick 广告</a></h2>
            <p>点击跳转</p>
          </li>
          <li class="b_algo">
            <h2><a href="https://www.bing.com/ck/a?!&amp;u=a1aHR0cHM6Ly93d3cuYmluZy5jb20vYWNsaWNrP2lkPTE&amp;ntb=1">Base64 包装的广告</a></h2>
            <p>二次跳转广告</p>
          </li>
          <li class="b_algo">
            <h2><a href="https://www.bing.com/ck/a?!&amp;p=missing_u">无法解包的追踪链接</a></h2>
            <p>追踪垃圾</p>
          </li>
          <li class="b_algo">
            <h2><a href="https://www.googleadservices.com/pagead/aclk?sa=L">广告联盟链接</a></h2>
            <p>联盟跳转</p>
          </li>
          <li class="b_algo">
            <span class="b_adSlug">广告</span>
            <h2><a href="https://promo.example/inline">内联广告徽章</a></h2>
            <p>包含广告徽章</p>
          </li>
          <li class="b_algo b_vtl_deeplinks">
            <h2><span class="t"><a data-h="1" href="https://www.bing.com/ck/a?!&amp;u=a1aHR0cHM6Ly9kb2NzLnN3aWZ0Lm9yZy9zd2lmdC1ib29rLw&amp;ntb=1">Swift 官方文档</a></span></h2>
            <div class="b_caption"><p>Swift 编程语言官方指南</p></div>
          </li>
        </ol>
        """

        let results = WebText.bingResults(html)
        XCTAssertEqual(results, [
            WebText.Result(
                title: "Swift 官方文档",
                url: "https://docs.swift.org/swift-book/",
                snippet: "Swift 编程语言官方指南"
            ),
        ])
    }

    func testDuckDuckGoStripsSponsoredAdContainersAndTrackingURLs() {
        let html = """
        <div id="links" class="results">
          <div class="result results_links results_links_deep result--ad">
            <div class="links_main links_deep result__body">
              <a class="result__a" href="https://duckduckgo.com/y.js?ad_domain=spam.example">DuckDuckGo 广告</a>
              <a class="result__snippet">赞助商推广</a>
            </div>
          </div>
          <div class="result results_links web-result">
            <div class="links_main links_deep result__body">
              <a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fblog%2F&amp;rut=1" class="result__a">Swift 博客</a>
              <div class="result__snippet">官方发布说明</div>
            </div>
          </div>
          <div class="result results_links results_links_deep result--ad">
            <div class="links_main links_deep result__body">
              <a class="result__a" href="//duckduckgo.com/l/?rut=broken">未解包 DuckDuckGo 跳转</a>
              <a class="result__snippet">垃圾结果</a>
            </div>
          </div>
        </div>
        """

        let results = WebText.duckResults(html)
        XCTAssertEqual(results, [
            WebText.Result(
                title: "Swift 博客",
                url: "https://swift.org/blog/",
                snippet: "官方发布说明"
            ),
        ])
    }

    // MARK: - CJK Relevance Scoring & Off-Topic Spam Filtering

    func testCJKRelevanceTokenizesNoSpaceQueriesAndParaphrases() {
        let museumRelevance = SearchRelevance(query: "苏州博物馆开放时间")
        XCTAssertTrue(museumRelevance.matches(
            WebText.Result(title: "苏州博物馆官方网站", url: "https://www.szmuseum.com", snippet: "每日 9:00-17:00 开馆，周一闭馆")
        ))
        XCTAssertTrue(museumRelevance.matches(
            WebText.Result(title: "苏州市博物馆本馆参观指南", url: "https://travel.example.org/sz", snippet: "预约与入馆说明")
        ))
        XCTAssertTrue(museumRelevance.matches(
            WebText.Result(title: "苏州博物院预约须知", url: "https://guide.example.org/s", snippet: "提前七天预约")
        ))
        XCTAssertFalse(museumRelevance.matches(
            WebText.Result(title: "成都博物馆开放时间", url: "https://cd.example.org", snippet: "周二至周日开馆")
        ))
        XCTAssertFalse(museumRelevance.matches(
            WebText.Result(title: "陌陌同城交友软件下载", url: "https://spam.example.org", snippet: "附近约会神器")
        ))
        XCTAssertFalse(museumRelevance.matches(
            WebText.Result(title: "樱花动漫全集免费在线观看完整版", url: "https://anime.example.org", snippet: "高清新番")
        ))
        XCTAssertFalse(museumRelevance.matches(
            WebText.Result(title: "苏州博物馆附近同城交友约会神器", url: "https://spam2.example.org", snippet: "陌陌官方下载")
        ))

        let screenshotRelevance = SearchRelevance(query: "苹果手机怎么截屏")
        XCTAssertTrue(screenshotRelevance.matches(
            WebText.Result(title: "iPhone 苹果手机截图方法大全", url: "https://support.apple.com", snippet: "同时按侧边按钮和调高音量键")
        ))
        XCTAssertFalse(screenshotRelevance.matches(
            WebText.Result(title: "安卓手机推荐排行榜", url: "https://other.example.org", snippet: "2026 年性价比机型")
        ))

        let mixedRelevance = SearchRelevance(query: "Swift6并发编程")
        XCTAssertTrue(mixedRelevance.matches(
            WebText.Result(title: "Swift 6 并发新特性详解", url: "https://docs.swift.org/concurrency", snippet: "Sendable 与 Actor 隔离")
        ))

        let domainRelevance = SearchRelevance(query: "Swift 官网")
        XCTAssertTrue(domainRelevance.matches(
            WebText.Result(title: "Documentation", url: "https://www.swift.org/documentation/", snippet: "Language guide")
        ))

        let weatherRelevance = SearchRelevance(query: "重庆今日天气")
        XCTAssertTrue(weatherRelevance.matches(
            WebText.Result(title: "重庆今日气温 18℃，多云转晴", url: "https://weather.example.cn/cq", snippet: "空气质量优")
        ))
        XCTAssertFalse(weatherRelevance.matches(
            WebText.Result(title: "上海今日气温", url: "https://weather.example.cn/sh", snippet: "小雨")
        ))
    }

    func testOffTopicSpamGuardAllowsExplicitUserQueries() {
        let animeQuery = SearchRelevance(query: "樱花动漫 官网")
        XCTAssertTrue(animeQuery.matches(
            WebText.Result(title: "樱花动漫官方网站", url: "https://example.org/yh", snippet: "动画目录更新")
        ))
    }

    func testCyrillicAndNonCJKUnicodeRelevance() {
        let russian = SearchRelevance(query: "погода Москва")
        XCTAssertTrue(russian.matches(
            WebText.Result(title: "Москва: погода на завтра", url: "https://meteo.example.org/msk", snippet: "Облачно, +12")
        ))
        XCTAssertTrue(russian.matches(
            WebText.Result(title: "Прогноз погоды в Москве", url: "https://weather.example.org", snippet: "Ветер умеренный")
        ))
        XCTAssertFalse(russian.matches(
            WebText.Result(title: "Новости Санкт-Петербурга", url: "https://news.example.org/spb", snippet: "Главные события дня")
        ))
        XCTAssertFalse(russian.matches(
            WebText.Result(title: "Погода в Сочи", url: "https://meteo.example.org/sochi", snippet: "Солнечно")
        ))

        let greek = SearchRelevance(query: "Αθήνα καιρός")
        XCTAssertTrue(greek.matches(
            WebText.Result(title: "Αθήνα - Καιρός", url: "https://meteo.example.gr", snippet: "Πρόγνωση εβδομάδας")
        ))
        XCTAssertFalse(greek.matches(
            WebText.Result(title: "Θεσσαλονίκη νέα", url: "https://news.example.gr", snippet: "Τοπικά νέα")
        ))
    }

    func testBalancedAdContainerStrippingIsLinearOnDeepUnclosedTags() {
        let deepNested = String(repeating: "<div><span>ad</span>", count: 3_000)
        let duckHTML = """
        <div class="result web-result">
          <div class="links_main result__body">
            <a class="result__a" href="https://docs.example.org/ok">Valid Result</a>
            <a class="result__snippet">Legitimate summary</a>
          </div>
        </div>
        <div class="result results_links result--ad">
        """ + deepNested

        let duckParsed = WebText.duckResults(duckHTML)
        XCTAssertEqual(duckParsed, [
            WebText.Result(title: "Valid Result", url: "https://docs.example.org/ok", snippet: "Legitimate summary"),
        ])

        let unclosedBing = "<li class=\"b_algo\"><h2><a href=\"https://swift.org\">Swift</a></h2><p>Docs</p></li>"
            + "<li class=\"b_ad\">" + String(repeating: "<li><span>ad</span>", count: 3_000)
        let bingParsed = WebText.bingResults(unclosedBing)
        XCTAssertEqual(bingParsed, [
            WebText.Result(title: "Swift", url: "https://swift.org", snippet: "Docs"),
        ])
    }

    func testBuiltinSearchSkipsAdsAndOffTopicSpamToPickRelevantResult() async throws {
        let tool = WebSearchTool { _ in
            """
            <ol id="b_results">
              <li class="b_ad"><h2><a href="https://ad.example/1">竞价广告</a></h2><p>杭州西湖</p></li>
              <li class="b_algo"><h2><a href="https://www.bing.com/aclick?ld=9">点击广告</a></h2><p>杭州西湖门票</p></li>
              <li class="b_algo"><h2><a href="https://junk.example/anime">樱花动漫在线观看完整版</a></h2><p>高清动漫</p></li>
              <li class="b_algo"><h2><a href="https://junk.example/dating">同城交友约会神器</a></h2><p>附近单身</p></li>
              <li class="b_algo"><h2><a href="https://westlake.example.cn/guide">杭州西湖景区参观指南</a></h2><p>西湖门票免费，部分景点需预约</p></li>
            </ol>
            """
        }

        let output = try await tool.run(.object(["query": .string("杭州西湖门票")]))
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.text.contains("杭州西湖景区参观指南"))
        XCTAssertFalse(output.text.contains("竞价广告"))
        XCTAssertFalse(output.text.contains("点击广告"))
        XCTAssertFalse(output.text.contains("樱花动漫"))
        XCTAssertFalse(output.text.contains("同城交友"))
    }

    // MARK: - SearXNG URL Normalization & Security Rules

    func testSearXNGEndpointAllowsPublicHTTPSAndPrivateLANHTTP() {
        let validCases: [(raw: String, normalized: String, isLAN: Bool)] = [
            ("https://search.example.com///", "https://search.example.com", false),
            ("HTTPS://Search.Example.COM/searx/", "https://search.example.com/searx", false),
            ("https://search.example.com:8443/search/", "https://search.example.com:8443/search", false),
            ("http://localhost:8080/", "http://localhost:8080", true),
            ("http://searx.localhost:8080", "http://searx.localhost:8080", true),
            ("http://127.0.0.1:8888/", "http://127.0.0.1:8888", true),
            ("http://[::1]:8888/", "http://[::1]:8888", true),
            ("http://10.0.0.25:8080/", "http://10.0.0.25:8080", true),
            ("http://192.168.1.50:8080/", "http://192.168.1.50:8080", true),
            ("http://172.16.0.5:8080", "http://172.16.0.5:8080", true),
            ("http://172.31.255.10:8080/", "http://172.31.255.10:8080", true),
            ("http://home-searx.local:8080/", "http://home-searx.local:8080", true),
            ("http://[fd00::1]/", "http://[fd00::1]", true),
            ("http://[FD12:3456::1]:8080/", "http://[fd12:3456::1]:8080", true),
        ]

        for item in validCases {
            switch SearXNGEndpoint.parse(item.raw) {
            case .success(let parsed):
                XCTAssertEqual(parsed.baseURL, item.normalized, item.raw)
                XCTAssertEqual(parsed.isLAN, item.isLAN, item.raw)
            case .failure(let err):
                XCTFail("Expected success for \(item.raw), got \(err)")
            }
        }
    }

    func testSearXNGIPv6BracketPreservationAndSearchURLs() throws {
        let loopbackParsed = try SearXNGEndpoint.parse("http://[::1]:8888/").get()
        XCTAssertEqual(loopbackParsed.baseURL, "http://[::1]:8888")
        XCTAssertEqual(loopbackParsed.searchBaseURL, "http://[::1]:8888/search")
        XCTAssertEqual(loopbackParsed.originKey, "http://[::1]:8888")
        XCTAssertTrue(loopbackParsed.isLAN)
        let loopbackSearch = try SearXNGEndpoint.buildSearchURL(baseURL: "http://[::1]:8888/", query: "Swift")
        XCTAssertEqual(loopbackSearch.absoluteString, "http://[::1]:8888/search?q=Swift&format=json")

        let ulaParsed = try SearXNGEndpoint.parse("http://[FD00::1]/").get()
        XCTAssertEqual(ulaParsed.baseURL, "http://[fd00::1]")
        XCTAssertEqual(ulaParsed.searchBaseURL, "http://[fd00::1]/search")
        XCTAssertEqual(ulaParsed.originKey, "http://[fd00::1]:80")
        XCTAssertTrue(ulaParsed.isLAN)
        let ulaSearch = try SearXNGEndpoint.buildSearchURL(baseURL: "http://[FD00::1]/", query: "Swift")
        XCTAssertEqual(ulaSearch.absoluteString, "http://[fd00::1]/search?q=Swift&format=json")
    }

    func testSearXNGEndpointRejectsPublicHTTPBadSchemesCredentialsAndQueries() {
        let invalidCases: [(raw: String, expected: SearXNGError)] = [
            ("", .empty),
            ("   \n ", .empty),
            ("http://search.example.com", .requiresHTTPS),
            ("http://8.8.8.8:8080", .requiresHTTPS),
            ("http://172.32.0.1:8080", .requiresHTTPS),
            ("http://[2606:4700::1111]:8080", .requiresHTTPS),
            ("ftp://search.example.com", .invalidFormat),
            ("file:///etc/passwd", .invalidFormat),
            ("javascript:alert(1)", .invalidFormat),
            ("search.example.com", .invalidFormat),
            ("https://", .invalidFormat),
            ("https://has space.example.com", .invalidFormat),
            ("http://0.0.0.0:8080", .invalidFormat),
            ("http://169.254.169.254", .invalidFormat),
            ("http://[::]:8080", .invalidFormat),
            ("https://user:pass@search.example.com", .embeddedCredentials),
            ("http://admin@192.168.1.50:8080", .embeddedCredentials),
            ("https://user%40x@search.example.com", .embeddedCredentials),
            ("https://search.example.com/search?q=1", .queryOrFragmentNotAllowed),
            ("https://search.example.com/#section", .queryOrFragmentNotAllowed),
        ]

        for item in invalidCases {
            switch SearXNGEndpoint.parse(item.raw) {
            case .success(let parsed):
                XCTFail("Expected failure \(item.expected) for \(item.raw), got \(parsed)")
            case .failure(let err):
                XCTAssertEqual(err, item.expected, item.raw)
            }
        }
    }

    // MARK: - SearXNG Request Building & JSON Parsing

    func testSearXNGBuildRequestAndParseJSON() throws {
        let request = try WebSearchAPI.buildRequest(
            provider: .searxng,
            query: "C++ 中文",
            apiKey: nil,
            searxngURL: "http://192.168.1.50:8080///"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://192.168.1.50:8080/search?q=C%2B%2B%20%E4%B8%AD%E6%96%87&format=json"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        let alreadySearchRequest = try WebSearchAPI.buildRequest(
            provider: .searxng,
            query: "Swift",
            apiKey: "sx-secret-token",
            searxngURL: "https://search.example.com/search/"
        )
        XCTAssertEqual(
            alreadySearchRequest.url?.absoluteString,
            "https://search.example.com/search?q=Swift&format=json"
        )
        XCTAssertEqual(alreadySearchRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sx-secret-token")

        let payload = """
        {
          "query": "C++ 中文",
          "results": [
            {"title": "<b>C++</b> 参考手册", "url": "https://zh.cppreference.com/w/", "content": "标准库 &amp; 语法说明"},
            {"title": "C++ 参考手册重复", "url": "https://zh.cppreference.com/w/", "content": "应去重"},
            {"title": "广告重定向", "url": "https://www.bing.com/aclick?ld=123", "content": "应过滤"},
            {"title": "危险协议", "url": "javascript:alert(1)", "content": "应过滤"},
            {"title": "备用摘要字段", "url": "https://example.org/cpp", "snippet": "使用 snippet 回退"}
          ]
        }
        """
        let parsed = try WebSearchAPI.parseResponse(provider: .searxng, status: 200, data: Data(payload.utf8))
        XCTAssertEqual(parsed, [
            WebText.Result(title: "C++ 参考手册", url: "https://zh.cppreference.com/w/", snippet: "标准库 & 语法说明"),
            WebText.Result(title: "备用摘要字段", url: "https://example.org/cpp", snippet: "使用 snippet 回退"),
        ])

        XCTAssertThrowsError(try WebSearchAPI.parseResponse(provider: .searxng, status: 403, data: Data())) { err in
            XCTAssertTrue(err.localizedDescription.contains("403"))
        }
    }

    // MARK: - SearXNG URLProtocol Transport & Redirect Policy

    func testSearXNGURLSessionTransportAndRedirectSecurity() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [SearXNGFixtureProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        let lanURL = try SearXNGEndpoint.buildSearchURL(baseURL: "http://192.168.1.50:8080/", query: "Swift")
        let lanResponse = try await WebFetch.searxngJSON(URLRequest(url: lanURL), session: session)
        XCTAssertEqual(lanResponse.status, 200)
        let lanResults = try WebSearchAPI.parseResponse(provider: .searxng, status: lanResponse.status, data: lanResponse.data)
        XCTAssertEqual(lanResults.first?.title, "LAN SearXNG Result")

        let publicURL = try SearXNGEndpoint.buildSearchURL(baseURL: "https://searx.example/", query: "Swift")
        let publicResponse = try await WebFetch.searxngJSON(URLRequest(url: publicURL), session: session)
        XCTAssertEqual(publicResponse.status, 200)
        let publicResults = try WebSearchAPI.parseResponse(provider: .searxng, status: publicResponse.status, data: publicResponse.data)
        XCTAssertEqual(publicResults.first?.title, "Public SearXNG Result")

        // Public plain-HTTP must still be refused by WebFetch.searxngJSON.
        let badPublicHTTP = URLRequest(url: URL(string: "http://searx.example/search?q=Swift&format=json")!)
        do {
            _ = try await WebFetch.searxngJSON(badPublicHTTP, session: session)
            XCTFail("Expected public HTTP SearXNG call to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("https://"))
        }

        // Standard WebFetch.json for non-SearXNG providers must still block LAN HTTP and LAN HTTPS.
        do {
            _ = try await WebFetch.json(URLRequest(url: lanURL), session: session)
            XCTFail("Expected WebFetch.json to refuse LAN HTTP")
        } catch {}
        do {
            _ = try await WebFetch.json(URLRequest(url: URL(string: "https://192.168.1.50:8443/search")!), session: session)
            XCTFail("Expected WebFetch.json to refuse LAN HTTPS")
        } catch {}

        // Redirect policy checks.
        let lanOrigin = URL(string: "http://192.168.1.50:8080/search?q=a")!
        XCTAssertTrue(WebFetch.allowsSameOriginSearXNGRedirect(from: lanOrigin, to: URL(string: "http://192.168.1.50:8080/search?q=a&p=1")!, allowLAN: true))
        XCTAssertFalse(WebFetch.allowsSameOriginSearXNGRedirect(from: lanOrigin, to: URL(string: "http://192.168.1.1/admin")!, allowLAN: true))
        XCTAssertFalse(WebFetch.allowsSameOriginSearXNGRedirect(from: lanOrigin, to: URL(string: "http://192.168.1.50:9090/search")!, allowLAN: true))
        XCTAssertFalse(WebFetch.allowsSameOriginSearXNGRedirect(from: URL(string: "https://192.168.1.50:8443/search")!, to: URL(string: "http://192.168.1.50:8443/search")!, allowLAN: true))
        XCTAssertFalse(WebFetch.allowsSameOriginSearXNGRedirect(from: URL(string: "https://searx.example/search")!, to: URL(string: "http://127.0.0.1/search")!, allowLAN: false))
    }

    // MARK: - Ordered Multi-Source Fallback

    func testSearchChainDeduplicatesAndRespectsFallbackToBuiltin() {
        let chain1 = WebSearchConfig(
            primary: .searxng,
            fallbackToBuiltin: true,
            fallbackOrder: [.searxng, .tavily, .tavily, .anysearch]
        ).searchChain
        XCTAssertEqual(chain1, [.searxng, .tavily, .anysearch, .builtin])

        let chain2 = WebSearchConfig(
            primary: .searxng,
            fallbackToBuiltin: false,
            fallbackOrder: [.tavily, .brave]
        ).searchChain
        XCTAssertEqual(chain2, [.searxng, .tavily, .brave])

        let chain3 = WebSearchConfig(
            primary: .searxng,
            fallbackToBuiltin: true,
            fallbackOrder: [.builtin, .anysearch]
        ).searchChain
        XCTAssertEqual(chain3, [.searxng, .builtin, .anysearch])
    }

    func testOrderedMultiSourceFallbackTriesProvidersInExactOrder() async throws {
        let log = CallLog()
        let config = WebSearchConfig(
            primary: .searxng,
            fallbackToBuiltin: true,
            apiKeys: [.tavily: "tvly-key-1", .anysearch: "as-key-2"],
            searxngURL: "http://192.168.1.50:8080",
            fallbackOrder: [.tavily, .anysearch]
        )
        let tool = WebSearchTool(
            config: config,
            sendJSON: { request in
                let host = request.url?.host ?? ""
                log.append(host)
                switch host {
                case "192.168.1.50":
                    return (503, Data())
                case "api.tavily.com":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tvly-key-1")
                    return (200, Data(#"{"results":[]}"#.utf8))
                case "api.anysearch.com":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer as-key-2")
                    return (200, Data(#"{"results":[{"title":"AnySearch Backup Hit","url":"https://backup.example.org","snippet":"Fallback worked"}]}"#.utf8))
                default:
                    XCTFail("Unexpected host \(host)")
                    return (500, Data())
                }
            },
            fetchHTML: { _ in
                XCTFail("Should not reach builtin when AnySearch succeeded")
                return ""
            }
        )

        let output = try await tool.run(.object(["query": .string("Swift")]))
        XCTAssertFalse(output.isError)
        XCTAssertEqual(log.snapshot(), ["192.168.1.50", "api.tavily.com", "api.anysearch.com"])
        XCTAssertTrue(output.text.contains("搜索来源：AnySearch"))
        XCTAssertTrue(output.text.contains("AnySearch Backup Hit"))
    }

    func testOrderedMultiSourceFallbackFallsBackToBuiltinWhenAllAPIsFail() async throws {
        let log = CallLog()
        let config = WebSearchConfig(
            primary: .searxng,
            fallbackToBuiltin: true,
            apiKeys: [:],
            searxngURL: nil,
            fallbackOrder: [.tavily]
        )
        let tool = WebSearchTool(
            config: config,
            sendJSON: { request in
                log.append("json:\(request.url?.absoluteString ?? "")")
                return (500, Data())
            },
            fetchHTML: { url in
                log.append("html:\(url.host ?? "")")
                return #"<li class="b_algo"><h2><a href="https://weather.example.org">重庆天气预报</a></h2><p>晴</p></li>"#
            }
        )

        let output = try await tool.run(.object(["query": .string("重庆 天气")]))
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.text.contains("搜索来源：Bing 国际站"))
        XCTAssertTrue(output.text.contains("重庆天气预报"))
        XCTAssertEqual(log.snapshot(), ["html:www.bing.com"])
    }

    func testOrderedMultiSourceFallbackReportsCombinedErrorsWhenAllSourcesFail() async throws {
        let config = WebSearchConfig(
            primary: .searxng,
            fallbackToBuiltin: false,
            apiKeys: [.tavily: "tvly-secret-token"],
            searxngURL: "https://searx.example",
            fallbackOrder: [.tavily]
        )
        let tool = WebSearchTool(
            config: config,
            sendJSON: { request in
                if request.url?.host == "searx.example" {
                    return (502, Data())
                }
                return (429, Data())
            }
        )

        let output = try await tool.run(.object(["query": .string("Swift")]))
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("502"))
        XCTAssertTrue(output.text.contains("429"))
        XCTAssertFalse(output.text.contains("tvly-secret-token"))
    }

    func testProbeIgnoresFallbackAndValidatesSearXNGConfig() async {
        let config = WebSearchConfig(
            primary: .searxng,
            fallbackToBuiltin: true,
            searxngURL: "http://search.example.com",
            fallbackOrder: [.anysearch]
        )
        let probe = await WebSearchTool.probe(query: "Swift", config: config)
        XCTAssertFalse(probe.ok)
        XCTAssertEqual(probe.source, "SearXNG")
        XCTAssertTrue(probe.detail.contains("https://"))
    }

    func testSearXNGTokenOriginBindingPreventsCrossOriginLeak() async throws {
        let boundOrigin = try SearXNGEndpoint.parse("https://searx-a.example:8443/").get().originKey
        XCTAssertEqual(boundOrigin, "https://searx-a.example:8443")

        let sameOriginConfig = WebSearchConfig(
            primary: .searxng,
            apiKey: "tok-a",
            fallbackToBuiltin: false,
            searxngURL: "https://searx-a.example:8443/search",
            searxngKeyOrigin: boundOrigin
        )
        XCTAssertEqual(sameOriginConfig.key(for: .searxng), "tok-a")

        let differentPortConfig = WebSearchConfig(
            primary: .searxng,
            apiKey: "tok-a",
            fallbackToBuiltin: false,
            searxngURL: "https://searx-a.example:9443",
            searxngKeyOrigin: boundOrigin
        )
        XCTAssertNil(differentPortConfig.key(for: .searxng))

        let differentHostConfig = WebSearchConfig(
            primary: .searxng,
            apiKey: "tok-a",
            fallbackToBuiltin: false,
            apiKeys: [.searxng: "tok-a"],
            searxngURL: "http://192.168.1.50:8080",
            searxngKeyOrigin: boundOrigin
        )
        XCTAssertNil(differentHostConfig.key(for: .searxng))

        let tool = WebSearchTool(
            config: differentHostConfig,
            sendJSON: { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, Data(#"{"results":[{"title":"No Leaked Token","url":"https://docs.example.org","content":"Safe"}]}"#.utf8))
            }
        )
        let out = try await tool.run(.object(["query": .string("Swift")]))
        XCTAssertFalse(out.isError)
        XCTAssertTrue(out.text.contains("No Leaked Token"))
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ value: String) {
        lock.lock()
        entries.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private final class SearXNGFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: Data
        switch url.host {
        case "192.168.1.50":
            body = Data(#"{"results":[{"title":"LAN SearXNG Result","url":"https://docs.example.org/lan","content":"From local instance"}]}"#.utf8)
        case "searx.example":
            body = Data(#"{"results":[{"title":"Public SearXNG Result","url":"https://docs.example.org/pub","content":"From HTTPS instance"}]}"#.utf8)
        default:
            body = Data(#"{"results":[]}"#.utf8)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
