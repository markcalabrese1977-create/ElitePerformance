import SwiftUI
import SwiftData

/// Main 3-tab shell for the app:
/// - Today  = what's up next + start session
/// - Program = full block view / edit
/// - History = past sessions
struct RootTabView: View {
    var body: some View {
        TabView {
            // TODAY TAB
            NavigationStack {
                TodayView()
            }
            .tabItem {
                Image(systemName: "bolt.fill")
                Text("Today")
            }

            // PROGRAM TAB (hub / plan)
            NavigationStack {
                HomeView() // HomeView already wraps ProgramPlanView + change program
            }
            .tabItem {
                Image(systemName: "list.bullet.rectangle")
                Text("Program")
            }

            // HISTORY TAB
            NavigationStack {
                HistoryView()
            }
            .tabItem {
                Image(systemName: "clock.arrow.circlepath")
                Text("History")
            }
        }
    }
}
