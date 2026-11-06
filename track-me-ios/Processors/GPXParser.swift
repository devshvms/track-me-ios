import Foundation
import SwiftData
import CoreLocation

class GPXParser: NSObject, XMLParserDelegate {
    private(set) var originalTrackMeId: String?
    
    private var points: [GPSPoint] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentTime: Date?
    private var rideName: String?
    
    private var currentText = ""
    
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private let dateFormatterNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    
    func parse(url: URL) -> Ride? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        parser.delegate = self
        points = []
        rideName = nil
        originalTrackMeId = nil
        
        parser.parse()
        
        guard !points.isEmpty else { return nil }
        
        points.sort { $0.timestamp < $1.timestamp }
        
        var totalDistance = 0.0
        var maxSpeed = 0.0
        for i in 1..<points.count {
            let prev = points[i-1]
            let curr = points[i]
            
            let prevLoc = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
            let currLoc = CLLocation(latitude: curr.latitude, longitude: curr.longitude)
            let distance = currLoc.distance(from: prevLoc)
            totalDistance += distance
            let timeDiff = curr.timestamp.timeIntervalSince(prev.timestamp)
            
            if timeDiff > 0 {
                let speed = distance / timeDiff
                points[i].speed = speed
                if speed > maxSpeed && speed < 150.0 {
                    maxSpeed = speed
                }
            }
        }
        
        let startTime = points.first!.timestamp
        let endTime = points.last!.timestamp
        let movingDurationMillis = Int64(max(endTime.timeIntervalSince(startTime) * 1000, 0))
        let avgSpeed = movingDurationMillis > 0 ? (totalDistance / (Double(movingDurationMillis) / 1000.0)) : 0.0
        let elev = RideMetrics.elevationGainMeters(from: points)

        let aggregate = RideAggregateSnapshot(
            distanceMeters: totalDistance,
            movingDurationMillis: movingDurationMillis,
            maxSpeedMps: maxSpeed,
            avgSpeedMps: avgSpeed,
            pointCount: points.count,
            elevationGainMeters: elev
        )

        let ride = Ride(
            startTime: startTime,
            sourceInfo: "Imported GPX",
            isBroadcasted: false,
            isSynced: false,
            title: rideName ?? "Imported Ride"
        )
        ride.endTime = endTime
        ride.points = points
        ride.applyAggregate(aggregate)
        
        return ride
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentText = ""
        if elementName == "trkpt" {
            if let latStr = attributeDict["lat"], let lat = Double(latStr),
               let lonStr = attributeDict["lon"], let lon = Double(lonStr) {
                currentLat = lat
                currentLon = lon
            }
            currentEle = nil
            currentTime = nil
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if elementName == "name", rideName == nil, !text.isEmpty {
            rideName = text
        } else if elementName == "desc", text.hasPrefix("TrackMeID:") {
            originalTrackMeId = String(text.dropFirst("TrackMeID:".count))
        } else if elementName == "ele" {
            currentEle = Double(text)
        } else if elementName == "time" {
            currentTime = dateFormatter.date(from: text) ?? dateFormatterNoFractional.date(from: text)
        } else if elementName == "trkpt" {
            if let lat = currentLat, let lon = currentLon {
                let time = currentTime ?? Date(timeIntervalSince1970: TimeInterval(points.count))
                let point = GPSPoint(
                    latitude: lat,
                    longitude: lon,
                    altitude: currentEle ?? 0.0,
                    accuracy: 0.0,
                    speed: 0.0,
                    timestamp: time,
                    isPaused: false
                )
                points.append(point)
            }
            currentLat = nil
            currentLon = nil
            currentEle = nil
            currentTime = nil
        }
    }
}
