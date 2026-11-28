import Foundation

/// 录音逐句润色策略，用来控制转写完成后的默认开销。
public enum LLMPolishMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case rules
    case llm
    case off

    public var id: String { rawValue }
}

/// 模型路由层级：轻量任务优先用便宜/本机小模型，复杂综合留给主模型。
public enum LLMTier: String, CaseIterable, Codable, Sendable {
    case primary
    case light
}

/// 分析模型使用策略（与 AppSettings.AnalysisMode 保持同名原始值）。
public enum LLMAnalysisMode: String, CaseIterable, Codable, Sendable {
    case auto
    case cloud
    case local
}

/// 区分每一次模型调用所属的业务环节，便于路由和统计用量。
public enum LLMTaskKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case analyzeChunk
    case analyzeFinal
    case polish
    case retitle
    case dictation
    case rewrite
    case ask
    case translate
    case study

    public var id: String { rawValue }

    /// 各项任务默认的成本层级。
    public var defaultTier: LLMTier {
        switch self {
        case .analyzeChunk, .polish, .retitle, .dictation:
            .light
        case .analyzeFinal, .rewrite, .ask, .translate, .study:
            .primary
        }
    }
}

/// 一个经过整理、可直接发起请求或脱敏记账的接口端点。
public struct LLMRouteEndpoint: Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public var key: String

    public init(baseURL: String, model: String, key: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool {
        !baseURL.isEmpty && !model.isEmpty
    }

    /// 仅保留域名或本地主机名，不写入路径、查询参数或密钥。
    public var providerHost: String {
        guard let url = URL(string: baseURL), let host = url.host, !host.isEmpty else {
            return baseURL.isEmpty ? "local" : "custom"
        }
        return host.lowercased()
    }

    public var isLocalURL: Bool {
        let host = providerHost
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

/// 路由计算出的候选执行节点，按优先级从高到低排列。
public enum LLMRouteCandidate: Sendable, Equatable {
    case cloud(LLMRouteEndpoint)
    case builtInLocal
}

/// 分级模型路由器：根据任务层级、分析模式与开关计算候选列表。
public enum LLMRouter: Sendable {
    /// 计算轻量云端端点：若只填了轻量模型名，默认继承主服务的接口地址与密钥；
    /// 若单独填了本地或不同域名的接口地址，则只在同域名时继承主密钥，避免把云端密钥发到别处。
    public static func effectiveLightEndpoint(
        primary: LLMRouteEndpoint?,
        lightBaseURL: String,
        lightModel: String,
        lightKey: String
    ) -> LLMRouteEndpoint? {
        let trimmedModel = lightModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return nil }

        let trimmedBase = lightBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBase = trimmedBase.isEmpty ? (primary?.baseURL ?? "") : trimmedBase
        guard !resolvedBase.isEmpty else { return nil }

        let probe = LLMRouteEndpoint(baseURL: resolvedBase, model: trimmedModel, key: "")
        let trimmedKey = lightKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey: String
        if !trimmedKey.isEmpty {
            resolvedKey = trimmedKey
        } else if let primary, !probe.isLocalURL,
                  trimmedBase.isEmpty || probe.providerHost == primary.providerHost {
            resolvedKey = primary.key
        } else {
            resolvedKey = ""
        }
        return LLMRouteEndpoint(baseURL: resolvedBase, model: trimmedModel, key: resolvedKey)
    }

    public static func resolveCandidates(
        tier: LLMTier,
        mode: LLMAnalysisMode,
        primary: LLMRouteEndpoint?,
        light: LLMRouteEndpoint?,
        localReady: Bool,
        lightUseLocalFirst: Bool
    ) -> [LLMRouteCandidate] {
        let validPrimary = primary?.isConfigured == true ? primary : nil
        let validLight = light?.isConfigured == true ? light : nil

        var ordered: [LLMRouteCandidate] = []
        func appendUnique(_ candidate: LLMRouteCandidate) {
            if !ordered.contains(candidate) { ordered.append(candidate) }
        }

        switch mode {
        case .local:
            if localReady { appendUnique(.builtInLocal) }

        case .cloud:
            switch tier {
            case .primary:
                if let validPrimary { appendUnique(.cloud(validPrimary)) }
            case .light:
                if let validLight { appendUnique(.cloud(validLight)) }
                if let validPrimary { appendUnique(.cloud(validPrimary)) }
            }

        case .auto:
            switch tier {
            case .primary:
                if let validPrimary { appendUnique(.cloud(validPrimary)) }
                if localReady { appendUnique(.builtInLocal) }
            case .light:
                if lightUseLocalFirst {
                    if localReady { appendUnique(.builtInLocal) }
                    if let validLight { appendUnique(.cloud(validLight)) }
                    if let validPrimary { appendUnique(.cloud(validPrimary)) }
                } else {
                    if let validLight { appendUnique(.cloud(validLight)) }
                    if let validPrimary { appendUnique(.cloud(validPrimary)) }
                    if localReady { appendUnique(.builtInLocal) }
                }
            }
        }

        return ordered
    }
}

/// 单次聊天补全返回的 token 用量，优先取接口 `usage` 字段，缺失时按文本长度估算。
public struct LLMTokenUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var estimated: Bool

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int? = nil, estimated: Bool) {
        let p = max(0, promptTokens)
        let c = max(0, completionTokens)
        let t = max(0, totalTokens ?? (p + c))
        self.promptTokens = p
        self.completionTokens = c
        self.totalTokens = t > 0 ? t : (p + c)
        self.estimated = estimated
    }

    public static let zero = LLMTokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0, estimated: true)

    public static func parse(
        responseJSONData data: Data,
        promptText: String,
        completionText: String
    ) -> LLMTokenUsage {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usage = root["usage"] as? [String: Any] {
            let prompt = intValue(usage["prompt_tokens"]) ?? intValue(usage["input_tokens"])
            let completion = intValue(usage["completion_tokens"]) ?? intValue(usage["output_tokens"])
            let total = intValue(usage["total_tokens"])
            let resolvedPrompt = max(0, prompt ?? 0)
            let resolvedCompletion = max(0, completion ?? 0)
            let resolvedTotal = max(0, total ?? (resolvedPrompt + resolvedCompletion))
            if resolvedTotal > 0 || resolvedPrompt > 0 || resolvedCompletion > 0 {
                return LLMTokenUsage(
                    promptTokens: resolvedPrompt,
                    completionTokens: resolvedCompletion,
                    totalTokens: resolvedTotal,
                    estimated: false
                )
            }
        }
        let estPrompt = estimateTokens(promptText)
        let estCompletion = estimateTokens(completionText)
        return LLMTokenUsage(
            promptTokens: estPrompt,
            completionTokens: estCompletion,
            totalTokens: estPrompt + estCompletion,
            estimated: true
        )
    }

    /// 中英混排按经验比例粗估 token 数，仅在服务端不返回 usage 时兜底。
    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var asciiCount = 0
        var nonASCIICount = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if scalar.isASCII {
                asciiCount += 1
            } else {
                nonASCIICount += 1
            }
        }
        guard asciiCount > 0 || nonASCIICount > 0 else { return 0 }
        let estimate = Int((Double(nonASCIICount) * 1.1 + Double(asciiCount) * 0.35).rounded(.up))
        return max(1, estimate)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let n = Int(s) { return n }
        return nil
    }
}

