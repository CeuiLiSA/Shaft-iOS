import Foundation

/// All in-app navigation destinations. One enum, one place to add a new
/// route — see `RouteHost` for the destination registration.
enum AppRoute: Hashable, Codable, Sendable {
    case illustDetail(Int64)
    case novelDetail(Int64)
    case userProfile(Int64)
    case ranking(initialMode: String)
    case search
    case searchResults(word: String)
    case tagResults(tag: String)
    case relatedIllusts(illustId: Int64)
    case userIllusts(userId: Int64, type: String)
    case userBookmarks(userId: Int64)
    case userNovels(userId: Int64)
    case userFollowing(userId: Int64)
    case userFollower(userId: Int64)
    case comments(target: CommentTarget)
    case spotlight
    case walkthrough
    case recommendUsers
    case latestWorks
    case more
    case history
    case downloads
    case mute
    case settings
    case about

    enum CommentTarget: Hashable, Codable, Sendable {
        case illust(Int64)
        case novel(Int64)
    }
}
