# Firestore Android SDK 26.0.2 Performance Regression

## Summary

Upgrading the native Firebase Android SDK from **BoM 34.1.0** (Cloud Firestore 26.0.0) to **BoM 34.4.0** (Cloud Firestore 26.0.2) causes **snapshot listeners to stall or deliver with extreme latency** on Android under concurrent load.

This regression was introduced by the "performance improvements" in Firestore 26.0.2, most likely:

- [#7376](https://github.com/firebase/firebase-android-sdk/issues/7376) — Replaced the deprecated `AsyncTask` thread pool with a self-managed thread pool
- [#7370](https://github.com/firebase/firebase-android-sdk/issues/7370) — Internal memoization of calculated document data
- [#7388](https://github.com/firebase/firebase-android-sdk/issues/7388) — Avoiding excessive `Comparator` instance creation
- [#7389](https://github.com/firebase/firebase-android-sdk/issues/7389) — Using unsorted `HashMap` instead of sorted `TreeMap`

## Impact

Our production Flutter app experienced **complete Firestore stalling** on Android after upgrading from `cloud_firestore: 6.1.2` (BoM 34.1.0) to `cloud_firestore: 6.1.3` (BoM 34.4.0). Symptoms:

- First visit to each screen works (snapshots arrive in 86–261ms)
- Subsequent visits stall — `WatchStream` subscribes but the snapshot callback **never fires**
- Dead silence periods of **5–60+ seconds** with no snapshot delivery
- Cache loads that normally take 80–680ms take **5+ seconds**
- The app becomes effectively unusable

Pinning all Firebase packages back to their BoM 34.1.0 versions **immediately resolves the issue**.

## Usage Pattern That Triggers the Regression

The stalling occurs under a combination of factors common to real-world Flutter apps:

1. **6–10 concurrent snapshot listeners** across tabs, dashboard widgets, and detail editors
2. **Large documents** with 50+ fields, deeply nested maps, arrays of IDs, and small inline base64 images (~3 KB each)
3. **Complex queries** using `Filter.or` with multiple branches and `whereIn` filters
4. **Background CPU work** (optional — the issue reproduces even without it, but CPU contention makes it worse)

None of these are unusual or unsupported patterns — they all work correctly on Firestore 26.0.0.

## Reproduction Steps

### Prerequisites

1. A Firebase project with Firestore enabled
2. An Android device or emulator
3. Flutter SDK 3.32+ (latest stable)

### Setup

```bash
flutter pub get
```

Add your Firebase configuration (e.g., via `flutterfire configure` or manually adding `google-services.json`).

Deploy the included `firestore.rules` (open read/write) and composite indexes to your project:

```bash
firebase -P <your-project-id> deploy --only firestore:rules
firebase -P <your-project-id> deploy --only firestore:indexes
```

Or use the included `Taskfile.yml`:

```bash
task indexes:deploy GOOGLE_CLOUD_PROJECT=<your-project-id>
```

The composite indexes in `firestore.indexes.json` are required for the `Filter.or`, `whereIn`, and `orderBy` queries used by the snapshot listeners. Allow a few minutes for indexes to finish building before running the test.

### Reproduce the Regression

1. **Run with current (broken) SDK:**
   ```bash
   flutter run -d <android-device>
   ```

2. In the app, follow the numbered steps:
   1. **Seed Data** — populates the `perf_test` collection with 30 large documents
   2. **Start Listeners** — opens 8 concurrent snapshot listeners with various query types (`Filter.or`, `whereIn`, equality, nested field filters)
   3. **Start Canary** — begins automated writes to a canary document every 3 seconds, measuring snapshot delivery latency for each write. If a snapshot doesn't arrive within 10 seconds, the write is counted as "missed."
   - Optionally: **Start CPU Load** — adds background isolate work (the issue reproduces without this, but it can make it worse)

3. **Observe the log output:**
   - **CANARY #N: Xms** (cyan) — snapshot delivered with measured latency
   - **CANARY SLOW #N** (orange) — delivered but exceeded 10s timeout
   - **CANARY MISSED #N** (red) — snapshot never arrived within timeout
   - **CANARY SUMMARY** — printed when canary is stopped, with total writes, received, missed, avg/max latency
   - **Expected (26.0.0):** All canary writes received, avg latency <500ms, 0 missed
   - **Actual (26.0.2):** Canary writes stall or miss, avg latency 5–60+ seconds

4. **Verify fix by downgrading:** Add to `pubspec.yaml`:
   ```yaml
   dependency_overrides:
     cloud_firestore: 6.1.2
     cloud_firestore_platform_interface: 7.0.6
     firebase_core: 4.4.0
   ```
   Run `flutter clean && flutter pub get` and repeat the test — canary latency returns to normal.

## Environment

- **Flutter:** 3.32+ (latest stable)
- **Dart:** 3.11+
- **Working:** `cloud_firestore: 6.1.2` → BoM 34.1.0 → Firestore native 26.0.0
- **Broken:** `cloud_firestore: 6.1.3` → BoM 34.4.0 → Firestore native 26.0.2
- **Platform:** Android

## Related

The thread pool change in [#7376](https://github.com/firebase/firebase-android-sdk/issues/7376) is the most likely root cause. The `AsyncTask` thread pool was well-integrated with Android's threading model and Flutter's platform channel dispatch. The replacement self-managed thread pool may have different scheduling characteristics that cause thread starvation or priority inversion when:

- Multiple Firestore queries compete for the same pool
- Background CPU work (running on other cores) causes scheduler contention
- Large document deserialization blocks pool threads for extended periods
