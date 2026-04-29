import SwiftUI

struct ContentView: View {
    @State private var auth = AuthViewModel()

    var body: some View {
        Group {
            if auth.token != nil {
                LoggedInView(auth: auth)
            } else {
                LoginView(auth: auth)
            }
        }
    }
}

#Preview {
    ContentView()
}
