import Foundation
import SwiftData

/// A BTR chat the reader has asked at least one question in, kept so it can
/// be reopened later — from the chat's own history list, in any reading
/// mode. Written by `BTRChatViewModel` as the conversation goes; a chat that
/// was opened and closed without a question is never stored.
///
/// The anchor is kept with the chat, so a reopened chat keeps answering
/// from the same point in the book it was started at: never further, even
/// if the reader has since read on, which keeps it spoiler-free whichever
/// position it's reopened from.
@Model
final class SavedBTRChat {
    /// How the chat was opened.
    enum Kind: String, Codable {
        /// From a text selection (or RSVP's current word): the chat shows
        /// the passage around it at the top.
        case selection
        /// From the reader controls, with no selection: the chat covers the
        /// page the reader was on and everything before it.
        case page
    }

    /// One stored message. Only finished exchanges are stored: a reply that
    /// was still pending or had failed when the chat was saved is left out.
    struct Message: Codable, Equatable {
        enum Role: String, Codable {
            case reader
            case assistant
        }

        var id: UUID
        var role: Role
        var text: String
    }

    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var kindRawValue: String
    /// Serialized Readium `Locator`: the position the chat answers up to.
    var anchorLocatorJSON: String
    /// The chapter the chat was opened in, for the history list.
    var chapterTitle: String?
    /// The words the reader had selected in the passage strip
    /// (`BTRContextWord.id`s), restored with the chat.
    var selectedWordIDs: [Int] = []
    /// `[Message]`, JSON-encoded. Kept as data rather than a relationship:
    /// messages are only ever read and written as a whole conversation.
    var messagesData: Data
    var book: Book?

    init(
        id: UUID = UUID(),
        kind: Kind,
        anchorLocatorJSON: String,
        chapterTitle: String? = nil,
        selectedWordIDs: [Int] = [],
        messages: [Message] = [],
        createdAt: Date = .now,
        book: Book? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        updatedAt = createdAt
        kindRawValue = kind.rawValue
        self.anchorLocatorJSON = anchorLocatorJSON
        self.chapterTitle = chapterTitle
        self.selectedWordIDs = selectedWordIDs
        messagesData = (try? JSONEncoder().encode(messages)) ?? Data()
        self.book = book
    }

    var kind: Kind {
        Kind(rawValue: kindRawValue) ?? .selection
    }

    var messages: [Message] {
        get { (try? JSONDecoder().decode([Message].self, from: messagesData)) ?? [] }
        set { messagesData = (try? JSONEncoder().encode(newValue)) ?? messagesData }
    }

    /// The chat's first question, which names it in the history list.
    var title: String {
        messages.first(where: { $0.role == .reader })?.text ?? "Untitled chat"
    }

    /// How many questions were asked.
    var questionCount: Int {
        messages.filter { $0.role == .reader }.count
    }
}
