import Testing
@testable import ReadBTR

struct RSVPTimingTests {
    static let settings = RSVPSettings(
        wordsPerMinute: 300,
        smartTimingEnabled: true,
        skipIncrementSmall: 5,
        skipIncrementMedium: 15,
        skipIncrementLarge: 30
    )

    @Test func baseDelayMatchesWordsPerMinute() {
        var settings = Self.settings
        settings.smartTimingEnabled = false

        // 300 wpm -> 60/300 = 0.2s/word, regardless of word shape, when
        // smart timing is off.
        let delay = RSVPTiming.delay(forWord: "a", after: nil, settings: settings)
        #expect(abs(delay - 0.2) < 0.0001)

        let longWordDelay = RSVPTiming.delay(forWord: "extraordinarily", after: ". ", settings: settings)
        #expect(abs(longWordDelay - 0.2) < 0.0001)
    }

    @Test func smartTimingStretchesLongerWords() {
        let short = RSVPTiming.delay(forWord: "cat", after: " ", settings: Self.settings)
        let long = RSVPTiming.delay(forWord: "extraordinarily", after: " ", settings: Self.settings)
        #expect(long > short)
    }

    @Test func smartTimingPausesLongerAtSentenceEndThanComma() {
        let base = RSVPTiming.delay(forWord: "word", after: " next", settings: Self.settings)
        let comma = RSVPTiming.delay(forWord: "word", after: ", next", settings: Self.settings)
        let period = RSVPTiming.delay(forWord: "word", after: ". Next", settings: Self.settings)

        #expect(comma > base)
        #expect(period > comma)
    }

    @Test func smartTimingIgnoresPunctuationWhenDisabled() {
        var settings = Self.settings
        settings.smartTimingEnabled = false

        let noPunctuation = RSVPTiming.delay(forWord: "word", after: " next", settings: settings)
        let period = RSVPTiming.delay(forWord: "word", after: ". Next", settings: settings)
        #expect(noPunctuation == period)
    }

    @Test func emptyOrNilAfterContextIsTreatedAsNoPunctuation() {
        let nilAfter = RSVPTiming.delay(forWord: "word", after: nil, settings: Self.settings)
        let emptyAfter = RSVPTiming.delay(forWord: "word", after: "", settings: Self.settings)
        #expect(nilAfter == emptyAfter)
    }
}
