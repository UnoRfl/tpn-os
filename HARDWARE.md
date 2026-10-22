# TPN OS hardware guide

Everything about the machines TPN OS runs on at the restaurant: what they are, what software runs on each, how the pages talk to the printer, drawer and rear screen, how to build and install the two Android apps from a home PC, and how to test all of it on a PC with the iMin simulator before it goes near the real counter.

Last checked against the code on Oct 22, 2026 (HANDOFF Rev 36, apps 1.4.1).

---

## 1. The machines

### 1.1 The counter: iMin D4-504

| Part | What it is | How TPN OS uses it |
|---|---|---|
| Model | iMin D4-504, model sticker **I20D01** | — |
| Main screen | 15.6" Full HD (1920 × 1080) touch screen | The floor and counter page, inside the TPN Counter app |
| Rear screen | 10.1" 1280 × 800, facing the guest | The customer page (`tpn-dine-in-floor-customer`): the order, the total, how to pay, "salamat" |
| Printer | Built-in 80 mm thermal printer with an automatic cutter (576 dots per line, 203 dpi) | Receipts, bills, kitchen tickets (when Kitchen tickets is set to "Counter printer", or as the backup when the kitchen printer fails), test prints |
| Cash drawer | Plugs into the printer's drawer port; opened by a printer command | Opens on cash payments and on a manager's "Open drawer" |
| System | Android 11, **no Google Play Store** (iMin App Store only) | Apps are installed from the TPN release links or with `adb` |
| Built-in web view | Android System WebView **83** (2020), cannot be updated on this device | Too old for the main pages. Only the rear screen uses it |
| Chrome | Chrome 104 is installed | Not needed any more. The app carries its own engine |

Sources for the screen and printer sizes: iMin's D4 Pro datasheet (15.6" FHD main, 10.1" 1280 × 800 customer display, 80 mm printer with auto-cutter) and the device itself (checked Oct 21: Android 11, WebView 83.0.4103.120, no Play Store). The main screen's size in web pixels depends on the Android density. If a layout looks wrong on the device, check it with `adb shell wm size` and `adb shell wm density` (section 6).

### 1.2 The kitchen

| Part | What it is | How TPN OS uses it |
|---|---|---|
| Kitchen screen (optional) | Any Android tablet or screen running the **TPN Kitchen** app | The kitchen station page: tickets, start cooking, mark ready, void requests, 86 |
| Kitchen printer (optional) | Any network thermal printer that takes **ESC/POS on port 9100** (Wi-Fi or LAN cable, **not** Bluetooth-only), 80 mm or 58 mm paper | Kitchen tickets, sent by the counter |

A restaurant can use the screen, the printer, or both. The counter's printer menu sets which one gets paper tickets (section 4.3).

### 1.3 The network

- The iMin and the kitchen printer must be on the **same restaurant network**.
- Give the kitchen printer a **fixed address** in the router (often called a "DHCP reservation"). If the router gives it a new address, kitchen tickets fall back to the counter printer until someone types the new one in.
- Without internet, the counter keeps working offline (cash only). The kitchen printer, the counter printer, the drawer and the rear screen all keep working, because none of them need the internet.

---

## 2. What runs on the iMin

