import Foundation

/// What a model can do. Services do not say, so it is guessed from the name; the user can set it right by hand.
public struct ModelTraits: Codable, Equatable, Hashable, Sendable {
    /// Takes pictures.
    public var sees: Bool
    /// Calls tools.
    public var tools: Bool
    /// Thinks before it answers (or can be asked to).
    public var thinks: Bool
    /// Context window in tokens.
    public var window: Int

    public init(sees: Bool, tools: Bool = true, thinks: Bool = false, window: Int = 131_072) {
        self.sees = sees
        self.tools = tools
        self.thinks = thinks
        self.window = window
    }

    /// 「看图 · 思考 · 1M」
    public var summary: String {
        var parts: [String] = []
        if sees { parts.append("看图") }
        if thinks { parts.append("思考") }
        if !tools { parts.append("不会用工具") }
        parts.append(Tokens.short(window).replacingOccurrences(of: ".00M", with: "M").replacingOccurrences(of: ".05M", with: "M"))
        return parts.joined(separator: " · ")
    }

    /// The best guess from a model's name. Names change often; what is not known here is guessed plainly
    /// (no pictures, tools yes, no thinking, 128K), and the user can correct it.
    public static func guess(_ model: String) -> ModelTraits {
        let name = model.lowercased()
        // OpenRouter and some others put the maker in front: 「openai/gpt-5」.
        let bare = name.split(separator: "/").last.map(String.init) ?? name
        return ModelTraits(sees: sees(bare), tools: tools(bare), thinks: thinks(bare), window: Tokens.window(for: bare))
    }

    static func sees(_ name: String) -> Bool {
        func has(_ part: String) -> Bool { name.contains(part) }
        // Said plainly in the name.
        if has("vision") || has("-vl") || has("vl-") || has("qvq") || has("omni") || has("llava")
            || has("pixtral") || has("internvl") || has("minicpm-v") || has("glm-4v") || has(".5v") || has("4.6v") { return true }
        // DeepSeek: V4.1 Flash sees (and the old Flash names now lead to it); Pro and the older ones do not.
        if has("deepseek") {
            return has("deepseek-flash") || has("deepseek-v4-flash") || has("v4.1")
        }
        if has("claude") { return true }
        if has("gemini") || has("gemma-3") || has("gemma3") || has("gemma-4") { return true }
        if has("gpt-4o") || has("gpt-4.1") || has("gpt-4-turbo") || has("gpt-5") || has("gpt-6") || has("chatgpt") { return !has("audio") && !has("search") }
        if name.hasPrefix("o3") || name.hasPrefix("o4") { return !has("mini") || has("o4-mini") }
        if has("grok") { return has("grok-4") || has("grok-5") || has("vision") }
        if has("kimi") { return has("k2.5") || has("k2-5") || has("k2.6") || has("k3") || has("kimi-latest") }
        if has("glm") { return has("flash") && (has("glm-5.3") || has("glm-5.4") || has("glm-6")) }
        if has("qwen") { return has("qwen3.5") || has("qwen3.6") || has("qwen-omni") }
        if has("doubao") { return has("seed") || has("vision") }
        if has("minimax") { return has("-m3") || has("-m4") }
        if has("llama-4") || has("llama4") || has("mistral-medium") || has("mistral-small-3") || has("step-1v") || has("step-3") { return true }
        return false
    }

    static func tools(_ name: String) -> Bool {
        let none = ["embed", "tts", "whisper", "dall-e", "image", "audio", "rerank", "moderation", "transcribe", "speech", "ocr", "instruct-0", "o1-mini", "qwq-32b-preview"]
        return !none.contains { name.contains($0) }
    }

    static func thinks(_ name: String) -> Bool {
        func has(_ part: String) -> Bool { name.contains(part) }
        if has("thinking") || has("reasoner") || has("reasoning") || has("-r1") || has("qwq") || has("qvq") { return true }
        if has("deepseek") { return has("v4") || has("flash") || has("v3.2") || has("v3.1") }
        if has("claude") { return !has("claude-3") || has("3-7") || has("3.7") }
        if has("gpt-5") || has("gpt-6") { return !has("chat") }
        if name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") { return true }
        if has("gemini") { return has("2.5") || has("gemini-3") || has("gemini-4") }
        if has("grok") { return has("grok-3-mini") || has("grok-4") || has("grok-5") }
        if has("glm") { return has("glm-4.5") || has("glm-4.6") || has("glm-4.7") || has("glm-5") || has("glm-6") }
        if has("kimi") { return has("k2.5") || has("k2-5") || has("k2.6") || has("k2.7") || has("k3") }
        if has("qwen") { return has("qwen3") || has("qwen-plus") || has("qwen-flash") || has("qwen-max") }
        if has("doubao") { return has("seed") }
        if has("minimax") { return has("-m2") || has("-m3") || has("-m4") }
        if has("hunyuan-t") || has("ernie-x") || has("magistral") || has("step-3") { return true }
        return false
    }

    /// Lists also carry models for pictures, speech, search embeddings: they cannot hold a conversation.
    public static func isChat(_ model: String) -> Bool {
        let name = model.lowercased()
        let not = ["embed", "tts", "whisper", "dall-e", "gpt-image", "-image", "image-", "audio", "rerank", "moderation", "transcribe",
                   "speech", "realtime", "davinci", "babbage", "sora", "veo", "imagen", "flux", "stable-diffusion", "kolors", "wanx",
                   "cosyvoice", "sensevoice", "paraformer", "seedream", "seedance", "lyria", "aqa", "bge-", "-ocr", "computer-use"]
        return !not.contains { name.contains($0) }
    }
}

public extension Tokens {
    /// A model's context window, by its name. Unknown models get 128K, the common floor.
    static func window(for model: String) -> Int {
        let name = model.lowercased()
        func has(_ part: String) -> Bool { name.contains(part) }
        if has("deepseek") {
            if has("deepseek-flash") || has("deepseek-v4") || name == "deepseek-chat" || name == "deepseek-reasoner" { return 1_048_576 }
            return 131_072
        }
        if has("gemini") { return 1_048_576 }
        if has("gpt-4.1") { return 1_047_576 }
        if has("gpt-5") || has("gpt-6") { return 400_000 }
        if has("claude") { return has("1m") || has("opus-4-8") || has("opus-5") ? 1_000_000 : 200_000 }
        if has("kimi-k3") { return 1_048_576 }
        if has("kimi") || has("moonshot") { return 262_144 }
        if has("minimax-m3") || has("minimax-m4") || has("minimax-text") { return 1_000_000 }
        if has("minimax") { return 204_800 }
        if has("grok-4") || has("grok-5") { return 256_000 }
        if has("glm-5") || has("glm-4.6") || has("glm-4.7") { return 200_000 }
        if has("qwen-long") || has("qwen-plus") || has("qwen-flash") || has("qwen-turbo") || has("qwen3.5") { return 1_000_000 }
        if has("qwen3-max") || has("qwen-max") { return 262_144 }
        if has("doubao-seed") { return 256_000 }
        if has("o3") || has("o4") { return 200_000 }
        return 131_072
    }
}
