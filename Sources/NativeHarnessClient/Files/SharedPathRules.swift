import YardletRemote

/// The engine's path rules are the remote protocol's (`YardletRemote/PathRules.swift`), so every engine file reads
/// them under this name without importing that module.
typealias PathRules = YardletRemote.PathRules
