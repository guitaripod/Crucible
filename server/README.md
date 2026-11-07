# Crucible Server

The optional companion that runs on the machine with your Plex Media Server. Crucible on iPhone, iPad and Apple
TV pairs with it once and then gets:

- **Skips from the file itself**: intro, recap, preview, ending and credits from Plex's markers and the file's
  named chapters (`GET /crucible/v1/segments/{ratingKey}`).
- **Previously On**: a short recap of the last episodes you finished, written by a model on your own hardware
  from Plex's synopsis and the episodes' own subtitles, and checked before you see it.
- **Ask**: pause and ask about what you're watching; the answer uses only what you've already seen.

Nothing leaves your network. The model runs on this machine or on a computer on your own tailnet.

## Install

On the computer that runs Plex:

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/Crucible/master/server/packaging/install.sh | sh    # Linux and macOS
brew install guitaripod/tap/crucible-server && crucible-server setup                           # macOS
yay -S crucible-server-bin && crucible-server setup                                              # Arch Linux
cargo install --path server && crucible-server setup                                             # from source
```

With Docker (Unraid, Synology, TrueNAS, any NAS): build the image from `server/packaging/Dockerfile` with the
Linux release binary beside it, mount your media read-only at the paths Plex uses, and run setup once in the
container before starting it:

```sh
docker compose -f server/packaging/compose.yml run --rm -it crucible-server setup --no-service
docker compose -f server/packaging/compose.yml up -d
```

`setup` finds Plex on this machine, checks that Plex refuses requests without a token, signs you in at
plex.tv/link, finds a model server (llama-swap, Ollama or LM Studio on this machine, or `--model-url`), makes the
server's certificate, keeps it running as a service (systemd user unit or launchd agent) and shows a QR code. Scan it
with the iPhone's Camera, or in Crucible under Settings, Crucible Server.

```sh
crucible-server pair        # a new pairing code for another device
crucible-server devices     # what is paired
crucible-server unpair ID
crucible-server doctor      # Plex, the model, ffmpeg, the certificate and the service, checked
crucible-server summarize EPISODE.mkv --show "Dragon Ball Super"   # judge a model on a real file
```

Needs ffmpeg for subtitles. Any OpenAI-compatible endpoint works; a model with a 32K window or more reads a whole
episode's dialogue, a smaller one reads an even sample of it.

## How it keeps you safe

- It answers only this machine, the home network and your tailnet, over HTTPS with its own certificate.
- Pairing moves a single-use 128-bit secret out of band (the QR code or a typed code). The server proves it knows
  the secret first, keyed to the fingerprint of the certificate the device actually sees, so a machine pretending
  to be your Plex server learns nothing; then the device proves it and gets a token, kept only as a hash here.
- Every request carries the person's own Plex token for this server, and Plex is asked as that person, so a
  restricted profile sees only what Plex already shows it. The owner chooses who may use the server: only them,
  their Plex Home, or everyone the server is shared with.
- Summaries use names only from the episode's dialogue, synopsis and cast; a summary that invents one, or a sentence
  the sources don't support, is rewritten or dropped.

Licensed GPL-3.0, like Crucible.
