#!/usr/bin/env python3
"""Write the demo's prepared answers, Sources/CrucibleDemo/Data/answers.json.

The demo uses no network, so What to Watch and Write a Recap answer there from a file. This script makes that file
by asking Crucible's live aliases once, about the demo's own library, in every language of the app:

    CRUCIBLE_CORE_ONLY=1 CRUCIBLE_DEMO_ASKS=/tmp/demo-asks.json \\
        swift test --filter DemoBrainTests/writeTheAsksTheGeneratorSends
    python3 -I tools/ai/gen_demo_answers.py --asks /tmp/demo-asks.json

The Swift test writes what the app itself would send (each title's digest line, each show's recap message). This
script turns each example request into a plan, applies the plan the way WatchPicker.candidates does, asks for up to
eight picks with a reason each, and asks for a recap of each show the demo starts partway through. Replies are kept
in --cache, so a run that stops partway continues where it was. Run it again after the demo library, the example
requests or the instructions in tools/ai/prompts change; `swift test --filter DemoBrainTests` checks the result.

It asks one call at a time with a pause between them, on purpose: a burst of calls gets a request ended for CPU
time on the service's plan, which hangs that edge for everyone until the service is deployed again.

It asks on throwaway anonymous Midgar IDs, a new one whenever an ID's free answers run out, and prints no credential.
"""

import argparse
import hashlib
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
GATEWAY = "https://api.midgarcorp.cc/v1"
APP = "crucible"
BUNDLE = "com.guitaripod.crucible"
CODES = ["en", "de", "fr", "es", "it", "pt-BR", "pl", "sv", "da", "nb", "fi", "is", "ko", "ja", "zh-Hans", "zh-Hant"]
EXAMPLES = [
    "A film I haven't seen, under two hours",
    "Something light for tonight",
    "A series to start this weekend",
    "For the whole family",
]
PICKS_ASKED = 8
PICKS_NEEDED = 3
YEAR = 2026


class Caller:
    """The ID the calls go out on, and the pause kept between them."""

    token = None
    pause = 2.0


def post(url, body, headers):
    """One POST, returning the status and the decoded reply."""
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json", "X-App-ID": APP, "User-Agent": "crucible-demo-answers", **headers})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.loads(error.read())
        except Exception:
            return error.code, {}
    except (urllib.error.URLError, TimeoutError):
        return 0, {}


def mint():
    """A new anonymous Midgar ID's access token."""
    for attempt in range(6):
        status, reply = post(f"{GATEWAY}/identity/mint/unverified", {"bundleId": BUNDLE}, {})
        session = reply.get("session", reply)
        if status in (200, 201) and "accessToken" in session:
            return session["accessToken"]
        time.sleep(5 * (attempt + 1))
    sys.exit(f"could not get an anonymous Midgar ID (last status {status})")


def ask(alias, text, language):
    """The alias's reply as a decoded object, moving to a new ID when one's free answers are used up."""
    status, reply = 0, {}
    for attempt in range(8):
        if Caller.token is None:
            Caller.token = mint()
        body = {"alias": alias, "input": text, "idempotency_key": str(uuid.uuid4())}
        if language:
            body["language"] = language
        time.sleep(Caller.pause)
        status, reply = post(f"{GATEWAY}/intelligence/v1/run/chat.completion", body, {"Authorization": f"Bearer {Caller.token}"})
        if status == 200 and "content" in reply:
            try:
                return json.loads(reply["content"])
            except json.JSONDecodeError:
                continue
        if status in (401, 402, 403, 429):
            Caller.token = None
            continue
        if status == 502:
            sys.exit("the service answers 502: an edge may be hung (ops/runbooks/mako.md in the Midgar monorepo); stop and look before asking again")
        time.sleep(3 * (attempt + 1))
    sys.exit(f"{alias} gave no answer (last status {status}, code {reply.get('code') or reply.get('error')})")


class Cache:
    """Replies kept by alias, language and message, so a second run asks only for what is missing."""

    def __init__(self, path):
        self.path = pathlib.Path(path)
        self.held = json.loads(self.path.read_text()) if self.path.exists() else {}

    def answer(self, alias, text, language, accept):
        key = hashlib.sha256(f"{alias}\n{language}\n{text}".encode()).hexdigest()
        held = self.held.get(key)
        if held is not None and accept(held):
            return held
        for _ in range(5):
            reply = ask(alias, text, language)
            if accept(reply):
                self.held[key] = reply
                self.path.write_text(json.dumps(self.held, ensure_ascii=False))
                return reply
        sys.exit(f"{alias} in {language or 'no language'} never gave an acceptable answer")


