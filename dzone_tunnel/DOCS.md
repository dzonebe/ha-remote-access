# DZone Remote Access

Maakt je Home Assistant van buitenaf bereikbaar op `https://<naam>.ha.dzone.be`,
zonder poorten open te zetten op je router.

## Instellen

1. Kies bij **Configuratie** een **subdomein** (kleine letters, cijfers en
   koppeltekens). De servers laat je ongewijzigd.
2. Start de app en zet **Starten bij opstarten**, **Watchdog** en
   **Automatisch bijwerken** aan. Bij de eerste start past de app één
   netwerkinstelling van Home Assistant aan en herstart Home Assistant één keer.
3. Open het **Logboek** van de app en volg de link achter *Subscribe here* om
   een abonnement af te sluiten (€ 3 per maand, maandelijks opzegbaar). Na de
   betaling komt de verbinding binnen enkele minuten vanzelf tot stand; je
   hoeft niets te herstarten.
4. Stel in de Home Assistant-app op je telefoon `https://<naam>.ha.dzone.be` in
   als externe URL. Laat de interne URL staan: thuis blijft alles dan werken,
   ook als de verbinding met DZone wegvalt.

## Abonnement beheren of opzeggen

Herstart de app en open de link achter *Manage your subscription* in het
**Logboek**. Daar pas je je betaalgegevens aan, vind je je facturen en zeg je op.
Na het opzeggen blijft de toegang werken tot het einde van de betaalde periode.

## Wat de app aan Home Assistant verandert

Home Assistant aanvaardt verkeer via de tunnel alleen als het de app als proxy
vertrouwt. De app stelt dat zelf in onder **Instellingen → Systeem → Netwerk →
HTTP-server**: **Trust X-Forwarded-For** gaat aan en `172.30.33.0/24` en
`127.0.0.1` komen bij de vertrouwde proxy's. Je andere instellingen blijven
ongewijzigd. Home Assistant herstart daarvoor één keer; lukt de nieuwe
instelling niet, dan zet Home Assistant zelf de vorige terug.

Wil je dit liever zelf doen, zet dan bij **Configuratie** de optie
`configure_home_assistant` uit en vul de instellingen hierboven met de hand in.

Op een oudere versie van Home Assistant, zonder HTTP-instellingen onder
Netwerk, voeg je dit toe aan `configuration.yaml` en herstart je:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.30.33.0/24
    - 127.0.0.1
```

## Beveiliging

Je inlogscherm is bereikbaar vanaf het internet. Gebruik een sterk wachtwoord en
schakel tweestapsverificatie in via je profiel in Home Assistant.

De app maakt zelf een geheime sleutel aan en bewaart die in zijn eigen opslag;
die zit ook in je Home Assistant-back-ups.

## Problemen

- **"400: Bad Request" in de browser:** Home Assistant vertrouwt de app nog
  niet als proxy, of is nog niet herstart. Zie "Wat de app aan Home Assistant
  verandert".
- **Home Assistant gebruikt een eigen SSL-certificaat:** de tunnel heeft gewone
  HTTP nodig. Verwijder het certificaat onder Instellingen → Systeem → Netwerk;
  DZone zorgt al voor HTTPS.
- **"Not active yet":** er is nog geen abonnement voor deze installatie. Volg
  de link in het logboek.
- **"Subdomain ... belongs to another installation":** het subdomein is al in
  gebruik. Kies een ander, of neem contact op als je de app opnieuw installeerde
  zonder back-up.
- **"Your subscription has ended":** vernieuw via de link in het logboek.
- **"Remote access is blocked":** neem contact op met DZone.
- **De verbinding valt weg:** de app probeert zelf opnieuw te verbinden.
