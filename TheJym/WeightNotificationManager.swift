//
//  WeightNotificationManager.swift
//  TheJym
//
//  A local notification on Sundays — the only day weight is ever logged to
//  (BodyWeightView/TodayView both snap to Formatters.nearestPastSunday) —
//  reminding you to log it. Rescheduled fresh every time the app's scene
//  phase changes (TheJymApp.ContentView), same pattern as
//  StreakNotificationManager, so it never fires once this week's entry
//  already exists.
//

import Foundation
import UserNotifications

enum WeightNotificationManager {
    private static let reminderIdentifier = "weightReminder"

    /// Cancels any pending reminder outright — used when the setting's off.
    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
    }

    /// Re-evaluates the reminder: cancels whatever's pending, then (if
    /// enabled, today is Sunday, this week's entry doesn't exist yet, and
    /// reminderHour hasn't already passed) schedules a fresh one-shot for
    /// later today. A no-op on any day that isn't Sunday.
    static func refresh(enabled: Bool, alreadyLoggedThisWeek: Bool, reminderHour: Int, now: Date = .now) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
        guard enabled, !alreadyLoggedThisWeek else { return }

        let cal = Calendar.current
        guard cal.component(.weekday, from: now) == 1 else { return }   // 1 = Sunday

        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = reminderHour
        comps.minute = 0
        guard let fireDate = cal.date(from: comps), fireDate > now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Fat fuck"
        content.body = "Get on the scale. 🐷"
        content.sound = .default

        let triggerComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComps, repeats: false)
        let request = UNNotificationRequest(identifier: reminderIdentifier, content: content, trigger: trigger)
        center.add(request)
    }
}
