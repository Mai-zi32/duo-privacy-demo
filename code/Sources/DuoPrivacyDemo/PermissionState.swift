import Foundation

enum PermissionGrantState: Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
    case restartRequired

    var isAuthorized: Bool {
        self == .authorized
    }
}

struct RequiredPermissionState: Equatable {
    let camera: PermissionGrantState
    let screenRecording: PermissionGrantState

    var isReady: Bool {
        camera.isAuthorized && screenRecording.isAuthorized
    }
}
