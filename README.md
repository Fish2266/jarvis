# Jarvis

A menu-bar app that listens for **two claps**, then does what you tell it. Opens apps and websites, searches the web, sets timers, moves windows, works the volume and the music, keeps the Mac awake, reads back your day, reports the weather — and answers in JARVIS's voice using Apple's on-device model.

The mic is only transcribed for a few seconds after a clap. Nothing is listened to the rest of the time.

## Run it

```bash
cd ~/Desktop/jarvis && ./install.sh
```

Or open `Jarvis.xcodeproj` and hit Run. No Dock icon — look for the clap icon in the menu bar.

macOS will ask for **Microphone** and **Speech Recognition** up front, then **Location** (weather), **Reminders**, **Calendar** (reading your day back), and **Automation → Chrome** (reusing an open tab) the first time each is needed. **Accessibility** is optional and covers three things: the desktop-switching gestures, the playback keys, and moving windows. The menu names whichever of them is actually going without. Requires macOS 26 for Apple Intelligence.

## Using it

Clap twice, then say a command. Any of these verbs work interchangeably:

> **open** · **start** · **start up** · **launch** · **fire up** · **boot up** · **run** · **pull up** · **bring up** · **spin up** · **go to** · **take me to**

A second family of verbs goes the other way. **open** takes *you* to the app, switching desktops if it lives on another one. **bring** fetches the app to *you*, moving its windows onto the desktop you are already looking at:

> **bring** · **bring over** · **move over** · **send over** · **pull over** · **drag over** · **gimme**

```
clap clap  "open xcode"                -> switches to Xcode's desktop
clap clap  "bring over xcode"          -> Xcode's windows come to this desktop
clap clap  "bring xcode over here"     -> the same, said the long way
clap clap  "start up the craft"        -> Prism Launcher, or the game if it's running
clap clap  "open chrome"               -> Google Chrome
clap clap  "jarvis, open my email"     -> Gmail, in the Work profile
clap clap  "open youtube"              -> YouTube, in the Connor profile
clap clap  "wake up daddy's home"      -> Claude
clap clap  "what's it like outside"    -> weather on screen
clap clap  "open a new tab"            -> a fresh tab in the front window
clap clap  "open new tab on personal"  -> a fresh Chrome window, Connor profile
clap clap  "remind me september 3rd at 10am to brush my teeth"
clap clap  "quit chrome"               -> asks Chrome to quit
clap clap  "set a timer for ten minutes"
clap clap  "turn it up"                -> volume up a notch
clap clap  "next track"                -> skips whatever is playing
clap clap  "search for how to poach an egg"
clap clap  "what's on my calendar"     -> read out loud
clap clap  "what's fifteen percent of two hundred and forty"
clap clap  "snap left"                 -> the front window takes the left half
clap clap  "stay awake for two hours"
clap clap  "copy that down 0 7 1 double 4 double 6"
clap clap  "lock the screen"
```

### Chrome profiles

Website commands can pin themselves to a Chrome profile, so school and personal stay separate — for example:

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

Only your **six most recently used Chrome windows** are searched. Chrome answers scripting requests slowly once a lot of windows are open — asking about every tab in a twelve-window browser took over three seconds and timed out, while the front few answer in about half a second.

Everything Jarvis asks Chrome goes through AppleScript — which tabs are open, focus this one, make a new window — and **compiling an AppleScript costs 26 ms**, measured. Each request used to be built as a fresh source string with the window id or URL pasted into it, so a single "open gmail" spent 52 ms compiling before it had said a word to Chrome. They are now handlers of one document, compiled once, with the varying parts passed as arguments; a warm call costs 0.1 ms. That is also the safer arrangement, because an argument is *data*: a URL containing a quote or a backslash can no longer break the script or change what it says, and there is no hand-rolled escaping left to get wrong.

Under the hood this launches `open -n -a "Google Chrome" --args --profile-directory=<dir> <url>`. The `-n` matters: launch arguments only reach a *new* Chrome instance, which then routes the request into the right profile. Without it, a running Chrome just gets activated and the profile flag is silently dropped.

A leading "jarvis" or "hey jarvis" is optional and always stripped.

**Press Escape any time after clapping** to kill the HUD and stop everything in flight — the listener, the model, the voice.

**Or just clap again.** A double clap during a command interrupts it and starts a new phrase, whatever was happening — a model still thinking, a reply still being spoken, a camera still watching. It used to be ignored: arming insisted on being idle, and every command parks the app in "on it" for over three seconds afterwards, so for those three seconds Jarvis was deaf to the one gesture that wakes it. Which is exactly when you are most likely to clap again, having got the wrong thing.

Every app on your Mac already works without setup: 100 were indexed here — including `~/Downloads` — so "open audacity" or "fire up xcode" just work. Macros are for renaming things — teaching it that *"the craft"* means Minecraft.

### Minecraft

"open minecraft" means two different things and always has. Before you're in a world it means the launcher — Prism here, and MultiMC, ATLauncher or Mojang's own if that's what's installed — because that is where the instance gets picked. Once the game is up it means the game: dropping the launcher window in front of the world you're standing in is the one thing it can't have meant. So the command checks, and goes wherever you actually meant.

"bring over minecraft" and "quit minecraft" follow it. Saying the launcher's name doesn't — "open prism" is a request for Prism even mid-game, which is when you'd be asking.

Nothing here knows a version number. Every launcher starts the game as a bare `java` process with no bundle identifier and no name but "java", so it can't be found by path or id the way every other app is; it is found by its command line, which names the client jar whatever the version, loader or launcher. 26.2 and 1.8.9 look identical to it.

## Triggering it

Two ways in, and they do the same thing:

- **Double clap.**
- **A keyboard shortcut**, under **Keyboard trigger** in the menu. Default is ⌘J.

The shortcut is a Carbon hot key, the same mechanism Escape uses, so it needs no Accessibility or Input Monitoring permission. But it is registered for as long as Jarvis is enabled rather than for a few seconds after a clap, which means it genuinely takes that combination away from every other app — ⌘J is also Finder's View Options and Xcode's jump bar. Hence ⌥⌘J, ⌃⌘J and ⌥Space as alternatives, and **Off** if you'd rather only clap. Pausing Jarvis hands the combination back.

