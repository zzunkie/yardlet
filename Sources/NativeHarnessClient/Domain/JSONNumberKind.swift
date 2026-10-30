import Foundation

extension NSNumber {
    /// JSONSerialization read this number from `true` or `false`.
    var isJSONBoolean: Bool {
        #if canImport(Darwin)
        CFGetTypeID(self) == CFBooleanGetTypeID()
        #else
        // Foundation outside Apple's platforms keeps a JSON boolean as a `Bool` (`c`).
        String(cString: objCType) == "c"
        #endif
    }

    /// JSONSerialization read this number with a fraction or an exponent.
    var isJSONFloat: Bool {
        #if canImport(Darwin)
        CFNumberIsFloatType(self)
        #else
        ["d", "f"].contains(String(cString: objCType))
        #endif
    }
}
