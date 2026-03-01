import SwiftUI

struct SafetyGateSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Safety Gate")
                    .font(.title2.weight(.semibold))
                Text("These values apply across all open documents and presentation windows.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    settingsSlider(
                        title: "Confidence Threshold",
                        value: $settings.confidenceThreshold,
                        range: 0.0...1.0,
                        step: 0.01
                    )
                    settingsSlider(
                        title: "Cooldown (seconds)",
                        value: $settings.cooldownSeconds,
                        range: 0.0...5.0,
                        step: 0.05
                    )
                    settingsSlider(
                        title: "Dwell (seconds)",
                        value: $settings.dwellSeconds,
                        range: 0.0...3.0,
                        step: 0.05
                    )
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(minWidth: 360, idealWidth: 390, maxWidth: 420, minHeight: 230, alignment: .topLeading)
    }

    private func settingsSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
