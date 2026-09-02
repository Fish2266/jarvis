# Jarvis

A menu-bar app that listens for **two claps**, then does what you tell it. Opens apps, opens websites, reports the weather — and answers in JARVIS's voice using Apple's on-device model.

The mic is only transcribed for a few seconds after a clap. Nothing is listened to the rest of the time.

## Run it

```bash
cd ~/Desktop/jarvis && ./install.sh
```

Or open `Jarvis.xcodeproj` and hit Run. No Dock icon — look for the clap icon in the menu bar.

macOS will ask for **Microphone** and **Speech Recognition** up front, then **Location** (weather), **Reminders**, and **Automation → Chrome** (reusing an open tab) the first time each is needed. Requires macOS 26 for Apple Intelligence.

## Using it

Clap twice, then say a command. Any of these verbs work interchangeably:

> **open** · **start** · **start up** · **launch** · **fire up** · **boot up** · **run** · **pull up** · **bring up** · **spin up** · **go to** · **take me to**

A second family of verbs goes the other way. **open** takes *you* to the app, switching desktops if it lives on another one. **bring** fetches the app to *you*, moving its windows onto the desktop you are already looking at:

> **bring** · **bring over** · **move over** · **send over** · **pull over** · **drag over** · **gimme**

```
clap clap  "open xcode"                -> switches to Xcode's desktop
clap clap  "bring over xcode"          -> Xcode's windows come to this desktop
clap clap  "bring xcode over here"     -> the same, said the long way
clap clap  "start up the craft"        -> Prism Launcher
clap clap  "open chrome"               -> Google Chrome
clap clap  "jarvis, open my email"     -> Gmail, in the Work profile
clap clap  "open youtube"              -> YouTube, in the Connor profile
clap clap  "wake up daddy's home"      -> Claude
clap clap  "what's it like outside"    -> weather on screen
clap clap  "open a new tab"            -> a fresh tab in the front window
clap clap  "open new tab on personal"  -> a fresh Chrome window, Connor profile
clap clap  "remind me september 3rd at 10am to brush my teeth"
```

### Chrome profiles

Website commands can pin themselves to a Chrome profile, so school and personal stay separate:

| Profile | Commands |
|---|---|
| **Work** — student@school.edu | Gmail, Schoology, Google Drive |
| **Connor** — someone@gmail.com | YouTube, Netflix, Disney Plus |

"Chrome" itself is a command too, with phrases including "new tab" and "new window".

Set it per command with the **Profile** dropdown. "Default browser" means whatever your system browser does, ignoring profiles.

You can also name a profile out loud, which overrides the pinned one:

```
"open chrome on work"          "open chrome with personal"
"open new tab on school"       "open gmail on personal"
```

"work" and "school" both find the Work profile, "personal" finds Connor — matched against the profile's own name first, then its mail domain, so no aliases to configure. If the word doesn't clearly name a profile it's ignored rather than guessed at.

### Reusing an open tab

Say "open gmail" and Gmail is already open, and Jarvis switches to that tab instead of stacking up another copy. Ask for a new one explicitly and it obliges:

```
"open gmail"              -> switches to the open Gmail tab
"open new gmail"          -> new tab
"open a new gmail tab"    -> new tab
"open another netflix tab" -> new tab
```

Matching is by host, plus path prefix when the command's URL has one. Turn it off with **Reuse an open tab** in the menu. This is the one feature that needs Automation permission for Chrome — if you decline, it just opens a new tab every time.

**Reuse only applies to commands with no fixed profile.** Chrome doesn't tell scripts which profile a window belongs to — `given name` is empty, `mode` is just normal/incognito, and the title says nothing — so a matching tab can't be attributed to an account. Rather than risk opening your school site in your personal window, a command pinned to a profile always opens there. If you'd rather have reuse on a particular site, set its Profile to "Default browser".

Only your **four most recently used Chrome windows** are searched. Chrome answers scripting requests slowly once a lot of windows are open — asking about every tab in a twelve-window browser took over three seconds and timed out, while the front four answer in about half a second.

