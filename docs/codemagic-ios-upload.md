# iOS-Veröffentlichung mit Codemagic

## Projektwerte

- Workflow: `ios-release`
- Bundle-ID: `de.adleraufmasse.atool`
- Version: `1.2.3`
- Buildnummer: `32`
- Mindestversion: iOS 15.5
- Ausgabe: signierte IPA-Datei und dSYM-Dateien
- Veröffentlichung: automatischer Upload zu TestFlight

## Einmalig in Codemagic einrichten

1. Das Repository mit Codemagic verbinden.
2. Unter **Teams → Integrations → Developer Portal → App Store Connect** einen
   App-Store-Connect-API-Schlüssel hinterlegen.
3. Die Integration exakt `Codemagic` nennen, da dieser Name in
   `codemagic.yaml` verwendet wird.
4. In Apple Developer und App Store Connect muss die App mit der Bundle-ID
   `de.adleraufmasse.atool` vorhanden sein.
5. Der API-Schlüssel benötigt Zugriff auf App-Verwaltung und TestFlight.

## Build starten

1. Alle Änderungen committen und in das verbundene Repository pushen.
2. In Codemagic **Start new build** wählen.
3. Workflow **iOS Release** starten.
4. Nach erfolgreichem Build wird die IPA automatisch zu TestFlight übertragen.

Falls Buildnummer `32` in App Store Connect bereits verwendet wurde, muss die
Buildnummer hinter dem Pluszeichen in `pubspec.yaml` erhöht werden, zum Beispiel
auf `1.2.3+33`.

## App-Store-Prüfung

Da ATool eine Anmeldung voraussetzt, in App Store Connect unter den
Prüfhinweisen ein funktionierendes Demo-Konto hinterlegen. Kamera und
Fotobibliothek werden ausschließlich für die OCR-Funktion verwendet.
