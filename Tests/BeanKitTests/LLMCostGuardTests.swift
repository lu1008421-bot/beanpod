import Foundation
import Testing
@testable import BeanKit

@Test func routesPrimaryAndLightTiersAcrossModes() {
    let primary = LLMRouteEndpoint(baseURL: "https://api.openai.com/v1", model: "gpt-4o", key: "sk-primary")
    let light = LLMRouter.effectiveLightEndpoint(
        primary: primary,
        lightBaseURL: "",
        lightModel: "gpt-4o-mini",
        lightKey: ""
    )
    #expect(light == LLMRouteEndpoint(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini", key: "sk-primary"))

    // 轻量模型在 auto + lightUseLocalFirst=true 且本机就绪时：本机 -> 轻量云端 -> 主模型兜底
    let autoLocalFirst = LLMRouter.resolveCandidates(
        tier: .light,
        mode: .auto,
        primary: primary,
        light: light,
        localReady: true,
        lightUseLocalFirst: true
    )
    #expect(autoLocalFirst == [.builtInLocal, .cloud(light!), .cloud(primary)])

    // 轻量模型关闭本机优先时：轻量云端 -> 主模型 -> 本机
    let autoCloudFirst = LLMRouter.resolveCandidates(
        tier: .light,
        mode: .auto,
        primary: primary,
        light: light,
        localReady: true,
        lightUseLocalFirst: false
    )
    #expect(autoCloudFirst == [.cloud(light!), .cloud(primary), .builtInLocal])

    // 主任务永远优先用主云端模型，不走轻量模型
    let primaryCandidates = LLMRouter.resolveCandidates(
        tier: .primary,
        mode: .auto,
        primary: primary,
        light: light,
        localReady: true,
        lightUseLocalFirst: true
    )
    #expect(primaryCandidates == [.cloud(primary), .builtInLocal])

    // 只用本机模式不会外发云端
    let localOnly = LLMRouter.resolveCandidates(
        tier: .light,
        mode: .local,
        primary: primary,
        light: light,
        localReady: true,
        lightUseLocalFirst: false
    )
    #expect(localOnly == [.builtInLocal])

    // 只用云端模式不会回落到本机
    let cloudOnly = LLMRouter.resolveCandidates(
        tier: .light,
        mode: .cloud,
        primary: primary,
        light: light,
        localReady: true,
        lightUseLocalFirst: true
    )
    #expect(cloudOnly == [.cloud(light!), .cloud(primary)])
}

@Test func effectiveLightEndpointProtectsPrimaryKeyAcrossHosts() {
    let primary = LLMRouteEndpoint(baseURL: "https://api.openai.com/v1", model: "gpt-4o", key: "sk-secret")

    // 同域未填密钥时可继承主密钥
    let sameHost = LLMRouter.effectiveLightEndpoint(
        primary: primary,
        lightBaseURL: "https://api.openai.com/v1",
        lightModel: "gpt-4o-mini",
        lightKey: ""
    )
    #expect(sameHost?.key == "sk-secret")

    // 切换成独立域名（或本机 Ollama）且未填密钥时，不得误传主密钥
    let localOllama = LLMRouter.effectiveLightEndpoint(
        primary: primary,
        lightBaseURL: "http://127.0.0.1:11434/v1",
        lightModel: "qwen3:4b",
        lightKey: ""
    )
    #expect(localOllama?.key == "")
    #expect(localOllama?.isLocalURL == true)

    let otherHost = LLMRouter.effectiveLightEndpoint(
        primary: primary,
        lightBaseURL: "https://api.deepseek.com/v1",
        lightModel: "deepseek-chat",
        lightKey: ""
    )
    #expect(otherHost?.key == "")
}

