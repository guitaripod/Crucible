import datetime
import hashlib
import random
import time

SECTIONS = {
    "1": ("Movies", "movie"),
    "2": ("TV Shows", "show"),
    "3": ("Documentaries", "movie"),
}

GENRES = ["Action", "Adventure", "Animation", "Comedy", "Documentary", "Drama", "Mystery", "Sci-Fi", "Thriller"]
GENRE_ID = {g: str(i + 1) for i, g in enumerate(GENRES)}

MACHINE_ID = "7c1e5d2a9b304f68a1d7e3c05b92f4a8"
SERVER_NAME = "Marcus-PC"
CLIP_DURATION_MS = 150000

FIRST = ["Maren", "Idris", "Tove", "Sam", "Ana", "Tom", "Kasia", "Joel", "Imara", "Luca", "Nia", "Oskar", "Priya", "Dante",
         "Elin", "Rafi", "Wren", "Mateo", "Sana", "Bram", "Linnea", "Kofi", "Ines", "Callum", "Yara", "Teo", "Hanne", "Dario",
         "Mina", "Arlo", "Soren", "Leila", "Jonah", "Freya", "Niko", "Zadie", "Emil", "Rosa", "Anselm", "Thea"]
LAST = ["Vale", "Koh", "Lund", "Ortega", "Reyes", "Hale", "Brandt", "Okafor", "Marlow", "Sato", "Calder", "Nyberg", "Haddad",
        "Voss", "Ferreira", "Linden", "Abara", "Quill", "Strand", "Moreau", "Ketter", "Dahl", "Ibarra", "Thorne", "Yusuf",
        "Pryce", "Lindqvist", "Bellamy", "Duarte", "Raske", "Halloran", "Mbeki", "Orsini", "Fenwick", "Aldous", "Kemp",
        "Tavares", "Oyelaran", "Brask", "Solberg"]
ROLES = ["Captain", "Courier", "Inspector", "Cartographer", "Harbour Master", "Mechanic", "Medic", "Smuggler", "Dockhand",
         "Archivist", "Deputy", "Ranger", "Stranger", "Surveyor", "Radio Operator", "Lighthouse Keeper", "Cook", "Foreman",
         "Auditor", "Fixer", "Pilot", "Engineer", "Broker", "Navigator"]


def slug(name):
    return "".join(c.lower() if c.isalnum() else "-" for c in name).strip("-")


def stable_rng(*parts):
    h = hashlib.sha256("|".join(str(p) for p in parts).encode()).digest()
    return random.Random(int.from_bytes(h[:8], "big"))


def person_pool():
    rng = stable_rng("people")
    names, seen = [], set()
    while len(names) < 70:
        n = f"{rng.choice(FIRST)} {rng.choice(LAST)}"
        if n not in seen:
            seen.add(n)
            names.append(n)
    return names


PEOPLE = person_pool()

