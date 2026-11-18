# DZone Remote Access

Maakt je Home Assistant van buitenaf bereikbaar op `https://<naam>.ha.dzone.be`,
zonder poorten open te zetten op je router.

## Instellen

1. Kies bij **Configuratie** een **subdomein** (kleine letters, cijfers en
   koppeltekens). De servers laat je ongewijzigd.
2. Voeg dit toe aan `configuration.yaml` en herstart Home Assistant:

   ```yaml
   http:
     use_x_forwarded_for: true
     trusted_proxies:
       - 172.30.33.0/24
       - 127.0.0.1
   ```

3. Start de app en zet **Starten bij opstarten** en **Watchdog** aan.
4. Open het **Logboek** van de app en geef de **koppelcode** (6 tekens) door aan
   DZone Consulting. Zodra DZone je installatie goedkeurt, komt de verbinding
   binnen enkele minuten vanzelf tot stand; je hoeft niets te herstarten.
5. Stel in de Home Assistant-app op je telefoon `https://<naam>.ha.dzone.be` in
   als externe URL. Laat de interne URL staan: thuis blijft alles dan werken,
   ook als de verbinding met DZone wegvalt.

## Beveiliging

Je inlogscherm is bereikbaar vanaf het internet. Gebruik een sterk wachtwoord en
schakel tweestapsverificatie in via je profiel in Home Assistant.

De app maakt zelf een geheime sleutel aan en bewaart die in zijn eigen opslag;
die zit ook in je Home Assistant-back-ups.

## Problemen

- **"400: Bad Request" in de browser:** stap 2 ontbreekt of Home Assistant is
  nog niet herstart.
- **"Waiting for approval":** DZone heeft je installatie nog niet goedgekeurd.
- **"Subdomain ... belongs to another installation":** het subdomein is al in
  gebruik. Kies een ander, of neem contact op als je de app opnieuw installeerde
  zonder back-up.
- **"Remote access is blocked" of "has expired":** neem contact op met DZone.
- **De verbinding valt weg:** de app probeert zelf opnieuw te verbinden.
