# Android foreground GPS recording

Design and operating notes for the piece that keeps recording alive when the
phone screen is off. Implemented in `ideas/android_plan.txt` phases 1–2
(hardening, lifecycle), 3 (permissions/compatibility) and 4 (testing status).

## Why this exists

On Android 12+ (API 31+) an app whose activity is stopped is "background",
and Android delivers no location fixes to background apps. Turning the screen
off therefore silenced device GPS recording entirely. The sanctioned fix is a
**foreground `location` service**: while it runs, the OS treats the process as
foreground and keeps feeding the receiver stream.

## Responsibilities

The foreground service is purely an elevation contract. It holds no GPS logic;
the Dart side owns the fix stream through geolocator. The controller starts it
when the device stream starts and stops it when the stream stops.

```
beginRun / resume / resumeFromSnapshot (running)
        │
        ▼
_startDeviceStream ──► runForegroundLifespan.start()          ──► native service
        │                     │                                      startForeground(type=location)
        │                     │  return failure or null               + "Recording your run" notification
        │                     ▼
        │              BackgroundProtection:
        │                starting ─► active   (success, distinguishable!)
        │                ─► unavailable + reason (failure, said out loud)
        ▼
pause / finish / dismissRun / dispose
        │
        ▼
_stopDeviceStream ──► runForegroundLifespan.stop() ──► stopService ─► notification removed
```

## Startup is observable (Phase 1)

`RunForegroundLifespan.start()` returns `Future<ForegroundStartFailure?>`
(`null` = the platform took the start). Every native failure maps to a typed
reason — never silently swallowed, never assumed away:

| Native code              | ForegroundStartFailure       | UI                              |
| ---                      | ---                          | ---                             |
| `permission-denied`      | `denied`                     | live-screen banner + diagnostics |
| `security`               | `denied`                     | same                            |
| `location-disabled`      | `locationDisabled`           | same                            |
| `not-allowed`            | `notAllowed`                 | same                            |
| `start-failed`           | `platform`                   | same                            |
| (unexpected)             | `unknown`                    | same                            |
| no registrar / no binding| `unavailable`                | diagnostics only                |

The controller keeps recording state (`LiveRunState.status`) **separate** from
foreground-service state (`LiveRunState.backgroundProtection`). This is a
deliberate product decision (the plan invites it): GNSS recording with the
screen on does not need the service, so a failed start does **not** abort the
run. It is logged with the typed reason and surfaced as a
"SCREEN-OFF RECORDING NOT PROTECTED" banner on the live screen plus a
`Foreground service` row in the developer diagnostics — the UI never claims
protection it does not have.

## Lifecycle rules (Phase 2)

- **Start** on `_startDeviceStream` (START / RESUME / restored running
  snapshot), **stop** on `_stopDeviceStream` (pause / finish / dismiss /
  dispose). Exactly the device-stream lifetime.
- **Idempotent**: a repeated pause, or a repeated stop after one already
  happened, issues no second platform request. The state-machine guards plus a
  `_foregroundActive` flag make start/stop one-shot per transition.
- **No races**: a `start()` still in flight when a stop arrives is superseded
  (`lifespan != _foregroundLifespan`), and the platform processes the start
  and stop intents in channel order — a finish while startup is pending leaves
  no orphaned service, verified by test.
- **Dispose-safe**: the seam instance is captured at start because `stop` can
  run from `ref.onDispose`, where Riverpod forbids reading providers. A late
  start settling after dispose touches nothing.

### Process death — explicitly unsupported (Option A)

A process kill or force-stop **interrupts recording**. The Dart session is
gone and is not restored. The service therefore runs `START_NOT_STICKY`: the
OS must not resurrect it alone, because a resurrected service would show a
"Recording your run" notification for a recording that no longer exists.
Full recovery (persisting and restoring the session after process recreation)
is a separate feature, deliberately out of scope (see `ideas/android_plan.txt`
Phase 2, Option B).

## Permissions and compatibility (Phase 3)

Manifest (`app/android/app/src/main/AndroidManifest.xml`):

- `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_LOCATION` (the latter required
  to *declare* location type from API 34).
- `<service android:name=".RecordingForegroundService"
  android:exported="false" android:foregroundServiceType="location"/>`.
- Pre-run acquisition (`DeviceGpsSource.ensureAvailable`) already gates the
  recording on the location permission and location services being on; the
  native start re-checks both (`permission-denied` / `location-disabled`) as
  defence in depth.

Version behaviour:

- API 26+ (`startForegroundService`), API 29+ (`startForeground` with
  `FOREGROUND_SERVICE_TYPE_LOCATION`), API 31+ background-start refused
  (`not-allowed`, only possible if the start were ever attempted from the
  background — the controller always starts from a user-visible transition).
- Notification channel created on API 26+ (`recording`, low importance);
  `stopForeground(STOP_FOREGROUND_REMOVE)` removes it on API 24+.
- minSdk 24 / targetSdk 36 (Flutter 3.41 defaults; the project overrides
  neither).

## Verification status (Phase 4)

Automated (all in CI):

- `recording_service_lifespan_test.dart` — lifecycle, failed-start surfaced,
  finish-while-pending, idempotent stops, scenario no-touch.
- `run_foreground_channel_test.dart` — the native error-code → typed-failure
  mapping and missing-registrar behaviour.
- `live_run_protection_banner_test.dart` — the banner appears only for
  `unavailable`.
- Full Flutter suite, `flutter analyze`, and the Android debug build
  (`make build`, `MAP_VIEW=true`) are green.

On physical hardware (not run in this workspace — needs a phone):

- Start a recording, lock the screen, record 5–10 minutes; confirm fixes keep
  arriving (the live FIXES counter) and the saved track has no gap.
- Walk a known route with the screen locked; inspect the track for gaps.
- Pause/resume with the screen locked (requires unlocking to resume).
- Finish and confirm the notification disappears.
- Repeat with battery saver enabled (OEM power managers are the next most
  likely gap source; a wake-lock and battery-optimisation guidance are the
  documented follow-ups).

**Android 17 compatibility is unverified**: the analysis above covers API
24–36 (Flutter 3.41 defaults) and APK compilation with targetSdk 36, but no
Android 17 device or emulator run has validated screen-off GPS on that build.
Android 15's 6-hour location-foreground-service timeout also stands for
≈6 h + recordings.