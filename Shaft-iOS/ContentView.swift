import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.artframe")
                .imageScale(.large)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Shaft-iOS")
                .font(.largeTitle.bold())
            Text("Hello, SwiftUI!")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
