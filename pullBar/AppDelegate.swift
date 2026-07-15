//
//  AppDelegate.swift
//  pullBar
//
//  Created by Pavel Makhov on 2021-11-15.
//

import Cocoa
import Defaults
import SwiftUI
import Foundation
import KeychainAccess

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    @FromKeychain(.githubToken) var githubToken
    
    let ghClient = GitHubClient()
    var statusBarItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu: NSMenu = NSMenu()
    
    var preferencesWindow: NSWindow!
    var aboutWindow: NSWindow!
    
    var timer: Timer? = nil
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        migrateCategoriesIfNeeded()

        NotificationCenter.default.addObserver(self, selector: #selector(AppDelegate.windowClosed), name: NSWindow.willCloseNotification, object: nil)

        guard let statusButton = statusBarItem.button else { return }
        let icon = NSImage(named: "git-pull-request")
        let size = NSSize(width: 16, height: 16)
        icon?.isTemplate = true
        icon?.size = size
        statusButton.image = icon
        statusButton.imagePosition = NSControl.ImagePosition.imageLeft
        
        statusBarItem.menu = menu
        
        timer = Timer.scheduledTimer(
            timeInterval: Double(Defaults[.refreshRate] * 60),
            target: self,
            selector: #selector(refreshMenu),
            userInfo: nil,
            repeats: true
        )
        timer?.fire()
        RunLoop.main.add(timer!, forMode: .common)
        NSApp.setActivationPolicy(.accessory)
        
        
        // Insert code here to initialize your application
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    @objc
    func openLink(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(sender.representedObject as! URL)
    }

    /// One-time migration of the legacy per-type toggles into the unified
    /// `categories` list, then reconcile the stored list with the current builtins
    /// (so builtins added in newer versions show up and their name/filter stay
    /// authoritative while the user's enabled choice is preserved).
    func migrateCategoriesIfNeeded() {
        if !Defaults[.didMigrateCategories] {
            var categories = Defaults[.categories]
            let legacyEnabled: [String: Bool] = [
                SearchCategory.assignedId: Defaults[.showAssigned],
                SearchCategory.createdId: Defaults[.showCreated],
                SearchCategory.reviewRequestedId: Defaults[.showRequested],
            ]
            for index in categories.indices {
                if let enabled = legacyEnabled[categories[index].id] {
                    categories[index].enabled = enabled
                }
            }
            Defaults[.categories] = categories
            Defaults[.didMigrateCategories] = true
        }

        Defaults[.categories] = SearchCategory.reconcile(Defaults[.categories])
    }

}

