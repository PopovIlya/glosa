import Foundation

public enum ClaudeError: LocalizedError {
    case noBackend
    case http(Int, String)
    case refusal
    case truncated
    case badOutput(String)
    case cli(String)

    public var errorDescription: String? {
        switch self {
        case .noBackend: "Нет ключа ANTHROPIC_API_KEY в .env и не найден claude CLI."
        case .http(let code, let body): "Claude API: HTTP \(code). \(body.prefix(300))"
        case .refusal: "Claude отказался отвечать на этот текст."
        case .truncated: "Ответ обрезан: текст слишком длинный, выдели фрагмент поменьше."
        case .badOutput(let why): "Не разобрал ответ Claude: \(why)"
        case .cli(let message): "claude CLI: \(message.prefix(300))"
        }
    }
}

/// One request to Claude: system prompt and user message in. With a JSON schema the answer is schema-valid
/// JSON; without one it is plain text, which is several times faster through the CLI.
public protocol ClaudeBackend: Sendable {
    var label: String { get }
    func complete(system: String, user: String, schema: String?) async throws -> Data
}

/// Messages API over HTTPS with structured outputs. Used when ANTHROPIC_API_KEY is set.
public struct AnthropicAPI: ClaudeBackend {
    public let apiKey: String
    public let model: String
    public var label: String { model }

    /// Models that accept the `fallbacks: "default"` refusal fallback.
    private static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func complete(system: String, user: String, schema: String?) async throws -> Data {
        var outputConfig: [String: Any] = ["effort": "low"]
        if let schema {
            outputConfig["format"] = ["type": "json_schema", "schema": try JSONSerialization.jsonObject(with: Data(schema.utf8))]
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
            // A dictionary lookup needs little thinking; low effort keeps the popup quick.
            "output_config": outputConfig,
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if Self.fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ClaudeError.http(status, String(decoding: data, as: UTF8.self)) }
        return try Self.text(from: data)
    }

    /// The JSON text of a Messages API response, after checking why the model stopped.
    static func text(from data: Data) throws -> Data {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badOutput("not an object")
        }
        switch message["stop_reason"] as? String {
        case "refusal": throw ClaudeError.refusal
        case "max_tokens": throw ClaudeError.truncated
        default: break
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ClaudeError.badOutput("no text block") }
        return Data(text.utf8)
    }
}

/// The `claude` CLI in print mode, which uses whatever account it is logged in to. No key needed.
public struct ClaudeCLI: ClaudeBackend {
    public let executable: URL
    public let model: String
    public var label: String { "claude CLI · \(model)" }

    public init(executable: URL, model: String) {
        self.executable = executable
        self.model = model
    }

    /// Apps started from Finder get no shell PATH, so look in the usual install places.
    public static func find() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude",
                     "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
        return paths.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func complete(system: String, user: String, schema: String?) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        // The text goes through stdin, so a selection starting with "-" is never read as a flag.
        process.arguments = ["-p", "--model", model, "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                             "--system-prompt", system, "--output-format", "json"] + (schema.map { ["--json-schema", $0] } ?? [])
        // Claude Code looks around its working folder at startup, and macOS asks for Downloads, Pictures and the
        // like in Glosa's name. An empty folder of its own leaves it nothing to look at.
        let workdir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glosa/cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        process.currentDirectoryURL = workdir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch { throw ClaudeError.cli(error.localizedDescription) }
        stdin.fileHandleForWriting.write(Data(user.utf8))
        try? stdin.fileHandleForWriting.close()
        // Drain both pipes while the process runs, so a long answer cannot fill the buffer and stall it.
        async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        async let errOut = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
        let (output, errData) = await (out, errOut)
        process.waitUntilExit()
        guard !output.isEmpty else {
            let err = String(decoding: errData, as: UTF8.self)
            throw ClaudeError.cli(err.isEmpty ? "exit \(process.terminationStatus)" : err)
        }
        return try Self.result(from: output, plain: schema == nil)
    }

    /// The structured result from `--output-format json` output.
    static func result(from data: Data, plain: Bool = false) throws -> Data {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.cli(String(decoding: data.prefix(300), as: UTF8.self))
        }
        if envelope["is_error"] as? Bool == true {
            throw ClaudeError.cli(envelope["result"] as? String ?? "error")
        }
        if let structured = envelope["structured_output"], JSONSerialization.isValidJSONObject(structured) {
            return try JSONSerialization.data(withJSONObject: structured)
        }
        guard var text = envelope["result"] as? String else { throw ClaudeError.badOutput("no result") }
        if plain { return Data(text.utf8) }
        // Without schema support the model may wrap JSON in a code fence.
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") { text = String(text[start...end]) }
        return Data(text.utf8)
    }
}

/// Translates selections and conjugates verbs.
public struct Lexicon: Sendable {
    public let backend: ClaudeBackend

    public init(backend: ClaudeBackend) { self.backend = backend }

    public static let defaultModel = "claude-opus-5-5"
    public static let defaultCLIModel = "opus"

    /// API key first (fast), then the logged-in CLI.
    public static func fromEnvironment(_ env: Env = .load()) -> Lexicon? {
        if let key = env["ANTHROPIC_API_KEY"] {
            return Lexicon(backend: AnthropicAPI(apiKey: key, model: env["CLAUDE_MODEL"] ?? defaultModel))
        }
        // An alias, not a model id: each CLI version maps it to the newest model it supports.
        if let cli = ClaudeCLI.find() {
            return Lexicon(backend: ClaudeCLI(executable: cli, model: env["CLAUDE_CLI_MODEL"] ?? defaultCLIModel))
        }
        return nil
    }

    public func translate(_ text: String) async throws -> Lookup {
        let data = try await backend.complete(system: Prompt.translateSystem, user: Prompt.translateUser(text),
                                              schema: Prompt.translationSchema)
        return try Self.decode(Lookup.self, data)
    }

    /// The translation, a note for an idiom, and short entries for `unknown` words: plain text, no schema,
    /// a few seconds even through the CLI.
    public func quickTranslation(_ text: String, unknown: [String] = []) async throws -> Prompt.QuickReply {
        let user = unknown.isEmpty ? Prompt.translateUser(text) : Prompt.phraseUser(text, unknown: unknown)
        let data = try await backend.complete(system: Prompt.quickSystem, user: user, schema: nil)
        return Prompt.parseQuick(String(decoding: data, as: UTF8.self))
    }

    /// A phrase whose other words the dictionary already explained: the translation, a note, and entries
    /// for `unknown` only, which keeps the answer short.
    public func translatePhrase(_ text: String, unknown: [String]) async throws -> Lookup {
        let data = try await backend.complete(system: Prompt.translateSystem, user: Prompt.phraseUser(text, unknown: unknown),
                                              schema: Prompt.translationSchema)
        return try Self.decode(Lookup.self, data)
    }

    public func conjugate(_ verb: String, language: Lang) async throws -> Conjugation {
        let data = try await backend.complete(system: Prompt.conjugateSystem,
                                              user: Prompt.conjugateUser(verb: verb, language: language),
                                              schema: Prompt.conjugationSchema)
        return try Self.decode(Conjugation.self, data)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder.snake.decode(type, from: data) } catch {
            throw ClaudeError.badOutput(String(describing: error).prefix(200).description)
        }
    }
}
