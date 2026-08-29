import SwiftUI

struct GamificationRevealView: View {
    let newLevel: GamificationLevel?
    let newAchievements: [String]
    let onDismiss: () -> Void
    
    @State private var isVisible = false
    @State private var scale: CGFloat = 0.5
    @State private var confettiProgress: CGFloat = 0.0
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            
            // Basic Confetti implementation
            GeometryReader { geometry in
                ForEach(0..<100, id: \.self) { i in
                    ConfettiParticleView(progress: confettiProgress, geometry: geometry, index: i)
                }
            }
            .ignoresSafeArea()
            
            VStack(spacing: 24) {
                if let level = newLevel {
                    VStack(spacing: 8) {
                        Text("Level Up!")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                        
                        Text("You've reached Level \(level.level)")
                            .font(.title3)
                            .fontWeight(.semibold)
                        
                        Text(level.name)
                            .font(.title)
                            .fontWeight(.heavy)
                            .foregroundColor(.orange)
                        
                        Text("Required Active Minutes: \(level.requiredActiveMinutes)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if !newAchievements.isEmpty {
                    if newLevel != nil {
                        Divider().padding(.horizontal)
                    }
                    VStack(spacing: 12) {
                        Text("New Achievements Unlocked")
                            .font(.headline)
                            .fontWeight(.bold)
                        
                        ForEach(newAchievements, id: \.self) { achievement in
                            Text("🏆 \(achievement)")
                                .font(.body)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                
                Button(action: onDismiss) {
                    Text("Awesome!")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
                .padding(.top, 16)
            }
            .padding(32)
            .background(Color(.systemBackground))
            .cornerRadius(24)
            .shadow(radius: 20)
            .padding(24)
            .scaleEffect(scale)
            .opacity(isVisible ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                isVisible = true
                scale = 1.0
            }
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                confettiProgress = 1.0
            }
            Haptics.notify(.success)
        }
    }
}

struct ConfettiParticleView: View {
    let progress: CGFloat
    let geometry: GeometryProxy
    let index: Int
    
    @State private var randomX = CGFloat.random(in: 0...1)
    @State private var randomY = CGFloat.random(in: -0.5...0)
    @State private var randomSpeed = CGFloat.random(in: 0.5...1.5)
    @State private var color: Color = [.red, .blue, .green, .yellow, .purple, .orange].randomElement()!
    @State private var size = CGFloat.random(in: 8...16)
    
    var body: some View {
        let currentY = randomY + (progress * randomSpeed * 2)
        let wrappedY = currentY.truncatingRemainder(dividingBy: 1.5)
        
        if wrappedY > -0.2 && wrappedY < 1.2 {
            Rectangle()
                .fill(color)
                .frame(width: size, height: size)
                .position(
                    x: randomX * geometry.size.width,
                    y: wrappedY * geometry.size.height
                )
                .rotationEffect(.degrees(Double(progress * 360 * randomSpeed)))
        }
    }
}