MOVIES = [
    ("Halcyon", 2021, 134, "R", ["Thriller", "Sci-Fi", "Drama"], 9.2, 8.1, "North Tide Pictures",
     "Some things are lost for a reason.",
     "When a derelict research platform surfaces in the Halcyon shipping lane, a retired salvage pilot is hired to find what its crew left behind. What she brings back is worth more than the platform itself, and someone else wants it first.",
     ("teal_amber", "platform", "cond"), 2, "unwatched", 1),
    ("Deep Field", 2026, 125, "PG-13", ["Sci-Fi", "Adventure"], 8.4, 8.0, "Orbit Lane Studios",
     "Every light is a door.",
     "A survey crew on the edge of charted space finds a signal repeating from a region the maps call empty. Following it means leaving the one thing they promised to protect.",
     ("violet_neon", "nebula", "light"), 1, "progress:0.42", 1),
    ("Low Tide", 2017, 108, "R", ["Drama", "Mystery"], 7.9, 7.6, "Gannet Films",
     "The sea gives back what it wants to.",
     "A harbour town's oldest secret surfaces when the water drops lower than anyone has seen it. A tired detective has one tide to find out who stands to lose the most.",
     ("ocean_deep", "lighthouse", "serif"), 410, "watched", 1),
    ("Undertow", 2019, 117, "R", ["Thriller"], 7.4, 7.2, "Gannet Films",
     "Don't fight it.",
     "A strong swimmer helps a stranger out of the surf and finds herself pulled into a missing-persons case with no body and too many witnesses.",
     ("indigo_dawn", "ocean", "cond"), 520, "watched", 1),
    ("Glass Harbour", 2014, 112, "PG-13", ["Drama"], 7.6, 7.9, "Kestrel & Dahl",
     "Fragile things survive the longest.",
     "Three generations of glassblowers fight to keep their furnace lit as developers close in on the old waterfront. A single commission may save the family or finish it.",
     ("aqua_mint", "mirror", "serif"), 700, "watched", 1),
    ("Cold Meridian", 2022, 128, "R", ["Thriller", "Action"], 7.8, 7.5, "Polar Line Pictures",
     "Two hours north of everything.",
     "A weather-station crew winters at the top of the world and learns their supply drops are being intercepted by someone who knows their names.",
     ("ice_blue", "snowpeaks", "cond"), 300, "watched", 1),
    ("Night Ferry", 2012, 99, "PG-13", ["Mystery", "Thriller"], 7.0, 7.3, "Lowlight Pictures",
     "The last crossing.",
     "On the final ferry of the night, a ticket inspector counts one passenger too many. Somewhere between the two shores, the extra face begins to look familiar.",
     ("violet_neon", "ship", "black"), 880, "watched", 1),
    ("Afterglow", 2024, 121, "PG-13", ["Sci-Fi", "Drama"], 8.0, 7.7, "Orbit Lane Studios",
     "The light remembers.",
     "Decades after a failed colony mission, its only survivor receives a transmission from the future she never reached. Answering it will cost her the quiet life she built.",
     ("sunset_pink", "dunes", "light"), 150, "unwatched", 1),
    ("Tidewater", 2010, 104, "PG", ["Adventure"], 6.9, 7.4, "Kestrel & Dahl",
     "Adventure comes in on the tide.",
     "Two siblings spending a summer at their grandfather's boatyard discover a hand-drawn chart hidden in the hull of an unfinished sloop.",
     ("ocean_deep", "ship", "cond"), 900, "watched", 1),
    ("Lantern Hill", 2016, 96, "PG", ["Animation", "Adventure"], 8.2, 8.5, "Paper Moon Animation",
     "Follow the lights home.",
     "A young lamplighter's apprentice climbs the hill nobody returns from to relight the last lantern before the festival of the longest night.",
     ("indigo_dawn", "hills", "serif"), 640, "watched", 1),
    ("Second Sun", 2025, 138, "PG-13", ["Sci-Fi", "Action"], 7.7, 7.4, "Orbit Lane Studios",
     "One sky. Two suns. No time.",
     "When a second sun appears over the northern hemisphere, a disgraced astronomer is the only person who knows how long the world has left to decide what to do about it.",
     ("ember", "dunes", "black"), 60, "unwatched", 1),
    ("Blackwater", 2018, 109, "R", ["Thriller", "Action"], 7.2, 7.0, "Lowlight Pictures",
     "Nobody comes back dry.",
     "A river guide agrees to take a group of strangers through the flooded canyons on a route she swore she would never run again.",
     ("forest_green", "river", "black"), 570, "watched", 1),
    ("Quiet Engines", 2023, 102, "PG-13", ["Sci-Fi", "Drama"], 7.5, 7.1, "North Tide Pictures",
     "Some silences are loud.",
     "The caretaker of a decommissioned freight station keeps its engines humming for a convoy that stopped coming twenty years ago, until one night a light appears on the line.",
     ("rust_dust", "rails", "light"), 200, "unwatched", 1),
    ("Iron Coast", 2020, 126, "R", ["Action", "Drama"], 7.6, 7.8, "Polar Line Pictures",
     "Hold the line.",
     "After a shipyard collapse, a union foreman and a corporate fixer are locked into the same impossible week: raise the last ship or lose the town.",
     ("rust_dust", "harbour", "cond"), 380, "watched", 1),
    ("Halcyon Bay", 2018, 101, "PG-13", ["Drama"], 6.8, 7.0, "Kestrel & Dahl",
     "Calm waters run deep.",
     "A hospice nurse returns to the seaside town she left at eighteen to care for the one person she has never forgiven.",
     ("aqua_mint", "mirror", "light"), 460, "unwatched", 1),
    ("Hal's Gambit", 2015, 114, "PG-13", ["Comedy", "Thriller"], 7.1, 7.6, "Lowlight Pictures",
     "Every move is a bluff.",
     "A mild-mannered chess instructor is mistaken for a legendary hustler and has exactly one evening to pull off the con everyone expects.",
     ("sunset_pink", "city", "serif"), 790, "unwatched", 1),
    ("Halfmoon", 2023, 97, "PG", ["Animation"], 7.8, 8.3, "Paper Moon Animation",
     "Half the world. Twice the wonder.",
     "A shy fox who only comes out at dusk befriends a moon-watcher and sets out to find the other half of the sky.",
     ("indigo_dawn", "hills", "light"), 240, "unwatched", 1),
    ("Paper Moons", 2009, 93, "PG", ["Comedy"], 6.6, 7.2, "Kestrel & Dahl",
     "The funniest night of their lives.",
     "A failing travelling theatre has one night to impress a critic who has already written the review.",
     ("sunset_pink", "city", "cond"), 1200, "watched", 1),
    ("The Long Weekend", 2011, 98, "PG-13", ["Comedy"], 6.4, 7.0, "Lowlight Pictures",
     "Four days. Three bad ideas.",
     "Four old friends rent a lake house for one last weekend and discover the owner has left a few house rules.",
     ("desert_gold", "lake", "cond"), 1100, "watched", 1),
    ("Ember & Ash", 2013, 119, "R", ["Drama"], 7.7, 7.9, "North Tide Pictures",
     "What burns, remains.",
     "Two rival chefs inherit the same restaurant and one kitchen. Neither will leave and neither can afford to stay.",
     ("ember", "city", "serif"), 960, "watched", 1),
    ("Rooftop Radio", 2019, 95, "PG", ["Comedy", "Drama"], 7.3, 7.7, "Kestrel & Dahl",
     "Tune in.",
     "A teenager broadcasts a pirate station from the roof of her apartment block and accidentally becomes the voice of the neighbourhood.",
     ("sunset_pink", "city", "light"), 540, "watched", 1),
    ("Signal Fires", 2008, 123, "R", ["Action", "Adventure"], 7.0, 7.4, "Polar Line Pictures",
     "Light them all.",
     "A mountain rescue team races a blizzard to light a chain of signal fires across a pass that has been closed for a century.",
     ("ice_blue", "snowpeaks", "black"), 1300, "watched", 1),
    ("Velvet Static", 2022, 107, "R", ["Mystery"], 7.1, 6.9, "Lowlight Pictures",
     "Listen closer.",
     "A sound engineer restoring a lost studio tape hears a confession buried under the music and realises the voice is still alive.",
     ("violet_neon", "city", "black"), 330, "unwatched", 1),
    ("Northern Lights Out", 2024, 111, "PG-13", ["Comedy"], 6.9, 7.2, "Kestrel & Dahl",
     "A very polite disaster.",
     "A small-town power cut during the biggest aurora of the decade turns a quiet community dinner into an all-night farce.",
     ("aqua_mint", "snowpeaks", "light"), 120, "unwatched", 1),
    ("Saltwater Kings", 2016, 131, "R", ["Action", "Adventure"], 7.4, 7.7, "Gannet Films",
     "Long live the tide.",
     "Rival crab-boat captains race the season's final storm for a catch that could end one family and make another.",
     ("ocean_deep", "ship", "cond"), 610, "watched", 1),
    ("The Cartographer's Daughter", 2021, 116, "PG-13", ["Adventure", "Mystery"], 7.6, 7.8, "Kestrel & Dahl",
     "Not all maps lead home.",
     "After her father vanishes, a young mapmaker follows the one chart he never published into a coastline the world forgot.",
     ("desert_gold", "dunes", "serif"), 280, "unwatched", 1),
    ("Moth Season", 2017, 100, "PG-13", ["Drama"], 7.4, 7.5, "North Tide Pictures",
     "Everything is drawn to the light.",
     "In a remote village where the lamps burn all night, a widow and a travelling entomologist share one very strange summer.",
     ("olive_haze", "hills", "light"), 560, "watched", 1),
    ("Orbit Hotel", 2025, 104, "PG-13", ["Comedy", "Sci-Fi"], 6.8, 7.1, "Orbit Lane Studios",
     "Zero gravity. Zero tips.",
     "The night manager of the first orbital hotel has twelve hours to find a missing VIP before the morning shuttle arrives.",
     ("indigo_dawn", "nebula", "cond"), 90, "unwatched", 1),
    ("Ice Core", 2019, 88, "TV-PG", ["Documentary"], 8.3, 8.1, "Polar Line Pictures",
     "The planet keeps a diary.",
     "Glaciologists drill three kilometres into the ice to read the last eight hundred thousand years of the atmosphere.",
     ("ice_blue", "snowpeaks", "light"), 330, "watched", 3),
    ("The Last Lighthouse", 2020, 92, "TV-PG", ["Documentary"], 8.0, 7.9, "Gannet Films",
     "Someone has to keep watch.",
     "A year with the final keeper of a manned lighthouse on the northern coast, and the engineers racing to automate her post.",
     ("teal_amber", "lighthouse", "serif"), 420, "unwatched", 3),
    ("Fathom Deep", 2022, 97, "TV-G", ["Documentary"], 8.4, 8.3, "North Tide Pictures",
     "Below the light.",
     "Marine biologists lower a camera sled to the floor of a trench no one has filmed and find it is crowded.",
     ("ocean_deep", "ocean", "cond"), 260, "watched", 3),
    ("Concrete Gardens", 2018, 84, "TV-PG", ["Documentary"], 7.5, 7.6, "Kestrel & Dahl",
     "Growth finds a way.",
     "Rooftop farmers, balcony beekeepers and a retired bus driver turn a city's grey margins into something green.",
     ("forest_green", "city", "light"), 800, "unwatched", 3),
    ("Silent Orchards", 2015, 90, "TV-G", ["Documentary"], 7.7, 7.8, "Kestrel & Dahl",
     "A year in a single field.",
     "Four seasons in a family-run orchard at the end of the road, filmed in one place and almost no words.",
     ("olive_haze", "hills", "serif"), 1000, "unwatched", 3),
    ("Wild Signal", 2023, 95, "TV-PG", ["Documentary"], 7.9, 8.0, "Lowlight Pictures",
     "The wilderness is talking.",
     "Radio ecologists tune in to the hidden soundscape of a protected valley and uncover how a forest keeps its own time.",
     ("forest_green", "forest", "cond"), 180, "unwatched", 3),
]

