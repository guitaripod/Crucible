# Crucible Server

The optional companion that runs on the machine with your Plex Media Server. Crucible on iPhone, iPad and Apple
TV pairs with it once and then gets:

- **Skips from the file itself**: intro, recap, preview, ending and credits from Plex's markers and the file's
  named chapters (`GET /crucible/v1/segments/{ratingKey}`).
- **Previously On**: a short recap of the last episodes you finished, written by a model you choose from Plex's
  synopsis and the episodes' own subtitles, and checked before you see it.
- **Ask**: pause and ask about what you're watching; the answer uses only what you've already seen.
- **Library Research**: for the videos in your Other Videos libraries (sports, adult films or anything else), your model
  searches the web, reads the pages about each file and gives it a real title, date, description, people and poster in
  Plex, without touching the files, and all of it can be taken back ([Library Research](#library-research)).

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

With Docker (Unraid, Synology, TrueNAS, any NAS): put the Linux release binary beside `server/packaging/Dockerfile` as
`crucible-server-amd64` (or `crucible-server-arm64`), build the image under the name `compose.yml` uses, mount your
media read-only at the paths Plex uses, and run setup once in the container before starting it:

```sh
docker build -t ghcr.io/guitaripod/crucible-server:latest server/packaging
docker compose -f server/packaging/compose.yml run --rm -it crucible-server setup --no-service
docker compose -f server/packaging/compose.yml up -d
```

`setup` finds Plex on this machine, checks that Plex refuses requests without a token, signs you in at
plex.tv/link, finds a model server (llama-swap, Ollama or LM Studio on this machine, or `--model-url`), makes the
server's certificate, keeps it running as a service (systemd user unit or launchd agent) and shows a QR code. Scan it
with the iPhone's Camera, or in Crucible under Settings, Crucible Server.

An Apple TV pairs through a paired iPhone or iPad: on the TV, You › Crucible Server › Pair with iPhone, pick the
iPhone and tap Allow on it; or Show Code for iPhone and scan the TV's code with the iPhone's Camera. Or type the code
`crucible-server pair` prints.

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

Recaps, answers and Library Research come from any OpenAI-compatible endpoint. `setup` looks for llama-swap, Ollama and
LM Studio on this machine and lists their models by name, a loaded one with a large enough window first;
`crucible-server model` changes the choice later without signing in to Plex again, asks the model a tiny question to
see that it answers, and restarts the service this user installed (restart a container yourself).

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

## Library Research

Plex has no agent for the videos in an Other Videos library, so each shows up as its file name
(`ufc.fight.night.286.nurmagomedov.vs.song.1080p.web.h264-verum`). Library Research turns that into
**UFC Fight Night 286: Nurmagomedov vs. Song**, dated, sorted with the event's other parts, with the card, the venue and
the event's artwork, and does it again on its own whenever a new file arrives. You say what each library holds:

- **Sports**: each file is researched as an event, with its card, and every part of an event is titled alike.
- **Adult**: each film or scene is researched for its title, studio, performers, release date and cover, through your
  own model and the search engine you chose. The summary is a neutral, non-graphic listing. A file whose name
  suggests someone under 18 is not researched; after research, every sentence of the record and of the pages read that
  mentions a young age, minors, school or a birth date is judged by your model against the work's cast and date (a
  site's age gate is not counted), and a work any sentence counts against is not written. The same check covers a file
  in another library whose name or sources mark it as adult. The apps never show this artwork on their research
  screens, and only the owner sees these files there.
- **General**: anything else, such as game cinematics, concerts, documentaries or clips; the model works out what each
  file is, with its series, maker and the people in it.

It is for people who run a capable model: one that calls tools, thinks before it answers and has a context window of
32K tokens or more. In practice that is a model of about 20 billion parameters or more on a graphics card with 16 GB
of memory (24 GB is comfortable), or on an Apple silicon Mac with 32 GB or more. Each file is researched by the model
itself: it searches the web, reads the pages that confirm what the file is, and hands in a record. The server checks
the record before anything reaches Plex: the date must be real and before the file arrived, an event number in the
file name must match, the sources must be pages the model actually saw, and nothing may give away a result. Then it
writes the title, sort title, date, summary, studio, genre, collection, cast and artwork through Plex's own API, every
field locked so Plex's agents leave it alone. The media files are never opened, moved or renamed, so a torrent client
can keep seeding them. Change a field by hand in Plex and the server leaves that item to you from then on.

Before research first writes to a file it keeps what Plex showed, poster included, so any file, or a whole library, can
be taken back: every field research wrote returns to what it was and is unlocked, the genres, collections and cast it
added go, and its poster gives way to the one Plex showed before. Whatever you changed in Plex yourself since stays as
you made it, and research leaves the file alone until you ask for it again. Take a library out of research and the
research running in it stops at once (a write already under way finishes, so Plex is never left half written); what it
wrote stays until you take it back. Change what a library holds and its files are researched again as the new kind.

```sh
crucible-server research                                                     # every requirement, checked live
crucible-server research --searxng http://127.0.0.1:8888 --library Sports --kind Sports=sports --agree --on
crucible-server research --try "UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4"       # research one name, write nothing
crucible-server research --try "01 - Wings of Liberty - The Deal.mkv" --as general
crucible-server research --undo "UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4"      # take one file back
crucible-server research --undo-library Sports                                    # take a whole library back
crucible-server research --again "UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4"     # research it again
```

Search goes through a [SearXNG](https://docs.searxng.org) you run (turn its JSON format on) or Brave Search with your
own key (`--brave-key-file`). Searches name what is in your files, such as "UFC 334 prelims" or a film's title; nothing
else from your library is sent, and the research does not start until you agree to where searches go. Pages are read
only from public addresses, checked again on every redirect.

Crucible on iPhone, iPad and Apple TV shows every requirement with whether it is met and how to meet it, lets the
owner choose libraries and what they hold, agree and switch research on, shows each file being researched and the step
the model is on, lists what it made of each file, and takes back a file or a library. With Nemotron 3.5 Bolt on
llama.cpp a file takes about a minute; the copies of a file and the other parts of a sports event reuse it (each scene
of a film is its own research, since it has its own title, cast and date), newest files go first, and with a model on
your own machines four are researched at once.

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
- Library Research writes to Plex only for the libraries the owner chose, only as the owner, and only metadata, and keeps
  what it replaced so it can be taken back. It reads web pages only at public addresses, so a page cannot steer it into
  your network.

Licensed GPL-3.0, like Crucible.
