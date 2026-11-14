import Foundation
import YardletRemote

/// The fixture's browser tabs (§15.25): "Publish the release notes" waits on a sign-in page handed to the person, which
/// takes clicks, typing and keys as a page would (the username shows, the password as dots, Sign in checks that both
/// are there), and a second tab of the same task holds a static page whose site asks for the camera and microphone, as
/// a permission prompt the phone answers (its number past 2^53, as Chromium's media prompts have). A phone that asks for
/// its own size (`viewport`) gets the pages laid out at it. ⌘C (`Meta+c`) in the username field copies it for the phone
/// (`tabCopied`) and ⌘X cuts it; in the password field neither copies anything. Nothing typed is kept but the username
/// and the password's length.
struct RemoteFixtureTabs {
    enum Field: Equatable {
        case username
        case password
    }

    static let signInTab = "0F1E7AB1-0000-4000-8000-00000000007A"
    static let docsTab = "0F1E7AB2-0000-4000-8000-00000000007B"
    static let firstPermission = RemoteTabPermission(prompt: (1 << 62) | 1, origin: "https://docs.github.com",
                                                     permissions: ["camera", "microphone"])
    /// The pages' size in CSS pixels when no one asks for another, drawn one pixel per CSS pixel.
    static let viewport = (width: 640, height: 400)
    /// The size a watching phone asked for, which the pages are laid out at while it watches.
    var size = RemoteFixtureTabs.viewport

    var username = ""
    var passwordLength = 0
    var focus: Field?
    var signedIn = false
    var refused = false
    /// The front tab of the task's panel.
    var front = signInTab
    /// The static page's permission prompt until it is answered (`askAgain` brings another).
    var permission: RemoteTabPermission? = RemoteFixtureTabs.firstPermission

    /// The task's tabs, the sign-in page handed over while `handoff` waits.
    func listed(handoff: (requestID: String, reason: String)?) -> [RemoteBrowserTab] {
        [
            RemoteBrowserTab(tabId: Self.docsTab, title: "Managing releases in a repository - GitHub Docs",
                             url: "https://docs.github.com/en/repositories/releasing-projects-on-github",
                             active: front == Self.docsTab ? true : nil, waiting: permission == nil ? nil : "permission",
                             permission: permission),
            RemoteBrowserTab(tabId: Self.signInTab, title: signedIn ? "New release · acme/web" : "Sign in to GitHub · GitHub",
                             url: signedIn ? "https://github.com/acme/web/releases/new" : "https://github.com/login",
                             active: front == Self.signInTab ? true : nil, canGoBack: true,
                             waiting: handoff == nil ? nil : "handoff", requestId: handoff?.requestID, reason: handoff?.reason,
                             passwordField: focus == .password ? true : nil)
        ]
    }

    // MARK: - Input

    /// What the input changed: the page's picture, its list entry (title, password focus), or nothing.
    struct Change: OptionSet {
        let rawValue: Int
        static let picture = Change(rawValue: 1)
        static let list = Change(rawValue: 2)
    }

    private typealias Box = (x: Int, y: Int, width: Int, height: Int)
    /// The form's column, centered and at most 300 wide.
    private var column: (x: Int, width: Int) {
        let width = min(300, size.width - 40)
        return ((size.width - width) / 2, width)
    }
    private var usernameBox: Box { (column.x, 130, column.width, 30) }
    private var passwordBox: Box { (column.x, 190, column.width, 30) }
    private var button: Box { (column.x, 240, column.width, 32) }

    private func inside(_ box: Box, _ x: Double, _ y: Double) -> Bool {
        x >= Double(box.x) && x < Double(box.x + box.width) && y >= Double(box.y) && y < Double(box.y + box.height)
    }

    mutating func input(_ input: RemoteTabInput, on tabID: String) -> Change {
        guard tabID == Self.signInTab else { return [] }
        let before = (focus, signedIn)
        switch input.kind {
        case .click, .mouse:
            guard input.kind == .click || input.action == "down", let x = input.x, let y = input.y, !signedIn else { return [] }
            if inside(usernameBox, x, y) {
                focus = .username
            } else if inside(passwordBox, x, y) {
                focus = .password
            } else if inside(button, x, y) {
                submit()
            } else {
                focus = nil
            }
        case .text:
            guard !signedIn else { return [] }
            let text = (input.text ?? "").filter { !$0.isNewline }
            switch focus {
            case .username: username = String((username + text).prefix(30))
            case .password: passwordLength = min(30, passwordLength + text.count)
            case nil: return []
            }
            refused = false
        case .key:
            switch input.key {
            case "Backspace":
                if focus == .username, !username.isEmpty { username.removeLast() }
                if focus == .password { passwordLength = max(0, passwordLength - 1) }
            case "Tab": focus = focus == .username ? .password : .username
            case "Enter": submit()
            default: return []
            }
        case .navigate where input.action == "reload":
            username = ""
            passwordLength = 0
            focus = nil
            refused = false
        case .scroll, .navigate:
            return []
        }
        var change: Change = .picture
        if before.0 != focus || before.1 != signedIn { change.insert(.list) }
        return change
    }

    /// What ⌘C or ⌘X copies for the phone: the username field's text, never the password's.
    mutating func copy(_ input: RemoteTabInput, on tabID: String) -> String? {
        guard tabID == Self.signInTab, input.kind == .key, ["Meta+c", "Meta+x"].contains(input.key ?? ""),
              !signedIn, focus == .username, !username.isEmpty else { return nil }
        let copied = username
        if input.key == "Meta+x" { username = "" }
        return copied
    }

    private mutating func submit() {
        guard !signedIn else { return }
        if username.isEmpty || passwordLength == 0 {
            refused = true
        } else {
            signedIn = true
            focus = nil
        }
    }