Under the hood this launches `open -n -a "Google Chrome" --args --profile-directory=<dir> <url>`. The `-n` matters: launch arguments only reach a *new* Chrome instance, which then routes the request into the right profile. Without it, a running Chrome just gets activated and the profile flag is silently dropped.

A leading "jarvis" or "hey jarvis" is optional and always stripped.

**Press Escape any time after clapping** to kill the HUD and stop everything in flight — the listener, the model, the voice.

Every app on your Mac already works without setup: 100 were indexed here — including `~/Downloads` — so "open audacity" or "fire up xcode" just work. Macros are for renaming things — teaching it that *"the craft"* means Minecraft.

## Programming your own commands

**Commands…** in the menu (or `⌘,`). Each command has:

- **Name** — what the HUD says. "Minecraft" becomes "Opening Minecraft".
- **Says** — comma-separated phrases. Either a bare target (`the craft`) that pairs with any verb, or a whole catchphrase (`wake up daddy's home`) you say on its own.
- **Action** — open an app, open a website, or report the weather.
- **Profile** — for websites, which Chrome profile to open in. Reads your real profiles out of Chrome, so it lists them by the names you gave them.
- **Target** — an app (there's a **Choose…** picker) or a URL.

The **Says** and **Target** boxes wrap and scroll, so long phrase lists and long URLs stay fully readable.

**Try it now** runs the command immediately so you can check it before relying on it.

## Putting the Mac to sleep

```
"jarvis, sleep"        "jarvis, power down"     "jarvis, night night"
"jarvis, go to bed"    "goodnight"              "lights out"
"time for bed"         "nap time"               "go to sleep"
```

It says goodnight, then sleeps about two and a half seconds later so the line isn't cut off.

**It can only sleep.** There is no shutdown, restart, or log-out anywhere in the app. The action runs `/usr/bin/pmset sleepnow` with `["sleepnow"]` as a literal argument list — no user input reaches it, and it has exactly one call site. The only other process the app ever launches is `/usr/bin/open`, for Chrome.

Three guards keep it from firing by accident:

- **Near-exact matching.** Ordinary commands match loosely, which is why "start up the craft" works. That would also fire on "how do i sleep better", since it contains "sleep". Sleep phrases instead need the whole sentence to match, give or take a typo — so "tell me about sleep", "what time should i go to sleep" and "power down chrome" all leave the Mac awake.
- **A verb in front means you meant something else.** "open sleep" is a request to open an app called Sleep; "bring over sleep" is a request to fetch a window. Neither sleeps the Mac. Sleep phrases are matched against what you said with only "jarvis" removed, so "jarvis, go to sleep" still works while "launch sleep" does not.
- **The model can't reach it.** Sleep commands are withheld from the list Apple Intelligence chooses from, so a misheard question can never put the Mac to sleep. It only happens when you actually say the phrase.

## Reminders

```
"remind me to buy milk"
"remind me in 30 minutes to brush my teeth"
"remind me in an hour to call mom"
"remind me september 3rd at 10am to brush my teeth"
"remind me tomorrow at 5pm to call mom"
"remember to lock the door"
```

The phrase is a **prefix** — everything after it is the reminder. The time can sit anywhere in the sentence, before or after the task, and leftover connectors ("to", "at", "on") get trimmed so the title reads cleanly. No time is fine too.

Two kinds of time are understood:

- **Clock times and dates** — "tomorrow at 5pm", "September 3rd at 10am", "Friday at 9am" — via the system date parser.
- **Durations** — "in 30 minutes", "in an hour", "in half an hour", "in a couple hours", "in 3 days". The system parser doesn't handle these, so they're parsed separately.

Unlike every other command, a dictated one doesn't fire the instant it parses — otherwise "remind me in…" would become a reminder called "in". It waits about a second after you stop talking, and extends the listening window while you're still going.

Add your own trigger phrases, or point it at a specific list, under **Commands…**.

## Voice

**Jarvis speaks with the best voice installed, and picks it automatically** — ranked by quality first, then a British accent, then male, with Apple's novelty voices ("Bubbles", "Bad News") pushed to the bottom.

### Make it sound good

The **Voice** menu lists every voice installed, grouped by quality with a count: Premium, Enhanced, English (compact), Other languages. It re-reads the list each time you open the menu, so a voice you just downloaded shows up without relaunching.

Apple's **Enhanced** and **Premium** voices are a free download, run entirely on-device, and sound dramatically better than the compact ones shipped by default.

**System Settings ▸ Accessibility ▸ Spoken Content ▸ System Voice ▸ Manage Voices** → *English (United Kingdom)* → a voice tagged **Enhanced** or **Premium** (Daniel, Oliver, Malcolm, Jamie, Serena).

> **The Siri voices don't work here.** Downloading "Siri Voice 1–5" changes nothing: macOS reserves those for Siri and VoiceOver and does not expose them to third-party apps through `AVSpeechSynthesisVoice`. They won't appear in Jarvis's list and there's no way around it. Scroll past the Siri section to the language headings.

Nothing to configure afterwards — leave the setting on "Best installed voice" and the app ranks by quality, then British accent, then male. **Voice ▸ Where are my downloaded voices?…** explains all of this in the app.

### Room effects

Speech is synthesised to audio buffers and run through a small AVAudioEngine chain before playing:

- **High-pass at 95 Hz** — clears the rumble compact voices sit on.
- **−2.5 dB at 320 Hz** — takes out the boxiness.
- **+3.5 dB shelf above 4.2 kHz** — presence, so it cuts through.
- **Medium hall reverb at 14% wet** — a room rather than a phone speaker.

Plus slightly slower speech (rate 0.46) and a slightly lower pitch (0.92), because a butler is unhurried. Toggle it with **Voice ▸ Room effects**; **Preview** plays a line.

All local. No account, no API, no per-word cost.

## Asking it things

Anything that sounds like a question, and isn't one of your commands, gets answered out loud:

```
clap clap  "jarvis, how are you?"
clap clap  "what's the capital of France?"
clap clap  "why is the sky blue?"
clap clap  "tell me a joke"
```

Recognised by opener — *what, when, where, why, who, how, which, is, are, was, do, can, could, should, would, if, tell me, explain*. Turn it off with **Answer questions**.

**Commands always win.** The command resolver runs first, so "what's the weather" still hits your instant Weather command and never reaches the model. Only what the resolver can't place is treated as a question. Checking costs **3.4 µs** against the **702 µs** it takes to resolve a command — 0.5%, and only on the path where nothing matched. Opening an app is exactly as fast as before.

Answers take roughly 0.6–2 seconds and are held to two sentences, because you're listening to them rather than reading them. Stage directions, markdown and rambling get stripped before they're spoken.

**The clock is answered from the clock.** "What time is it" and "what day is it" are answered from the system clock instead of the model — asked cold, it confidently invented "2:13 p.m." at half past nine at night. Every other question gets the real date and time handed to it as context.

## How it decides what you meant

Three tiers, ordered so the thing that matters — opening your app — never waits on a model.

| Tier | What | Measured cost | Blocks your app? |
|---|---|---|---|
| 1 | String matching against your commands + installed apps | ~0 ms | **yes, and it's the only one that does** |
| 2 | Apple Intelligence names a target, tier 1 validates it | ~350–580 ms warm | only when tier 1 found nothing |
| 3 | Apple Intelligence writes the spoken reply | ~500–800 ms | **never** — runs after the app already opened |

**Tier 1** handles everything normal. It strips "jarvis", strips the verb, and fuzzy-matches what's left against your phrases and then every installed app.

It waits about **0.6 seconds** after you stop talking before acting (about a second for dictated commands like reminders). That pause isn't laziness: speech arrives a word at a time, and "open chrome" is a complete command right up until it becomes "open chrome on work". Acting on the first thing that parses meant trailing qualifiers were never heard.

**Tier 2** only runs when tier 1 comes back empty, so it costs nothing in the common case. It catches loose phrasing — *"I could go for some blocky building"* → Minecraft, *"check my inbox"* → Gmail. The model is prewarmed on the double clap, so it's hot by the time it's needed (cold, it costs 4+ seconds).

Crucially, the model doesn't pick the action itself — it just **names** what you seem to want, and that name goes back through tier 1's matcher. So it can reach any installed app, not only the commands you've written, and it can't fire something unrelated to the name it gave: if the name matches nothing, nothing happens.

**Tier 3** is pure flavour. The action already ran. The model gets what it just did and what you said, and writes one line in JARVIS's voice, which is spoken and shown under the headline. If it takes too long, drifts long, or asks a question, a canned line is used instead — it can never delay or break anything.

Switch tiers 2 and 3 off entirely with **Use Apple Intelligence**. Everything still works; replies just come from a fixed list.

## The HUD

Clapping brings up a full-screen reticle on every display with a countdown ring for your speaking window. When a command resolves, it snaps to gold with a flash and a particle burst.

The headline is **what it's doing** — "OPENING CLAUDE", "CHECKING THE WEATHER" — never the raw transcript. Weather replaces the headline with the conditions when they land. The JARVIS line appears underneath as it's spoken.

The overlay is click-through and never takes focus. **Preview the HUD** shows the whole sequence without clapping.

## Clap detection

A clap is an impulse: instant attack, broadband, gone inside ~100 ms. Three gates, all of which must pass:

1. **Loud enough** — above an absolute floor *and* above a slow rolling estimate of room noise, so it recalibrates between rooms.
2. **A real attack** — louder than the preceding ~40 ms, not just the slow background. This is what stops the *tail* of a sustained sound from reading as a clap.
3. **It decayed** — every candidate is held 85 ms and confirmed only if energy collapsed below a third of its peak. Speech and music fail here.

Two confirmed claps 90–700 ms apart trigger it.

## Scripting hooks

Bind these to a keyboard shortcut (Shortcuts.app, Raycast, anything that runs a shell command) — handy if you'd rather not clap:

```bash
notifyutil -p com.connorchristopherson.Jarvis.arm       # start listening
notifyutil -p com.connorchristopherson.Jarvis.cancel    # same as Escape
notifyutil -p com.connorchristopherson.Jarvis.trigger   # run the first command
notifyutil -p com.connorchristopherson.Jarvis.commands  # open the editor
notifyutil -p com.connorchristopherson.Jarvis.previewHUD
```

## Weather

Open-Meteo — no account, no API key. Location comes from Location Services, or set fixed coordinates under **Weather ▸** to skip location access entirely. Fahrenheit or Celsius in the same menu.

## Tuning

**Clap Monitor…** shows a live meter, the current threshold, and a log of every sound it took or ignored, plus what it heard and which tier resolved it.

- Nothing registers → raise sensitivity to High.
- *"ignored a loud sound — didn't decay like a clap"* → it heard you, but the sound was too sustained. Sharper claps, or move closer.
- Random triggers → drop to Low.

## Tests

```bash
./Tests/run.sh
```

Offline, no mic or network: clap detection against synthetic audio (real claps, distant claps, sustained noise, speech-like bursts, music with rests, silence), phrase matching, command resolution — every verb, macros, installed-app fallback, a set of conversational phrases that must *not* fire, and a regression case pinning "the craft" to the right launcher — plus Chrome profile discovery and the check that commands saved before profiles existed still load.

```bash
./Tests/run-live.sh
```

Live: Apple Intelligence (both tiers plus the reply sanitiser), a real weather fetch, and an end-to-end pass against the running app — arm, cancel, stand down, trigger. Needs Jarvis running and takes about a minute.

## Notes

- Ad-hoc signed, so macOS may re-ask for microphone access after a rebuild. Signing with your Apple ID team in Xcode's Signing & Capabilities makes it stick.
- Running from Xcode launches a *second* copy alongside the installed one.
- Escape is registered as a global hotkey only while listening, so it isn't swallowed from other apps the rest of the time. It needs no Accessibility permission.
