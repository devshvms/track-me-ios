import SwiftUI
import MapKit

struct ExportPreviewView: View {
    let ride: Ride
    let snapshotImage: UIImage
    
    @State private var showStats = true
    @State private var showTitle = true
    
    @State private var isShowingShareSheet = false
    @State private var shareItems: [Any] = []
    
    var body: some View {
        VStack {
            Spacer()
            exportFrame
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()
                .shadow(radius: 10)
            Spacer()
            
            Form {
                Toggle("Show Ride Title", isOn: $showTitle)
                Toggle("Show Stats Overlay", isOn: $showStats)
            }
            .frame(height: 150)
            .cornerRadius(16)
            .padding(.horizontal)
            
            Button(action: shareImage) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share Image")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(BrandColor.primaryFill)
                .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle("Export Preview")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(activityItems: shareItems)
        }
    }
    
    var exportFrame: some View {
        ZStack(alignment: .bottom) {
            Image(uiImage: snapshotImage)
                .resizable()
                .scaledToFill()
                .frame(width: 350, height: 400)
                .clipped()
            
            if showStats || showTitle {
                VStack(alignment: .leading, spacing: 6) {
                    if showTitle {
                        Text(ride.title ?? "TrackMe Ride")
                            .font(.title2).bold()
                            .foregroundColor(.white)
                    }
                    if showStats {
                        let duration = String(format: "%.0f mins", (ride.endTime?.timeIntervalSince(ride.startTime) ?? 0) / 60)
                        let distanceStr: String = {
                            if let pts = ride.points, pts.count > 0 {
                                return String(format: "%.2f km", calculateDistance(pts) / 1000)
                            }
                            return "0.00 km"
                        }()
                        let dateStr = DateFormatter.localizedString(from: ride.startTime ?? Date(), dateStyle: .medium, timeStyle: .none)
                        
                        Text("\(dateStr) • \(duration) • \(distanceStr)")
                            .font(.subheadline)
                            .foregroundColor(Color.white.opacity(0.9))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.6))
            }
        }
        .frame(width: 350, height: 400)
    }
    
    @MainActor
    private func shareImage() {
        let renderer = ImageRenderer(content: exportFrame)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            renderer.scale = windowScene.screen.scale
        } else {
            renderer.scale = 2.0
        }
        if let uiImage = renderer.uiImage {
            shareItems = [uiImage]
            isShowingShareSheet = true
        }
    }
    
    private func calculateDistance(_ points: [GPSPoint]) -> Double {
        var dist = 0.0
        for i in 1..<points.count {
            let p1 = points[i-1].coordinate
            let p2 = points[i].coordinate
            dist += p1.distance(to: p2) // Assuming MKMapPoint distance wait no, CLLocations are better. Let's use simple Pythagorean approximation just for export display or distance property.
            // Wait, coordinate is CLLocationCoordinate2D.
        }
        return dist // We actually don't have a direct distance property on GPSPoint. Let's fix this in the code.
    }
}

extension CLLocationCoordinate2D {
    func distance(to: CLLocationCoordinate2D) -> Double {
        let l1 = CLLocation(latitude: self.latitude, longitude: self.longitude)
        let l2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return l1.distance(from: l2)
    }
}

struct StatBadge: View {
    var icon: String
    var value: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(value).bold()
        }
        .font(.caption)
        .foregroundColor(.white)
    }
}
