import SwiftUI

struct ContentView: View {
    @State private var text = ""
    @AppStorage(
        KeyboardSettings.showsDirectionalSymbolsKey,
        store: KeyboardSettings.sharedDefaults
    ) private var showsDirectionalSymbols = KeyboardSettings.showsDirectionalSymbols
    @AppStorage(
        KeyboardSettings.autoCommitCompositionKey,
        store: KeyboardSettings.sharedDefaults
    ) private var autoCommitComposition = KeyboardSettings.autoCommitComposition
    @AppStorage(
        KeyboardSettings.remembersSelectionsKey,
        store: KeyboardSettings.sharedDefaults
    ) private var remembersSelections = KeyboardSettings.remembersSelections
    @State private var showsClearConfirmation = false
    @State private var learningMessage: String?

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

                Toggle("選完字後自動提交", isOn: $autoCommitComposition)
                Text("關閉後需按「確定」提交組字內容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("記憶選字", isOn: $remembersSelections)
                Text("提交後記住新詞與選字次數。鍵盤需要開啟「允許完整取用」才能寫入；資料只保存在此裝置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("清除學習資料", role: .destructive) {
                    showsClearConfirmation = true
                }
                if let learningMessage {
                    Text(learningMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                NavigationLink("第三方授權") {
                    ThirdPartyLicensesView()
                }
            }
            .padding()
            .navigationTitle("FlickZhuyin")
            .confirmationDialog("清除所有新詞與選字次數？", isPresented: $showsClearConfirmation) {
                Button("清除學習資料", role: .destructive) {
                    Task {
                        do {
                            guard let url = KeyboardSettings.userLearningURL else {
                                throw UserLearningError.database("App Group 容器不可用")
                            }
                            let store = try UserLearningStore(url: url, writable: true)
                            try store.clear()
                            learningMessage = "已清除學習資料。"
                        } catch {
                            learningMessage = "清除失敗：\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
