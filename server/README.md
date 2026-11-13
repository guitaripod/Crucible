# Crucible Server

The optional companion that runs on the machine with your Plex Media Server. Crucible on iPhone, iPad and Apple
TV pairs with it once and then gets:

- **Skips from the file itself**: intro, recap, preview, ending and credits from Plex's markers and the file's
  named chapters (`GET /crucible/v1/segments/{ratingKey}`).
- **Previously On**: a short recap of the last episodes you finished, written by a model you choose from Plex's
  synopsis and the episodes' own subtitles, and checked before you see it.
- **Ask**: pause and ask about what you're watching; the answer uses only what you've already seen.

With a model on this machine or on a computer on your own tailnet, nothing leaves your network. No such computer?
Point it at a hosted model with your own key instead ([The model](#the-model)); it says what would be sent before
it uses one.

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

An Apple TV pairs through a paired iPhone or iPad: on the TV, You › Crucible Server › Pair with iPhone, pick the
iPhone and tap Allow on it; or Show Code for iPhone and scan the TV's code with the iPhone's Camera. Typing the code
`crucible-server pair` prints works too.

```sh
crucible-server pair        # a new pairing code for another device
crucible-server devices     # what is paired
crucible-server unpair ID
crucible-server model       # which model writes and where it is, then asks it a tiny question
crucible-server doctor      # Plex, the model, ffmpeg, the certificate and the service, checked
crucible-server summarize EPISODE.mkv --show "Dragon Ball Super"   # judge a model on a real file
```

Needs ffmpeg for subtitles.

## The model

Recaps and answers come from any OpenAI-compatible endpoint. `setup` looks for llama-swap, Ollama and LM Studio on
this machine; `crucible-server model` changes the choice later without signing in to Plex again, asks the model a
tiny question to see that it answers, and restarts the service this user installed (restart a container yourself).

```sh
crucible-server model --url http://gamingpc:8081/v1 --name NAME                           # a model server on your tailnet
crucible-server model --url https://openrouter.ai/api/v1 --name NAME --key-file key.txt   # a hosted service, your key
crucible-server model --key-file new-key.txt                                              # a new key for the same service
crucible-server model --off                                                               # skips only
```

The more of an episode's dialogue fits the model's window, the better: about 32K holds a long episode whole, and with
less a summary reads an even sample of it and an answer reads the latest lines whole and a sample of the earlier
ones. When a service does not state the window, 8K is assumed: say it with `--context` (`--model-context` in `setup`).

**A hosted model.** Any service that speaks the OpenAI API works by its address, such as OpenRouter
(`https://openrouter.ai/api/v1`) or OpenAI (`https://api.openai.com/v1`), with the model's name as that service
lists it and the key it gave you in a file. Before using one, Crucible Server says what it will send there and asks
(with `--yes` it says it and goes on): the subtitles of episodes people here have finished and of the one they are
watching up to where they paused, the names of shows and episodes, Plex's synopses and cast lists, and the questions
they ask. No Plex account, token or file is sent, and nothing goes to Crucible's developer. You are asked once
for each host, and the agreement is recorded with it: a hosted model written into `config.toml` by hand, or copied
in from another machine, is not used until you agree to it in `setup` or `crucible-server model`, and saying no
there ends its use and forgets its key. `crucible-server model --off` does the same for one you agreed to. You pay the service for what is asked of it, which is
little: nothing is written until someone asks, a Previously On reads at most three finished episodes' subtitles, an
answer reads the episode being watched and up to five summaries, and each episode's summary is kept and not written
again while its subtitles, the model and the prompt stay the same.

The key is kept in `model-key` beside the config, readable only by your user, never in `config.toml` or a log, with
the address it was given for, and it is sent nowhere else: point the server at another address, by a command or by
editing the config, and that address gets no key, and a key file given to `setup` is never tried on the model
servers setup looks for by itself. It leaves your own network only over HTTPS; a model server on this machine, your
home network or your tailnet that asks for a key gets it over plain HTTP, directly and never through a proxy.
Redirects are never followed. In Docker, mount the key as a secret and give its path to `setup` with
`--model-key-file`, or in `CRUCIBLE_MODEL_KEY_FILE`, beside `--model-url`.

## How it keeps you safe

- It answers only this machine, the home network and your tailnet, over HTTPS with its own certificate.
- Pairing moves a single-use 128-bit secret out of band (the QR code or a typed code). The server proves it knows
  the secret first, keyed to the fingerprint of the certificate the device actually sees, so a machine pretending
  to be your Plex server learns nothing; then the device proves it and gets a token, kept only as a hash here.
- An Apple TV gets its secret from a paired iPhone or iPad: over Apple's encrypted device-to-device link after you
  tap Allow, or by the iPhone passing on the secret the TV shows, over its pinned connection. Either secret pairs one
  device once, only while it is fresh, and only if the Plex account on the TV is one the server lets in. The iPhone
  follows pairing links only to addresses on the home network or the tailnet.
- Every request carries the person's own Plex token for this server, and Plex is asked as that person, so a
  restricted profile sees only what Plex already shows it. The owner chooses who may use the server: only them,
  their Plex Home (the members plex.tv lists with access to this server, asked again at most every ten minutes, or
  once a minute while someone it does not list keeps asking), or
  everyone the server is shared with. `crucible-server doctor` says how many people that is.
- A model outside your network is used only after you agree to what it is sent, with a key that never leaves your
  network over plain HTTP. `crucible-server doctor` says where the model is, and so does Crucible's own status line.
- Summaries use names only from the episode's dialogue, synopsis and cast; a summary that invents one, or a sentence
  the sources don't support, is rewritten or dropped.

Licensed GPL-3.0, like Crucible.
