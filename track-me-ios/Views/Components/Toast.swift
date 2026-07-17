import SwiftUI

enum ToastStyle {
    case info
    case success
    case error
}

struct Toast: Equatable {
    var message: String
    var style: ToastStyle = .info
}

@Observable
class ToastManager {
    static let shared = ToastManager()
    
    var toast: Toast?
    var showToast = false
    private var workItem: DispatchWorkItem?
    
    func show(message: String, style: ToastStyle = .info, duration: TimeInterval = 3.0) {
        workItem?.cancel()
        
        Task { @MainActor in
            self.toast = Toast(message: message, style: style)
            withAnimation(.spring()) {
                self.showToast = true
            }
            
            let task = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                withAnimation(.spring()) {
                    self.showToast = false
                }
            }
            self.workItem = task
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
        }
    }
}

struct ToastView: View {
    let toast: Toast
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
            Text(toast.message)
                .font(.subheadline)
                .foregroundColor(.white)
            Spacer(minLength: 0)
        }
        .padding()
        .background(Color(UIColor.darkGray))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.3), radius: 5, x: 0, y: 2)
        .padding(.horizontal, 24)
        .padding(.bottom, 24) // Float above tab bar
    }
    
    private var iconName: String {
        switch toast.style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
    
    private var iconColor: Color {
        switch toast.style {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        }
    }
}

struct ToastModifier: ViewModifier {
    var toastManager = ToastManager.shared
    
    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content
            
            if toastManager.showToast, let toast = toastManager.toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            }
        }
    }
}

extension View {
    func withGlobalToasts() -> some View {
        self.modifier(ToastModifier())
    }
}