SHOWS = [
    dict(title="The Salt Road", year=2019, end=2023, cr="TV-MA", rating=9.0, audience=8.7, studio="Gannet Films",
         genres=["Drama", "Thriller", "Mystery"], tagline="Everything washes up eventually.",
         summary="A salvage crew works the cold northern coast, hauling up cargo that was never meant to be found. Each season follows one wreck and the people who profit from it.",
         style=("teal_amber", "lighthouse", "cond"), added=1, runtime=(42, 48),
         seasons=[
             ["The Wreck at Gannet Point", "Cold Salvage", "Spindrift", "Dead Weight", "The Harbour Board", "Ropewalk", "Brine", "What the Tide Left"],
             ["Harbour Lights", "Slack Water", "Salt and Rope", "Low Tide", "Undertow", "The Long Ebb", "Dead Reckoning", "Fathom", "Black Ice", "Landfall"],
             ["Gale Warning", "Slipway", "Ballast", "Halyard", "Cargo Manifest", "Lee Shore", "Fog Signal", "The Hundredth Fathom"],
             ["Return to Gannet Point", "Salvor's Right", "Stormglass", "Keelhaul", "The Last Cargo", "Open Water"],
         ],
         watch=lambda s, e: "w" if s == 1 or (s == 2 and e <= 3) else ("p:0.58" if (s, e) == (2, 4) else "")),
    dict(title="Northbound", year=2025, end=None, cr="TV-14", rating=8.2, audience=8.0, studio="Polar Line Pictures",
         genres=["Drama", "Adventure"], tagline="The road only goes one way.",
         summary="A rescue pilot and a runaway drive the length of a frozen country to deliver a package neither of them is allowed to open.",
         style=("ice_blue", "road", "light"), added=3, runtime=(44, 52),
         seasons=[["Departure", "Kilometre Zero", "The Border Road", "Whiteout", "Frozen Lake", "Wolf Hour", "Checkpoint Nine", "Aurora"]],
         watch=lambda s, e: "w" if e <= 5 else ""),
    dict(title="Meridian", year=2020, end=None, cr="TV-14", rating=8.8, audience=8.6, studio="Orbit Lane Studios",
         genres=["Sci-Fi", "Drama"], tagline="Find your place in the dark.",
         summary="The crew of a long-haul survey ship maps the places between stars, and slowly discovers the map is also mapping them.",
         style=("indigo_dawn", "nebula", "cond"), added=5, runtime=(43, 55),
         seasons=[
             ["First Light", "Transit", "Parallax", "Drift", "Perihelion", "Occultation", "Syzygy", "Apogee"],
             ["Reentry", "Dark Side", "Solstice", "Nadir", "Zenith", "Retrograde", "Eclipse", "Meridian Line"],
             ["Gravity Well", "The Long Night", "Redshift", "Anomaly", "Cascade", "Event Horizon", "Dust", "Convergence"],
             ["Aftermath", "Signal Lost", "Orbital Decay", "Lagrange", "Final Approach", "Home Orbit"],
         ],
         watch=lambda s, e: "w" if s < 4 or e == 1 else ""),
    dict(title="Ironwood", year=2021, end=None, cr="TV-MA", rating=8.5, audience=8.3, studio="Polar Line Pictures",
         genres=["Action", "Drama"], tagline="Roots run deeper than loyalty.",
         summary="A logging dynasty fights to keep the last stand of old-growth forest in the family as rivals, regulators and its own heirs close in.",
         style=("forest_green", "forest", "black"), added=4, runtime=(45, 58),
         seasons=[
             ["Timber Rights", "Old Growth", "The Mill", "Sawdust", "Blaze", "Felling", "Hardwood", "Heartwood"],
             ["Second Growth", "Sapling", "Burl", "Canopy", "Understory", "Windfall", "Taproot", "Rings"],
             ["Clearcut", "Splinter", "Deadfall", "Kindling", "Ironbark", "Ashes"],
         ],
         watch=lambda s, e: "w" if s < 3 else ("p:0.12" if (s, e) == (3, 1) else "")),
    dict(title="Paper Lanterns", year=2025, end=None, cr="TV-Y7", rating=8.9, audience=9.0, studio="Paper Moon Animation",
         genres=["Animation", "Adventure"], tagline="Small lights, big wishes.",
         summary="In a river town that celebrates with paper lanterns, a girl and her talking moth run errands for the wind and uncover where wishes go.",
         style=("sunset_pink", "river", "serif"), added=6, runtime=(22, 26),
         seasons=[["The Festival of Small Lights", "Wind Errand", "River of Paper", "The Lantern Maker", "Moth Night", "Dawn Release"]],
         watch=lambda s, e: "w" if e <= 2 else ("p:0.74" if e == 3 else "")),
    dict(title="Dry Season", year=2022, end=2022, cr="TV-PG", rating=8.6, audience=8.4, studio="North Tide Pictures",
         genres=["Documentary"], tagline="Water is the only story.",
         summary="Six months with farmers, well-diggers and rain-counters in a country that has not seen a full wet season in years.",
         style=("desert_gold", "dunes", "serif"), added=70, runtime=(46, 50),
         seasons=[["Cracked Earth", "The Rain Counters", "Wells", "Dust Roads", "Green Shoots", "First Rain"]],
         watch=lambda s, e: "w"),
    dict(title="Kestrel Row", year=2023, end=None, cr="TV-14", rating=7.9, audience=8.2, studio="Kestrel & Dahl",
         genres=["Comedy"], tagline="Thin walls. Thick plots.",
         summary="The residents of a crumbling apartment block share a leaky roof, a feuding landlord and absolutely no privacy.",
         style=("sunset_pink", "city", "cond"), added=40, runtime=(22, 27),
         seasons=[["Move-In Day", "Thin Walls", "The Landlord's Dog", "Fire Escape", "Rent Strike", "Block Party", "Power Cut", "Lease Renewal"],
                  ["New Tenants", "Leak", "The Elevator", "Roof Access", "Noise Complaint", "Spring Cleaning", "The Inspection", "Moving Out"]],
         watch=lambda s, e: "w" if s == 1 or e <= 2 else ""),
    dict(title="Halftide", year=2024, end=None, cr="TV-PG", rating=7.6, audience=7.9, studio="Lowlight Pictures",
         genres=["Comedy"], tagline="Always somewhere between.",
         summary="Two mismatched ferry deckhands try to keep a failing island service afloat, one ridiculous passenger at a time.",
         style=("aqua_mint", "mirror", "cond"), added=55, runtime=(22, 26),
         seasons=[["Half Measures", "Low Water", "Pier Pressure", "Bait and Switch", "Net Loss", "The Regatta", "Tidy Up", "High Water"],
                  ["Shoreline", "Message in a Bucket", "Crabby", "Flotsam", "Jetsam", "Dry Dock", "Seasick", "Anchors Away"]],
         watch=lambda s, e: "w" if s == 1 else ""),
    dict(title="Static Bloom", year=2026, end=None, cr="TV-MA", rating=8.1, audience=7.8, studio="Lowlight Pictures",
         genres=["Mystery", "Sci-Fi"], tagline="Something is broadcasting.",
         summary="A late-night radio host begins receiving calls from listeners who haven't been born yet.",
         style=("violet_neon", "city", "black"), added=8, runtime=(41, 49),
         seasons=[["Pilot Frequency", "Dead Air", "White Noise", "Carrier Wave", "The Listener", "Interference", "Bloom", "Signal to Noise"]],
         watch=lambda s, e: ""),
]

