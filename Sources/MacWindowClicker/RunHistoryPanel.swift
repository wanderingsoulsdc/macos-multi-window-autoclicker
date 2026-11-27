import SwiftUI
import ClickerCore

struct RunHistoryPanel: View {
    let records: [RunRecord]

    var body: some View {
        ScrollView {
            // One text surface keeps scrolling independent of changing row identities.
            Text(verbatim: records.isEmpty ? "运行后显示记录。" : historyText)
                .font(.system(size: 10).monospacedDigit()).lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 5)
        }.frame(height: 90)
    }

    private var historyText: String {
        records.map { "\($0.time.formatted(date: .numeric, time: .standard))  \($0.message)" }
            .joined(separator: "\n")
    }
}