@Test func parsesOpenAIAndResponsesUsageAndFallsBackToEstimate() {
    let openAIJSON = Data(#"{"usage":{"prompt_tokens":120,"completion_tokens":45,"total_tokens":165}}"#.utf8)
    let openAIUsage = LLMTokenUsage.parse(responseJSONData: openAIJSON, promptText: "hi", completionText: "hello")
    #expect(openAIUsage == LLMTokenUsage(promptTokens: 120, completionTokens: 45, totalTokens: 165, estimated: false))

    let responsesJSON = Data(#"{"usage":{"input_tokens":80,"output_tokens":20}}"#.utf8)
    let responsesUsage = LLMTokenUsage.parse(responseJSONData: responsesJSON, promptText: "hi", completionText: "hello")
    #expect(responsesUsage == LLMTokenUsage(promptTokens: 80, completionTokens: 20, totalTokens: 100, estimated: false))

    let missingJSON = Data(#"{"choices":[{"message":{"content":"你好世界"}}]}"#.utf8)
    let fallbackUsage = LLMTokenUsage.parse(responseJSONData: missingJSON, promptText: "请总结一下今天会议的重点内容", completionText: "好的，重点如下")
    #expect(fallbackUsage.estimated == true)
    #expect(fallbackUsage.promptTokens > 0)
    #expect(fallbackUsage.completionTokens > 0)
    #expect(fallbackUsage.totalTokens == fallbackUsage.promptTokens + fallbackUsage.completionTokens)
}

@Test func ledgerCapsEntriesAndPersistsWithoutSensitiveFields() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-ledger-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let fileURL = tempDir.appendingPathComponent("llm_usage.json")

    var entries: [LLMUsageEntry] = []
    for i in 1...10 {
        let entry = LLMUsageEntry(
            timestamp: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i)),
            task: i % 2 == 0 ? .polish : .analyzeFinal,
            tier: i % 2 == 0 ? .light : .primary,
            model: "secret-free-model",
            providerHost: "api.deepseek.com",
            builtInLocal: false,
            recordingID: UInt32(i),
            usage: LLMTokenUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150, estimated: false)
        )
        entries = LLMUsageLedger.append(entry, to: entries, limit: 5)
    }

    #expect(entries.count == 5)
    #expect(entries.first?.recordingID == 6)
    #expect(entries.last?.recordingID == 10)

    try LLMUsageLedger.save(entries, to: fileURL, limit: 5)
    let loaded = LLMUsageLedger.load(from: fileURL)
    #expect(loaded == entries)

    let rawText = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(!rawText.contains("sk-"))
    #expect(!rawText.contains("Bearer"))
}

@Test func summarizesWindowsTasksModelsAndFormatsTokens() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_760_000_000) // arbitrary anchor
    let today = now
    let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now)!
    let fortyDaysAgo = calendar.date(byAdding: .day, value: -40, to: now)!

    let entries = [
        LLMUsageEntry(
            timestamp: today,
            task: .analyzeFinal,
            tier: .primary,
            model: "gpt-4o",
            providerHost: "api.openai.com",
            builtInLocal: false,
            recordingID: 1,
            usage: LLMTokenUsage(promptTokens: 700, completionTokens: 300, totalTokens: 1000, estimated: false)
        ),
        LLMUsageEntry(
            timestamp: tenDaysAgo,
            task: .polish,
            tier: .light,
            model: "Qwen3-4B",
            providerHost: "127.0.0.1",
            builtInLocal: true,
            recordingID: 1,
            usage: LLMTokenUsage(promptTokens: 400, completionTokens: 200, totalTokens: 600, estimated: false)
        ),
        LLMUsageEntry(
            timestamp: fortyDaysAgo,
            task: .translate,
            tier: .primary,
            model: "gpt-4o-mini",
            providerHost: "api.openai.com",
            builtInLocal: false,
            recordingID: 2,
            usage: LLMTokenUsage(promptTokens: 1500, completionTokens: 500, totalTokens: 2000, estimated: false)
        ),
    ]

    let summary = LLMUsageLedger.summarize(entries, now: now, calendar: calendar)
    #expect(summary.totalCalls == 3)
    #expect(summary.totalTokens == 3600)
    #expect(summary.cloudTokens == 3000)
    #expect(summary.localTokens == 600)
    #expect(summary.todayTokens == 1000)
    #expect(summary.todayCloudTokens == 1000)
    #expect(summary.last30DaysTokens == 1600)
    #expect(summary.last30DaysCloudTokens == 1000)
    #expect(summary.byTask[.analyzeFinal] == 1000)
    #expect(summary.byTask[.polish] == 600)
    #expect(summary.byTask[.translate] == 2000)
    #expect(summary.byModel.first?.model == "gpt-4o-mini")
    #expect(LLMUsageLedger.formatTokens(850) == "850")
    #expect(LLMUsageLedger.formatTokens(1000) == "1K")
    #expect(LLMUsageLedger.formatTokens(12_340) == "12.3K")
    #expect(LLMUsageLedger.formatTokens(1_500_000) == "1.5M")
}
