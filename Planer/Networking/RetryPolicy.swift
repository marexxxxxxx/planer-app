//
//  RetryPolicy.swift
//  Planer
//
//  Wiederholungsregeln für transiente Netzwerkfehler (spec-ios §10).
//

import Foundation

/// Begrenzt, wie oft und wie lange ein fehlgeschlagener Request wiederholt wird.
///
/// Zweck: exponentielles Backoff für Timeout, Offline, 429 und retryable 5xx;
/// 400/401/403 werden nie wiederholt.
/// Grenze: kein Circuit Breaker und kein Persistieren von Fehlversuchen.
struct RetryPolicy: Equatable, Sendable {
    /// Gesamtzahl der Versuche inklusive des ersten.
    let maxAttempts: Int
    let initialDelay: TimeInterval
    let multiplier: Double
    let maximumDelay: TimeInterval

    /// Drei Versuche, 0,5 s Startverzögerung, Verdopplung bis maximal 8 s.
    static let `default` = RetryPolicy()

    init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 0.5,
        multiplier: Double = 2,
        maximumDelay: TimeInterval = 8
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = max(0, initialDelay)
        self.multiplier = max(1, multiplier)
        self.maximumDelay = max(0, maximumDelay)
    }

    /// Wartezeit vor einem Versuch (1-basiert). Vor dem ersten Versuch: 0.
    func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let exponent = Double(attempt - 2)
        return min(maximumDelay, initialDelay * pow(multiplier, exponent))
    }

    /// Entscheidet, ob nach `attempt` Versuchen ein weiterer folgen darf.
    func shouldRetry(_ error: APIError, afterAttempt attempt: Int) -> Bool {
        attempt < maxAttempts && error.isRetryable
    }
}
