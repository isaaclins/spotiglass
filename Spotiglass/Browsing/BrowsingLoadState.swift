import Foundation

struct BrowsingDisplayError: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let canRetry: Bool
    let diagnosticDetails: String?

    init(title: String, message: String, canRetry: Bool, diagnosticDetails: String? = nil) {
        self.title = title
        self.message = message
        self.canRetry = canRetry
        self.diagnosticDetails = diagnosticDetails
    }

    static func == (lhs: BrowsingDisplayError, rhs: BrowsingDisplayError) -> Bool {
        lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.canRetry == rhs.canRetry
            && lhs.diagnosticDetails == rhs.diagnosticDetails
    }
}

enum BrowsingLoadState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case empty(String)
    case staleCache(Value, BrowsingDisplayError?)
    case refreshing(Value)
    case error(BrowsingDisplayError)

    var currentValue: Value? {
        switch self {
        case let .loaded(value), let .staleCache(value, _), let .refreshing(value):
            value
        case .loading, .empty, .error:
            nil
        }
    }
}
