import XCTest

/// `SpeakerMatcher` 纯函数测试：余弦匹配三档判定、Margin 校验、驳回候选跳过。
final class SpeakerMatcherTests: XCTestCase {
    private let e1: [Float] = [1, 0, 0]

    private func unit(_ cos: Float) -> [Float] {
        [cos, (1 - cos * cos).squareRoot(), 0]
    }

    private let rejectedKey: (UUID) -> String = { $0.uuidString }

    func testCentroidNormalizes() {
        let c = SpeakerMatcher.centroid([e1, e1])
        XCTAssertEqual(c, e1)
    }

    func testAutoMatch() {
        let a = UUID()
        let result = SpeakerMatcher.match(centroid: e1,
                                          candidates: [SpeakerCandidate(personID: a, centroid: e1)],
                                          rejectedKeys: [], rejectedKey: rejectedKey)
        XCTAssertEqual(result.tier, .auto)
        XCTAssertEqual(result.personID, a)
    }

    func testSuggestTier() {
        let a = UUID()
        let result = SpeakerMatcher.match(centroid: e1,
                                          candidates: [SpeakerCandidate(personID: a, centroid: unit(0.5))],
                                          rejectedKeys: [], rejectedKey: rejectedKey)
        XCTAssertEqual(result.tier, .suggest)
        XCTAssertEqual(result.topCandidateID, a)
        XCTAssertNil(result.personID)
    }

    func testNewPersonTier() {
        let a = UUID()
        let result = SpeakerMatcher.match(centroid: e1,
                                          candidates: [SpeakerCandidate(personID: a, centroid: unit(0.3))],
                                          rejectedKeys: [], rejectedKey: rejectedKey)
        XCTAssertEqual(result.tier, .newPerson)
    }

    func testMarginBlocksAutoWhenTwoCandidatesTie() {
        let a = UUID(), b = UUID()
        let result = SpeakerMatcher.match(centroid: e1,
                                          candidates: [SpeakerCandidate(personID: a, centroid: e1),
                                                       SpeakerCandidate(personID: b, centroid: e1)],
                                          rejectedKeys: [], rejectedKey: rejectedKey)
        // 两个候选并列，间距不足 → 不能硬塞给谁，落到「建议确认」
        XCTAssertEqual(result.tier, .suggest)
    }

    func testRejectedCandidateSkipped() {
        let a = UUID(), b = UUID()
        let result = SpeakerMatcher.match(centroid: e1,
                                          candidates: [SpeakerCandidate(personID: a, centroid: e1),
                                                       SpeakerCandidate(personID: b, centroid: unit(0.9))],
                                          rejectedKeys: [rejectedKey(a)], rejectedKey: rejectedKey)
        XCTAssertEqual(result.tier, .auto)
        XCTAssertEqual(result.personID, b, "已驳回的 A 应被跳过，自动署名到 B")
    }
}
