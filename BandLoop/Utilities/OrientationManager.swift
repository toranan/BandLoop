import UIKit

@MainActor
enum OrientationManager {
    static func requestLandscape(onFailure: @escaping (String) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            onFailure("화면 방향을 바꿀 수 없어요.")
            return
        }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in
            DispatchQueue.main.async {
                onFailure("기기의 세로 방향 잠금을 끄고 다시 눌러 주세요.")
            }
        }
    }
}
