import SwiftUI

struct ThirdPartyLicensesView: View {
    private let notices: String

    init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            notices = contents
        } else {
            notices = "無法載入第三方授權聲明。"
        }
    }

    var body: some View {
        ScrollView {
            Text(notices)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle("第三方授權")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ThirdPartyLicensesView()
    }
}