    /// Back to the sign-in page, for the next handoff; the static page's prompt stays as it is.
    mutating func signOut() {
        let permission = permission
        self = RemoteFixtureTabs(size: size, front: front)
        self.permission = permission
    }

    /// The static page asks again, under the next number: an answer to the last one reaches nothing.
    mutating func askAgain(after prompt: Int) {
        permission = RemoteTabPermission(prompt: prompt + 1, origin: Self.firstPermission.origin,
                                         permissions: Self.firstPermission.permissions)
    }

    // MARK: - Pictures

    private enum Color: UInt8 {
        case white, ink, muted, line, header, headerText, accent, button, buttonText, error, field
    }

    private static let palette: [(UInt8, UInt8, UInt8)] = [
        (0xFF, 0xFF, 0xFF), (0x1F, 0x23, 0x28), (0x59, 0x63, 0x6E), (0xD1, 0xD9, 0xE0), (0x24, 0x29, 0x2F),
        (0xFF, 0xFF, 0xFF), (0x09, 0x69, 0xDA), (0x1F, 0x88, 0x3D), (0xFF, 0xFF, 0xFF), (0xCF, 0x22, 0x2E),
        (0xF6, 0xF8, 0xFA)
    ]

    /// The tab's page as PNG, at most `maxWidth` by `maxHeight` pixels.
    func frame(of tabID: String, maxWidth: Int, maxHeight: Int) -> RemoteTabFrame? {
        guard tabID == Self.signInTab || tabID == Self.docsTab else { return nil }
        var picture = RemoteFixturePicture(width: size.width, height: size.height, palette: Self.palette)
        picture.fill(x: 0, y: 0, width: size.width, height: 44, color: Color.header.rawValue)
        picture.text("GitHub", x: 16, y: 14, scale: 2, color: Color.headerText.rawValue)
        if tabID == Self.docsTab {
            drawDocs(&picture)
        } else if signedIn {
            drawSignedIn(&picture)
        } else {
            drawSignIn(&picture)
        }
        let fit = min(1, Double(maxWidth) / Double(size.width), Double(maxHeight) / Double(size.height))
        let scaled = picture.scaled(by: fit)
        return RemoteTabFrame(image: scaled.png, mediaType: "image/png", width: scaled.width, height: scaled.height,
                              viewportWidth: Double(size.width), viewportHeight: Double(size.height))
    }

    private func drawSignIn(_ picture: inout RemoteFixturePicture) {
        picture.centeredText("Sign in to GitHub", y: 66, scale: size.width >= 340 ? 3 : 2, color: Color.ink.rawValue)
        picture.text("Username or email address", x: usernameBox.x, y: usernameBox.y - 18, scale: 1,
                     color: Color.ink.rawValue)
        field(&picture, usernameBox, focused: focus == .username, text: username)
        picture.text("Password", x: passwordBox.x, y: passwordBox.y - 18, scale: 1, color: Color.ink.rawValue)
        field(&picture, passwordBox, focused: focus == .password, text: String(repeating: "*", count: passwordLength))
        picture.fill(x: button.x, y: button.y, width: button.width, height: button.height,
                     color: Color.button.rawValue)
        picture.text("Sign in", x: button.x + (button.width - RemoteFixturePicture.width(of: "Sign in", scale: 2)) / 2,
                     y: button.y + 8, scale: 2, color: Color.buttonText.rawValue)
        if refused {
            picture.centeredText("Enter your username and password.", y: 292, scale: 1, color: Color.error.rawValue)
        }
        picture.centeredText("New to GitHub? Create an account.", y: 330, scale: 1, color: Color.accent.rawValue)
    }

    private func field(_ picture: inout RemoteFixturePicture, _ box: Box, focused: Bool,
                       text: String) {
        picture.fill(x: box.x, y: box.y, width: box.width, height: box.height, color: Color.field.rawValue)
        picture.frame(x: box.x, y: box.y, width: box.width, height: box.height,
                      color: focused ? Color.accent.rawValue : Color.line.rawValue, thickness: focused ? 2 : 1)
        picture.text(text, x: box.x + 8, y: box.y + 8, scale: 2, color: Color.ink.rawValue)
        if focused {
            let caret = box.x + 8 + (text.isEmpty ? 0 : RemoteFixturePicture.width(of: text, scale: 2) + 2)
            picture.fill(x: caret, y: box.y + 6, width: 2, height: 18, color: Color.ink.rawValue)
        }
    }

    private func drawSignedIn(_ picture: inout RemoteFixturePicture) {
        picture.text("acme / web", x: 40, y: 70, scale: 2, color: Color.accent.rawValue)
        picture.text("New release", x: 40, y: 104, scale: 3, color: Color.ink.rawValue)
        picture.text("Signed in as \(username).", x: 40, y: 150, scale: 2, color: Color.ink.rawValue)
        picture.text("The agent can publish the release notes now.", x: 40, y: 184, scale: 1, color: Color.muted.rawValue)
        picture.fill(x: 40, y: 220, width: max(0, size.width - 80), height: 1, color: Color.line.rawValue)
    }

    private func drawDocs(_ picture: inout RemoteFixturePicture) {
        picture.text("Managing releases", x: 40, y: 70, scale: 3, color: Color.ink.rawValue)
        let lines = ["You can create releases to bundle and deliver iterations", "of a project to users.", "",
                     "1. On GitHub, open the main page of the repository.", "2. Click Releases, then Draft a new release.",
                     "3. Choose a tag, write the notes, and publish."]
        for (index, line) in lines.enumerated() {
            picture.text(line, x: 40, y: 120 + index * 22, scale: 1, color: Color.ink.rawValue)
        }
    }
}
