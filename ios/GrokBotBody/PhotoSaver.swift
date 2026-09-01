import Foundation
import Photos

enum PhotoSaver {
    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoSaverError.denied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

private enum PhotoSaverError: LocalizedError {
    case denied

    var errorDescription: String? {
        switch self {
        case .denied:
            return "相册没开权限"
        }
    }
}
