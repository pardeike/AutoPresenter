import SwiftUI

struct SafetyGateSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title3.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Safety Gate") {
                        VStack(alignment: .leading, spacing: 10) {
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
                        .padding(.top, 2)
                    }

                    GroupBox("Realtime Timing") {
                        VStack(alignment: .leading, spacing: 10) {
                            settingsMillisecondsSlider(
                                title: "Commit Interval (ms)",
                                value: $settings.realtimeSilenceDurationMilliseconds,
                                range: 120...1_000,
                                step: 20
                            )
                            settingsIntegerSlider(
                                title: "Max Output Tokens",
                                value: $settings.realtimeMaxOutputTokens,
                                range: 80...420,
                                step: 10
                            )
                            settingsMillisecondsSlider(
                                title: "Mark Cooldown (ms)",
                                value: $settings.realtimeMarkCooldownMilliseconds,
                                range: 0...3_000,
                                step: 50
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Mark Evidence Mode")
                                    Spacer()
                                    Text(settings.markingStrictnessMode.title)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Picker("Mark Evidence Mode", selection: $settings.markingStrictnessMode) {
                                    ForEach(MarkingStrictnessMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Text(settings.markingStrictnessMode.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }

                    GroupBox("Quote Audio") {
                        VStack(alignment: .leading, spacing: 10) {
                            settingsMillisecondsSlider(
                                title: "Start Delay (ms)",
                                value: $settings.quoteAudioStartDelayMilliseconds,
                                range: 0...10_000,
                                step: 50
                            )
                            settingsMillisecondsSlider(
                                title: "Post-Playback Wait (ms)",
                                value: $settings.quoteAudioPostPlaybackWaitMilliseconds,
                                range: 0...10_000,
                                step: 50
                            )
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)
            }
        }
        .padding(16)
        .frame(width: 460, height: 500, alignment: .topLeading)
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

    private func settingsMillisecondsSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded())) ms")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func settingsIntegerSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
