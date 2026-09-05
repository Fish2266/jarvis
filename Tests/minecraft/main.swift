import AppKit

// "open minecraft" routing to the game rather than to the launcher that started
// it. The half that can be pinned down offline is which command this is and
// what you asked for — whether the game is up is the machine's business, and
// the last section checks only what stays true either way.

var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

print("=== which commands this applies to ===")
for path in ["/Users/x/Desktop/Prism Launcher.app", "/Applications/MultiMC.app",
             "/Applications/ATLauncher.app", "/Applications/Minecraft.app"] {
    check("\((path as NSString).lastPathComponent) is a launcher",
          Minecraft.isLauncher(path: path))
}
// Every other command opens its app the way it always did — the redirect can
// only ever fire on the one command that points at a launcher.
for path in ["/Applications/Xcode.app", "/Applications/Google Chrome.app",
             "/Applications/Minecraft Bedrock Launcher.app", ""] {
    check("\"\((path as NSString).lastPathComponent)\" is not",
          !Minecraft.isLauncher(path: path))
}

print("\n=== naming the launcher asks for the launcher ===")
let prism = "/Users/x/Desktop/Prism Launcher.app"
// Mid-game is exactly when you'd say these: you want the instance list, not
// the world you can already see.
for said in ["open prism", "launch prism launcher", "open the launcher",
             "jarvis, fire up prism"] {
    check("\"\(said)\" -> the launcher", Minecraft.namedLauncher(in: said, path: prism))
}
// And these are the ones that mean the game.
for said in ["open minecraft", "start up the craft", "play minecraft",
             "bring over minecraft", "quit minecraft", ""] {
    check("\"\(said)\" -> the game", !Minecraft.namedLauncher(in: said, path: prism))
}
// Mojang's own launcher is called Minecraft, so matching its name would turn
// the redirect off for every sentence that could ask for it.
check("\"open minecraft\" with Minecraft.app still means the game",
      !Minecraft.namedLauncher(in: "open minecraft", path: "/Applications/Minecraft.app"))

print("\n=== the seeded command ===")
_ = AppIndex.shared.refresh()
let seeded = Macro.seeded().first { $0.name == "Minecraft" }
if let seeded {
    check("points at a launcher", Minecraft.isLauncher(path: seeded.target), seeded.target)
    check("says so in the editor", seeded.subtitle.contains("the game"), seeded.subtitle)
    let resolved = ["open minecraft", "start up the craft", "play minecraft", "open prism"]
        .map { Resolver.resolveFast(transcript: $0, macros: [seeded])?.macro.name }
    check("still resolves the way it always did",
          resolved.allSatisfy { $0 == "Minecraft" }, "\(resolved)")
} else {
    print("SKIP  no launcher installed, so no command was seeded")
}

print("\n=== finding the game ===")
// Whether anything is running depends on the Mac this runs on, so the only
// thing asserted is the mistake that would matter: handing back the launcher
// would make "open minecraft" a no-op that looks like a hang.
let game = Minecraft.running()
check("never mistakes a launcher for the game",
      game?.bundleIdentifier?.hasPrefix("org.prismlauncher") != true
      && game?.bundleIdentifier != "com.mojang.minecraftlauncher",
      game?.bundleIdentifier ?? "nothing running")
if let game {
    print("      found: pid \(game.processIdentifier), \(game.localizedName ?? "?")")
} else {
    print("      the game isn't running, so \"open minecraft\" opens the launcher")
}

print(failures == 0 ? "\nall good" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
