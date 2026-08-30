import SwiftUI

struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var isSending = false
    @State private var isSent = false
    @State private var errorMessage: String?
    @State private var sendFeedbackTrigger = 0
    @FocusState private var messageIsFocused: Bool

    private let service = FeedbackService()
    private let maximumLength = 1_500

    var body: some View {
        NavigationStack {
            ZStack {
                BandLoopTheme.background.ignoresSafeArea()

                if isSent {
                    successView
                } else {
                    form
                }
            }
            .navigationTitle("개선 제안")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기", systemImage: "xmark") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.bold))
                }
            }
        }
        .tint(BandLoopTheme.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            messageIsFocused = true
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("어떤 점이 더 좋아지면 좋을까요?")
                    .font(.title2.bold())
                Text("불편했던 점이나 원하는 기능을 자유롭게 적어주세요.")
                    .font(.subheadline)
                    .foregroundStyle(BandLoopTheme.secondaryText)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: limitedMessage)
                    .focused($messageIsFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(12)

                if message.isEmpty {
                    Text("다양한 의견을 남겨주세요!")
                        .font(.body)
                        .foregroundStyle(BandLoopTheme.secondaryText.opacity(0.72))
                        .padding(.horizontal, 17)
                        .padding(.vertical, 21)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 220)
            .background(BandLoopTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(messageIsFocused ? BandLoopTheme.accent.opacity(0.55) : Color.white.opacity(0.07), lineWidth: 1)
            }

            HStack {
                Spacer()
                Text("\(message.count)/\(maximumLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(BandLoopTheme.secondaryText)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BandLoopTheme.coral)
            }

            Spacer(minLength: 0)

            Button(action: send) {
                HStack(spacing: 9) {
                    if isSending {
                        ProgressView()
                            .tint(.black)
                        Text("보내는 중…")
                    } else {
                        Label("보내기", systemImage: "paperplane.fill")
                    }
                }
                .font(.headline.bold())
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .foregroundStyle(Color.black)
                .background(BandLoopTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(FeedbackSendButtonStyle())
            .disabled(isSending)
            .sensoryFeedback(.impact(weight: .medium), trigger: sendFeedbackTrigger)
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(Color.black)
                .frame(width: 72, height: 72)
                .background(BandLoopTheme.accent, in: Circle())

            Text("의견을 보냈어요")
                .font(.title2.bold())

            Text("직접 확인하고 BandLoop를 더 좋은 연습 도구로 다듬을게요.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(BandLoopTheme.secondaryText)

            Button("확인") {
                dismiss()
            }
            .font(.headline.bold())
            .foregroundStyle(Color.black)
            .frame(width: 160, height: 50)
            .background(BandLoopTheme.accent, in: Capsule())
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(30)
    }

    private var limitedMessage: Binding<String> {
        Binding(
            get: { message },
            set: { message = String($0.prefix(maximumLength)) }
        )
    }

    private func send() {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            errorMessage = "내용을 한 글자 이상 입력해 주세요."
            return
        }

        sendFeedbackTrigger += 1
        messageIsFocused = false
        errorMessage = nil
        isSending = true

        Task {
            do {
                try await service.submit(trimmedMessage)
                await MainActor.run {
                    isSending = false
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        isSent = true
                    }
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? "의견을 보내지 못했어요."
                }
            }
        }
    }
}

private struct FeedbackSendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.1 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
