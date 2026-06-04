import Foundation
import simd

enum SIMDHelpers {
    static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double {
        Double(simd_length(a - b))
    }

    static func clamped(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        max(minValue, min(value, maxValue))
    }
}