SETUPS = [
    "A new lead pulls the team in a direction nobody expected.",
    "An old promise comes due at the worst possible moment.",
    "The weather turns and plans fall apart.",
    "A stranger arrives with a story that does not add up.",
    "Someone on the inside has been keeping a record.",
    "A routine job exposes something that was buried on purpose.",
    "Two allies find themselves on opposite sides of a quiet decision.",
    "A message arrives that was meant for someone else.",
]
TWISTS = [
    "By nightfall, one choice changes how the rest of the season will be told.",
    "What looks like an ending turns out to be a door.",
    "Nothing is lost, but nothing is the same afterwards.",
    "The truth comes out, and not everyone is ready for it.",
    "A small mistake grows into a very large problem.",
    "A debt is called in, and the price is higher than anyone guessed.",
    "The cost of staying silent finally becomes clear.",
    "Hope arrives from the least likely direction.",
]

SALT_S2_SUMMARIES = [
    "The crew returns to Gannet Point after a long winter and finds the harbour lights burning in a boat that has been dry-docked for years.",
    "A tide table that does not match the almanac sends Mara to the one man who keeps the real one. His price is a favour she cannot repay.",
    "A knotted rope found on the seabed leads the crew to an old rigging loft. Inside, someone has been cataloguing every wreck on the coast.",
    "The tide drops lower than it has in a century and exposes the hull everyone was told was never there. Mara goes down alone.",
    "A cargo hold cracked open on the wreck holds nothing but sand, and the crew starts to wonder what was taken out of it.",
    "Stranded on a sandbar with the water rising, the crew has to decide whether to trust the one outsider who knew the channel.",
    "Using only a compass and an old logbook, Jonas retraces the ship's last hours and does not like where it ends.",
    "A diver surfaces from forty fathoms with a plan that could save the season, or end it.",
    "A freeze strands the harbour and everyone in it. Old grievances thaw faster than the ice.",
    "The wreck gives up its last secret and the crew learns exactly who has been paying them, and why.",
]

