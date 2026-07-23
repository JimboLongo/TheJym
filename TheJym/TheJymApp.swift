//
//  TheJymApp.swift
//  TheJym
//
//  Created by Jimmy Long on 7/23/26.
//

import SwiftUI
import CoreData

@main
struct TheJymApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
