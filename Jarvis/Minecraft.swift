import AppKit

/// Telling the game apart from the launcher that starts it.
///
/// "open minecraft" is two commands wearing one name. Before you're in a world
/// it means the launcher — Prism, or whichever one is installed — because that
/// is where the instance gets picked. Once the game is up it means the game:
/// putting the launcher's window in front of the world you're standing in is
/// the one thing the command can't have meant.
///
/// The game is not discoverable the ordinary way, and that is the whole reason
/// this file exists. Every launcher starts it as a bare `java` process, so it
/// has no bundle identifier and LaunchServices calls it "java" — nothing that
/// matches on a path or an id can find it, `Spaces.runningApp(atPath:)`
/// included. What it does have is a command line, and the command line always
/// names Minecraft: the client jar sits on the classpath under
/// `com/mojang/minecraft/<version>/` whichever launcher, mod loader or version
/// put it there. So the version is never mentioned here — 26.2 and 1.8.9 look
/// identical to everything below.
enum Minecraft {

    /// Launcher app names, in the order they're preferred when seeding the
    /// command. This list is also what decides whether a command *is* the
    /// Minecraft one: point it somewhere else in the editor and none of the
    /// routing below applies to it.
    static let launcherNames = ["Prism Launcher", "MultiMC", "ATLauncher", "Minecraft"]

    /// `Minecraft.app` is Mojang's *launcher*, not the game. Opening it is
    /// already what the command does, so it must never be mistaken for the
    /// thing the command should be redirected to.
    private static let launcherBundleID = "com.mojang.minecraftlauncher"

    /// A server has a window and a `minecraft_server.jar`, so it says Minecraft
    /// as loudly as the client does. Switching to one when you asked to play
    /// would be worse than not finding the game at all.
    private static let serverMarkers = [
        "minecraft_server", "server.jar", "net.minecraft.server", "nogui",
    ]

    // MARK: - Which command this is

    /// Whether the app at `path` is a Minecraft launcher.
    static func isLauncher(path: String) -> Bool {
        let name = displayName(at: path)
        guard !name.isEmpty else { return false }
        return launcherNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether you asked for the launcher by name — "open prism", "open the
    /// launcher" — which is a request for the launcher even mid-game, since
    /// mid-game is exactly when you'd be asking for it. Picking a different
    /// instance is a thing you do while one is already running.
    ///
    /// Deliberately dead when the launcher *is* `Minecraft.app`: its name is
    /// the same word every one of these commands says, and matching it there
    /// would turn the redirect off for everybody using Mojang's launcher.
    static func namedLauncher(in heard: String, path: String) -> Bool {
        let name = PhraseMatcher.normalize(displayName(at: path))
        guard !name.isEmpty, name != "minecraft" else { return false }
        let said = Set(PhraseMatcher.normalize(heard).split(separator: " "))
        return name.split(separator: " ").contains { said.contains($0) }
    }

    private static func displayName(at path: String) -> String {
        guard !path.isEmpty else { return "" }
        let base = (path as NSString).lastPathComponent
        return base.hasSuffix(".app") ? String(base.dropLast(4)) : base
    }

    // MARK: - Finding the game

    /// The running game, or nil if only the launcher is up — or nothing is, in
    /// which case the ordinary open goes ahead untouched.
    static func running() -> NSRunningApplication? {
        // Only apps with a Dock tile are considered, and that one test does
        // most of the work: a launcher spawns helper JVMs alongside the game —
        // a mod's crash reporter, an auth listener — and every one of them is
        // background-only, so they're ruled out before a single command line
        // is read.
        let games = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && isGame($0)
        }
        guard !games.isEmpty else { return nil }

        // Two instances at once is rare but not strange — a modded world and a
        // vanilla one — and the one you're looking at is the one you mean.
        if let front = NSWorkspace.shared.frontmostApplication,
           games.contains(where: { $0.processIdentifier == front.processIdentifier }) {
            return front
        }
        return games.first
    }

    private static func isGame(_ app: NSRunningApplication) -> Bool {
        // A real Minecraft bundle: Bedrock from the App Store, or anything else
        // Mojang ships as an app rather than as a pile of jars.
        if let id = app.bundleIdentifier {
            return id.hasPrefix("com.mojang.") && id != launcherBundleID
        }
        // Otherwise it has to be a JVM whose arguments say Minecraft. Both
        // halves matter: "java" alone is any Java app on the Mac, and the
        // arguments alone would match a text editor with a mod open.
        guard let exe = app.executableURL?.lastPathComponent,
              exe == "java" || exe == "javaw",
              let args = arguments(of: app.processIdentifier)?.lowercased(),
              args.contains("minecraft")
        else { return false }
        return !serverMarkers.contains { args.contains($0) }
    }

    /// One process's argument vector, joined with spaces, or nil if it can't be
    /// read — which is what happens for anything running as another user, and
    /// is a fine answer: it wasn't your game.
    ///
    /// `KERN_PROCARGS2` returns a single buffer holding the argument count, the
    /// executable path, then argv and the environment, all NUL-separated. Only
    /// argv is wanted. The environment is full of paths that say nothing about
    /// what was run, and searching it would find Minecraft in any process
    /// started from a shell that happened to have `MINECRAFT_*` set.
    private static func arguments(of pid: pid_t) -> String? {
        let header = MemoryLayout<Int32>.size
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > header else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > header else { return nil }

        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0 else { return nil }

        // The executable path is first and is padded with extra NULs, so
        // dropping the first field and then taking argc of them lands on argv
        // without having to know how much padding there was.
        var fields = buffer[header..<size].split(separator: 0, omittingEmptySubsequences: true)
        guard !fields.isEmpty else { return nil }
        fields.removeFirst()
        return fields.prefix(argc)
            .compactMap { String(bytes: $0, encoding: .utf8) }
            .joined(separator: " ")
    }
}
