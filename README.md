# Pool Robot (iAquaLink) — Control4 Driver

A Control4 DriverWorks driver that controls a Zodiac / Polaris robotic pool cleaner through the iAquaLink cloud. It puts a **Pool Robot** button in the Control4 app that starts and stops the robot and shows whether it's cleaning. It also exposes the robot's canister status to Composer programming.

**Current version:** 13 · **File:** `PoolRobotButton.c4z` · **Proxy:** `uibutton`

> **Unofficial driver.** It uses the iAquaLink cloud API, which was reverse-engineered from the official iAquaLink app. Zodiac/Fluidra doesn't support or document this API, and it can change without notice.

---

## Features

- **One-tap toggle:** tap the Pool Robot icon in the Control4 app to start cleaning, and tap again to stop.
- **Live icon state:** the icon switches between an idle image and a cleaning image, and it stays in sync with the robot even when someone starts or stops it from the iAquaLink app.
- **Robot picker:** after login, the driver lists the robots on the iAquaLink account in a dropdown, so you don't have to type a serial number.
- **Status polling (optional):** the driver can check the robot's state on a schedule.
- **Canister alerts:** a property and events report when the debris canister needs emptying.
- **Programming actions:** Start Cleaning, Stop Cleaning and Refresh Robot List are available in Composer programming and on the Actions tab.

## Requirements

- A Control4 controller with internet access. The driver connects outbound over HTTPS/WSS on port 443.
- An iAquaLink account (email and password) with the robot already set up in the iAquaLink app.
- A robot that the iAquaLink app can control over the cloud. The driver was built and tested against a **VR / Vortex-family** robot, which uses the `vr` command set. Other robot families (CycloNext, CycloBat, i2d) report their state differently and may not work.
- Composer Pro, for installation.

## Installation