If another app got there first, registration fails, Jarvis says so, and clapping still works.

## Hand gestures

The same double clap that opens the microphone also opens the camera. Say a command and it behaves exactly as it always has. Say nothing, and it watches your hands instead.

```
clap clap  (say nothing)  pull both hands apart   -> Mission Control
clap clap  (say nothing)  move one hand left      -> the desktop on the right
clap clap  (say nothing)  move one hand right     -> the desktop on the left
```

The directions are the trackpad's, not the mouse's: your hand drags the row of desktops past you, the same way a three-finger swipe does.

The capture session is built a couple of seconds after launch, because opening a camera cold takes several seconds — measured — and that used to come out of the window you had to gesture in. Building a session is not running one: no frames, and the camera indicator stays dark. The window also doesn't start counting until frames actually arrive, so a slow open costs you nothing.

**The camera is only ever on inside that window.** It is off before the clap and off again about eight seconds later — sooner if you say something, sooner still if you gesture. There is no always-on mode and no preview window; the green light coming on is the honest signal that the window is open.

### Voice and hands never both fire

The two halves take turns, and the rule is the same in both directions — **whoever commits first wins, and the other one stops.**

| What happens | Microphone | Camera |
|---|---|---|
| You say a command | resolves and runs it | **off**, immediately |
| You say nothing | gives up after ~6 s | keeps watching for ~8 s |
| You say something it can't place | hands it to the model after ~1 s | keeps watching — this is what gestures are for, and a hand still wins while the model thinks |
| You gesture | **stops listening**, mid-phrase if need be | runs it, stays open ~2.5 s for another |
| Escape | cancels | cancels |

While words are actually arriving the camera stops looking altogether — frames are dropped without being analysed. That mute outlasts the last word by 1.4 seconds, which is deliberately longer than the pause a spoken command waits out before it fires: a phrase that is *about* to resolve always gets there before a hand that happens to be moving can.

After a gesture lands the camera stays open a moment longer, so moving two desktops over is one thought rather than two double claps.

Gestures are quiet in the other sense too: **no spoken reply, no confirmation burst, and the reticle goes the moment one lands** — so the screen is already clear as Mission Control arrives. Nothing flashes up to announce what happened — a gesture should feel like reaching out and moving the desktop yourself, and the desktop moving *is* the feedback. Spoken commands keep their confirmation, because there the HUD is the only thing that tells you it heard you correctly.

### What counts as a gesture

Jarvis keeps a second and a half of where your hands have been, and on every frame asks one question: is there any moment in that trail which, paired with right now, makes a gesture?

That replaced an earlier design that measured from an *anchor* — a spot where your hands had been still for a moment. It was accurate and far too slow. A gesture could not begin until you had first stopped, so clapping and immediately pulling your hands apart was guaranteed to do nothing; worse, if the camera opened while you were already moving there was no still moment left to find, and the gesture was unrecognisable no matter how plainly you made it. Searching the trail costs 0.3 microseconds a frame — a thousandth of one percent of a core — and removes the wait entirely.

- Travel at least **18%** of the frame, and finish inside **1.2 s**. Slower than that is repositioning, not a gesture.
- Move **sideways** — the horizontal distance must beat the vertical by 1.6×, so reaching for your coffee isn't a command.
- Throwing it clean **off the edge of the frame** works. A hand that vanishes within 0.12 of the edge has left the picture rather than stopped dead, so it's measured as having reached the edge — a lower bound on where it actually went, not a guess. Everything else still applies: the same thresholds decide, measured the same way. A hand resting near the edge that blinks out fires nothing.
- For Mission Control, **both** hands do some of the work. One hand sweeping past a hand resting on the desk opens the same gap and is not the same gesture.

Hand detection in an ordinary room is gappy rather than steady, so four things work to keep hold of a hand that Vision keeps losing. The camera runs in its **widest format**: macOS publishes no field of view per format, but the shape gives it away — on Apple's built-in cameras the 16:9 modes are a vertical crop of the same sensor readout the 4:3 modes use whole, so this FaceTime camera's 1760×1328 is the same horizontal field as its default 1920×1080 with about a quarter more of you vertically. The commonest way to lose a gesture is a hand leaving the top or bottom of the picture. It is **pinned to 30 fps**, which caps the exposure with it — in dim light a webcam lengthens its exposure, and a hand moving through a long one arrives as a smear with no skeleton in it, so detection fails exactly when you're gesturing. A hand's position comes from the **wrist and knuckles when they're confident and the average of every joint Vision saw when they're not**, because a hand held at an angle loses precisely those anchor joints while the fingers stay perfectly visible. And the trail survives **0.45 s** of a hand not being seen at all.

A hand may drop out of view for a couple of frames without losing its trail, and so may *one of two* — Vision loses a hand against a busy background constantly, and a pull-apart heads for the edges of the frame where it happens most. Only an absence longer than **0.45 s** starts over.

A change in *how many* hands are up is a different question, and is counted in frames rather than seconds: **four in a row** of a new count before it is believed. Vision blinks for a frame or two, never for four. Crucially the frames are held rather than dropped while it decides, so when the change is believed the new trail starts at the frame the count first changed on — not an eighth of a second later with the opening of the gesture already spent. That matters more than it sounds, because the double clap that opens the camera *is* a change in hand count: hands together, then apart.

What the anchor was really guarding against — a hand crossing half the frame on its way *in* reading as a swipe — is handled directly instead: a hand that first appears **at the edge** of the picture is presumed to still be arriving for 0.35 s. A hand that appears in open frame, because it was already up when the camera opened, is measurable from the instant it is seen. So there is nothing to wait for: clap, and pull your hands apart whenever you like.

### Permissions

Mission Control needs **only the camera**: Jarvis opens `Mission Control.app`, which is a trampoline that tells the Dock to show the overview.

The two desktop swipes need **Accessibility** as well, and there is genuinely no way around it. Three routes were tried on macOS 26 and all three are dead ends:

| Route | Result |
|---|---|
| `SLSManagedDisplaySetCurrentSpace` (private SkyLight) | ignored — the call returns, the desktop does not move |
| `System Events … key code 124` (AppleScript) | *"osascript is not allowed to send keystrokes"* — the caller still needs Accessibility |
| `CGEvent.postToPid(Dock)` (bypasses the HID tap) | delivered, but the space never changes |

