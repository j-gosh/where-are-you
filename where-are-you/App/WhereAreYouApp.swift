//
//  WhereAreYouApp.swift
//  where-are-you
//
//  Created on 5/14/25.
//

import SwiftUI

@main
struct WhereAreYouApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Built at launch, including background launches for location and region events.
    @State private var dependencies = AppDependencies.make()

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
                .dependencies(dependencies)
                .task {
                    let push = dependencies.push
                    appDelegate.onDeviceToken = { token in
                        push?.didRegister(deviceToken: token)
                    }
                }
        }
        .backgroundTask(.appRefresh(SharingService.refreshTaskIdentifier)) { [sharing = dependencies.sharing] in
            await sharing?.refreshInBackground()
        }
    }
}