/// 一条脱敏后的 AI 调用账本记录（不存接口密钥、原始文本或完整地址）。
public struct LLMUsageEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var task: LLMTaskKind
    public var tier: LLMTier
    public var model: String
    public var providerHost: String
    public var builtInLocal: Bool
    public var recordingID: UInt32?
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var estimated: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        task: LLMTaskKind,
        tier: LLMTier,
        model: String,
        providerHost: String,
        builtInLocal: Bool,
        recordingID: UInt32? = nil,
        usage: LLMTokenUsage
    ) {
        self.id = id
        self.timestamp = timestamp
        self.task = task
        self.tier = tier
        self.model = model
        self.providerHost = providerHost
        self.builtInLocal = builtInLocal
        self.recordingID = recordingID
        self.promptTokens = max(0, usage.promptTokens)
        self.completionTokens = max(0, usage.completionTokens)
        self.totalTokens = max(0, usage.totalTokens)
        self.estimated = usage.estimated
    }

    public var isCloud: Bool {
        !builtInLocal && providerHost != "127.0.0.1" && providerHost != "localhost" && providerHost != "::1"
    }
}

/// 按模型聚合后的用量明细。
public struct LLMModelUsage: Sendable, Equatable, Identifiable {
    public var id: String { "\(providerHost)::\(model)::\(builtInLocal ? "local" : "cloud")" }
    public var model: String
    public var providerHost: String
    public var builtInLocal: Bool
    public var calls: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var cloudTokens: Int
    public var localTokens: Int
}

