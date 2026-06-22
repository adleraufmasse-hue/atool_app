# Serverseitige Authentifizierungs- und E-Mail-Anpassungen

Die Flutter-App ruft den Lizenzserver unter
`https://adler-aufmasse.de/licensing/api` auf. Die folgenden Änderungen müssen
zusätzlich auf diesem Server umgesetzt werden, da der E-Mail-Versand nicht Teil
des App-Projekts ist.

## Passwort zurücksetzen

Die App sendet an `POST /forgot-password.php`:

```json
{
  "email": "kunde@example.com"
}
```

Erfolgsantwort:

```json
{
  "success": true
}
```

Der Endpunkt sollte aus Datenschutzgründen für vorhandene und nicht vorhandene
E-Mail-Adressen immer dieselbe Erfolgsantwort liefern. Der per E-Mail versendete
Link muss ein einmalig verwendbares, zeitlich begrenztes Token enthalten. Das
Token darf nicht im Klartext in der Datenbank gespeichert werden.

## Neue Willkommensmail nach der E-Mail-Bestätigung

**Betreff:** Willkommen bei ATool – Ihr Zugang und unser Jahresangebot

```text
Hallo {{name}},

herzlich willkommen bei ATool. Ihre E-Mail-Adresse wurde erfolgreich bestätigt
und Ihr Testzugang ist jetzt bereit.

ATool kostet 349,00 € netto pro Jahr.

Wenn Sie dieses Angebot annehmen möchten, klicken Sie einfach auf den folgenden
Button. Wir aktivieren anschließend Ihren Zugang und bestätigen Ihnen die
Freischaltung per E-Mail.

[Ich nehme das Angebot an – bitte Zugang aktivieren]

Das Abonnement läuft jeweils zwölf Monate. Sie können es spätestens einen Monat
vor Beginn des nächsten Abonnementzeitraums per E-Mail an
support@adler-aufmasse.de kündigen.

Freundliche Grüße
Ihr ATool-Team
Adler Aufmaße
```

Der Button verweist mit einem persönlichen, zeitlich begrenzten Token auf
`/licensing/api/accept-offer.php`. Dort werden Firmenname, Nutzername,
Rechnungs-E-Mail-Adresse, Straße, PLZ und Ort abgefragt. Die Annahme wird in
`lic_offer_acceptances` gespeichert und als einzelne Aktivierungsnachricht an
`support@adler-aufmasse.de` gesendet.

Bestätigungs-, Willkommens- und Passwort-Reset-Mails begrenzen die Empfänger
direkt vor dem Versand auf genau die angegebene Adresse und entfernen mögliche
CC-/BCC-Empfänger.

Vor dem Livegang müssen Preisangabe, Umsatzsteuerhinweis, Laufzeit und
Kündigungsregel mit den tatsächlich geltenden Vertragsbedingungen abgeglichen
werden.
