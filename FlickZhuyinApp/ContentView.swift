import SwiftUI

struct ContentView: View {
    @State private var text = ""
    @AppStorage(
        KeyboardSettings.showsDirectionalSymbolsKey,
        store: KeyboardSettings.sharedDefaults
    ) private var showsDirectionalSymbols = KeyboardSettings.showsDirectionalSymbols

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

                Toggle("顯示四方向符號", isOn: $showsDirectionalSymbols)
                Text("關閉後注音與標點按鍵只顯示中央符號。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

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
