import Foundation
import FirebaseFirestore
import FirebaseAuth

struct DataExportResponse: Codable {
    let requestId: String?
    let userId: String?
    let status: String
    let requestedAt: String?
    let completedAt: String?
    let downloadUrl: String?
    let expiresAt: String?
    let message: String?
}

class DataExportService {
    static let shared = DataExportService()
    private let db = Firestore.firestore()
    private let baseURL = "https://trackme.shvms.in"
    
    func checkExportStatus(completion: @escaping (Result<DataExportResponse?, Error>) -> Void) {
        guard let user = Auth.auth().currentUser else {
            completion(.success(nil))
            return
        }
        
        guard let url = URL(string: "\(baseURL)/api/export/status?userId=\(user.uid)") else {
            completion(.success(nil))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        
        user.getIDTokenForcingRefresh(true) { [weak self] token, _ in
            if let token = token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let data = data,
                   let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    if let exportResponse = try? JSONDecoder().decode(DataExportResponse.self, from: data) {
                        DispatchQueue.main.async { completion(.success(exportResponse)) }
                        return
                    }
                }
                
                self?.checkFirestoreStatus(userId: user.uid, completion: completion)
            }.resume()
        }
    }
    
    private func checkFirestoreStatus(userId: String, completion: @escaping (Result<DataExportResponse?, Error>) -> Void) {
        db.collection("users").document(userId).collection("data_export_requests")
            .order(by: "requestedAt", descending: true)
            .limit(to: 1)
            .getDocuments { snapshot, error in
                DispatchQueue.main.async {
                    guard let doc = snapshot?.documents.first else {
                        completion(.success(nil))
                        return
                    }
                    let data = doc.data()
                    let status = data["status"] as? String ?? "QUEUED"
                    let downloadUrl = data["downloadUrl"] as? String
                    let reqId = data["requestId"] as? String ?? doc.documentID
                    let response = DataExportResponse(
                        requestId: reqId,
                        userId: userId,
                        status: status,
                        requestedAt: nil,
                        completedAt: nil,
                        downloadUrl: downloadUrl,
                        expiresAt: nil,
                        message: status == "COMPLETED" ? "Your archive is ready for download." : "Your archive request is not ready yet."
                    )
                    completion(.success(response))
                }
            }
    }
    
    func requestDataArchiveExport(completion: @escaping (Result<DataExportResponse, Error>) -> Void) {
        guard let user = Auth.auth().currentUser else {
            let error = NSError(
                domain: "DataExportService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "User not authenticated"]
            )
            completion(.failure(error))
            return
        }
        
        guard let url = URL(string: "\(baseURL)/api/export/request") else {
            let error = NSError(domain: "DataExportService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            completion(.failure(error))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        
        let body: [String: Any] = [
            "userId": user.uid,
            "userEmail": user.email ?? "",
            "clientOS": "iOS",
            "exportFormats": ["GPX", "JSON_ARCHIVE"]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        user.getIDTokenForcingRefresh(true) { [weak self] token, _ in
            if let token = token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let data = data,
                   let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode),
                   let exportResponse = try? JSONDecoder().decode(DataExportResponse.self, from: data) {
                    
                    self?.mirrorRequestToFirestore(userId: user.uid, userEmail: user.email ?? "", requestId: exportResponse.requestId ?? UUID().uuidString, status: exportResponse.status)
                    
                    TelemetryManager.shared.trackDataDownloadRequested()
                    DispatchQueue.main.async { completion(.success(exportResponse)) }
                    return
                }
                
                DispatchQueue.main.async {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let error = NSError(
                        domain: "DataExportService",
                        code: statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Could not request archive export. Please try again."]
                    )
                    completion(.failure(error))
                }
            }.resume()
        }
    }
    
    private func mirrorRequestToFirestore(userId: String, userEmail: String, requestId: String, status: String, completion: ((Error?) -> Void)? = nil) {
        let docRef = db.collection("users").document(userId)
            .collection("data_export_requests").document(requestId)
        
        let data: [String: Any] = [
            "requestId": requestId,
            "userId": userId,
            "userEmail": userEmail,
            "status": status,
            "requestedAt": FieldValue.serverTimestamp(),
            "clientOS": "iOS",
            "exportFormats": ["GPX", "JSON_ARCHIVE"],
            "metadata": [
                "appVersion": "1.2.0"
            ]
        ]
        docRef.setData(data, merge: true) { error in
            completion?(error)
        }
    }
}
