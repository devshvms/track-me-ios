import SwiftUI

struct SwipeToTriggerSlider: View {
    var onTriggered: () -> Void
    var text: String = "Swipe for SOS"
    
    @State private var offset: CGFloat = 0
    @State private var isTriggered: Bool = false
    @State private var countdown: Int = 10
    @State private var timer: Timer?
    @State private var animationProgress: CGFloat = 0
    
    let thumbSize: CGFloat = 64
    
    var body: some View {
        GeometryReader { geometry in
            let maxDrag = geometry.size.width - thumbSize
            
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: thumbSize / 2)
                    .fill(isTriggered ? Color.red.opacity(0.8) : Color.red.opacity(0.3))
                
                if !isTriggered {
                    Text(text)
                        .font(.subheadline).bold()
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                    
                    Circle()
                        .fill(Color.red)
                        .frame(width: thumbSize, height: thumbSize)
                        .overlay(
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.white)
                        )
                        .offset(x: offset)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if value.translation.width > 0 {
                                        offset = min(maxDrag, value.translation.width)
                                    }
                                }
                                .onEnded { value in
                                    if offset > maxDrag * 0.95 {
                                        let impact = UIImpactFeedbackGenerator(style: .heavy)
                                        impact.impactOccurred()
                                        startCountdown()
                                    } else {
                                        withAnimation(.spring()) {
                                            offset = 0
                                        }
                                    }
                                }
                        )
                } else {
                    RoundedRectangle(cornerRadius: thumbSize / 2)
                        .fill(Color(red: 0.7, green: 0, blue: 0))
                        .frame(width: max(thumbSize, geometry.size.width * animationProgress))
                        .animation(.linear(duration: Double(countdown)), value: animationProgress)
                        
                    HStack(alignment: .center) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                        Text("Cancel (\(countdown))")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        cancelCountdown()
                    }
                }
            }
        }
        .frame(height: thumbSize)
    }
    
    private func startCountdown() {
        isTriggered = true
        countdown = 10
        animationProgress = 1.0
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if countdown > 1 {
                countdown -= 1
            } else {
                timer?.invalidate()
                timer = nil
                onTriggered()
                reset()
            }
        }
    }
    
    private func cancelCountdown() {
        timer?.invalidate()
        timer = nil
        reset()
    }
    
    private func reset() {
        isTriggered = false
        offset = 0
        animationProgress = 0
    }
}
