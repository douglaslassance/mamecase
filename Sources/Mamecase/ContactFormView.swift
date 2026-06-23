import SwiftUI

struct ContactFormView: View {
    @Environment(\.dismiss) var dismiss
    @State private var email: String = ""
    @State private var subject: String = ""
    @State private var message: String = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isSending = false
    @State private var lastFeedbackTime: Date? = nil

    var body: some View {
        VStack(spacing: 16) {
            Text("Contact")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 4)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Your Email")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("your.email@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Subject")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("Enter subject", text: $subject)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Message")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            Spacer()

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSending)

                Button("Send") {
                    sendFeedback()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty ||
                         subject.trimmingCharacters(in: .whitespaces).isEmpty ||
                         message.trimmingCharacters(in: .whitespaces).isEmpty ||
                         isSending ||
                         !isValidEmail(email))
            }
        }
        .padding(24)
        .frame(width: 400, height: 440)
        .alert("Feedback", isPresented: $showAlert) {
            Button("OK") {
                if alertMessage.contains("successfully") {
                    dismiss()
                }
            }
        } message: {
            Text(alertMessage)
        }
    }

    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }

    private func sanitizeInput(_ input: String) -> String {
        var sanitized = input
        sanitized = sanitized.replacingOccurrences(of: "<script.*?>.*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
        sanitized = sanitized.replacingOccurrences(of: "javascript:", with: "", options: [.regularExpression, .caseInsensitive])
        if sanitized.count > 1000 {
            sanitized = String(sanitized.prefix(1000))
        }
        return sanitized
    }

    private func canSendFeedback() -> Bool {
        guard let lastTime = lastFeedbackTime else {
            return true
        }
        return Date().timeIntervalSince(lastTime) > 300
    }

    private func sendFeedback() {
        guard canSendFeedback() else {
            alertMessage = "Please wait before sending another feedback message."
            showAlert = true
            return
        }

        guard isValidEmail(email) else {
            alertMessage = "Please enter a valid email address."
            showAlert = true
            return
        }

        let sanitizedEmail = sanitizeInput(email)
        let sanitizedSubject = "[Mamecase] " + sanitizeInput(subject)
        let sanitizedMessage = sanitizeInput(message)

        guard !sanitizedEmail.isEmpty, !sanitizedSubject.isEmpty, !sanitizedMessage.isEmpty else {
            alertMessage = "Invalid input detected. Please check your message."
            showAlert = true
            return
        }

        isSending = true

        guard let url = URL(string: "https://formspree.io/f/xbddrwbe") else {
            alertMessage = "Invalid form configuration"
            showAlert = true
            isSending = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = [
            "email": sanitizedEmail,
            "subject": sanitizedSubject,
            "message": sanitizedMessage
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            alertMessage = "Failed to prepare feedback"
            showAlert = true
            isSending = false
            return
        }

        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isSending = false

                if let error = error {
                    alertMessage = "Failed to send feedback: \(error.localizedDescription)"
                    showAlert = true
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        alertMessage = "Feedback sent successfully! Thank you for your input."
                        showAlert = true
                        lastFeedbackTime = Date()
                    } else {
                        alertMessage = "Failed to send feedback."
                        showAlert = true
                    }
                }
            }
        }.resume()
    }
}
