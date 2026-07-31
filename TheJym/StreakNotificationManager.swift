//
//  StreakNotificationManager.swift
//  TheJym
//
//  A single local notification reminding you to log a workout or rest day
//  before your rest-bank streak takes a hit — rescheduled fresh every time
//  the app's scene phase changes (TheJymApp.ContentView), so it always
//  reflects today's actual logged state instead of nagging blindly. Uses one
//  fixed identifier throughout, so scheduling naturally replaces whatever
//  was pending rather than needing to track/cancel duplicates.
//

import Foundation
import UserNotifications

enum StreakNotificationManager {
    private static let reminderIdentifier = "streakReminder"

    /// Requests notification permission if it's never been asked before —
    /// safe to call repeatedly (a no-op once the user's already answered).
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Cancels any pending reminder outright — used when the setting's off.
    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
    }

    /// Re-evaluates today's reminder: cancels whatever's pending, then (if
    /// enabled, nothing's logged yet today, and reminderHour hasn't already
    /// passed) schedules a fresh one-shot for later today. Never schedules
    /// for a future day — each call only ever concerns "today."
    static func refresh(enabled: Bool, loggedToday: Bool, reminderHour: Int, now: Date = .now) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
        guard enabled, !loggedToday else { return }

        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = reminderHour
        comps.minute = 0
        guard let fireDate = cal.date(from: comps), fireDate > now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Lazy fuck"
        content.body = "Log something. Streak's dying. 🐖"
        content.sound = .default

        let triggerComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComps, repeats: false)
        let request = UNNotificationRequest(identifier: reminderIdentifier, content: content, trigger: trigger)
        center.add(request)
    }
}