def passes(title, plan):
    """Whether a title passes a plan's limits, as WatchPicker.candidates decides it."""
    if plan.get("kind") in ("movie", "show") and title["kind"] != plan["kind"]:
        return False
    if plan.get("watched") == "unseen" and title["seen"] != "unseen":
        return False
    if plan.get("watched") == "seen" and title["seen"] == "unseen":
        return False
    minutes, year = title["minutes"], title["year"]
    longest, shortest = plan.get("max_minutes"), plan.get("min_minutes")
    if longest and minutes is not None and minutes > longest:
        return False
    if shortest and minutes is not None and minutes < shortest:
        return False
    if plan.get("from_year") and year is not None and year < plan["from_year"]:
        return False
    if plan.get("to_year") and year is not None and year > plan["to_year"]:
        return False
    return not (plan.get("family") and title["adult"])


def pick_message(request, plan, candidates):
    """The message the pick alias reads, as WatchPicker.pickInput writes it, asking for more picks than a screen shows."""
    children = "Children will be watching.\n" if plan.get("family") else ""
    lines = "".join(f"\n{number}|{title['digest']}" for number, title in enumerate(candidates, start=1))
    return f"They asked: {request}\n{children}Choose up to {PICKS_ASKED}.\nTitles:{lines}"


def chosen(reply, candidates):
    """The distinct candidates a pick reply names, each with its reason."""
    picks, seen = [], set()
    for pick in reply.get("picks", []) if isinstance(reply, dict) else []:
        number, why = pick.get("id"), " ".join(str(pick.get("why", "")).split())
        if not isinstance(number, int) or not 1 <= number <= len(candidates) or number in seen or len(why) < 12:
            continue
        seen.add(number)
        title = candidates[number - 1]
        picks.append({"title": title["title"], "year": title["year"], "why": why[:160]})
    return picks


def good_recap(reply):
    return isinstance(reply, dict) and 20 <= len(str(reply.get("recap", "")).strip()) <= 1200


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--asks", required=True, help="the file DemoBrainTests/writeTheAsksTheGeneratorSends wrote")
    parser.add_argument("--out", default=str(ROOT / "Sources/CrucibleDemo/Data/answers.json"))
    parser.add_argument("--cache", default="demo-answers.cache.json")
    parser.add_argument("--pause", type=float, default=2.0, help="seconds between calls")
    arguments = parser.parse_args()

    asks = json.loads(pathlib.Path(arguments.asks).read_text())
    languages = asks["languages"]
    if len(languages) != len(CODES):
        sys.exit(f"the asks name {len(languages)} languages, this script {len(CODES)}")
    catalog = json.loads((ROOT / "Localization/Localizable.xcstrings").read_text())["strings"]

    def spoken(example, code):
        if code == "en":
            return example
        return catalog[example]["localizations"][code]["stringUnit"]["value"]

    cache = Cache(arguments.cache)
    Caller.pause = arguments.pause
    plans = []
    for example in EXAMPLES:
        plan = cache.answer("watch.plan.v1", f"Year now: {YEAR}\nThey asked: {example}", None, lambda reply: isinstance(reply, dict) and "watched" in reply)
        candidates = [title for title in asks["titles"] if passes(title, plan)]
        if len(candidates) < PICKS_NEEDED:
            sys.exit(f"\"{example}\" leaves {len(candidates)} titles of the demo library")
        plans.append((plan, candidates))
        print(f"plan for \"{example}\": {len(candidates)} candidates")

    def picks_for(place, code, language):
        plan, candidates = plans[place]
        message = pick_message(spoken(EXAMPLES[place], code), plan, candidates)
        reply = cache.answer("watch.pick.v1", message, language, lambda reply: len(chosen(reply, candidates)) >= PICKS_NEEDED)
        return {"picks": chosen(reply, candidates), "note": " ".join(str(reply.get("note") or "").split())[:200]}

    def recap_for(recap, language):
        return str(cache.answer("recap.describe.v1", recap["input"], language, good_recap)["recap"]).strip()

    watch = [{"plan": json.dumps(plan, ensure_ascii=False, separators=(",", ":")), "answers": {}} for plan, _ in plans]
    recaps = [{"input": recap["input"], "answers": {}} for recap in asks["recaps"]]
    total = len(languages) * (len(EXAMPLES) + len(recaps))
    done = 0
    for code, language in zip(CODES, languages):
        for place in range(len(EXAMPLES)):
            watch[place]["answers"][language] = picks_for(place, code, language)
        for place, recap in enumerate(asks["recaps"]):
            recaps[place]["answers"][language] = recap_for(recap, language)
        done += len(EXAMPLES) + len(recaps)
        print(f"{done} of {total} answers, through {language}", flush=True)

    for entry in watch + recaps:
        entry["answers"] = {language: entry["answers"][language] for language in languages}
    pathlib.Path(arguments.out).write_text(json.dumps({"version": 1, "watch": watch, "recaps": recaps}, ensure_ascii=False, indent=1) + "\n")
    print(f"wrote {arguments.out}: {len(watch)} examples and {len(recaps)} recaps in {len(languages)} languages")


main()