| Program | Where it comes from | What it does |
|---|---|---|
| **TPN Counter** (`ph.tyopaengnyo.counter`) | `https://github.com/UnoRfl/tpn-os/releases/latest/download/tpn-counter.apk` | The whole counter. It opens `tpn-dine-in-floor` on its own engine (GeckoView 153, Firefox's engine), shows the rear screen, passes kitchen tickets to the network printer, and reopens after a power cut |
| **iMinprinterplugin** | iMin App Store | iMin's print service. It lets a web page print on the built-in printer and open the drawer (`127.0.0.1:8081`) |
| Android System WebView 83 | Built in | Draws the rear customer screen only |

On the kitchen device, **TPN Kitchen** (`ph.tyopaengnyo.kitchen`, `tpn-kitchen.apk` from the same release) opens `tpn-kitchen-station`. It has no rear screen.

The two apps are the same Android project with two "flavors" (`android/app/build.gradle`):

| | TPN Counter | TPN Kitchen |
|---|---|---|
| Package | `ph.tyopaengnyo.counter` | `ph.tyopaengnyo.kitchen` |
| Opens | `tpn-dine-in-floor` | `tpn-kitchen-station` |
| Rear screen | Yes (`CUSTOMER_SCREEN true`) | No |
| User agent tag | `TPNCounter/1.4.x` | `TPNKitchen/1.4.x` |

The web pages read that user agent tag: it turns on the light drawing mode (`html.tpn-lite`, no blur), and it sends the app back to its station if it ever lands on the public website, the QR table menu or the rewards page (`tpn-kit.js`).

The pages themselves are **not inside the app**. The app loads them from the website, so almost every change (screens, prints, rules, wording) reaches the iMin after a reload, with no new download. Only changes in `android/` need a new app.

---

## 3. How the pages talk to the hardware

Everything is on the device itself (`127.0.0.1`). Nothing goes through the internet.

| Address | Who answers | Used for | Code |
|---|---|---|---|
| `ws://127.0.0.1:8081/websocket` | iMin's print service | Printer commands (text, picture, QR, feed, cut), printer status, cash drawer | `modules/imin.js`, `vendor/imin-printer-1.4.0.min.js` |
| `http://127.0.0.1:8081/upload` | iMin's print service | Uploads the picture of a slip before it prints | same |
| `http://127.0.0.1:8091/ping` | TPN Counter app | "Is the app here, and can it print to the kitchen?" | `modules/kprint.js`, `modules/customer-display.js` |
| `http://127.0.0.1:8091/state` | TPN Counter app | What the rear screen should show | `modules/customer-display.js` → `CustomerScreenService.java` |
| `http://127.0.0.1:8091/print?host=…&port=9100` | TPN Counter app | Passes a kitchen ticket to the network printer | `modules/kprint.js` → `CustomerScreenService.java` |
| `<printer address>:9100` | The kitchen printer | ESC/POS bytes from the app | `CustomerScreenService.java` |

Safety rules in the app's link (`CustomerScreenService.java`):
- It only answers the TPN site's own pages (the `Origin` header must match the site the app was built for).
- `/print` only reaches private home or restaurant addresses (10.x, 172.16–31.x, 192.168.x) on ports 9100–9109. A page can't use it to reach the internet.
- Bodies are capped: 64 KB for the rear screen, 2 MB for a print.

### 3.1 The iMin print service protocol

The page sends JSON messages `{ "type": N, "data": { "text", "value", … } }` over the WebSocket. These are the types TPN OS uses:

| Type | Command | Notes |
|---|---|---|
| 1 | Choose the printer connection | `"USB"` (the D4) or `"SPI"`; `imin.js` tries both |
| 2 | Printer status | Answer value: 0 ready, 3 cover open, 7–8 paper, other = offline |
| 3 / 4 | Line feed / feed n dots | |
| 5 | Cut (partial) | |
| 6 / 7 / 9 | Align / text size / bold | Size is in dots (24 normal) |
| 12 / 13 | Print text | 13 carries its own alignment |
| 14 | Print columns | Used by the plain-text fallback receipt |
| 20 / 23 / 24 | QR size / print QR | Plain-text fallback only; the picture slips draw their own QR |
| 26 / 27 | Print the picture just uploaded | The normal path for every slip |
| 100 | Open the cash drawer | Logged in the audit log by `imin.js` |

Every slip is drawn as one black-and-white picture, 576 dots wide (`modules/slips.js`), uploaded to `/upload`, then printed with type 26. If that fails, `imin.js` prints the plain-text version, and managers see why in the printer menu.

### 3.2 Kitchen printer bytes

`modules/kprint.js` turns the same picture into ESC/POS: `ESC @` (reset), the picture as `GS v 0` raster bands of 128 rows, then `ESC d 4` (feed) and `GS V 66 0` (cut). On 58 mm paper it scales the picture to 384 dots.

---

## 4. Adjusting what runs on it

### 4.1 Things set on the device (no new app needed)

All of these are in the floor screen's top bar, under 🖨 → **Printers**. They're for managers only (permission "Printer tools", `printer.manage`); other staff see the printer status and Reconnect.

| Setting | Where it's stored | Effect |
|---|---|---|
| Auto-print receipts | this device (`tpn.imin.auto`) | Prints the receipt after every payment and on Close Table |
| Kitchen tickets | this device (`tpn.kprint.mode`) | **Kitchen screen only**: no paper while online. **Kitchen printer**: paper in the kitchen, with the counter as backup. **Counter printer**: paper at the counter |
| Kitchen printer address, port, paper | this device (`tpn.kprint.host / port / paper`) | Where kitchen tickets go |
| Test kitchen ticket / Test receipt / Test bill | — | Print filler-only samples on the counter printer; the kitchen part has its own Test kitchen ticket and Test receipt |
| Open drawer | — | Opens the drawer without a sale (logged) |

Only **one** device should be in "Kitchen printer" mode. That device also prints the QR-menu and website orders, so two would print them twice.

Android settings worth setting once on the iMin:
- **Display over other apps** → allow for TPN Counter (the app asks). It's needed for the rear screen, and for reopening after a power cut.
- **Display → keep the screen on while charging**.
- **Battery** → don't optimise TPN Counter, so Android doesn't stop the rear-screen service.

### 4.2 Things built into the app (need a new app)

`android/app/build.gradle` and the Java files in `android/app/src/main/java/ph/tyopaengnyo/counter/`:

| What | Where | Notes |
|---|---|---|
| Which site the app opens | `TPN_SITE_URL` when building (default `https://unorfl.github.io/tpn-os/`) | Point a test build at another copy (section 7.3) |
| Start page per app | `START_PATH` in each flavor | `tpn-dine-in-floor` / `tpn-kitchen-station` |
| Rear screen on or off | `CUSTOMER_SCREEN` | Counter only |
| User agent tag | `UA_TAG` | The pages look for `TPNCounter/` and `TPNKitchen/` |
| Version | `versionName '1.4.' + TPN_VERSION_CODE` | GitHub Actions sets the code to its run number |
| Engine | `org.mozilla.geckoview:geckoview:153.…` (pinned) | 154+ needs compileSdk 37 and a newer Android Gradle Plugin |
| Allowed plain-HTTP addresses | `res/xml/network_security_config.xml` | Only 127.0.0.1 and localhost (the print service and the app's link) |
| Kitchen printer rules | `CustomerScreenService.print()` / `isLan()` | Private addresses, ports 9100–9109 |
| Reopen after a power cut | `BootReceiver.java` | Needs "Display over other apps" on Android 10+ |
| Remote debugging | `MainActivity`: `remoteDebuggingEnabled(adbOn())` | Only while USB debugging is on (section 6) |

### 4.3 What code must work on

| Part | Engine | What that means for code |
|---|---|---|
| Main pages inside the apps | GeckoView 153 (Firefox engine) | Modern features are fine. Test in Firefox as well as Chrome (the simulator can open Firefox) |
| Rear screen | Android WebView 83 (Chromium 83, 2020) | Nothing newer than Chromium 83 on `tpn-dine-in-floor-customer`: no `:has()`, no container queries without a fallback, no `structuredClone`, no top-level `await` |
| Phones (QR menu, website) | Whatever guests have | Usual care: 16px text boxes, no sideways scrolling |

On the iMin, `html.tpn-lite` turns off blur and long motion (`tpn-kit.js`). Keep animations to transform and opacity.

---

## 5. Building the apps on your home PC

You don't have to build locally. Pushing a change in `android/` to GitHub makes **GitHub Actions** build both apps (`.github/workflows/build-apk.yml`). Building at home is for trying app changes quickly.

### 5.1 Install once (Windows)

1. **Java 17**: install "Eclipse Temurin JDK 17" (adoptium.net). Check with `java -version`.
2. **Android SDK**. Either:
   - **Android Studio** (easiest): install it, open the `android` folder, let it download what it asks for, or
   - **Command-line tools only**: download "Command line tools only" from developer.android.com/studio, unzip to `C:\Android\cmdline-tools\latest`, then run:
     ```bash
     sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"
     ```
   Set `ANDROID_HOME=C:\Android` and add `C:\Android\platform-tools` to `PATH` (that's where `adb` lives).
3. **Gradle 8.11.1**: the repo has no Gradle wrapper. GitHub Actions installs Gradle 8.11.1 itself. At home, either let Android Studio run the build, or install Gradle 8.11.1 (gradle.org/releases) and add its `bin` to `PATH`.
4. **Node.js 18 or newer** (nodejs.org): only for the simulator and the database tests.
5. **Git**, then clone:
   ```bash
   git clone https://github.com/UnoRfl/tpn-os.git
   ```

On a Mac or Linux the steps are the same, with Homebrew or the official installers.

### 5.2 Build

From the repo folder:

```bash
gradle -p android assembleCounterDebug assembleKitchenDebug
```

The apps land in `android/app/build/outputs/apk/counter/debug/` and `…/kitchen/debug/`.

A **debug** build is signed with a debug key. Android won't install it over the release app; you'd have to uninstall the release app first, which **wipes its storage** (sign-in, printer settings). Use debug builds on a spare device, or uninstall knowingly.

**Release** builds signed with the real key install over the restaurant's app and keep its settings:

```bash
set TPN_KEYSTORE=C:\secure\tpn-counter.p12
set TPN_KEYSTORE_PASSWORD=<the key's password>
gradle -p android assembleCounterRelease assembleKitchenRelease
```

On a Mac or Linux, use `export` instead of `set`.

- The signing key (`tpn-counter.p12`) lives only in `~/Downloads/tpn-os-study/keys/` on the Mac. Copy it to the home PC by hand (USB stick or a password manager's file vault), never by email or chat, and **never commit it**. If it's lost, no future app can install over the existing one.
- Release apps land in `android/app/build/outputs/apk/counter/release/app-counter-release.apk` and `…/kitchen/release/app-kitchen-release.apk`.
- Optional: `set TPN_VERSION_CODE=99` to give a home build its own version number (it must be higher than the installed app's to install over it).

### 5.3 Publish (the official way)

1. Push the change to a `feature/…` branch. GitHub Actions builds both apps (Actions tab → "Build TPN apps").
2. Download the artifact, then create a release `apps-X.Y.Z` with **both** files named `tpn-counter.apk` and `tpn-kitchen.apk`, so the `releases/latest/download/…` links keep working (HANDOFF Rev 31).

---

## 6. Installing and checking on the iMin

### 6.1 Without a cable

On the iMin, open the browser, go to the `tpn-counter.apk` link, download it, and install it over the old app. Android asks once to allow installs from the browser.

### 6.2 With a USB cable (adb)

1. On the iMin: **Settings → About → tap Build number 7 times**, then **Developer options → USB debugging: on**.
2. Plug it into the PC and accept the "Allow USB debugging?" prompt on the iMin.
3. On the PC:

```bash
adb devices
```

```bash
adb install -r android/app/build/outputs/apk/counter/release/app-counter-release.apk
```

Useful checks:

| Command | Shows |
|---|---|
| `adb shell wm size` and `adb shell wm density` | The real screen size and density, and so the size in web pixels |
| `adb shell dumpsys display \| findstr mDisplayId` | Both screens (Windows: `findstr`; Mac/Linux: `grep`) |
| `adb shell pm list packages \| findstr imin` | That iMin's print service is installed |
| `adb logcat \| findstr -i "gecko tpn"` | The app's log |
| `adb shell am force-stop ph.tyopaengnyo.counter` | Restart the app |

**See the page's console and inspect it:** with USB debugging on, the app allows remote debugging. On the PC, open Firefox → `about:debugging` → **Setup** → enable USB devices → the iMin appears → **Inspect** the TPN Counter tab.

### 6.3 Testing your PC's copy on the real iMin

The app only allows plain-HTTP connections to the device itself. To show the iMin a site served from your PC:

1. Start the simulator's site server on the PC (`node tools/imin-sim/imin-sim.js --local --browser none`). Only its port 7071 is needed. The iMin uses its own printer and app link, not the simulator's.
2. Forward that port to the iMin:
   ```bash
   adb reverse tcp:7071 tcp:7071
   ```
3. Build a test app that opens it, and install it:
   ```bash
   set TPN_SITE_URL=http://127.0.0.1:7071/
   gradle -p android assembleCounterDebug
   ```
   Then `adb install -r …` (debug build: use a spare device, or uninstall the release app first).

The iMin now runs your PC's files with its real printer, drawer and rear screen. App 1.4.1 or later is needed, because 1.4.0 didn't accept the port number in the site address.

---

## 7. The iMin simulator

`tools/imin-sim/` is a program for your PC that pretends to be the iMin's hardware. The real TPN pages run in normal browser windows sized like the iMin's screens, and what would have printed shows up on screen. Use it to test changes without installing anything on the counter.

### 7.1 What it simulates

| Real thing | In the simulator |
|---|---|
| iMin print service (`127.0.0.1:8081`) | Same address and the same protocol. Every slip appears on the dashboard's **Counter printer** roll (pictures exactly as printed) |
| Cash drawer | "Cash drawer opened" in the dashboard's events |
| TPN Counter app's link (`127.0.0.1:8091`) | Same address and rules (`/ping`, `/state`, `/print`) |
| Kitchen network printer | Any home-network address you type (e.g. `192.168.1.250`) prints on the dashboard's **Kitchen printer** roll |
| Main screen | An app window, 1920 × 1080 (or `--screen 720` for 1280 × 720 at density 1.5) |
| Rear screen | A second window, 1280 × 800, sharing the counter's browser storage, so it hears the counter the same way |
| The app's identity | The app's user agent (`… Android 11 … TPNCounter/1.4.0`), so `tpn-lite` and the app-only behaviour switch on |
| Faults | Dashboard switches: printer out of paper, cover open, print service not installed, kitchen printer unplugged, no app link (an older app), slow printing |

### 7.2 Run it

Needs Node.js 18+ and Chrome or Edge (or Firefox). Nothing to install with npm. From the repo folder:

```bash
node tools/imin-sim/imin-sim.js
```

That opens the dashboard (`http://127.0.0.1:7070/`), the counter and the rear screen on the **live** site. Sign in once in the counter window; the simulator keeps its own browser profile in `~/.tpn-imin-sim`, so you stay signed in between runs.

To test **your own changes before pushing**, serve this folder instead:

```bash
node tools/imin-sim/imin-sim.js --local
```

To test on **Firefox**, the same engine as the apps:

```bash
node tools/imin-sim/imin-sim.js --local --browser firefox
```

All options: `node tools/imin-sim/imin-sim.js --help`.

| Option | Does |
|---|---|
| `--local [dir]` | Serve a copy of the site (default this repo) at `http://127.0.0.1:7071/` and open that |
| `--site URL` | Open another site (default the live one) |
| `--screen 1080\|720` | Counter window size |
| `--browser chrome\|edge\|firefox\|none` | Which browser to open (`none`: only the servers and dashboard) |
| `--browser-path PATH` | A specific browser program |
| `--kitchen` | Also open the kitchen station, as TPN Kitchen |
| `--no-rear` | Don't open the rear screen |
| `--version 1.4.1` | The app version in the user agent |
| `--fresh` | Start signed out with empty settings |

**Important:** the real TPN Counter app and the simulator use the same ports. Don't run the simulator on a PC that also runs the app in an emulator.

### 7.3 A test round

1. Start the simulator and sign in on the counter window with a manager account.
2. 🖨 → **Printers** → **Test kitchen ticket**, **Test receipt**, **Test bill**. All three appear on the Counter printer roll.
3. Kitchen printer: address `192.168.1.250`, port 9100, Kitchen tickets → **Kitchen printer**, Save, then its test buttons. They appear on the Kitchen printer roll.
4. Switch **Kitchen printer → Unplugged** on the dashboard and send a ticket. It should print on the counter roll with a "printed at the counter" message.
5. Take a cash payment and watch the drawer event and the rear screen.
6. Try **Counter printer → Out of paper** and **Print service not installed**, and check the counter says so.
7. Resize or use `--screen 720` to check layouts.

### 7.4 What it can't tell you

- **The rear screen's old engine:** the simulator draws the rear page in a modern browser, but the iMin uses WebView 83. Keep that page to Chromium 83 features (section 4.3), or check it on the device.
- **The exact app engine:** use `--browser firefox` to be close; GeckoView 153 behaves like Firefox 153.
- **Real paper:** cutter jams, faint print and real speed only show on the printer. Use **Print delay** for slowness.
- **Android itself:** permissions, start after a power cut, the "Display over other apps" switch and the USB printer driver only exist on the device.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Printer chip says "No printer service" | iMinprinterplugin not installed, or not started since boot | Install or open it from the iMin App Store, then Reconnect |
| "Printer offline" | The service lost the printer | Reconnect; check paper and cover |
| A slip prints in plain text, not the designed look | The picture upload failed | The printer menu shows the reason to managers; Reconnect, check the service is up to date |
| Kitchen ticket printed at the counter | Kitchen printer off, out of paper, or its address changed | Check its power and paper, print its self-test page for the address, fix it in Printers → Kitchen printer, and reserve the address in the router |
| Kitchen printer section says "Update the TPN Counter app" | The page isn't inside TPN Counter 1.4+ | Install the latest `tpn-counter.apk` |
| Rear screen blank | "Display over other apps" not allowed, or Android stopped the service | Allow it in Android settings for TPN Counter, then reopen the app |
| App opens the public website | Old app or old page cache | Reload; the pages send the apps back to their station since Rev 35 |
| A new app won't install over the old one | Signed with a different key, or a lower version | Use the release key and a higher `TPN_VERSION_CODE` |

---

## 9. Files

| File | What it is |
|---|---|
| `modules/imin.js` | The counter printer: connect, status, picture printing, text fallback, drawer, test buttons, printer menu |
| `modules/slips.js` | Draws every slip (kitchen ticket, receipt, bill) as a 576-dot picture; test samples |
| `modules/kprint.js` | Kitchen printer: settings, ESC/POS, the Kitchen tickets setting, printing guests' orders |
| `modules/customer-display.js` | Sends the rear screen its state |
| `tpn-dine-in-floor-customer.html` | The rear screen page |
| `vendor/imin-printer-1.4.0.min.js` | iMin's own SDK (MIT) |
| `android/` | The two apps |
| `tools/imin-sim/` | The simulator (`imin-sim.js`, `dashboard.html`) |
