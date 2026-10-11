#!/bin/sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASE="${BASE:-http://127.0.0.1:${PORT:-32400}}"
TC=$(ls -d ~/.local/share/swiftly/toolchains/*/usr/lib/swift/linux 2>/dev/null | tail -1)
[ -n "$TC" ] && export LD_LIBRARY_PATH="$TC:$LD_LIBRARY_PATH"
W="$(mktemp -d)"
MODELS=$(find "$ROOT/Sources" -name APIModels.swift | head -1)
cp "$MODELS" "$W/APIModels.swift"
cat > "$W/Stubs.swift" <<'SW'
import Foundation
struct PlexAccountProbe: Decodable {
    let username: String?
    let title: String?
    let friendlyName: String?
}
struct HomeCardSnapshot: Codable, Sendable {
    let ratingKey: String
    let type: String?
    let title: String
    let grandparentTitle: String?
    let grandparentRatingKey: String?
    let grandparentThumb: String?
    let parentRatingKey: String?
    let thumb: String?
    let parentIndex: Int?
    let index: Int?
    let year: Int?
    let viewOffset: Int?
    let duration: Int?
    let viewCount: Int?
    let bucket: String
    var art: String? = nil
    var grandparentArt: String? = nil
    var librarySectionID: Int? = nil
}
enum Formatters {
    static func channelDescription(_ channels: Int?) -> String { "\(channels ?? 0)" }
}
SW
cat > "$W/main.swift" <<'SW'
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let base = CommandLine.arguments[1]
let paths = Array(CommandLine.arguments.dropFirst(2))
var failures = 0

func fetch(_ path: String) -> Data? {
    guard let url = URL(string: base + path) else { return nil }
    var req = URLRequest(url: url)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    let sem = DispatchSemaphore(value: 0)
    var out: Data?
    URLSession.shared.dataTask(with: req) { d, r, _ in
        if (r as? HTTPURLResponse)?.statusCode == 200 { out = d }
        sem.signal()
    }.resume()
    sem.wait()
    return out
}

for path in paths {
    guard let data = fetch(path) else { print("FAIL fetch \(path)"); failures += 1; continue }
    do {
        if path.hasPrefix("/api/v2/resources") {
            let r = try JSONDecoder().decode([PlexResource].self, from: data)
            let server = r.first { $0.provides.contains("server") }
            print("ok   \(path) resources=\(r.count) server=\(server?.name ?? "-") connections=\(server?.connections.count ?? 0)")
        } else if path.hasPrefix("/api/v2/pins") {
            let r = try JSONDecoder().decode(PlexPin.self, from: data)
            print("ok   \(path) pin=\(r.id) code=\(r.code) token=\(r.authToken ?? "nil")")
        } else if path.hasPrefix("/api/v2/user") {
            let r = try JSONDecoder().decode(PlexAccountProbe.self, from: data)
            print("ok   \(path) title=\(r.title ?? "-") username=\(r.username ?? "-")")
        } else if path.hasPrefix("/identity") {
            let r = try JSONDecoder().decode(PlexIdentity.self, from: data)
            print("ok   \(path) machine=\(r.MediaContainer.machineIdentifier ?? "-")")
        } else if path.hasPrefix("/status/sessions/history") {
            let r = try JSONDecoder().decode(PlexHistoryResponse.self, from: data)
            _ = try JSONDecoder().decode(PlexResponse.self, from: data)
            print("ok   \(path) history=\(r.MediaContainer.Metadata?.count ?? 0) total=\(r.MediaContainer.totalSize ?? 0)")
        } else {
            let r = try JSONDecoder().decode(PlexResponse.self, from: data)
            let c = r.MediaContainer
            print("ok   \(path) metadata=\(c.Metadata?.count ?? 0) hubs=\(c.Hub?.count ?? 0) dirs=\(c.Directory?.count ?? 0)")
        }
    } catch {
        print("FAIL decode \(path): \(error)"); failures += 1
    }
}
exit(failures == 0 ? 0 : 1)
SW
swiftc -o "$W/decode" "$W/main.swift" "$W/APIModels.swift" "$W/Stubs.swift" 2>&1 | grep -E "error" || true

j() { curl -s -H 'Accept: application/json' "$BASE$1"; }
EXTRA=$(j "/library/sections/1/all?X-Plex-Container-Size=500" | python3 -c "
import json,sys
m=json.load(sys.stdin)['MediaContainer']['Metadata']
print(' '.join('/library/metadata/%s'%x['ratingKey'] for x in m))")
SHOWS=$(j "/library/sections/2/all" | python3 -c "
import json,sys
m=json.load(sys.stdin)['MediaContainer']['Metadata']
print(' '.join('/library/metadata/%s /library/metadata/%s/children'%(x['ratingKey'],x['ratingKey']) for x in m))")
SEASONS=$(j "/library/metadata/2001/children" | python3 -c "
import json,sys
print(' '.join('/library/metadata/%s/children /library/metadata/%s'%(x['ratingKey'],x['ratingKey']) for x in json.load(sys.stdin)['MediaContainer']['Metadata']))")
EPS=$(j "/library/metadata/3002/children" | python3 -c "
import json,sys
print(' '.join('/library/metadata/%s'%x['ratingKey'] for x in json.load(sys.stdin)['MediaContainer']['Metadata']))")
PIN=$(curl -s -X POST "$BASE/api/v2/pins?strong=true" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
"$W/decode" "$BASE" /identity "/api/v2/pins/$PIN" /api/v2/resources /api/v2/user /library/sections \
  "/library/sections/1/all?X-Plex-Container-Start=0&X-Plex-Container-Size=50&sort=titleSort:asc" \
  "/library/sections/1/all?sort=addedAt:desc" "/library/sections/1/all?sort=year:desc&genre=6" \
  "/library/sections/2/all?sort=rating:desc" "/library/sections/3/all" \
  /library/sections/1/genre /library/sections/2/genre /library/sections/1/folder /library/sections/1/folder/A-F \
  /library/sections/2/folder /library/sections/3/folder \
  /hubs?count=20 /hubs/sections/1 /hubs/sections/2 /hubs/sections/3 /library/onDeck \
  "/library/recentlyAdded?X-Plex-Container-Start=0&X-Plex-Container-Size=100" \
  "/hubs/search?query=hal" "/hubs/search?query=salt" \
  "/status/sessions/history/all?X-Plex-Container-Start=0&X-Plex-Container-Size=100&sort=viewedAt:desc" \
  "/status/sessions/history/all?librarySectionID=1&sort=viewedAt:desc&X-Plex-Container-Start=0&X-Plex-Container-Size=120" \
  $EXTRA $SHOWS $SEASONS $EPS
