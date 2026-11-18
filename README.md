# DZone Remote Access

Bereik je Home Assistant van overal op je eigen adres,
`https://<naam>.ha.dzone.be`, zonder poorten open te zetten op je router en
zonder vast IP-adres.

[![Voeg deze repository toe aan Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fdzonebe%2Fha-remote-access)

## Wat je krijgt

- **Een eigen adres** met een geldig HTTPS-certificaat, dat werkt in de browser
  en in de Home Assistant-app op je telefoon.
- **Geen routerinstellingen:** de app legt zelf een uitgaande, versleutelde
  verbinding. Het werkt ook achter CGNAT of op een 4G/5G-verbinding.

## Wat je nodig hebt

- Home Assistant OS of Supervised (een installatie met de app store), op een
  64-bit toestel (amd64 of aarch64, bv. een Raspberry Pi 4 of 5).
- Een abonnement van € 3 per maand, maandelijks opzegbaar. Je sluit het af
  tijdens de installatie.

## Installeren

1. Klik op de knop hierboven, of voeg in Home Assistant onder
   **Instellingen → Apps → App store → ⋮ → Repositories** deze URL toe:

   ```
   https://github.com/dzonebe/ha-remote-access
   ```

2. Installeer **DZone Remote Access** en kies bij **Configuratie** een
   subdomein, bijvoorbeeld `familie-janssens`.
3. Start de app. Ze stelt Home Assistant zelf in en herstart het één keer. In
   het **Logboek** staat daarna een link om je abonnement af te
   sluiten. Na de betaling komt de verbinding binnen enkele minuten vanzelf tot
   stand.

De volledige handleiding, met oplossingen voor veelvoorkomende problemen, staat
in het tabblad **Documentatie** van de app en in
[dzone_tunnel/DOCS.md](dzone_tunnel/DOCS.md).

## Hoe het werkt

De app opent vanuit je Home Assistant een versleutelde tunnel naar de servers
van DZone. Wie naar `https://<naam>.ha.dzone.be` surft, komt bij die servers
terecht, en die sturen het verkeer door de tunnel naar jouw installatie. Omdat
de verbinding van binnenuit vertrekt, hoeft er niets open te staan op je router.

## Veiligheid

- De verbinding is versleuteld van je browser tot de servers van DZone, en van
  die servers tot je Home Assistant. De app controleert het certificaat van de
  server voor ze verbindt.
- Elke installatie maakt zelf een geheime sleutel aan. Die verlaat je toestel
  alleen richting de tunnelservers; een subdomein kan niet door een andere
  installatie overgenomen worden.
- Je inlogscherm is wel bereikbaar vanaf het internet. Gebruik een sterk
  wachtwoord en schakel tweestapsverificatie in via je profiel in Home
  Assistant.

## Vragen of problemen

Neem contact op via [dzone.be](https://www.dzone.be), of open een issue in deze
repository.

---

**English:** DZone Remote Access is a Home Assistant app that makes your
installation reachable at `https://<name>.ha.dzone.be` through an outbound,
encrypted tunnel, with no port forwarding. Add this repository to the Home
Assistant app store, pick a subdomain, and follow the link in the app's log to
subscribe (EUR 3 per month, cancel any time).