STREAM_SUBS = [
    (101, "English", "eng", "en", "English (SRT)", "srt", True, False),
    (102, "English", "eng", "en", "English SDH (SRT)", "srt", False, False),
    (103, "Spanish", "spa", "es", "Spanish (SRT)", "srt", False, False),
    (104, "Finnish", "fin", "fi", "Finnish (SRT)", "srt", False, False),
    (105, "French", "fra", "fr", "French (PGS)", "hdmv_pgs_subtitle", False, False),
]


class Library:
    def __init__(self, now=None):
        self.now = int(now or time.time())
        self.items = {}
        self.movies = []
        self.shows = []
        self.on_deck = []
        self.history = []
        self.actors = {}
        self._next = {"movie": 1001, "show": 2001, "season": 3001, "episode": 4001}
        self._build_movies()
        self._build_shows()
        self._build_related()
        for it in self.movies + self.shows:
            self._roles(it["_cast"])
        self._build_on_deck()
        self._build_history()

    def _rk(self, kind):
        v = self._next[kind]
        self._next[kind] += 1
        return str(v)

    def _t(self, days_ago, hour=12):
        return self.now - int(days_ago * 86400) - (hour * 137 % 3600)

    def _poster(self, rk, kind="thumb"):
        return f"/library/metadata/{rk}/{kind}/{1700000000 + int(rk)}"

    def _cast(self, key, n=5, fixed=None):
        rng = stable_rng("cast", key)
        if fixed:
            return fixed
        picks = rng.sample(PEOPLE, n + 3)
        roles = rng.sample(ROLES, n)
        cast = [(picks[i], roles[i]) for i in range(n)]
        return cast, picks[n], [picks[n + 1], picks[n + 2]]

    def _roles(self, cast):
        out = []
        for i, (name, role) in enumerate(cast):
            s = slug(name)
            self.actors[s] = name
            out.append({"id": 9000 + int(hashlib.md5(s.encode()).hexdigest()[:5], 16) % 90000, "tag": name, "role": role,
                        "thumb": f"/actors/{s}.jpg"})
        return out

    def _media(self, rk, duration_ms, width, height, hdr, size, title_kind):
        part_id = 50000 + int(rk)
        resolution = "4k" if height >= 2160 else "1080"
        audio_title = "English (EAC3 7.1)" if title_kind == "movie" else "English (AAC 5.1)"
        channels = 8 if title_kind == "movie" else 6
        streams = [
            {"id": int(rk) * 10 + 1, "streamType": 1, "codec": "h264", "language": "English", "languageCode": "eng",
             "bitrate": 14200 if height >= 2160 else 8200, "selected": True, "default": True,
             "displayTitle": ("4K (H.264 HDR10)" if hdr else "1080p (H.264)")},
            {"id": int(rk) * 10 + 2, "streamType": 2, "codec": "aac", "language": "English", "languageCode": "eng",
             "languageTag": "en", "channels": channels, "bitrate": 640, "selected": True, "default": True,
             "displayTitle": audio_title, "title": "Surround"},
            {"id": int(rk) * 10 + 3, "streamType": 2, "codec": "aac", "language": "Spanish", "languageCode": "spa",
             "languageTag": "es", "channels": 6, "bitrate": 448, "default": False,
             "displayTitle": "Spanish (AAC 5.1)"},
            {"id": int(rk) * 10 + 4, "streamType": 2, "codec": "aac", "language": "English", "languageCode": "eng",
             "languageTag": "en", "channels": 2, "bitrate": 192, "default": False,
             "displayTitle": "English Commentary (AAC Stereo)", "title": "Commentary"},
        ]
        for sid, lang, code, tag, display, codec, selected, forced in STREAM_SUBS:
            st = {"id": int(rk) * 10 + 5 + (sid - 101), "streamType": 3, "codec": codec, "language": lang,
                  "languageCode": code, "languageTag": tag, "displayTitle": display, "default": False, "forced": forced,
                  "selected": selected}
            if codec == "srt":
                st["format"] = "srt"
                st["key"] = f"/library/streams/{st['id']}"
            streams.append(st)
        return [{
            "id": int(rk), "duration": duration_ms, "bitrate": 14800 if height >= 2160 else 8800, "width": width,
            "height": height, "aspectRatio": 1.78, "audioChannels": channels, "audioCodec": "aac", "videoCodec": "h264",
            "videoResolution": resolution, "container": "mp4", "videoFrameRate": "24p",
            "videoProfile": "main 10" if hdr else "high",
            "Part": [{"id": part_id, "key": f"/library/parts/{part_id}/{1700000000 + int(rk)}/file.mp4",
                      "duration": duration_ms, "file": f"/media/{title_kind}s/{rk}.mp4", "size": size, "container": "mp4",
                      "Stream": streams}],
        }]

    def _markers(self, rk, duration_ms, kind):
        mk = []
        mid = int(rk) * 10
        if kind == "episode":
            mk.append({"id": mid + 1, "type": "intro", "startTimeOffset": 12000, "endTimeOffset": 58000})
            mk.append({"id": mid + 2, "type": "credits", "startTimeOffset": duration_ms - 70000,
                       "endTimeOffset": duration_ms, "final": True})
        else:
            mk.append({"id": mid + 2, "type": "credits", "startTimeOffset": duration_ms - 360000,
                       "endTimeOffset": duration_ms, "final": True})
        return mk

    def _build_movies(self):
        for (title, year, minutes, cr, genres, rating, aud, studio, tagline, summary, style, added, state, section) in MOVIES:
            rk = self._rk("movie")
            rng = stable_rng("movie", title)
            if title == "Halcyon":
                cast = [("Maren Vale", "Pilot"), ("Idris Koh", "Broker"), ("Tove Lund", "Engineer"), ("Sam Ortega", "Navigator")]
                directors, writers = ["Ana Reyes"], ["Tom Hale", "Ana Reyes"]
            else:
                cast, d, w = self._cast(title)
                directors, writers = [d], w
            duration = minutes * 60000
            hdr = rng.random() < 0.5 or title == "Halcyon"
            uhd = title == "Halcyon" or rng.random() < 0.4
            size = int(18.2 * 1073741824) if title == "Halcyon" else int(rng.uniform(6.5, 16) * 1073741824)
            item = {
                "ratingKey": rk, "key": f"/library/metadata/{rk}", "guid": f"plex://movie/{rk}", "type": "movie",
                "title": title, "titleSort": title.lower().removeprefix("the "), "librarySectionID": int(section),
                "librarySectionTitle": SECTIONS[str(section)][0], "studio": studio, "contentRating": cr,
                "summary": summary, "rating": rating, "audienceRating": aud, "year": year, "tagline": tagline,
                "thumb": self._poster(rk, "thumb"), "art": self._poster(rk, "art"), "duration": duration,
                "originallyAvailableAt": f"{year}-{(int(rk) % 11) + 1:02d}-{(int(rk) * 3 % 27) + 1:02d}",
                "addedAt": self._t(added, int(rk)), "updatedAt": self._t(added, int(rk)),
                "_style": style, "_genres": genres, "_directors": directors, "_writers": writers,
                "_cast": cast, "_kind": "movie",
            }
            item["_media"] = self._media(rk, duration, 3840 if uhd else 1920, 2160 if uhd else 1080, hdr, size, "movie")
            item["_markers"] = self._markers(rk, duration, "movie")
            if state == "watched":
                item["viewCount"] = 1
                item["lastViewedAt"] = self._t(rng.uniform(3, 90))
            elif state.startswith("progress:"):
                item["viewOffset"] = int(duration * float(state.split(":")[1]))
                item["lastViewedAt"] = self.now - 26 * 3600
            self.items[rk] = item
            self.movies.append(item)

    def _build_shows(self):
        for show in SHOWS:
            srk = self._rk("show")
            title = show["title"]
            rng = stable_rng("show", title)
            cast, d, w = self._cast(title, n=6)
            show_item = {
                "ratingKey": srk, "key": f"/library/metadata/{srk}/children", "guid": f"plex://show/{srk}", "type": "show",
                "title": title, "titleSort": title.lower().removeprefix("the "), "librarySectionID": 2,
                "librarySectionTitle": "TV Shows", "studio": show["studio"], "contentRating": show["cr"],
                "summary": show["summary"], "rating": show["rating"], "audienceRating": show["audience"],
                "year": show["year"], "tagline": show["tagline"], "thumb": self._poster(srk, "thumb"),
                "art": self._poster(srk, "art"), "duration": show["runtime"][0] * 60000,
                "originallyAvailableAt": f"{show['year']}-0{(int(srk) % 8) + 1}-1{int(srk) % 9}",
                "addedAt": self._t(show["added"], int(srk)), "updatedAt": self._t(show["added"], int(srk)),
                "childCount": len(show["seasons"]), "leafCount": 0, "viewedLeafCount": 0,
                "_style": show["style"], "_genres": show["genres"], "_directors": [], "_writers": [d], "_cast": cast,
                "_kind": "show", "_seasons": [], "_end": show["end"],
            }
            self.items[srk] = show_item
            self.shows.append(show_item)
            ep_counter = 0
            for si, titles in enumerate(show["seasons"], start=1):
                sk = self._rk("season")
                season = {
                    "ratingKey": sk, "key": f"/library/metadata/{sk}/children", "type": "season", "title": f"Season {si}",
                    "parentRatingKey": srk, "parentTitle": title, "parentIndex": si, "index": si,
                    "parentThumb": show_item["thumb"], "librarySectionID": 2, "librarySectionTitle": "TV Shows",
                    "thumb": self._poster(sk, "thumb"), "art": show_item["art"], "leafCount": len(titles),
                    "viewedLeafCount": 0, "addedAt": show_item["addedAt"], "year": show["year"] + si - 1,
                    "_style": show["style"], "_kind": "season", "_episodes": [], "_show": srk,
                    "summary": "", "_season": si,
                }
                self.items[sk] = season
                show_item["_seasons"].append(season)
                for ei, etitle in enumerate(titles, start=1):
                    ep_counter += 1
                    ek = self._rk("episode")
                    erng = stable_rng("ep", srk, si, ei)
                    minutes = erng.randint(*show["runtime"])
                    if title == "The Salt Road" and si == 2:
                        minutes = 42 if ei == 4 else erng.randint(43, 48)
                    duration = minutes * 60000
                    if title == "The Salt Road" and si == 2:
                        summary = SALT_S2_SUMMARIES[ei - 1]
                    else:
                        summary = SETUPS[(ei + si) % 8] + " " + TWISTS[(ei * 3 + si) % 8]
                    air = datetime.date(show["year"] + si - 1, 1 + (ei * 1) % 12, 3 + ei)
                    ep = {
                        "ratingKey": ek, "key": f"/library/metadata/{ek}", "guid": f"plex://episode/{ek}", "type": "episode",
                        "title": etitle, "titleSort": etitle.lower(), "grandparentRatingKey": srk, "parentRatingKey": sk,
                        "grandparentTitle": title, "parentTitle": f"Season {si}", "parentIndex": si, "index": ei,
                        "librarySectionID": 2, "librarySectionTitle": "TV Shows", "contentRating": show["cr"],
                        "summary": summary, "duration": duration, "originallyAvailableAt": air.isoformat(),
                        "year": air.year, "thumb": f"/library/metadata/{ek}/thumb/{1700000000 + int(ek)}",
                        "art": show_item["art"], "grandparentThumb": show_item["thumb"], "grandparentArt": show_item["art"],
                        "parentThumb": season["thumb"], "addedAt": show_item["addedAt"], "audienceRating": round(7 + erng.random() * 2.4, 1),
                        "_style": show["style"], "_kind": "episode", "_show": srk, "_season": sk,
                        "_genres": show["genres"], "_directors": [d], "_writers": [w[0]], "_cast": [],
                    }
                    ep["_media"] = self._media(ek, duration, 1920, 1080, False,
                                              int(erng.uniform(1.0, 3.4) * 1073741824), "episode")
                    ep["_markers"] = self._markers(ek, duration, "episode")
                    state = show["watch"](si, ei)
                    if state == "w":
                        ep["viewCount"] = 1
                        ep["lastViewedAt"] = self._t(erng.uniform(2, 200))
                    elif state.startswith("p:"):
                        ep["viewOffset"] = int(duration * float(state[2:]))
                    self.items[ek] = ep
                    season["_episodes"].append(ep)
        self._recount()
        self._set_progress_times()

    def _set_progress_times(self):
        by_title = {}
        for it in self.items.values():
            if it["type"] == "episode":
                by_title[(it["grandparentTitle"], it["parentIndex"], it["index"])] = it
        times = {("The Salt Road", 2, 4): 3600, ("Paper Lanterns", 1, 3): 3 * 86400, ("Ironwood", 3, 1): 5 * 86400}
        for key, secs in times.items():
            by_title[key]["lastViewedAt"] = self.now - secs

    def _recount(self):
        for show in self.shows:
            leaf = viewed = 0
            for season in show["_seasons"]:
                eps = season["_episodes"]
                season["leafCount"] = len(eps)
                season["viewedLeafCount"] = sum(1 for e in eps if e.get("viewCount", 0) > 0)
                leaf += season["leafCount"]
                viewed += season["viewedLeafCount"]
                if season["viewedLeafCount"] == season["leafCount"]:
                    season["viewCount"] = 1
                else:
                    season.pop("viewCount", None)
            show["leafCount"] = leaf
            show["viewedLeafCount"] = viewed
            if leaf and viewed == leaf:
                show["viewCount"] = 1
            else:
                show.pop("viewCount", None)
            last = [e.get("lastViewedAt", 0) for s in show["_seasons"] for e in s["_episodes"]]
            if max(last or [0]):
                show["lastViewedAt"] = max(last)

    def _build_related(self):
        for pool in (self.movies, self.shows):
            for it in pool:
                same = [o for o in pool if o is not it and o["librarySectionID"] == it["librarySectionID"]]
                same.sort(key=lambda o: (-len(set(o["_genres"]) & set(it["_genres"])),
                                         hashlib.md5((it["ratingKey"] + o["ratingKey"]).encode()).hexdigest()))
                it["_related"] = [o["ratingKey"] for o in same[:6]]

    def _find(self, show_title, season, index):
        for it in self.items.values():
            if it["type"] == "episode" and it["grandparentTitle"] == show_title and it["parentIndex"] == season and it["index"] == index:
                return it
        raise KeyError((show_title, season, index))

    def _build_on_deck(self):
        self.on_deck = [self._find("Northbound", 1, 6)["ratingKey"], self._find("Meridian", 4, 2)["ratingKey"],
                        self._find("Ironwood", 3, 2)["ratingKey"], self._find("Paper Lanterns", 1, 4)["ratingKey"]]

    def children_of(self, rk):
        it = self.items.get(rk)
        if not it:
            return None
        if it["type"] == "show":
            return it["_seasons"]
        if it["type"] == "season":
            return it["_episodes"]
        return []

    def render(self, it, full=False):
        out = {k: v for k, v in it.items() if not k.startswith("_")}
        if it["_kind"] in ("movie", "show") or full:
            if it.get("_genres"):
                out["Genre"] = [{"id": int(GENRE_ID[g]), "tag": g} for g in it["_genres"]]
        if full:
            if it.get("_directors"):
                out["Director"] = [{"id": 7000 + i, "tag": n} for i, n in enumerate(it["_directors"])]
            if it.get("_writers"):
                out["Writer"] = [{"id": 7100 + i, "tag": n} for i, n in enumerate(it["_writers"])]
            if it["_kind"] in ("movie", "show"):
                out["Role"] = self._roles(it["_cast"])
            elif it["_kind"] == "episode":
                show = self.items[it["_show"]]
                out["Role"] = self._roles(show["_cast"][:4])
            if "_media" in it:
                out["Media"] = it["_media"]
                out["Marker"] = it["_markers"]
            if "_related" in it:
                rel = [self.render(self.items[r]) for r in it["_related"]]
                label = "Related Movies" if it["type"] == "movie" else "Related Shows"
                out["Related"] = {"Hub": [{"type": it["type"], "hubIdentifier": f"{it['type']}.similar",
                                          "title": label, "size": len(rel), "more": False, "promoted": False,
                                          "Metadata": rel}]}
        return out

    def continue_watching(self):
        items = [i for i in self.items.values()
                 if i["type"] in ("movie", "episode") and i.get("viewOffset", 0) > 0 and not i.get("viewCount")]
        items.sort(key=lambda i: -i.get("lastViewedAt", 0))
        return items

    def recently_added(self):
        pool = list(self.movies) + list(self.shows)
        pool.sort(key=lambda i: -i["addedAt"])
        return pool

    def mark_watched(self, rk, watched):
        it = self.items.get(rk)
        if not it:
            return
        targets = [it]
        if it["type"] in ("show", "season"):
            targets = []
            for c in self.children_of(rk):
                targets.extend(self.children_of(c["ratingKey"]) if c["type"] == "season" else [c])
        for t in targets:
            if watched:
                t["viewCount"] = t.get("viewCount", 0) + 1
                t["lastViewedAt"] = self.now
                t.pop("viewOffset", None)
            else:
                t.pop("viewCount", None)
                t.pop("viewOffset", None)
        self._recount()

    def set_progress(self, rk, time_ms, duration_ms, state):
        it = self.items.get(rk)
        if not it or it["type"] not in ("movie", "episode"):
            return
        it["lastViewedAt"] = int(time.time())
        if state == "stopped" and duration_ms and time_ms >= duration_ms * 0.92:
            self.mark_watched(rk, True)
        elif time_ms > 0:
            it["viewOffset"] = time_ms

    def _build_history(self):
        for seed in range(1, 400):
            hist = self._try_history(seed)
            if hist:
                self.history = hist
                break
        else:
            self.history = self._try_history(1, strict=False)
        self.history.sort(key=lambda h: -h["viewedAt"])
        for i, h in enumerate(self.history):
            h["historyKey"] = f"/status/sessions/history/{i + 1}"

    def _entry(self, it, viewed_at):
        e = {"key": f"/library/metadata/{it['ratingKey']}", "ratingKey": it["ratingKey"], "type": it["type"],
             "title": it["title"], "viewedAt": viewed_at, "accountID": 1, "deviceID": 1 + int(it["ratingKey"]) % 3,
             "librarySectionID": it["librarySectionID"], "librarySectionTitle": it["librarySectionTitle"],
             "thumb": it["thumb"]}
        if it["type"] == "episode":
            e.update({"grandparentTitle": it["grandparentTitle"], "grandparentRatingKey": it["grandparentRatingKey"],
                      "grandparentThumb": it["grandparentThumb"], "grandparentKey": f"/library/metadata/{it['grandparentRatingKey']}",
                      "parentTitle": it["parentTitle"], "parentRatingKey": it["parentRatingKey"],
                      "parentIndex": it["parentIndex"], "index": it["index"],
                      "originallyAvailableAt": it["originallyAvailableAt"]})
        else:
            e["originallyAvailableAt"] = it["originallyAvailableAt"]
        return e

    def _try_history(self, seed, strict=True):
        rng = random.Random(seed)
        now = self.now
        today = datetime.date.fromtimestamp(now)
        start = datetime.date(2026, 1, 1)
        nd = (today - start).days
        weights = {"The Salt Road": 22, "Meridian": 18, "Ironwood": 12, "Northbound": 6, "Paper Lanterns": 4,
                   "Kestrel Row": 8, "Halftide": 8, "Dry Season": 3}
        eps = {}
        for s in self.shows:
            if s["title"] in weights:
                eps[s["title"]] = [e for se in s["_seasons"] for e in se["_episodes"] if e.get("viewCount")]
        cursor = {t: rng.randrange(len(v)) for t, v in eps.items()}
        movies = [m for m in self.movies if m.get("viewCount")]
        titles = list(weights)
        wlist = [weights[t] for t in titles]

        def ts(d, hour, minute):
            return datetime.datetime(d.year, d.month, d.day, 0, 0).timestamp() + hour * 3600 + minute * 60

        def episodes_run(title, n, t0, out, spacing_jitter=(0, 9)):
            t = t0
            for _ in range(n):
                lst = eps[title]
                it = lst[cursor[title] % len(lst)]
                cursor[title] += 1
                out.append(self._entry(it, int(t)))
                t += it["duration"] / 1000 + rng.randint(*spacing_jitter) * 60

        binge_age = None
        for age in range(20, min(32, nd)):
            d = today - datetime.timedelta(days=age)
            if d.weekday() == 5:
                binge_age = age
                break
        out = []
        run = 0
        for age in range(nd, -1, -1):
            d = today - datetime.timedelta(days=age)
            wk = d.weekday() >= 5
            if age < 12:
                active = True
            elif age == 12:
                active = False
            else:
                active = rng.random() < (0.9 if wk else 0.6) and run < 9
            run = run + 1 if active else 0
            if not active:
                continue
            if age == binge_age:
                episodes_run("Meridian", 13, ts(d, 12, 0), out, (0, 1))
                continue
            sessions = []
            if wk:
                sessions.append((rng.choice([15, 17, 19, 20]), rng.randint(0, 59), rng.randint(6, 9)))
                if rng.random() < 0.5:
                    sessions.append((rng.choice([22, 23]), rng.randint(0, 40), rng.randint(2, 3)))
            else:
                sessions.append((rng.choices([21, 22, 23, 0], [2, 4, 4, 3])[0], rng.randint(0, 59), rng.randint(3, 5)))
            for hour, minute, n in sessions:
                t0 = ts(d, hour, minute)
                if rng.random() < 0.2 and movies:
                    m = rng.choice(movies)
                    out.append(self._entry(m, int(t0)))
                else:
                    episodes_run(rng.choices(titles, wlist)[0], n, t0, out)
        out = [e for e in out if e["viewedAt"] <= now - 6 * 3600]
        halcyon = next(m for m in self.movies if m["title"] == "Halcyon")
        out.append(self._entry(halcyon, now - 2 * 3600))
        for ei, off in ((3, 3 * 3600 + 600), (2, 4 * 3600), (1, 4 * 3600 + 3000)):
            out.append(self._entry(self._find("The Salt Road", 2, ei), now - off))
        if not strict:
            return out
        out = [e for e in out if datetime.date.fromtimestamp(e["viewedAt"]) != today - datetime.timedelta(days=12)]
        dayset = {datetime.date.fromtimestamp(e["viewedAt"]) for e in out}
        if today not in dayset:
            return None
        cur = 0
        d = today
        while d in dayset:
            cur += 1
            d -= datetime.timedelta(days=1)
        longest = best = 0
        d = start
        while d <= today:
            if d in dayset:
                best += 1
                longest = max(longest, best)
            else:
                best = 0
            d += datetime.timedelta(days=1)
        if cur != 12 or longest != 12 or not (860 <= len(out) <= 960):
            return None
        return out
