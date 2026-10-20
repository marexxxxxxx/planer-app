//
//  VoicePermissions.swift
//  Planer
//
//  Freigaben für Mikrofon und Spracherkennung (spec-voice §2/V4, §11).
//

import AVFoundation
import Speech

/// Ergebnis einer Freigabeanfrage (spec-voice §11).
enum VoicePermissionStatus: Equatable {
    case nichtGefragt
    case erlaubt
    case verweigert
}

/// Holt die beiden Pflichtfreigaben und liest den Mikrofonstatus
/// (spec-voice §2/V4, §11).
///
/// Zweck: V2 fragt vor dem Diktat genau hier; die AVFoundation- und
/// Speech-Typen bleiben hinter dieser Datei. `request*` liefert immer einen
/// Status und wirft nie (spec-voice §11).
/// Grenze: zeigt keine Oberfläche und speichert nichts — die Systemdialoge
/// führt iOS selbst.
enum VoicePermissions {

    /// Fragt die Spracherkennung an (spec-voice §2/V4).
    static func requestSpeechRecognition() async -> VoicePermissionStatus {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return permissionStatus(for: authorization)
    }

    /// Fragt das Mikrofon an (spec-voice §2/V4).
    static func requestMicrophone() async -> VoicePermissionStatus {
        if let status = knownMicrophoneStatus() {
            return status
        }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .erlaubt : .verweigert
    }

    /// Aktueller Mikrofonstatus ohne Systemdialog (spec-voice §11).
    static var microphoneStatus: VoicePermissionStatus {
        knownMicrophoneStatus() ?? .nichtGefragt
    }

    /// Liest den Status; `nil` heißt: iOS hat noch nicht gefragt.
    private static func knownMicrophoneStatus() -> VoicePermissionStatus? {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .erlaubt
        case .denied:
            return .verweigert
        case .undetermined:
            return nil
        @unknown default:
            return .verweigert
        }
    }

    /// Übersetzt den Speech-Status in den gemeinsamen Status.
    private static func permissionStatus(for status: SFSpeechRecognizerAuthorizationStatus) -> VoicePermissionStatus {
        switch status {
        case .authorized:
            return .erlaubt
        case .denied, .restricted:
            return .verweigert
        case .notDetermined:
            return .nichtGefragt
        @unknown default:
            return .verweigert
        }
    }
}