extension AppDelegate {
    @objc
    func refreshMenu() {
        NSLog("Refreshing menu")
        self.menu.removeAllItems()

        if (Defaults[.githubUsername] == "" || githubToken == "") {
            addMenuFooterItems()
            return
        }


        let categories = Defaults[.categories].filter { $0.enabled && !$0.filter.trimmingCharacters(in: .whitespaces).isEmpty }
        var pullsByCategory: [String: [Edge]] = [:]

        let group = DispatchGroup()

        for category in categories {
            group.enter()
            ghClient.getPulls(filter: category.resolvedFilter(username: Defaults[.githubUsername])) { pulls in
                pullsByCategory[category.id, default: []].append(contentsOf: pulls)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.statusBarItem.button?.title = ""

            for category in categories {
                let pulls = pullsByCategory[category.id] ?? []
                if pulls.isEmpty { continue }

                if Defaults[.counterCategoryId] == category.id {
                    self.statusBarItem.button?.title = String(pulls.count)
                }

                self.menu.addItem(NSMenuItem(title: "\(category.name) (\(pulls.count))", action: nil, keyEquivalent: ""))
                for pull in pulls {
                    self.menu.addItem(self.createMenuItem(pull: pull))
                }
                self.menu.addItem(.separator())
            }

            self.addMenuFooterItems()
        }
    }
    
    func createMenuItem(pull: Edge) -> NSMenuItem {
        let issueItem = NSMenuItem(title: "", action: #selector(self.openLink), keyEquivalent: "")
        
        let issueItemTitle = NSMutableAttributedString(string: "")
            .appendString(string: pull.node.isReadByViewer ? "" : "⏺ ", color: .systemBlue)
        
        if (pull.node.isDraft) {
            issueItemTitle
                .appendIcon(iconName: "git-draft-pull-request", color: NSColor.secondaryLabelColor)
        }
        
        issueItemTitle
            .appendString(string: pull.node.title.trunc(length: 50), color: NSColor(.primary))
            .appendString(string: " #" +  String(pull.node.number))
            .appendSeparator()
        
        issueItemTitle.appendNewLine()
        
        issueItemTitle
            .appendIcon(iconName: "repo")
            .appendString(string: pull.node.repository.name)
            .appendSeparator()
            .appendIcon(iconName: "person")
            .appendString(string: pull.node.author?.login ?? User.ghost.login)
        
        if !pull.node.labels.nodes.isEmpty && Defaults[.showLabels] {
            issueItemTitle
                .appendNewLine()
                .appendIcon(iconName: "tag", color: NSColor(.secondary))
            for label in pull.node.labels.nodes {
                issueItemTitle
                    .appendString(string: label.name, color: hexColor(hex: label.color), fontSize: NSFont.smallSystemFontSize)
                    .appendSeparator()
            }
        }
        
        issueItemTitle.appendNewLine()
        
        let approvedByMe = pull.node.reviews.edges.contains{ $0.node.author?.login == Defaults[.githubUsername] }
        issueItemTitle
            .appendIcon(iconName: "check-circle", color: approvedByMe ? NSColor(named: "green")! : NSColor.secondaryLabelColor)
            .appendString(string: " " + String(pull.node.reviews.totalCount))
            .appendSeparator()
            .appendString(string: "+" + String(pull.node.additions ?? 0), color: NSColor(named: "green")!)
            .appendString(string: " -" + String(pull.node.deletions ?? 0), color: NSColor(named: "red")!)
            .appendSeparator()
            .appendIcon(iconName: "calendar")
            .appendString(string: pull.node.createdAt.getElapsedInterval())
        
        if Defaults[.showAvatar] {
            // Set default image initially
            let defaultImage = NSImage(named: "person")!
            let resizedDefaultImage = resizeImage(image: defaultImage, size: NSSize(width: 36.0, height: 36.0))
            issueItem.image = resizedDefaultImage
            
            // Load avatar asynchronously if available
            if let author = pull.node.author, let imageURL = author.avatarUrl {
                NSImage.loadImageAsync(fromURL: imageURL) { loadedImage in
                    guard let loadedImage = loadedImage else { return }
                    
                    loadedImage.cacheMode = NSImage.CacheMode.always
                    let resizedImage = self.resizeImage(image: loadedImage, size: NSSize(width: 36.0, height: 36.0))
                    issueItem.image = resizedImage
                }
            }
        }
        
        
        if let commits = pull.node.commits {
            
            if let checkSuites = commits.nodes[0].commit.checkSuites {
                
                if checkSuites.nodes.count > 0 {
                    issueItem.submenu = NSMenu()
                    issueItemTitle
                        .appendSeparator()
                        .appendIcon(iconName: "checklist", color: NSColor.secondaryLabelColor)
                }
                for checkSuite in checkSuites.nodes {
                    
                    if checkSuite.checkRuns.nodes.count > 0 {
                        issueItem.submenu?.addItem(withTitle: checkSuite.app?.name ?? "empty", action: nil, keyEquivalent: "")
                    }
                    for check in checkSuite.checkRuns.nodes {
                        
                        let buildItem = NSMenuItem(title: check.name, action: #selector(self.openLink), keyEquivalent: "")
                        buildItem.representedObject = check.detailsUrl
                        buildItem.toolTip = check.conclusion
                        if check.conclusion  == "SUCCESS" {
                            buildItem.image = NSImage(named: "check-circle-fill")!.tint(color: NSColor(named: "green")!)
                            issueItemTitle.appendIcon(iconName: "dot-fill", color: NSColor(named: "green")!)
                        } else if check.conclusion  == "FAILURE" {
                            buildItem.image = NSImage(named: "x-circle-fill")!.tint(color: NSColor(named: "red")!)
                            issueItemTitle.appendIcon(iconName: "dot-fill", color: NSColor(named: "red")!)
                        } else if check.conclusion  == "ACTION_REQUIRED" {
                            buildItem.image = NSImage(named: "issue-draft")!.tint(color: NSColor(named: "yellow")!)
                            issueItemTitle.appendIcon(iconName: "dot-fill", color: NSColor(named: "yellow")!)
                        } else {
                            buildItem.image = NSImage(named: "question")!.tint(color: NSColor.gray)
                            issueItemTitle.appendIcon(iconName: "dot-fill", color: NSColor.gray)
                        }
                        
                        issueItem.submenu?.addItem(buildItem)
                    }
                }
            }
            
            else if let statusCheckRollup = commits.nodes[0].commit.statusCheckRollup {
                
                if statusCheckRollup.contexts.nodes.count > 0 {
                    issueItem.submenu = NSMenu()
                    issueItemTitle
                        .appendSeparator()
                        .appendIcon(iconName: "checklist", color: NSColor.secondaryLabelColor)
                }
                
                for check in statusCheckRollup.contexts.nodes {
                    let itemTitle = NSMutableAttributedString()
                    itemTitle.appendString(string: check.name ?? check.context ?? "<empty>", color: NSColor(.primary))
                    itemTitle.appendNewLine()
                        .appendString(string: check.description ?? check.title ?? "<empty>", color: NSColor(.secondary))
                    
                    let buildItem = NSMenuItem(title: "", action: #selector(AppDelegate.openLink), keyEquivalent: "")
                    buildItem.attributedTitle = itemTitle
                    
                    buildItem.representedObject = check.detailsUrl ?? URL.init(string:check.targetUrl ?? "")
                    
                    buildItem.toolTip = check.conclusion ?? check.state ?? ""
                    
                    let status = check.conclusion ?? check.state ?? ""
                    switch status {
                    case "SUCCESS":
                        buildItem.image = NSImage(named: "check-circle-fill")!.tint(color: NSColor(named: "green")!)
                        issueItemTitle.appendIcon(iconName: "dot-fill", color: NSColor(named: "green")!)
                    case "FAILURE":
                        buildItem.image = NSImage(named: "x-circle-fill")!.tint(color: NSColor(named: "red")!)
                        issueItemTitle.appendIcon(iconName: "dot-fill", color: NSColor(named: "red")!)
                    case "PENDING":
                        buildItem.image = NSImage(named: "issue-draft")!.tint(color: NSColor(named: "yellow")!)
                        issueItemTitle.appendIcon(iconName: "dot-fill", color: NSColor(named: "yellow")!)
                    default:
                        buildItem.image = NSImage(named: "question")!.tint(color: NSColor.gray)
                        issueItemTitle.appendIcon(iconName: "dot-fill", color: NSColor.gray)
                        
                    }
                    issueItem.submenu?.addItem(buildItem)
                }
            }
        }
        
        issueItem.attributedTitle = issueItemTitle
        if pull.node.title.count > 50 {
            issueItem.toolTip = pull.node.title
        }
        issueItem.representedObject = pull.node.url
        
        return issueItem
    }
    
    func addMenuFooterItems() {
        self.menu.addItem(withTitle: "Refresh", action: #selector(self.refreshMenu), keyEquivalent: "")
        self.menu.addItem(.separator())
        self.menu.addItem(withTitle: "Preferences...", action: #selector(self.openPrefecencesWindow), keyEquivalent: "")
        // Remove for app store release
//        self.menu.addItem(withTitle: "Check for updates...", action: #selector(self.checkForUpdates), keyEquivalent: "")
        self.menu.addItem(withTitle: "About PullBar", action: #selector(self.openAboutWindow), keyEquivalent: "")
        self.menu.addItem(withTitle: "Quit", action: #selector(self.quit), keyEquivalent: "")
    }
    
    @objc
    func openPrefecencesWindow(_: NSStatusBarButton?) {
        NSLog("Open preferences window")
        let contentView = PreferencesView()
        if preferencesWindow != nil {
            preferencesWindow.close()
        }
        preferencesWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
            styleMask: [.closable, .titled],
            backing: .buffered,
            defer: false
        )
        
        preferencesWindow.title = "Preferences"
        preferencesWindow.contentView = NSHostingView(rootView: contentView)
        preferencesWindow.makeKeyAndOrderFront(nil)
        preferencesWindow.styleMask.remove(.resizable)
        
        // allow the preference window can be focused automatically when opened
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        let controller = NSWindowController(window: preferencesWindow)
        controller.showWindow(self)
        
        preferencesWindow.center()
        preferencesWindow.orderFrontRegardless()
    }
    
    @objc
    func openAboutWindow(_: NSStatusBarButton?) {
        NSLog("Open about window")
        let contentView = AboutView()
        if aboutWindow != nil {
            aboutWindow.close()
        }
        aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 500),
            styleMask: [.closable, .titled],
            backing: .buffered,
            defer: false
        )
        
        aboutWindow.title = "About"
        aboutWindow.contentView = NSHostingView(rootView: contentView)
        aboutWindow.makeKeyAndOrderFront(nil)
        aboutWindow.styleMask.remove(.resizable)
        
        // allow the preference window can be focused automatically when opened
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        let controller = NSWindowController(window: aboutWindow)
        controller.showWindow(self)
        
        aboutWindow.center()
        aboutWindow.orderFrontRegardless()
    }
    
    @objc
    func windowClosed(notification: NSNotification) {
        let window = notification.object as? NSWindow
        if let windowTitle = window?.title {
            if (windowTitle == "Preferences") {
                timer?.invalidate()
                timer = Timer.scheduledTimer(
                    timeInterval: Double(Defaults[.refreshRate] * 60),
                    target: self,
                    selector: #selector(refreshMenu),
                    userInfo: nil,
                    repeats: true
                )
                timer?.fire()
            }
        }
    }
    
    @objc
    func quit() {
        NSLog("User click Quit")
        NSApplication.shared.terminate(self)
    }
    
    @objc
    func checkForUpdates(_: NSStatusBarButton?) {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        ghClient.getLatestRelease { latestRelease in
            if let latestRelease = latestRelease {
                let versionComparison = currentVersion.compare(latestRelease.name.replacingOccurrences(of: "v", with: ""), options: .numeric)
                if versionComparison == .orderedAscending {
                    self.downloadNewVersionDialog(link: latestRelease.assets[0].browserDownloadUrl)
                } else {
                    self.dialogWithText(text: "You have the latest version installed!")
                }
            }
        }
    }
    
    func dialogWithText(text: String) -> Void {
        let alert = NSAlert()
        alert.messageText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    func downloadNewVersionDialog(link: String) -> Void {
        let alert = NSAlert()
        alert.messageText = "New version is available!"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        let pressedButton = alert.runModal()
        if (pressedButton == .alertFirstButtonReturn) {
            NSWorkspace.shared.open(URL(string: link)!)
        }
    }
    
    /// Resizes an NSImage to the specified size
    func resizeImage(image: NSImage, size: NSSize) -> NSImage {
        if image.size.height == size.height && image.size.width == size.width {
            return image
        }
        
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                  from: NSRect(origin: .zero, size: image.size),
                  operation: .sourceOver,
                  fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}
