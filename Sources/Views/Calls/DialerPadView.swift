import SwiftUI

public struct DialerPadView: View {
    @Binding var phoneNumber: String
    var onCall: (String) -> Void
    var onDigitTapped: ((Character) -> Void)?

    private let keyMatrix: [[(digit: Character, letters: String)]] = [
        [("1", ""), ("2", "A B C"), ("3", "D E F")],
        [("4", "G H I"), ("5", "J K L"), ("6", "M N O")],
        [("7", "P Q R S"), ("8", "T U V"), ("9", "W X Y Z")],
        [("*", ""), ("0", "+"), ("#", "")]
    ]

    public var body: some View {
        VStack(spacing: 20) {
            // Number Display Field
            HStack {
                Spacer()
                Text(phoneNumber.isEmpty ? "Enter number" : phoneNumber)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(phoneNumber.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()

                if !phoneNumber.isEmpty {
                    Button {
                        if !phoneNumber.isEmpty {
                            phoneNumber.removeLast()
                        }
                    } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
            }
            .frame(height: 48)
            .padding(.horizontal, 16)

            // 3x4 Grid of Dial Keys
            VStack(spacing: 12) {
                ForEach(0..<keyMatrix.count, id: \.self) { row in
                    HStack(spacing: 16) {
                        ForEach(0..<keyMatrix[row].count, id: \.self) { col in
                            let item = keyMatrix[row][col]
                            DialKeyButton(digit: item.digit, letters: item.letters) {
                                phoneNumber.append(item.digit)
                                onDigitTapped?(item.digit)
                            } onLongPress: {
                                if item.digit == "0" {
                                    phoneNumber.append("+")
                                    onDigitTapped?("+")
                                }
                            }
                        }
                    }
                }
            }

            // Green Call Button
            Button {
                let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onCall(trimmed)
            } label: {
                ZStack {
                    Circle()
                        .fill(phoneNumber.isEmpty ? Color.gray.opacity(0.4) : Color.green)
                        .frame(width: 64, height: 64)
                    Image(systemName: "phone.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(phoneNumber.isEmpty)
        }
        .frame(maxWidth: 320)
    }
}

public struct DialKeyButton: View {
    let digit: Character
    let letters: String
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil

    @State private var isPressed = false

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(String(digit))
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                if !letters.isEmpty {
                    Text(letters)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    onLongPress?()
                }
        )
    }
}