/// 用于设置页展示的汇总指标。
public struct LLMUsageSummary: Sendable, Equatable {
    public var totalCalls: Int
    public var totalPromptTokens: Int
    public var totalCompletionTokens: Int
    public var totalTokens: Int
    public var cloudTokens: Int
    public var localTokens: Int
    public var todayTokens: Int
    public var todayCloudTokens: Int
    public var last30DaysTokens: Int
    public var last30DaysCloudTokens: Int
    public var byTask: [LLMTaskKind: Int]
    public var byModel: [LLMModelUsage]
}

/// 本地用量账本的裁剪、持久化与统计。
public enum LLMUsageLedger: Sendable {
    public static let maxEntries = 5000

    public static func append(
        _ entry: LLMUsageEntry,
        to entries: [LLMUsageEntry],
        limit: Int = maxEntries
    ) -> [LLMUsageEntry] {
        guard limit > 0 else { return [] }
        var next = entries
        next.append(entry)
        if next.count > limit {
            next = Array(next.suffix(limit))
        }
        return next
    }

    public static func load(from url: URL) -> [LLMUsageEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LLMUsageEntry].self, from: data)) ?? []
    }

    public static func save(_ entries: [LLMUsageEntry], to url: URL, limit: Int = maxEntries) throws {
        let trimmed = limit > 0 && entries.count > limit ? Array(entries.suffix(limit)) : entries
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(trimmed)
        try data.write(to: url, options: .atomic)
    }

    public static func summarize(
        _ entries: [LLMUsageEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LLMUsageSummary {
        let startOfToday = calendar.startOfDay(for: now)
        let startOf30Days = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday

        var totalCalls = 0
        var totalPrompt = 0
        var totalCompletion = 0
        var totalTokens = 0
        var cloudTokens = 0
        var localTokens = 0
        var todayTokens = 0
        var todayCloudTokens = 0
        var last30Tokens = 0
        var last30CloudTokens = 0
        var byTask: [LLMTaskKind: Int] = [:]
        var modelBuckets: [String: LLMModelUsage] = [:]

        for e in entries {
            totalCalls += 1
            totalPrompt += e.promptTokens
            totalCompletion += e.completionTokens
            totalTokens += e.totalTokens
            if e.isCloud {
                cloudTokens += e.totalTokens
            } else {
                localTokens += e.totalTokens
            }

            if e.timestamp >= startOfToday {
                todayTokens += e.totalTokens
                if e.isCloud { todayCloudTokens += e.totalTokens }
            }
            if e.timestamp >= startOf30Days {
                last30Tokens += e.totalTokens
                if e.isCloud { last30CloudTokens += e.totalTokens }
            }

            byTask[e.task, default: 0] += e.totalTokens

            let bucketKey = "\(e.providerHost)::\(e.model)::\(e.builtInLocal ? "local" : "cloud")"
            var bucket = modelBuckets[bucketKey] ?? LLMModelUsage(
                model: e.model,
                providerHost: e.providerHost,
                builtInLocal: e.builtInLocal,
                calls: 0,
                promptTokens: 0,
                completionTokens: 0,
                totalTokens: 0,
                cloudTokens: 0,
                localTokens: 0
            )
            bucket.calls += 1
            bucket.promptTokens += e.promptTokens
            bucket.completionTokens += e.completionTokens
            bucket.totalTokens += e.totalTokens
            if e.isCloud {
                bucket.cloudTokens += e.totalTokens
            } else {
                bucket.localTokens += e.totalTokens
            }
            modelBuckets[bucketKey] = bucket
        }

        let sortedModels = modelBuckets.values.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            if $0.calls != $1.calls { return $0.calls > $1.calls }
            return $0.model < $1.model
        }

        return LLMUsageSummary(
            totalCalls: totalCalls,
            totalPromptTokens: totalPrompt,
            totalCompletionTokens: totalCompletion,
            totalTokens: totalTokens,
            cloudTokens: cloudTokens,
            localTokens: localTokens,
            todayTokens: todayTokens,
            todayCloudTokens: todayCloudTokens,
            last30DaysTokens: last30Tokens,
            last30DaysCloudTokens: last30CloudTokens,
            byTask: byTask,
            byModel: sortedModels
        )
    }

    public static func formatTokens(_ count: Int) -> String {
        let value = max(0, count)
        if value < 1_000 { return "\(value)" }
        if value < 1_000_000 {
            let k = Double(value) / 1_000.0
            let formatted = String(format: "%.1f", k)
            let clean = formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
            return "\(clean)K"
        }
        let m = Double(value) / 1_000_000.0
        let formatted = String(format: "%.2f", m)
        var clean = formatted
        while clean.contains(".") && (clean.hasSuffix("0") || clean.hasSuffix(".")) {
            clean.removeLast()
        }
        return "\(clean)M"
    }
}
