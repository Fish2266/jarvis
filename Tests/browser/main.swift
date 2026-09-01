import Foundation
import AppKit

var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

print("=== Chrome discovery ===")
check("Chrome is installed", Browser.isChromeInstalled, Browser.chromeURL()?.path ?? "nil")

let profiles = Browser.chromeProfiles()
print("\n=== profiles parsed from Local State ===")
for p in profiles { print("  dir=\(p.directory)  name=\(p.name)  label=\(p.label)") }
check("found at least two profiles", profiles.count >= 2, "\(profiles.count)")
check("Default is present", profiles.contains { $0.directory == "Default" })
check("Profile 1 is present", profiles.contains { $0.directory == "Profile 1" })
check("Chrome's own ordering is preserved", profiles.first?.directory == "Default",
      profiles.first?.directory ?? "nil")
check("names resolve", Browser.profileName(for: "Default") != nil,
      Browser.profileName(for: "Default") ?? "nil")
check("unknown directory resolves to nil", Browser.profileName(for: "Profile 99") == nil)
check("nil profile resolves to nil", Browser.profileName(for: nil) == nil)

print("\n=== macro round-trips through JSON (old macros must still decode) ===")
// A macro saved before chromeProfile existed.
let legacy = #"[{"id":"11111111-1111-1111-1111-111111111111","name":"Gmail","phrases":["gmail"],"kind":"url","target":"https://mail.google.com","enabled":true}]"#
if let decoded = try? JSONDecoder().decode([Macro].self, from: Data(legacy.utf8)) {
    check("legacy macro decodes", decoded.count == 1)
    check("legacy macro has no profile", decoded[0].chromeProfile == nil)
} else {
    check("legacy macro decodes", false, "decode threw")
}

var m = Macro(name: "YouTube", phrases: ["youtube"], kind: .url, target: "https://youtube.com")
m.chromeProfile = "Profile 1"
let data = try! JSONEncoder().encode([m])
let back = try! JSONDecoder().decode([Macro].self, from: data)
check("profile survives a save/load round trip", back[0].chromeProfile == "Profile 1",
      back[0].chromeProfile ?? "nil")
check("subtitle shows the profile", back[0].subtitle.contains("Connor") || back[0].subtitle.contains("·"),
      back[0].subtitle)

// MARK: - Picking which open tab a command should jump to

let school = "student@school.edu"
let personal = "someone@gmail.com"

func tab(_ window: Int, _ index: Int, _ url: String, _ title: String) -> Browser.OpenTab {
    Browser.OpenTab(windowID: window, tabIndex: index, url: url, title: title)
}

print("\n=== unpinned commands take the first match ===")
let anySchoology = [tab(1, 2, "https://school.schoology.com/home", "Schoology")]
check("jumps to the open tab", Browser.pickTab(from: anySchoology, profileEmail: nil,
                                               otherEmails: [school, personal]) == anySchoology[0])
check("nothing open means nothing to jump to",
      Browser.pickTab(from: [], profileEmail: nil, otherEmails: []) == nil)
check("empty profile email counts as unpinned",
      Browser.pickTab(from: anySchoology, profileEmail: "", otherEmails: []) == anySchoology[0])

print("\n=== a title naming the account settles it ===")
// Signed-in Google pages put the address in the title, which is the one place
// Chrome leaks which profile a window belongs to.
let bothInboxes = [
    tab(2, 1, "https://mail.google.com/mail/u/0/#inbox", "Inbox (7) - \(personal) - Gmail"),
    tab(1, 1, "https://mail.google.com/mail/u/0/#inbox", "Inbox (2) - \(school) - School Mail"),
]
check("school Gmail skips past the personal inbox",
      Browser.pickTab(from: bothInboxes, profileEmail: school,
                      otherEmails: [personal])?.windowID == 1)
check("personal Gmail skips past the school inbox",
      Browser.pickTab(from: bothInboxes, profileEmail: personal,
                      otherEmails: [school])?.windowID == 2)
check("account match is case-insensitive",
      Browser.pickTab(from: [tab(1, 1, "https://mail.google.com/", "Inbox - STUDENT@SCHOOL.EDU - Mail")],
                      profileEmail: school, otherEmails: [personal])?.windowID == 1)

print("\n=== a tab signed into the other account is refused, not guessed at ===")
let onlyPersonalInbox = [bothInboxes[0]]
check("school Gmail will not land in the personal inbox",
      Browser.pickTab(from: onlyPersonalInbox, profileEmail: school, otherEmails: [personal]) == nil)
check("personal Gmail will not land in the school inbox",
      Browser.pickTab(from: [bothInboxes[1]], profileEmail: personal, otherEmails: [school]) == nil)

print("\n=== titles that name no account fall back to being unambiguous ===")
// Schoology, Drive and YouTube never print an address, so one copy is safe and
// two copies might be two profiles.
check("one open Schoology tab is unambiguous",
      Browser.pickTab(from: anySchoology, profileEmail: school,
                      otherEmails: [personal])?.windowID == 1)
let twoWindows = [
    tab(1, 2, "https://school.schoology.com/home", "Schoology"),
    tab(5, 4, "https://school.schoology.com/courses", "Schoology"),
]
check("the same page in two windows is declined",
      Browser.pickTab(from: twoWindows, profileEmail: school, otherEmails: [personal]) == nil)
let twoTabsOneWindow = [
    tab(1, 2, "https://school.schoology.com/home", "Schoology"),
    tab(1, 6, "https://school.schoology.com/courses", "AP Calculus | Schoology"),
]
check("two copies in one window is still unambiguous",
      Browser.pickTab(from: twoTabsOneWindow, profileEmail: school,
                      otherEmails: [personal])?.tabIndex == 2)
check("a YouTube handle in a title is not read as an account",
      Browser.pickTab(from: [tab(3, 1, "https://www.youtube.com/watch", "Trailer — @somechannel")],
                      profileEmail: personal, otherEmails: [school])?.windowID == 3)

print("\n=== the wrong-account tab does not poison a good one ===")
let mixed = [
    tab(2, 1, "https://drive.google.com/drive/home", "Home - Google Drive - \(personal)"),
    tab(1, 4, "https://drive.google.com/drive/home", "Home - Google Drive"),
]
check("falls through to the account-less copy",
      Browser.pickTab(from: mixed, profileEmail: school, otherEmails: [personal])?.windowID == 1)
check("a profile with no known address still uses the one-window rule",
      Browser.pickTab(from: twoWindows, profileEmail: nil, otherEmails: []) != nil)

print("\n=== parsing what Chrome reports ===")
let raw = "1570389914\t2\thttps://school.schoology.com/home\tAP Calculus | Schoology\n"
    + "1570389974\t5\thttps://www.youtube.com/\t(11) YouTube\n"
let parsed = Browser.parseTabs(raw)
check("both lines parse", parsed.count == 2, "\(parsed.count)")
check("window id survives", parsed.first?.windowID == 1570389914)
check("tab index survives", parsed.first?.tabIndex == 2)
check("url survives", parsed.first?.url == "https://school.schoology.com/home")
check("title survives", parsed.first?.title == "AP Calculus | Schoology", parsed.first?.title ?? "nil")
check("a title containing a tab keeps its first field",
      Browser.parseTabs("7\t1\thttps://x.test/\ta\tb").first?.title == "a\tb")
check("malformed lines are dropped", Browser.parseTabs("garbage\nx\ty\n").isEmpty)
check("an empty reply parses to nothing", Browser.parseTabs("").isEmpty)

print("\n\(failures == 0 ? "ALL BROWSER TESTS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
