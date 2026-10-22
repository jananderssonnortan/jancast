import SwiftUI

struct PinSheet: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @FocusState private var focused: Bool

    private var device: Device? { model.devices.first { $0.id == model.pairingDeviceID } }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            VStack(spacing: 6) {
                Text("Pair with \(device?.displayName ?? "Apple TV")")
                    .font(.title2.weight(.semibold))
                Text(model.pairingAwaitingPin
                     ? "Enter the 4-digit code shown on your TV."
                     : "Asking the Apple TV to show a code…")
                    .foregroundStyle(.secondary)
            }

            TextField("", text: $pin, prompt: Text("0000"))
                .font(.system(size: 34, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .focused($focused)
                .disabled(!model.pairingAwaitingPin || model.pairingBusy)
                .onChange(of: pin) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(4))
                    if digits != new { pin = digits }
                }
                .onSubmit(submit)

            Group {
                if let err = model.pairingError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if model.pairingBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Pairing is needed only once per Apple TV.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(height: 20)

            HStack {
                Button("Cancel", role: .cancel) { model.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Pair", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.count != 4 || model.pairingBusy || !model.pairingAwaitingPin)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { focused = true }
        .onChange(of: model.pairingAwaitingPin) { _, v in if v { focused = true } }
    }

    private func submit() {
        guard pin.count == 4 else { return }
        model.submitPin(pin)
    }
}
