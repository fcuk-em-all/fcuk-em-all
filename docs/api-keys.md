# Third-Party API Keys

The appliance runs without any third-party keys, but a few optional features get
better with them (richer metadata, subtitles, extra discovery sources). Each key
goes in its own file under `secrets/`. `secrets/generate.sh` creates these as
one-line placeholder files describing where to get the key — replace the
placeholder line with your key.

All of these have a free tier and are optional.

| Service | What it improves | Free? | Where to get it | File in `secrets/` |
|---------|------------------|-------|-----------------|--------------------|
| **TMDB** | Movie/TV metadata, posters, artwork | Yes | [themoviedb.org → Settings → API](https://www.themoviedb.org/settings/api) | `tmdb_api_key.txt` |
| **AcoustID** | Music fingerprinting / tagging | Yes | [acoustid.org/api-key](https://acoustid.org/api-key) | `acoustid_api_key.txt` |
| **OpenSubtitles** | Subtitle search & download | Yes (consumer tier) | [opensubtitles.com/consumers](https://www.opensubtitles.com/consumers) | `opensubtitles_api_key.txt`, `opensubtitles_username.txt`, `opensubtitles_password.txt` |
| **Europeana** | Public-domain discovery source | Yes | [pro.europeana.eu → Get API key](https://pro.europeana.eu/pages/get-api-key) | `europeana_api_key.txt` |

## How to set one

```
printf '%s' 'YOUR_KEY_HERE' > secrets/tmdb_api_key.txt
chmod 600 secrets/tmdb_api_key.txt
```

Or just edit the placeholder file the generator created and replace the comment
line with your key. Files must be `0600`; the directory is gitignored, so keys
never leave your machine.

## Details

- **TMDB** — free for personal use. Create an account, request an API key under
  Settings → API (the v3 "API Key" is what you want). Powers Jellyfin/Radarr/Sonarr
  metadata and artwork.
- **AcoustID** — free application key from acoustid.org. Used for audio
  fingerprinting when tagging music.
- **OpenSubtitles** — the consumer REST API needs an API key **and** your account
  username and password. Register at opensubtitles.com, then request a consumer
  API key. All three values go in separate files.
- **Europeana** — free API key for the Europeana public-domain collection, used
  by the wizard's discovery panel (`/api/discover/europeana`).

## NordVPN token (not an API key, but related)

Only needed if you enable the `vpn` module. Get an access token from the NordVPN
dashboard → Services → NordVPN → "Set up NordVPN manually," and place it in
`secrets/nordvpn_token.txt` (`chmod 600`). See
[configuration.md](configuration.md).
