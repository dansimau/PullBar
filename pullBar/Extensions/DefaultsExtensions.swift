//
//  DefaultsExtensions.swift
//  issueBar
//
//  Created by Pavel Makhov on 2021-11-10.
//

import Foundation
import Defaults

extension Defaults.Keys {
    static let githubApiBaseUrl = Key<String>("githubApiBaseUrl", default: "https://api.github.com")
    static let githubUsername = Key<String>("githubUsername", default: "")
    static let githubAdditionalQuery = Key<String>("githubAdditionalQuery", default:"")

    // Legacy keys, kept so existing preferences can be migrated into `categories`.
    static let showAssigned = Key<Bool>("showAssigned", default: false)
    static let showCreated = Key<Bool>("showCreated", default: false)
    static let showRequested = Key<Bool>("showRequested", default: true)

    static let categories = Key<[SearchCategory]>("categories", default: SearchCategory.builtins)
    static let didMigrateCategories = Key<Bool>("didMigrateCategories", default: false)

    static let showAvatar = Key<Bool>("showAvatar", default: false)
    static let showLabels = Key<Bool>("showLabels", default: true)

    static let refreshRate = Key<Int>("refreshRate", default: 5)
    static let buildType = Key<BuildType>("buildType", default: .none)
    // Id of the category whose count is shown next to the menubar icon ("" == none).
    static let counterCategoryId = Key<String>("counterCategoryId", default: SearchCategory.reviewRequestedId)
}

extension KeychainKeys {
    static let githubToken: KeychainAccessKey = KeychainAccessKey(key: "githubToken")
}

/// A named GitHub search that becomes a section in the menu. Builtin categories
/// ship with the app and cannot be deleted; custom ones are added by the user.
struct SearchCategory: Codable, Defaults.Serializable, Identifiable, Hashable {
    var id: String
    var name: String
    var filter: String
    var enabled: Bool
    var isBuiltin: Bool

    static let assignedId = "assigned"
    static let createdId = "created"
    static let reviewRequestedId = "review-requested"
    static let userReviewRequestedId = "user-review-requested"

    /// Placeholder in a filter that is replaced with the configured username at
    /// query time. Not GitHub search syntax — used so builtin filters can be
    /// stored statically while still resolving to the current user.
    static let usernamePlaceholder = "<username>"

    /// The builtin categories, in display order. `filter` is the fragment that is
    /// inserted into the standard `is:open is:pr ... archived:false` wrapper.
    static let builtins: [SearchCategory] = [
        SearchCategory(id: assignedId, name: "Assigned", filter: "assignee:\(usernamePlaceholder)", enabled: false, isBuiltin: true),
        SearchCategory(id: createdId, name: "Created", filter: "author:\(usernamePlaceholder)", enabled: false, isBuiltin: true),
        SearchCategory(id: reviewRequestedId, name: "Review Requested", filter: "review-requested:\(usernamePlaceholder)", enabled: true, isBuiltin: true),
        SearchCategory(id: userReviewRequestedId, name: "Review Requested (direct)", filter: "user-review-requested:\(usernamePlaceholder)", enabled: false, isBuiltin: true),
    ]

    /// The search filter to actually query with. The `<username>` placeholder is
    /// replaced with the configured username; everything else is passed through
    /// verbatim, so raw GitHub search syntax (including a literal `@me`) in a
    /// custom filter is left untouched.
    func resolvedFilter(username: String) -> String {
        filter.replacingOccurrences(of: SearchCategory.usernamePlaceholder, with: username)
    }

    /// Reconciles a stored list against the current set of builtins: keeps each
    /// builtin's name/filter authoritative while preserving the user's enabled
    /// choice, inserts any builtin that is missing (e.g. added in a new version),
    /// and keeps custom categories untouched. Builtins are ordered first.
    static func reconcile(_ stored: [SearchCategory]) -> [SearchCategory] {
        let reconciledBuiltins = builtins.map { builtin -> SearchCategory in
            guard let existing = stored.first(where: { $0.id == builtin.id }) else { return builtin }
            var updated = builtin
            updated.enabled = existing.enabled
            return updated
        }
        let customCategories = stored.filter { category in
            !builtins.contains(where: { $0.id == category.id })
        }
        return reconciledBuiltins + customCategories
    }
}

enum BuildType: String, Defaults.Serializable, CaseIterable, Identifiable {
    case checks
    case commitStatus
    case none
    
    var id: Self { self }

    var description: String {

        switch self {
        case .checks:
            return "checks"
        case .commitStatus:
            return "commit statuses"
        case .none:
            return "none"
        }
    }
}

