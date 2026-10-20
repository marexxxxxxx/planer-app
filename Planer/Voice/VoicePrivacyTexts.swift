//
//  VoicePrivacyTexts.swift
//  Planer
//
//  Wortwörtliche Freigabe- und Datenschutztexte der Sprachschicht
//  (spec-voice §4, §5).
//

/// Die Texte, die iOS im Freigabedialog und die App als Hinweis zeigt
/// (spec-voice §4, §5).
///
/// Zweck: die Wortlaute stehen an genau einer Stelle; die Info.plist-Werte in
/// `project.pbxproj` müssen zeichengleich sein (spec-voice §5, §13).
/// Grenze: reine Konstanten — keine Logik, keine Lokalisierung.
enum VoicePrivacyTexts {

    /// `NSMicrophoneUsageDescription` (spec-voice §5).
    static let mikrofonFreigabe = "Planer benötigt das Mikrofon, um Ihre Diktate aufzunehmen. Die Aufnahme wird auf diesem Gerät ausgewertet und nicht an einen Server übertragen."

    /// `NSSpeechRecognitionUsageDescription` (spec-voice §5).
    static let spracherkennungFreigabe = "Planer wandelt Ihre gesprochenen Sätze auf diesem Gerät in Text um. Die Erkennung läuft ohne Netz auf dem Gerät; ohne deutsche On-Device-Erkennung bietet die App kein Diktat an."

    /// Dauerhafter Hinweis ohne deutsches On-Device-Diktat (spec-voice §4).
    static let diktatNichtMoeglich = "Diktieren ist auf diesem Gerät nicht möglich: Die deutsche Erkennung ohne Netz ist nicht verfügbar. Sie können weiter tippen."
}