1. In Composer Pro, open **Driver → Add or Update Driver or Agent** and select `PoolRobotButton.c4z`.
2. In **System Design**, add **Pool Robot (iAquaLink)** to the room where the button should appear.
3. Select the driver and fill in the properties described below.
4. Open **Navigators** (or the room's UI settings) and make sure the **Pool Robot** button is visible in the section where you want it.
5. Refresh Navigators.

**Upgrading from an earlier version:** the serial number you entered in v10 or earlier is kept and used until the robot list loads. Buttons already in your project keep their old name ("Experience Button") until you rename them; only newly added drivers default to "Pool Robot". If Composer still shows the old generic icon, restart Composer.

## Setup

1. Enter the iAquaLink **Email** and **Password**. The driver logs in and loads the robot list on its own.
2. Choose your robot from the **Robot** dropdown. If the account has only one robot, it's selected for you.
3. Optional: set **Poll Interval (Seconds)**, for example to `300`, so the icon and canister status stay current between commands.
4. Check **Status**. It should go from `Logged in` to `Loading robot list...` to `Found N robot(s)`. Once polling runs, it shows the robot's state.

If the dropdown shows `(no robots found - use Refresh Robot List)`, check the credentials and run the **Refresh Robot List** action.

## Properties

| Property | Type | Editable | Description |
|---|---|---|---|
| **Email** | Text | Yes | iAquaLink account email. Changing it clears the session and reloads the robot list. |
| **Password** | Password | Yes | iAquaLink account password. Changing it clears the session and reloads the robot list. |
| **Robot** | Dropdown | Yes | Robots on the account, shown as `Name (SERIAL)`. Devices named "VR" are left out of the list (see [Known limitations](#known-limitations)). |
| **Robot Serial** | Text | Read-only | Serial number of the selected robot. |
| **Status** | Text | Read-only | Last driver activity or error, such as `Logging in...`, `Start command sent`, `Cleaning` or `Login failed (401)`. |
| **Current State** | Text | Read-only | `Cleaning` or `Idle`. This matches the button icon. |
| **Canister** | Text | Read-only | `OK`, `Full` or `Unknown`. It shows `Unknown` until the robot first reports a canister value. |
| **Poll Interval (Seconds)** | Text | Yes | How often to check the robot's status. `0` (the default) turns polling off. Values below 15 are raised to 15. |
| **Debug Mode** | List | Yes | `Off` or `Print`. `Print` writes detailed logs to the Lua tab in Composer. Everything is also written to the driver log no matter what this is set to. |

## Actions and commands

These are available as **device commands** in programming and as buttons on the driver's **Actions** tab:

| Action | Command | What it does |
|---|---|---|
| Start Cleaning | `StartCleaning` | Starts a cleaning cycle. |
| Stop Cleaning | `StopCleaning` | Stops the robot. |
| Refresh Robot List | `RefreshRobotList` | Reloads the robot dropdown from the iAquaLink account. |

Tapping the button in the Control4 app toggles between the two: it starts the robot if it's idle and stops it if it's cleaning.

## Events

| Event | Fires when |
|---|---|
| **Canister Full** | The robot reports that its debris canister needs emptying. |
| **Canister Emptied** | The canister goes from full back to OK. |

Each event fires only when the state changes, not on every status check. The last canister state is saved, so restarting the controller doesn't fire **Canister Full** again for a canister that was already reported.

### Programming examples

- **Notify when the canister is full:** When *Pool Robot → Canister Full*, send a push notification: "Pool robot canister needs emptying."
- **Morning clean:** in the Scheduler at 7:00 AM, run *Pool Robot → Start Cleaning*.
- **Stop when the pool is in use:** When a pool-area scene runs, run *Pool Robot → Stop Cleaning*.

## How it works

| Step | Endpoint | Purpose |
|---|---|---|
| Login | `POST https://prod.zodiac-io.com/users/v1/login` | Gets the session tokens and user ID. |
| Robot list | `GET https://r-api.iaqualink.net/devices.json` | Lists the devices on the account for the dropdown. |
| Status | `GET https://prod.zodiac-io.com/devices/v1/{serial}/shadow` | Reads the robot's reported state for polling. |
| Start/stop | WebSocket `wss://prod-socket.zodiac-io.com/devices` | Authorizes against the robot and sends `setCleanerState`. |

- The driver logs in only when it needs to: on the first command, poll or list refresh. If a request comes back 401 or 403, it logs in again.
- For start and stop, the driver opens the WebSocket, waits for the robot to report its current state, and then sends the command. It closes the connection once the server confirms the change, or after 8 seconds if no confirmation arrives. No connection is left open.
- The driver reads three values from the robot's reported state:
  - `equipment.robot.state`: `1` = cleaning, anything else = idle.
  - `equipment.robot.canister`: `0` = OK, `1` = full.
  - `equipment.robot.errorState`: logged only; not yet exposed as a property.
- Requests send an iAquaLink-app User-Agent because the API sits behind a web application firewall that rejects other clients.

## Troubleshooting

Set **Debug Mode** to `Print` and open the **Lua** tab in Composer to watch the driver's activity.

| Symptom | Likely cause and fix |
|---|---|
| `Error: Email/Password not set` | Fill in both properties. |
| `Login failed (401)` or `(403)` | Wrong credentials. Check that you can sign in to the iAquaLink app with them. |
| `Robot list failed (…)` | The device-list endpoint was unreachable or rejected the request. Check the controller's internet access, then run **Refresh Robot List**. |
| `No robots found on account` | The account has no devices, or its only device is named "VR" (which is excluded). |
| `Error: no robot selected` | Pick a robot in the **Robot** dropdown. |
| `Handshake failed` | The WebSocket upgrade was rejected, usually because the session expired. Change and restore the password to force a fresh login, or wait for the next poll to log in again. |
| Status sticks at `Start command sent` | The server didn't confirm the command within 8 seconds. Check the robot in the iAquaLink app; it may be offline or out of the water. |
| Icon doesn't match the robot | Turn on polling, or start/stop the robot once from Control4 to resync it. |
| **Canister** never changes from `Unknown` | Your robot may not report `canister` at that path. Turn on `Print` and look for `canister=` lines or the raw status response in the log. |

## Known limitations

- **Unofficial API:** an update on Zodiac's side can break the driver.
- **Robot families:** start/stop uses the `vr` command set. Robots that use a different command set will log in and appear in the list but may not respond.
- **The "VR" exclusion matches device names, not device types.** If your account lists the robot itself with the name "VR", it won't appear in the dropdown. To change the filter, edit `EXCLUDED_DEVICE_NAMES` in `driver.lua`.
- **The canister mapping comes from community reverse-engineering** and hasn't been confirmed on every model.
- **No canister updates without polling:** with polling off, the canister status only updates when the robot is started or stopped.
- **Undeclared events:** the driver also calls `FireEvent("Cleaning")` and `FireEvent("Idle")` when the state changes, but those events aren't declared in `driver.xml`, so they don't appear in Composer programming.
- **Outdated built-in documentation:** `www/documentation.rtf` inside the driver is still the generic "Scenario Experience Button" template text.

## Security notes

- The iAquaLink password is stored as a Composer password property in Director and is sent only to the Zodiac login endpoint over TLS.
- Session tokens are kept in memory only and are not saved across restarts.
- The device-list request passes the session token as a URL query parameter, which is how that endpoint expects it. Anything that logs full URLs, such as debug logs, may capture the token.
- The `API_KEY` constant in `driver.lua` is the public application key embedded in the iAquaLink app; it isn't an account secret.

## Package contents

```
PoolRobotButton.c4z
├── driver.xml            Driver definition: properties, actions, events, icons
├── driver.lua            Driver logic
├── dkjson.lua            JSON library (MIT, David Kolf)
├── icons/                Source artwork (idle.PNG, cleaning.PNG)
└── www/
    ├── documentation.rtf Composer documentation tab (template text)
    ├── icons/
    │   ├── device_sm.png / device_lg.png   Composer icons (16 / 32 px)
    │   └── device/                          App icons, default + selected,
    │                                        70 / 90 / 300 / 512 / 1024 px
    └── icons-old/        Earlier icon set, not referenced by driver.xml
```

## Version history

| Version | Changes |
|---|---|
| 13 | Added the **Canister** property and the **Canister Full** / **Canister Emptied** events. |
| 12 | Proxy now defaults to the name "Pool Robot"; Composer now uses the robot icons (new 16 and 32 px images). |
| 11 | Added the **Robot** dropdown loaded from the iAquaLink account, the **Refresh Robot List** action and the "VR" name filter. **Robot Serial** became read-only. |
| 10 | Added status polling, icon states (idle/cleaning) synced from the robot, and the **Current State** property. |
| 7 | Initial start/stop over the WebSocket API with a tap-to-toggle button. |
