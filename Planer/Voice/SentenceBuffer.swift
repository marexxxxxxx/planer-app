//
//  SentenceBuffer.swift
//  Planer
//
//  Satzweise Pufferung des Antwortstroms vor der Sprachausgabe
//  (spec-voice §6.3, AD-V5).
//

import Foundation

/// Sammelt Text-Deltas und gibt vollständige Sätze frei.
///
/// Zweck: aus dem Token-Strom des Chats werden ganze Sätze, damit nicht jedes
/// Token eine eigene Äußerung erzeugt (AD-V5). Satzenden sind `.`, `!`, `?`,
/// `…` und der Zeilenumbruch; ein Restpuffer über `maxSentenceCharacters`
/// Zeichen wird am letzten Leerzeichen innerhalb der Grenze geschnitten.
/// Grenze: arbeitet auf dem Rohtext. Markdown entfernt `VoiceTextNormalizer`
/// unmittelbar vor dem Sprechen. Abkürzungen („z. B.") gelten nicht als
/// Sonderfall — die Spec (§6.3) nennt keine Abkürzungsliste.
struct SentenceBuffer {

    /// Zeichen, die einen Satz abschließen (spec-voice §6.3).
    private static let terminators: Set<Character> = [".", "!", "?", "…", "\n"]

    /// Zeichen, die direkt hinter dem Satzzeichen noch zum Satz gehören.
    private static let closers: Set<Character> = ["\"", "“", "”", "»", ")", "]"]

    /// Obergrenze einer Äußerung (spec-voice §6.3, AD-V5).
    private let maxSentenceCharacters: Int

    /// Noch nicht freigegebener Text.
    private var rest = ""

    /// Ein Code-Zaun kann über mehrere Deltas laufen; sein Inhalt wird nicht
    /// vorgelesen (§6.3 Punkt 4) und deshalb schon hier verworfen.
    private var isInsideCodeFence = false

    init(maxSentenceCharacters: Int = 240) {
        self.maxSentenceCharacters = max(1, maxSentenceCharacters)
    }

    /// `true`, solange Text auf die nächste Freigabe wartet.
    var isEmpty: Bool {
        rest.isEmpty
    }

    /// Hängt ein Delta an und liefert die dabei fertig gewordenen Sätze.
    ///
    /// Die Reihenfolge ist die des Stroms; leere Sätze entstehen nicht.
    mutating func append(_ delta: String) -> [String] {
        var sentences: [String] = []
        var remaining = Substring(delta)

        while !remaining.isEmpty {
            if isInsideCodeFence {
                guard let fence = remaining.range(of: "```") else {
                    // Alles bis zum schließenden Zaun ist Quelltext.
                    return sentences
                }
                remaining = remaining[fence.upperBound...]
                isInsideCodeFence = false
                continue
            }
            guard let fence = remaining.range(of: "```") else {
                rest += remaining
                break
            }
            rest += remaining[..<fence.lowerBound]
            remaining = remaining[fence.upperBound...]
            isInsideCodeFence = true
            sentences += drain()
        }
        sentences += drain()
        return sentences
    }

    /// Gibt den Restpuffer als letzte Äußerung frei (N3, `finishAssistantStream`).
    ///
    /// Nach dem Aufruf ist der Puffer leer; ein leerer Rest liefert nichts.
    mutating func flush() -> [String] {
        let sentence = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        rest = ""
        isInsideCodeFence = false
        return sentence.isEmpty ? [] : [sentence]
    }

    /// Verwirft den Puffer (Abbruch, Barging-in T6).
    mutating func reset() {
        rest = ""
        isInsideCodeFence = false
    }

    // MARK: Schnitt im Puffer

    /// Gibt alle fertigen Sätze aus dem Puffer frei.
    private mutating func drain() -> [String] {
        var sentences: [String] = []
        while let boundary = firstSentenceEnd() {
            emit(upTo: boundary, into: &sentences)
        }
        while rest.count > maxSentenceCharacters {
            emit(upTo: cutIndex(), into: &sentences)
        }
        return sentences
    }

    /// Index direkt **hinter** dem ersten Satzende, oder `nil`.
    ///
    /// Ein Satzende liegt nur vor, wenn danach ein Leerraum folgt. Sonst ist
    /// das Zeichen Teil eines Tokens — etwa der Punkt in
    /// `https://example.com` oder in `3.5` — und darf nicht trennen.
    /// Am Pufferende wird gewartet: das Token kann im nächsten Delta
    /// weitergehen; den letzten Satz gibt `flush()` frei.
    /// Ein Zeilenumbruch trennt immer.
    private func firstSentenceEnd() -> String.Index? {
        var index = rest.startIndex
        while index < rest.endIndex {
            guard Self.terminators.contains(rest[index]) else {
                index = rest.index(after: index)
                continue
            }
            var end = rest.index(after: index)
            if rest[index] == "\n" {
                return end
            }
            while end < rest.endIndex, Self.closers.contains(rest[end]) {
                end = rest.index(after: end)
            }
            // Am Pufferende ist offen, ob das Token weitergeht (Streaming).
            guard end < rest.endIndex else { return nil }
            if rest[end].isWhitespace {
                return end
            }
            index = end
        }
        return nil
    }

    /// Index, an dem ein zu langer Restpuffer geschnitten wird: das letzte
    /// Leerzeichen innerhalb der Obergrenze, sonst hart an der Grenze.
    private func cutIndex() -> String.Index {
        let limit = rest.index(rest.startIndex, offsetBy: maxSentenceCharacters)
        let prefix = rest[rest.startIndex..<limit]
        if let space = prefix.lastIndex(of: " "), space > rest.startIndex {
            return space
        }
        return limit
    }

    /// Schneidet alles bis `end` ab und gibt es als getrimmten Satz frei.
    private mutating func emit(upTo end: String.Index, into sentences: inout [String]) {
        let raw = rest[rest.startIndex..<end]
        rest = String(rest[end...])
        let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sentence.isEmpty {
            sentences.append(sentence)
        }
    }
}

/// Entfernt Markdown-Syntax, bevor der Text gesprochen wird (spec-voice §6.3).
///
/// Zweck: Code, Adressen und Hervorhebungszeichen würden sonst vorgelesen.
/// Grenze: reine Textersetzung ohne Grammatik — sie erkennt genau die in §6.3
/// genannten Formen und keinen Markdown-Dialekt darüber hinaus.
enum VoiceTextNormalizer {

    /// Reihenfolge ist bindend: Code und Adressen zuerst, Listenmarker vor den
    /// Hervorhebungszeichen (sonst bliebe von `* Punkt` nur ` Punkt` übrig).
    private static let rules: [(pattern: String, replacement: String)] = [
        // Code-Zaun samt Inhalt — Quelltext wird nicht vorgelesen.
        ("(?s)```.*?```", ""),
        // Inline-Code: der Text bleibt, die Backticks fallen weg.
        ("`([^`]*)`", "$1"),
        // Markdown-Link: nur die Beschriftung bleibt.
        ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
        // Nackte Adresse.
        ("https?://\\S+", ""),
        // Listenmarker am Zeilenanfang (`- `, `* `, `1. `).
        ("(?m)^\\s*(?:[-*+]|\\d+[.)])\\s+", ""),
        // Hervorhebung, Überschrift, Zitat.
        ("[*_#>`]+", "")
    ]

    /// Liefert den vorlesbaren Text; die Rückgabe kann leer sein.
    static func normalize(_ text: String) -> String {
        var result = text
        for rule in rules {
            result = result.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: [.regularExpression]
            )
        }
        return result
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
