import SwiftUI

struct ContentView: View {
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keyboard Test")
                    .font(.headline)

                TextEditor(text: $text)
                    .font(.body)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                    }
                    .accessibilityLabel("Keyboard test text")

                NavigationLink("第三方授權") {
                    ThirdPartyLicensesView()
                }
            }
            .padding()
            .navigationTitle("FlickZhuyin")
        }
    }
}

#Preview {
    ContentView()
}
