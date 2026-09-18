// The once-a-day export with nobody tapping anything.
//
// Two triggers, because neither is guaranteed:
//   HKObserverQuery on step count, with background delivery enabled at
//     `.hourly` — Health wakes the app when new steps land.
//   BGAppRefreshTask, which iOS schedules when it feels like it.
// Either one runs the 8-day export when the last run is older than 20 h,
// and logs what it did.
//
// 🛑 THE HEALTH DATABASE IS ENCRYPTED WHILE THE PHONE IS LOCKED, and every
// read fails until it is unlocked (HKErrorDatabaseInaccessible). No
// entitlement changes that. So "once a day in the background" means: the
// first time the phone is unlocked after 20 h have passed, when the next
// steps land — in practice the morning pickup, a two-second run nobody
// sees. An attempt that lands on a locked phone is skipped without a word
// and retried within the hour; `lastRun` moves only when a run succeeds.

import BackgroundTasks
import Foundation
import HealthKit
import UIKit

enum Background {
    static let taskID = "com.boulderhopkins.apple-tools.health.refresh"
    static let window = 8
    static let minimumGap: TimeInterval = 20 * 3600

    static func register(exporter: Exporter) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            Task { @MainActor in
                let ran = await runIfDue(exporter: exporter, trigger: "app refresh")
                task.setTaskCompleted(success: ran)
                schedule()
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date().addingTimeInterval(minimumGap)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Task { @MainActor in Log.shared.add("could not schedule app refresh: \(error.localizedDescription)", error: true) }
        }
    }

    @MainActor
    static func enableObserver(exporter: Exporter) {
        let type = HKQuantityType(.stepCount)
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            Task { @MainActor in
                if let error = error {
                    Log.shared.add("observer: \(error.localizedDescription)", error: true)
                } else {
                    _ = await runIfDue(exporter: exporter, trigger: "Health update")
                }
                completion()
            }
        }
        exporter.store.execute(query)
        exporter.store.enableBackgroundDelivery(for: type, frequency: .hourly) { ok, error in
            Task { @MainActor in
                if ok {
                    Log.shared.add("background delivery on: hourly, on new steps; runs once the phone is unlocked and 20 h have passed")
                } else {
                    Log.shared.add("background delivery refused: \(error?.localizedDescription ?? "?")", error: true)
                }
            }
        }
    }

    @MainActor
    static func runIfDue(exporter: Exporter, trigger: String) async -> Bool {
        if let last = exporter.lastRun, Date().timeIntervalSince(last) < minimumGap {
            return false
        }
        // Locked: Health would refuse every read. Not an error, not worth a
        // line; the next hourly wake-up tries again.
        guard UIApplication.shared.isProtectedDataAvailable else { return false }
        Log.shared.add("\(trigger): exporting")
        await exporter.exportRecent(days: window)
        return true
    }
}