So Jarvis synthesises ^← / ^→ through the ordinary event tap, which needs Accessibility — and which also means someone who has turned those shortcuts off in **Keyboard ▸ Shortcuts ▸ Mission Control** gets nothing. Neither case shrugs: without Accessibility the swipes are rerouted to Mission Control rather than landing on a silent no-op, the menu says what is missing, and the Clap Monitor logs every gesture it acted on.

Granting it needs an administrator, because macOS requires one for that pane. **Without it, all three gestures open Mission Control.** A two-handed pull-apart gets read as a one-handed swipe often enough to matter, and a gesture that could only have meant Mission Control landing on a silent no-op looks exactly like the whole feature being broken — so with the swipes unavailable, everything routes to the one thing that works with nothing granted. Better one gesture that always works than three where two do nothing.

The menu shows what is missing, and **Hand gestures after a double clap** turns the whole thing off.

## Programming your own commands

**Commands…** in the menu (or `⌘,`). Each command has:

- **Name** — what the HUD says. "Minecraft" becomes "Opening Minecraft".
- **Says** — comma-separated phrases. Either a bare target (`the craft`) that pairs with any verb, or a whole catchphrase (`wake up daddy's home`) you say on its own.
- **Action** — sixteen of them: open an app, open a website, search the web, report the weather, report tomorrow's forecast, add a reminder, read out your reminders, read out your calendar, set a timer, change the volume, play/pause or skip, move the front window, keep the Mac awake, copy what you say, lock the screen, put the Mac to sleep.
- **Profile** — for websites and searches, which Chrome profile to open in. Reads your real profiles out of Chrome, so it lists them by the names you gave them.
- **Target** — an app (there's a **Choose…** picker), a URL, a search engine, or a Reminders list. The actions that need nothing hide the box entirely.

The **Says** and **Target** boxes wrap and scroll, so long phrase lists and long URLs stay fully readable. The guidance under the form changes with the action, because a phrase means something different for a reminder than for an app.

**Try it now** runs the command immediately so you can check it before relying on it.

Phrases behave one of three ways, depending on the action:

| | How the phrase is matched | Actions |
|---|---|---|
| **Loose** | anywhere in the sentence, fuzzily | apps, websites, weather, forecast, reminders, calendar |
| **A prefix** | at the front, and what follows is the content | add a reminder, search the web |
| **Near-exact** | the whole sentence, give or take a typo | lock, sleep |

Timers, volume and playback are matched loosely and then **read the whole
sentence**: "cancel the timer", "turn it up" and "next track" are one command
each with the detail buried in the words, so the action is handed what you
actually said and works it out. That is what keeps them one command apiece
instead of an action per verb.

New built-in commands reach an existing installation too. Your saved commands
are never re-seeded, so anything added in a later version is offered once,
skipped if you already have one by that name, and never brought back if you
delete it.

### A phrase of one short word will bite you

Worth knowing before you write one, because it cost three bugs to learn.

Matching allows **one typo per word of four letters or more**, and a phrase of a
single word gets full marks for a single fuzzy match. So a one-word phrase fires
on every sentence containing any word one edit away from it — and English has a
lot of those.

`timer` shipped as a phrase, and `time` is one edit from it. Every sentence with
the word "time" in it became a timer, "what time is it" included, and the clock
quietly stopped answering. `pause` did the same through "cause", `skip` through
"ship", and a "stay awake" phrase of `dont sleep` was close enough to "do i
sleep" that *"how do i sleep better"* asked the Mac to stay up.

Two words fixes all of it, because the second one has to be there as well: "set
a timer", "pause it", "skip this". The built-ins are held to that by a test, with
one deliberate exception — "mute", whose neighbours are "mate", "mule" and
"muse", none of which turn up in a sentence you would say to a computer.

The lesson only applies to *short* words. "Chrome", "Netflix" and "caffeinate"
have empty neighbourhoods and are perfectly good on their own.

**This is not the same as containment**, which is deliberate and unchanged: a
command called Drive really is meant to open when you say "drive", so "how do I
drive to work" opens Google Drive. That is the resolver doing its job. A *typo*
match is different — there the word was never said at all.

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

## Timers

```
"set a timer for ten minutes"       "timer for thirty seconds"
"set a timer for half an hour"      "timer for an hour and a half"
"set a timer for two and a half hours"
"how long is left"                  "cancel the timer"
```

A pill appears in the corner of the screen with the time left and a ring that
unwinds. It stays there while you work, turns amber for the last ten seconds,
and flashes when the time is up.

**One timer at a time**, deliberately. Several named timers would need a way to
say which one you meant, a way to show them all, and a way to cancel the right
one — three new things to get wrong for a feature whose whole appeal is that you
say six words and forget about it. Starting a second replaces the first and
Jarvis says so, which is the honest version of a limit rather than a silent one.
The menu shows a running timer and can cancel it without your saying anything.

Nothing polls. The deadline is one timer scheduled once; the ring is a single
Core Animation stroke handed to the GPU at the start and never touched again,
and the only thing on a clock is the digits, which change once a second. A
twenty-minute timer costs twelve hundred label updates and no per-frame work.

Two parsing details worth knowing, because both were wrong first time:
**"half an hour" is thirty minutes** — reading the article as the number one made
it sixty — and **"two and a half hours" adds** rather than replaces, or the half
would eat the two and run for thirty minutes. An amount with no unit after it is
refused rather than guessed at: "timer for five" could mean seconds or minutes,
and picking one silently is how a five-second timer runs for five.

## Volume and playback

```
"turn it up"        "louder"      "volume down"     "quieter"
"mute"              "unmute"      "be quiet"        "max volume"
"set the volume to forty"         "volume sixty percent"
"how loud is it"
```

```
"pause"      "resume"      "next track"      "previous track"      "skip"
```

Volume goes through **CoreAudio directly** — in process, no permission, a read
costs a few microseconds. Not AppleScript's `set volume`, which would mean
compiling and running a script for a number and would go through Apple Events,
the one thing here that needs a permission prompt. An output with no volume
control Jarvis can reach — HDMI and a good many USB interfaces hand volume to
the hardware — says so out loud instead of pretending.

Playback sends the **media key**, the same one on the top row of the keyboard,
so it reaches whatever macOS considers to be playing: Music, Spotify, a video in
a tab, a podcast. One command covers all of them with no per-app Automation
prompt and no list to maintain. The cost is that synthesising any key needs
**Accessibility**, exactly as the desktop-switching gestures do; without it the
command says what is missing rather than silently doing nothing.

There is no bare "play", and that is deliberate: **"play" is already a verb
meaning open**, so "play minecraft" has to keep opening Minecraft. It costs
nothing, because the key macOS sends is a *toggle* — "pause" starts a paused
track as readily as it stops a playing one.

Both read the whole sentence rather than a captured tail, so one command covers
all of a thing instead of an action per verb. Matching is on **whole words, not
substrings**: "up" lives inside "upload" and "play" inside "display", and a
command that pauses your music because you said "display" is worse than one that
misses.

## Searching the web

```
"search for how to poach an egg"     "look up the offside rule"
"google for swift concurrency"       "search the web for tide times"
```

The phrase is a prefix and everything after it is the query. It opens in a new
tab every time — a search is a new question, and landing on the answer to the
last one looks exactly like nothing happening — and honours a Chrome profile the
same way a website command does.

**Engine** in the editor is the search URL the words are added to. Leave it empty
for Google, or paste another site's search URL and the same machinery points at
YouTube or Amazon with no code here knowing about either. Put `%s` in the URL if
the words don't belong on the end.

Queries are escaped as a *query component*, which is stricter than it sounds:
`&`, `=`, `+` and `#` are all legal in a URL and all change what the search engine
receives, so each is escaped rather than passed through. "c# vs f#" searches for
what you said instead of for "c".

**There is deliberately no bare "google" trigger.** It would capture "google
chrome" as a search for "chrome", and opening the browser is what that sentence
has always meant.

## Quitting an app

```
"quit chrome"      "close chrome"      "quit out of xcode"      "kill spotify"
```

The mirror of opening one, and it uses the same matching, so it reaches any
installed app rather than only the commands you have written.

`terminate` is what ⌘Q sends, so an app with unsaved work still gets to put its
own dialog up and win — this asks an app to stop, it does not kill it. Jarvis
declines to quit itself, on the grounds that nothing would then be listening to
be asked to bring it back.

Deliberately no "shut down" or "power off" in the verb list: those belong to the
sentence about the *Mac*, and the one thing worse than a command that doesn't
work is one that works on the wrong noun.

## Moving windows

```
"snap left"        "right half"       "top half"      "bottom half"
"top left"         "bottom right"     "upper right"   "lower left"
"maximize"         "fill the screen"  "full screen"   "centre the window"
```

Moves the window you are looking at — the frontmost app's focused one. Halves,
quarters, the whole visible screen, or full screen proper. Centring keeps the
window's own size and just puts it in the middle.

The only way to move another application's window is the accessibility API, so
this needs the **same grant the desktop-switching gestures do**, and says so when
it hasn't got it. Three details that are not obvious and were each wrong once:

- **Position, then size, then position again.** Not superstition. A window with
  a minimum size clamps the size it is given, and one crossing displays clamps
  the position, so a single pass leaves it somewhere neither asked for.
- **A full-screen window ignores every position it is given**, so it is taken
  out of full screen first — otherwise "put it on the left" looked like the
  command doing nothing at all.
- **Two coordinate systems.** AppKit measures from the bottom left of the
  primary display with y going up; accessibility measures from the top left with
  y going down. One subtraction converts between them, and the height to
  subtract from is always the *primary* display's, however many are attached.

Every request is bounded by a **half-second messaging timeout**, because asking
an app about its windows is a synchronous round trip into that app's run loop —
a beachballing process would otherwise hold the main thread here for as long as
it liked, and this runs while the HUD is animating.

## Staying awake

```
"stay awake"                 "keep the mac awake"      "caffeinate"
"stay awake for two hours"   "keep awake for half an hour"
"stop staying awake"         "you can let it sleep now"
```

The opposite of the sleep command, and the reason both exist: telling a Mac to
sleep is easy, and stopping it is the thing you actually want half way through a
long download. `caffeinate` without the process — the same power-management
assertion, taken in process and released when the time is up, when you say so,
and when Jarvis quits.

Deliberately the *idle system sleep* assertion rather than the display one. This
is for a Mac that must keep working; forcing the screen to stay lit as well would
flatten a laptop for a download that needed neither. The menu shows it while it
is held and can let it go without your saying anything.

## The clipboard

```
"copy that down 0 7 1 double 4 double 6"
"note this down the meeting moved to thursday"
"what's on my clipboard"
```

The one command that is really about *dictation* — everything else Jarvis does
with what you say is work out which action you meant, and this simply keeps the
words. Useful for the thing you want in a minute and don't want to open an app
for: a number read out to you, an address, a line you thought of on the way past.
No permission and nothing written to disk; it is the same clipboard ⌘C uses, so
it is already wherever you were going to paste it.

Read back, a long clipboard is **described rather than recited**. Four hundred
words of copied article read aloud is not an answer to "what's on my clipboard",
so past a sentence or two it says how much there is and reads the beginning.


## Locking the screen

```
"lock the screen"     "lock it up"     "lock my mac"     "lock screen"
```

The same three guards sleeping has, for the same reasons: **near-exact
matching**, so "what's the lock screen shortcut" and "remind me to lock the door"
leave the screen alone; **a verb in front means you meant something else**, so
"open lock" asks to open an app called Lock; and **the model can't reach it**, so
a misheard question can never lock you out.

It calls the same thing the Apple menu's Lock Screen item does, resolved at run
time so a future macOS that stops publishing it fails honestly rather than
crashing. Not `pmset displaysleepnow`, which only locks if your password setting
says "immediately" and otherwise looks like the command silently failing.

Like sleeping, it says the line first and locks a moment later — and **Escape
still stops it**, which is now true of sleeping too.

## Reading back your day

```
"what are my reminders"      "what's on my list"      "what do i have to do"
"what's on my calendar"      "my schedule"            "what's my next meeting"
"am i free"
```

Reminders due today or overdue, and today's remaining calendar events, read out
loud and shown in the strip at the bottom of the screen.

**Read-only, and there is no other kind.** No command in Jarvis can delete a
reminder or move a meeting. Voice recognition is good, not perfect, and the cost
of a misheard "delete" is not symmetrical with the cost of a misheard "read".

Undated reminders are included, which took a second attempt: asking EventKit for
reminders "due before tonight" excludes the ones with no due date at all, and a
list you never dated is still a list of things to do. The range is applied
afterwards instead, where undated can mean "always relevant".

Held to **three items and then a count** — "five reminders, sir: buy milk, call
mum and book the car, and two more". This is spoken aloud, and a fourteen-item
list read out is not information; by item five you have stopped listening. The
count comes first so the number is the thing you hear even if you tune out the
rest.

Reminders reuse the access the reminder command already asked for. The calendar
is a separate grant, asked for the first time you ask about it, and the menu says
so if you decline.


## Voice

**Jarvis speaks with the best voice installed, and picks it automatically** — ranked by quality first, then a British accent, then male, with Apple's novelty voices ("Bubbles", "Bad News") pushed to the bottom.

### Make it sound good

The **Voice** menu lists every voice installed, grouped by quality with a count: Premium, Enhanced, English (compact), Other languages. A voice you just downloaded shows up without relaunching.

Reading that list out of the system costs **119 ms** with the usual 180 voices installed — measured, and not a warm-up cost that goes away. It used to be paid on the main thread before *every spoken line*, on every menu open, and once during launch, which was most of the gap between a reply being written and it being heard. It is now read once and kept: macOS announces when the set of voices changes, and opening the menu also re-checks in the background, so a new download appears either way.

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

**Commands always win.** The command resolver runs first, so "what's the weather" still hits your instant Weather command and never reaches the model. Only what the resolver can't place is treated as a question. Checking costs **2.5 µs** against the **150–700 µs** it takes to resolve a command — well under a percent, and only on the path where nothing matched. Opening an app is exactly as fast as before.

Answers take roughly 0.6–2 seconds and are held to two sentences, because you're listening to them rather than reading them. Stage directions, markdown and rambling get stripped before they're spoken.

**The clock is answered from the clock.** "What time is it" and "what day is it" are answered from the system clock instead of the model — asked cold, it confidently invented "2:13 p.m." at half past nine at night. Every other question gets the real date and time handed to it as context.

### Anything with an exact answer gets one

The clock was the first of these, and the principle generalises: a language
model is confidently, fluently wrong at precisely the questions the Mac can
answer itself, and a wrong number is one you act on. So these never reach it.

```
"what's twelve times eight"            "what's fifteen percent of 240"
"what's twenty percent off fifty"      "what's 2 to the power of 10"
"how many kilometres in five miles"    "convert 20 celsius to fahrenheit"
"how many ounces in a pound"           "how many minutes in an hour"
"how much battery do i have"           "what's my uptime"
"what's my ip address"                 "how much space is left"
"what time is it in tokyo"             "what time is it in new york"
"flip a coin"                          "roll a die"      "roll a d20"
"pick a number between 1 and 10"       "what can you do"
"how long until friday"                "how many days until december 25"
"how many days until christmas"        "how many days until halloween"
"what's on my clipboard"               "say that again"
```

**Countdowns strip the opener before the date parser sees it**, and that is the
whole of a bug worth recording. Handed "until December 25" complete with the
word "until", `NSDataDetector` swallows the opener and answers with *today* at
four in the afternoon — so "how many days until Christmas" came back as an hour
and a half. It matched, it returned a date, and the date was nonsense. Only the
tail after "until" goes to the parser now.

A short table covers the holidays the system parser has never heard of —
Christmas, New Year, Halloween, Valentine's, the Fourth of July, Guy Fawkes —
resolved to the next time each comes round. Anything needing a rule rather than
a date, Easter above all, goes to the model, which is fine at exactly that. And
the answer is counted in **calendar days rather than 24-hour blocks**, because
that is what the question means: Christmas is the same number of sleeps away
whether you ask at breakfast or at midnight.

**"Say that again"** repeats the last answer from what was already said, so it
costs nothing, never asks the model to reproduce a line it wrote a moment ago,
and works with Apple Intelligence switched off. Confirmations are not repeated —
saying "Right away, sir" again helps nobody, and the line you missed is always
the one carrying the fact.

The **sums are parsed, not evaluated by a library**. `NSExpression` would be four
lines, but it raises an Objective-C exception on malformed input — which Swift
cannot catch, so "what's five plus" would take the whole app down. A hand-written
recursive-descent parser returns nothing instead, and nothing simply falls
through to the model like any other sentence it couldn't place.

Two things it gets right that are easy to get wrong. **A decimal point survives**:
the normalizer the rest of the app uses keeps letters and digits and turns
everything else into a space, so "3.5 plus 1.25" arrives as "3 5 plus 1 25" and
comes to a hundred and sixty. Sums get their own tidying that leaves `.`, `%` and
brackets alone. And **spaces are kept rather than stripped**, so "12 8 plus 3"
fails to parse instead of quietly answering 131 — the parser steps over
whitespace between tokens but refuses to read a number across it.

**Random is random.** A model asked to flip a coin has favourites; asked for a
number between one and ten it will give you seven twice running. The test flips
two hundred coins and rolls two hundred dice and insists on seeing every face.

**Free disk space is the one slow answer**, and it gets its own path. The figure
Finder shows — the one worth saying, because it counts space macOS would reclaim
on demand — costs **ten milliseconds** to read, measured. That is a dropped frame
or two of the HUD's animation, so it runs on a background queue and the answer
arrives when it arrives. Everything else here is microseconds and runs inline.

World clocks need no table to maintain: macOS ships four hundred-odd zone
identifiers shaped `Region/City`, so the city is the last path component with its
underscores turned back into spaces, and New York and Los Angeles fall out for
free. Reading and folding that list costs a few milliseconds, so it is warmed in
the background on the double clap — the same bargain the voice catalogue makes.

## How it decides what you meant

Three tiers, ordered so the thing that matters — opening your app — never waits on a model.

| Tier | What | Measured cost | Blocks your app? |
|---|---|---|---|
| 1 | String matching against your commands + installed apps | 0.15–0.7 ms | **yes, and it's the only one that does** |
| 2 | Apple Intelligence names a target, tier 1 validates it | ~350–580 ms warm | only when tier 1 found nothing |
| 3 | Apple Intelligence writes the spoken reply | ~500–800 ms | **never** — runs after the app already opened |

**Tier 1** handles everything normal. It strips "jarvis", strips the verb, and fuzzy-matches what's left against your phrases and then every installed app.

It waits about **0.6 seconds** after you stop talking before acting (about a second for dictated commands like reminders, and the same for anything it can't place). That pause isn't laziness: speech arrives a word at a time, and "open chrome" is a complete command right up until it becomes "open chrome on work". Acting on the first thing that parses meant trailing qualifiers were never heard.

This runs on the main thread, once per partial transcript, which for a spoken sentence is a few dozen times — so what it costs is worth knowing. Three things get it there.

The transcript is split into words and characters **once** rather than for every phrase of every command and then every app — a hundred and forty times over — and a window of it is a slice rather than a freshly built array. The edit distance is told what score it would have to beat, so it fills in only the diagonal band that could still land inside it and abandons a row whose cheapest cell has already overshot: two strings with nothing in common cost a row or two instead of the whole matrix.

And **the phrases are now prepared too**. That first optimisation fixed one side of the comparison and left the other alone: every phrase was still being turned into an array of characters *and* an array of arrays of characters on each partial transcript. With a hundred-odd phrases that came to **100 µs a call**, more than half the cost of resolving anything, all of it re-deriving something that only changes when you edit your commands. The listener now keeps a prepared catalogue and rebuilds it when they change.

And a phrase that cannot possibly match is now rejected by **counting bits**. An
edit distance is at least the number of *distinct characters* the phrase needs
and the window hasn't got, because each one has to be inserted or substituted in
and no single edit supplies two of them. Both sides carry a 36-bit character mask
— one per word on the transcript side, so a window's mask is an OR as the window
grows — and if the missing count exceeds what the cutoff allows, the matrix is
never filled in. On a rambling sentence against a hundred-odd phrases that is
most of the work: **three thousand distance calls became a few hundred**, for the
same answer.

Together these paid for the whole release. Tripling the number of built-in
commands would otherwise have tripled tier 1; instead every phrase got faster
than it was before, measured back to back on the same machine:

| Spoken | Before (7 commands, 43 phrases) | Now (18 commands, 142 phrases) |
|---|---|---|
| "open chrome" | 309 µs | **181 µs** |
| "start up the craft" | 515 µs | **271 µs** |
| "jarvis open chrome on work" | 443 µs | **260 µs** |
| "bring over xcode" | 951 µs | **262 µs** |
| "open a new gmail tab" | 566 µs | **310 µs** |
| "what is the capital of france" | 1262 µs | **1023 µs** |
| a rambling sentence matching nothing | 2763 µs | **1952 µs** |

None of it changes an answer, and that isn't taken on trust — `Tests/matcher` checks the cut-short distance against a plain full-matrix implementation, checks across thousands of generated phrases that every score at or above the bar comes back exactly as it would have, including scores landing precisely *on* it (which is where binary floating point would otherwise lose one), and checks that the prepared catalogue and the unprepared path resolve every phrase identically.

**Tier 2** only runs when tier 1 comes back empty, so it costs nothing in the common case. It catches loose phrasing — *"I could go for some blocky building"* → Minecraft, *"check my inbox"* → Gmail.

It starts **a second after you stop talking**, not when the listening window runs out. That used to be the same thing: nothing scheduled the handover, so a phrase tier 1 couldn't place sat in silence for the full six seconds and only *then* began to think. Every tier-2 command was six seconds slower than it needed to be, which is most of what made loose phrasing feel like it didn't work.

A whole session is prewarmed on the double clap, so the model is hot by the time it's needed (cold, it costs 4+ seconds). All three jobs are — interpreting, replying and answering each have their own standing instructions, and *creating* the session is what makes the model read them. Sessions used to be built at the moment they were needed, so every call paid for that inline and the prewarmed one held nothing but the model in memory. Each is used once and replaced with a fresh warm one in the background, so no request ever sees another's transcript.

Crucially, the model doesn't pick the action itself — it just **names** what you seem to want, and that name goes back through tier 1's matcher. So it can reach any installed app, not only the commands you've written, and it can't fire something unrelated to the name it gave: if the name matches nothing, nothing happens.

**Tier 3** is pure flavour. The action already ran. The model gets what it just did and what you said, and writes one line in JARVIS's voice, which is spoken and shown under the headline. If it takes too long, drifts long, or asks a question, a canned line is used instead — it can never delay or break anything.

Switch tiers 2 and 3 off entirely with **Use Apple Intelligence**. Everything still works; replies just come from a fixed list.

## What the menu tells you

Beyond the switches, the menu is where anything still running shows itself:

- **A running timer**, with the time left, and a way to cancel it without
  saying anything.
- **A held-awake Mac**, with how much longer, and "Let it sleep".
- **The last five things it did** — handy for catching a command that resolved
  to something other than what you meant, without keeping the Clap Monitor open.
- **Whatever permission is missing**, named for the feature that wants it rather
  than in the abstract.

## The HUD

The microphone opens **before** the reticle is built. Nothing is buffered from before the clap — that is the promise the whole feature rests on — so a word said in the gap between clapping and the recogniser opening is simply gone, and building a full-screen window and its layer tree first put exactly that gap there. People do not wait politely for a HUD before speaking. The reticle costs a couple of milliseconds either way.

Clapping brings up a full-screen reticle on every display with a countdown ring for your speaking window. When a command resolves, it snaps to gold with a flash and a particle burst.

The headline is **what it's doing** — "OPENING CLAUDE", "CHECKING THE WEATHER" — never the raw transcript. Weather replaces the headline with the conditions when they land. The JARVIS line appears underneath as it's spoken.

The overlay is click-through and never takes focus. **Preview the HUD** shows the whole sequence without clapping.

### The reticle breathes with your voice

The dot at the centre swells as you speak. It is the one honest signal the HUD
can give that it is *hearing* you without showing what it thinks you said —
which stays the rule. A reticle that sat perfectly still for six seconds gave
you no way at all to tell "listening" from "not working".

The level is curved rather than linear, for the reason the answer strip's
waveform is: speech is mostly quiet with brief loud peaks, and drawn straight it
sits flat on the floor and twitches only on plosives.

Getting it *smooth* took two goes. The level arrives about twenty-three times a
second, and the first version wrote it straight to the layer with animations
disabled — so the dot moved in twenty-three discrete steps a second on a screen
refreshing sixty or a hundred and twenty times, which reads as a jitter. It now
animates **between** levels, over slightly longer than the gap to the next one,
so Core Animation interpolates every intervening frame on the render thread.
That is both smoother and cheaper than driving it from a timer: still two layer
writes per level, and no per-frame work on the main thread at all.

The other half was the attack. Snapping straight to a louder frame tracked the
noise in the signal rather than the voice in it, so a rise is now followed
quickly rather than instantly, and a fall slowly. Run a synthetic speech
envelope through the filter and the frame-to-frame jerk falls by **eighty
percent** while the peak still reaches 99% of where it would have — followed,
not flattened. `Tests/answers` measures exactly that, so "smoother" is a number
rather than an opinion.

It costs two layer writes per level and **only while a phrase is being spoken** —
the engine asks for levels when it arms and stops when it stops, so the idle
cost is exactly zero. That mattered enough to derive the flag from the state
machine in one place rather than set it by hand in each of the eight paths that
end a phrase.

### The corner readouts say something true

Three of the four used to be decoration — a hard-coded "AUD 48.0 kHz" on a Mac
running at 44.1, and a "SYS 100%" that meant nothing at all. They are now the
real input sample rate, the real battery, the real time, and whether there is a
network. A panel that tells you the truth is worth more than one that looks like
it might. "MK VII" stays exactly as it was; it was never claiming to be a
measurement.

They are read once per HUD rather than once per display, so a Mac with three
monitors asks about its battery once.

### The ring warms as your window runs out

The countdown turns towards amber over the last quarter of the listening window,
so "you are running out of time to speak" is something you can see rather than
something you have to count. Free: Core Animation interpolates the colour on the
GPU alongside the sweep it is already drawing.

### A failure looks like one

A command that ran and couldn't do what it was asked turns the reticle **amber**
and says UNABLE, the same colour the cancel and stand-down paths already use.
Until now a failure was a line of small grey text under a headline that had
already flashed gold and burst — the HUD said ACCESS GRANTED and celebrated, and
the only thing saying otherwise was the detail line.

### Dimming is optional

**Dim the screen behind it** turns off the tint and the pool of shadow, so the
reticle floats over whatever you were looking at. Less legible on a bright
desktop, which is the trade being offered rather than a bug — it is the one part
of the HUD that covers your work.

### A timer keeps its own corner

A running timer gets a pill in the top right with the time left and a ring that
unwinds — see [Timers](#timers). It sits above the reticle so a timer stays
visible while you give another command, and the two never overlap: the reticle is
centred and the pill is in the corner.

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

Two more take arguments, so they need a distributed notification rather than
`notifyutil` — `…Jarvis.run` with `{"command": "Timer", "text": "5 minutes"}` and
`…Jarvis.ask` with `{"text": "how much battery do i have"}`. For the commands
that read the whole sentence, the text is the instruction: `run` with
`{"command": "Volume", "text": "set the volume to thirty"}` does what saying it
would.

## Weather

Open-Meteo — no account, no API key. Location comes from Location Services, or set fixed coordinates under **Weather ▸** to skip location access entirely. Fahrenheit or Celsius in the same menu.

"What's it like outside" gives current conditions, with **feels-like only when it
disagrees** by three degrees or more — printing "feels like 71" next to "71°F" on
an ordinary day is noise. Say **tomorrow** and you get the forecast instead:
tomorrow's low and high, the conditions, and the chance of rain when it is worth
mentioning.

```
"what's it like outside"     -> 64°F · Partly cloudy
"how's tomorrow looking"     -> Tomorrow: 58–71°F · Rain showers · 70% chance
"will it rain tomorrow"      "tomorrow's forecast"      "what about tomorrow"
```

Every forecast phrase says "tomorrow", deliberately. The weather command already
answers to "forecast", and two commands a hair apart in the matcher decide by
array order rather than by what you meant — so the forecast only answers to
sentences the other one cannot match at all.

The answer is **kept for three minutes**, with **a slot for each question**.
Conditions don't change minute to minute, and asking twice in a row used to mean
a location fix and a network round trip both times — seconds of "Checking the
weather" for a number already known. A single slot would have meant today and
tomorrow evicting each other every time, so anyone who asked both got no caching
at all. Switching between Fahrenheit and Celsius asks again rather than
converting nothing.

## Tuning

**Clap Monitor…** shows a live meter, the current threshold, and a log of every sound it took or ignored, plus what it heard and which tier resolved it.

It also shows **what the camera sees**: the frame Vision is being handed, with every joint it recognised drawn on top. Green means that hand has a position the recogniser can measure from; **amber means Vision can see the hand but can't place it confidently enough to use** — a different problem from not seeing it at all, and one you'd never guess from a log line. With two usable hands it draws the gap between them and the number, which is the figure the Mission Control gesture is trying to grow past 0.15.

The preview is mirrored, so what you see and what the recogniser measures agree.

While the monitor is shut, no frame is ever scaled or converted; while it's open the preview runs at 15 fps rather than the 30 the recogniser gets, and while Jarvis is muted because you're talking, it skips looking for hands altogether and just shows you the picture.

**Camera check** runs the camera without a clap — eight seconds at a time is no way to work out why a gesture isn't landing. Gestures are reported rather than performed, so your desktops don't fly past while you experiment. **Clap first and they run for real**, monitor open or not: the debug view stands in for the real thing only while nothing is armed, never in place of it. It turns itself off when the window closes.

- Nothing registers → raise sensitivity to High.
- *"ignored a loud sound — didn't decay like a clap"* → it heard you, but the sound was too sustained. Sharper claps, or move closer.
- Random triggers → drop to Low.

It logs the camera too. While the window is open it reports what Vision can actually see — *camera sees 2 hands* — and when the window closes it says how close you got: *gestures: widest two-hand spread 0.11 (needs 0.15)*, or *the camera never found a hand*. That turns "nothing happened" into something you can act on. Every gesture that does fire prints which way your hand went and what it did — *gesture: hand left -> desktop on the right*. If those ever disagree with each other, the camera is handing over a mirrored picture, and the one flip that decides it is `user(_:)`, nested inside `read(_:joints:)` in [HandTracker.swift](Jarvis/HandTracker.swift): change `1 - p.x` to `p.x`. Nothing else in the code knows which way round the frame is.

Gestures too twitchy, or not twitchy enough, live in `GestureConfig` in [Gestures.swift](Jarvis/Gestures.swift) — `travel` is how far a hand must go, `spread` is how far apart two must get, `maxDuration` is how long it has to finish, and `changeSamples` is how many frames a new hand count must hold before it is believed.

## Tests

```bash
./Tests/run.sh
```

Offline, no mic or network: clap detection against synthetic audio (real claps, distant claps, sustained noise, speech-like bursts, music with rests, silence), phrase matching, command resolution — every verb, macros, installed-app fallback, a set of conversational phrases that must *not* fire, and a regression case pinning "the craft" to the right launcher — plus Chrome profile discovery and the check that commands saved before profiles existed still load.

The phrase matcher is held to its old answers. It now stops measuring as soon as it can tell a phrase is below what the caller would accept, and its edit distance fills in only the band that could still land inside the limit — both are supposed to be invisible, so the test checks the cut-short distance against a plain full-matrix implementation over eight thousand pairs, and checks across eighteen thousand generated comparisons that every score at or above the bar is exactly the score the exhaustive version would have given. Scores landing precisely *on* the threshold are built deliberately and checked separately, because that is the case binary floating point loses. It prints what resolving actually costs, and fails if the slowest phrase drifts past 3 ms.

The Chrome scripts are compiled and their handlers called without Chrome being involved: every handler the Swift side asks for exists under that exact name and with that arity, and arguments carrying quotes, backslashes, tabs, newlines and an AppleScript injection attempt all arrive verbatim.

The keyboard trigger's shortcut table is checked for duplicates, bare keys with no modifier, and a clean round trip through the preference.

The gesture recogniser runs offline against a synthetic stream of hand positions — every gesture, everything that must *not* fire, dropped frames, hands flung off the edge of the picture, a change in hand count mid-gesture, and the diagnosis it prints when nothing lands.

The newer commands get two suites of their own. **`Tests/commands`** is mostly a
regression net: every phrase added is a fresh chance to shadow one that was
already there, so it pins "google chrome" to the browser rather than a web
search, "play minecraft" to Minecraft rather than the play/pause key, "remind me
to look up the recipe" to a reminder rather than a search, and a bare "forecast"
to current conditions. It checks locking has every guard sleeping has, that
quitting is a verb rather than a command, and — against real persistence, in the
test binary's own preferences domain — that an installation predating these
commands is offered them exactly once, that one you deleted is not resurrected,
that a command you wrote yourself is never shadowed by a built-in of the same
name, and that a single unreadable command no longer takes the whole list with
it.

**`Tests/minecraft`** pins the game-or-launcher decision, which is the half of
that feature that can be settled without a Mac in a particular state: which
commands it applies to at all, that naming the launcher out loud still asks for
the launcher, that Mojang's own launcher being *called* Minecraft doesn't switch
the whole thing off, and that the seeded command resolves exactly as it always
did. Whether the game is running is the machine's business, so the last check is
only the mistake that would matter — handing back the launcher as if it were the
game, which would make "open minecraft" a no-op that looks like a hang.

**`Tests/answers`** covers everything the Mac works out for itself: sums,
percentages, unit conversions, timer durations, volume and transport words, where
a window goes, how long something stays awake, the clipboard, countdowns to a
date, and the search URL's escaping. Several of its cases are bugs that were
caught here first — "3.5 plus 1.25" coming to a hundred and sixty, "12 8 plus 3"
quietly answering 131, "half an hour" running for an hour, "two and a half hours"
running for thirty minutes, "what should I eat on a diet" rolling a die because
*diet* contains *die*, and Christmas being an hour and a half away.

The reticle's smoothing is measured rather than eyeballed: a synthetic speech
envelope goes through the filter and the test insists the frame-to-frame jerk
falls by more than half while the peak still reaches most of its unsmoothed
height. Smoothing that flattened the signal would pass the first check and fail
the second.

The resolver's timing guard takes the **best of five** runs and allows six
milliseconds. Both are deliberate: a single timed batch measures the machine as
much as the code — the same build measured 2799, 3239 and 3844 µs on three
consecutive runs of a laptop with a game open — and the guard exists to catch an
order-of-magnitude regression, not a drift. The per-phrase numbers are printed
either way, so real drift stays visible.

Two sections of `Tests/commands` exist because of the one-short-word problem
above: one asserts that nine ordinary sentences containing "time" are not
commands, and another that "what's the cause of that" and "how big is the ship"
are not either. A third holds every built-in phrase to being more than one short
word.

Gestures are covered the same way: the recogniser takes timestamped hand positions rather than reading a clock, so a synthetic stream can assert on the awkward cases directly — a hand entering frame, a hand put back down, a slow drift across the desk, one hand sweeping past a resting one, a dropped frame mid-swipe.

```bash
./Tests/run-live.sh
```

Live: Apple Intelligence (both tiers plus the reply sanitiser), a real weather fetch, and an end-to-end pass against the running app — arm, cancel, stand down, trigger. Needs Jarvis running and takes about a minute.

## Notes

- Ad-hoc signed, so macOS may re-ask for microphone access after a rebuild. Signing with your Apple ID team in Xcode's Signing & Capabilities makes it stick.
- Running from Xcode launches a *second* copy alongside the installed one.
- Escape is registered as a global hotkey only while listening, so it isn't swallowed from other apps the rest of the time. It needs no Accessibility permission.
- Accessibility, needed only for the two desktop-switching gestures, is granted per code signature — an ad-hoc signed build may want it granted again after a rebuild, for the same reason the microphone does. Mission Control and everything else are unaffected.
