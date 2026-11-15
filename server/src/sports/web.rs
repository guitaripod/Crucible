//! The web as the research model sees it: a search engine the owner chose, and public pages read as plain text.
//! A page is read only from a public address, checked again on every redirect, so a page cannot steer the server into
//! the owner's own network.

use std::net::{IpAddr, SocketAddr};
use std::sync::LazyLock;
use std::time::Duration;

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::net::{classify, Peer};

/// Results a search returns to the model.
pub const RESULTS: usize = 8;
/// Characters of a page's text the model reads.
pub const PAGE_TEXT: usize = 9000;
/// Characters of a page's title the model reads.
const PAGE_TITLE: usize = 200;
/// The longest image address a page may offer as artwork.
const LONGEST_IMAGE_ADDRESS: usize = 2048;
/// The most a page or an image may weigh.
const LARGEST_DOWNLOAD: usize = 12 * 1024 * 1024;
const REDIRECTS: usize = 5;
const USER_AGENT: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36";

/// The search engine the research uses.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Engine {
    /// A SearXNG instance the owner runs, with its JSON format turned on.
    Searxng { url: String },
    /// Brave Search's API, with the key kept beside the config.
    Brave,
}

impl Engine {
    /// Where searches go, for the owner to read and agree to.
    pub fn destination(&self) -> String {
        match self {
            Engine::Searxng { url } => format!("your SearXNG at {}, which asks the search engines it is set to use", shown_address(url)),
            Engine::Brave => "Brave Search (api.search.brave.com)".into(),
        }
    }

    /// A short name for screens.
    pub fn label(&self) -> String {
        match self {
            Engine::Searxng { url } => format!("SearXNG at {}", shown_address(url).trim_end_matches('/')),
            Engine::Brave => "Brave Search".into(),
        }
    }
}

/// An address as it is shown to people: without a user name or password it may carry.
pub fn shown_address(url: &str) -> String {
    match reqwest::Url::parse(url) {
        Ok(mut parsed) if !parsed.username().is_empty() || parsed.password().is_some() => {
            let _ = parsed.set_username("");
            let _ = parsed.set_password(None);
            parsed.to_string().trim_end_matches('/').to_string()
        }
        _ => url.to_string(),
    }
}

#[derive(Debug, thiserror::Error)]
pub enum WebError {
    #[error("{0} did not answer: {1}")]
    Unreachable(String, String),
    #[error("{0} answered {1}")]
    Status(String, u16),
    #[error("{0} sent something unexpected")]
    Shape(String),
    #[error("only public http and https pages can be read")]
    NotPublic,
    #[error("{0} is too large to read")]
    TooLarge(String),
    #[error("Brave Search needs its key: crucible-server research --brave-key-file")]
    NoKey,
    #[error("the search engines {0} are turning searches away for now")]
    Busy(String),
}

/// One search result.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Found {
    pub title: String,
    pub url: String,
    pub snippet: String,
}

/// A page as the model reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Page {
    pub url: String,
    pub title: String,
    pub text: String,
    pub images: Vec<String>,
}

#[derive(Clone)]
pub struct Web {
    engine: Engine,
    key: Option<String>,
    http: reqwest::Client,
    last_search: std::sync::Arc<tokio::sync::Mutex<Option<std::time::Instant>>>,
}

/// The least time between two searches, so a library of new files never looks like a flood to the engines behind the search.
const SEARCH_SPACING: Duration = Duration::from_millis(1500);

static SCRIPTS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?is)<(script|style|noscript|svg|template|iframe)\b[^>]*>.*?</(script|style|noscript|svg|template|iframe)\s*>").expect("scripts")
});
static CHROME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<(nav|footer|header|aside|form)\b[^>]*>.*?</(nav|footer|header|aside|form)\s*>").expect("chrome"));
static BREAKS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)<br\s*/?>|</(p|div|li|tr|h[1-6]|table|section|article)\s*>").expect("breaks"));
static CELLS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)</t[dh]\s*>").expect("cells"));
static TAGS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<[^>]*>").expect("tags"));
static RUNS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[ \t\r\f\v\u{a0}]+").expect("runs"));
static BLANK_LINES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\n\s*\n+").expect("blank lines"));
static TITLE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?is)<title[^>]*>(.*?)</title>").expect("title"));
static META: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?is)<meta\b[^>]*>").expect("meta"));
static META_IMAGE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?i)(?:property|name)\s*=\s*["'](?:og:image(?::url|:secure_url)?|twitter:image(?::src)?)["']"#).expect("meta image"));
static CONTENT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(?i)content\s*=\s*["']([^"']+)["']"#).expect("content"));
static IMG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(?i)<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']"#).expect("img"));
static ARTWORK_WORDS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)poster|key-?art|event-?art|hero|banner|fight-?card").expect("artwork words"));

/// Entities common in page text, beside numeric ones.
fn unescape(text: &str) -> String {
    static NUMERIC: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"&#(x[0-9a-fA-F]+|\d+);").expect("numeric entity"));
    let named = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&ndash;", "-")
        .replace("&mdash;", "-")
        .replace("&rsquo;", "'")
        .replace("&lsquo;", "'")
        .replace("&ldquo;", "\"")
        .replace("&rdquo;", "\"");
    NUMERIC
        .replace_all(&named, |found: &regex::Captures| {
            let code = &found[1];
            let number = code.strip_prefix('x').map_or_else(|| code.parse().ok(), |hex| u32::from_str_radix(hex, 16).ok());
            number.and_then(char::from_u32).map_or_else(String::new, String::from)
        })
        .into_owned()
}

/// A page's readable text, title and the images it offers as artwork, from its HTML.
pub fn read_html(url: &reqwest::Url, html: &str) -> Page {
    let mut images = Vec::new();
    for meta in META.find_iter(html) {
        if META_IMAGE.is_match(meta.as_str()) {
            if let Some(content) = CONTENT.captures(meta.as_str()) {
                push_image(&mut images, url, &unescape(&content[1]));
            }
        }
    }
    for img in IMG.captures_iter(html) {
        let source = unescape(&img[1]);
        if ARTWORK_WORDS.is_match(&source) {
            push_image(&mut images, url, &source);
        }
    }
    let title: String = TITLE
        .captures(html)
        .map(|found| RUNS.replace_all(unescape(found[1].trim()).as_str(), " ").trim().chars().take(PAGE_TITLE).collect())
        .unwrap_or_default();
    let body = SCRIPTS.replace_all(html, " ");
    let body = CHROME.replace_all(&body, " ");
    let body = BREAKS.replace_all(&body, "\n");
    let body = CELLS.replace_all(&body, " | ");
    let body = TAGS.replace_all(&body, " ");
    let body = unescape(&body);
    let body = RUNS.replace_all(&body, " ");
    let body = BLANK_LINES.replace_all(&body, "\n");
    let text: String = body.lines().map(str::trim).filter(|line| !line.is_empty()).collect::<Vec<_>>().join("\n").chars().take(PAGE_TEXT).collect();
    images.truncate(8);
    Page { url: url.to_string(), title, text, images }
}

fn push_image(images: &mut Vec<String>, base: &reqwest::Url, source: &str) {
    let Ok(resolved) = base.join(source.trim()) else { return };
    if matches!(resolved.scheme(), "http" | "https")
        && resolved.as_str().len() <= LONGEST_IMAGE_ADDRESS
        && !images.iter().any(|known| known == resolved.as_str())
    {
        images.push(resolved.to_string());
    }
}

/// Whether every address a host resolves to is public, and the first of them to connect to.
async fn public_address(url: &reqwest::Url) -> Result<SocketAddr, WebError> {
    if !matches!(url.scheme(), "http" | "https") || !matches!(url.port_or_known_default(), Some(80 | 443)) {
        return Err(WebError::NotPublic);
    }
    let host = url.host_str().ok_or(WebError::NotPublic)?.trim_start_matches('[').trim_end_matches(']').to_string();
    let port = url.port_or_known_default().unwrap_or(443);
    let addresses: Vec<SocketAddr> = match host.parse::<IpAddr>() {
        Ok(ip) => vec![SocketAddr::new(ip, port)],
        Err(_) => tokio::net::lookup_host((host.as_str(), port)).await.map_err(|_| WebError::NotPublic)?.collect(),
    };
    if addresses.is_empty() || addresses.iter().any(|address| !is_public(address.ip())) {
        return Err(WebError::NotPublic);
    }
    Ok(addresses[0])
}

/// Whether an address is on the public internet: outside the owner's own networks, and none of the ranges that are
/// never a web server or that carry a private address inside them (NAT64, 6to4, Teredo, site-local, reserved).
fn is_public(ip: IpAddr) -> bool {
    let ip = ip.to_canonical();
    if classify(ip) != Peer::Outside || ip.is_unspecified() || ip.is_multicast() {
        return false;
    }
    match ip {
        IpAddr::V4(v4) => {
            let [first, second, third, _] = v4.octets();
            !(first == 0 || first >= 240 || (first, second, third) == (192, 0, 0))
        }
        IpAddr::V6(v6) => {
            let segments = v6.segments();
            if segments[..3] == [0x64, 0xff9b, 1] || segments[..6] == [0, 0, 0, 0, 0, 0] {
                return false;
            }
            if segments[..6] == [0x64, 0xff9b, 0, 0, 0, 0] {
                return is_public(IpAddr::V4(std::net::Ipv4Addr::from(((segments[6] as u32) << 16) | segments[7] as u32)));
            }
            if segments[0] == 0x2002 {
                return is_public(IpAddr::V4(std::net::Ipv4Addr::from(((segments[1] as u32) << 16) | segments[2] as u32)));
            }
            !(segments[0] & 0xffc0 == 0xfec0 || (segments[0], segments[1]) == (0x2001, 0) || segments[0] == 0x0100)
        }
    }
}

impl Web {
    pub fn new(engine: Engine, key: Option<String>) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(25))
            .connect_timeout(Duration::from_secs(8))
            .user_agent(USER_AGENT)
            .build()
            .expect("an HTTP client builds");
        Web { engine, key: key.map(|key| key.trim().to_string()).filter(|key| !key.is_empty()), http, last_search: Default::default() }
    }

    pub fn engine(&self) -> &Engine {
        &self.engine
    }

    /// Searches the web for `query`, a moment after the last search at the earliest.
    pub async fn search(&self, query: &str) -> Result<Vec<Found>, WebError> {
        {
            let mut last = self.last_search.lock().await;
            if let Some(at) = *last {
                let since = at.elapsed();
                if since < SEARCH_SPACING {
                    tokio::time::sleep(SEARCH_SPACING - since).await;
                }
            }
            *last = Some(std::time::Instant::now());
        }
        match &self.engine {
            Engine::Searxng { url } => {
                let endpoint = format!("{}/search", url.trim_end_matches('/'));
                let shown = shown_address(url);
                let response = self
                    .http
                    .get(&endpoint)
                    .query(&[("q", query), ("format", "json")])
                    .send()
                    .await
                    .map_err(|error| WebError::Unreachable(shown.clone(), error.without_url().to_string()))?;
                if !response.status().is_success() {
                    return Err(WebError::Status(shown, response.status().as_u16()));
                }
                let body: Value = response.json().await.map_err(|_| WebError::Shape(shown))?;
                let found = Self::found(&body["results"], "content");
                match throttled(&body) {
                    Some(engines) if found.is_empty() => Err(WebError::Busy(engines)),
                    _ => Ok(found),
                }
            }
            Engine::Brave => {
                let key = self.key.as_deref().ok_or(WebError::NoKey)?;
                let host = "api.search.brave.com".to_string();
                let response = self
                    .http
                    .get("https://api.search.brave.com/res/v1/web/search")
                    .query(&[("q", query), ("count", "8")])
                    .header("Accept", "application/json")
                    .header("X-Subscription-Token", key)
                    .send()
                    .await
                    .map_err(|error| WebError::Unreachable(host.clone(), error.without_url().to_string()))?;
                if response.status().as_u16() == 429 {
                    return Err(WebError::Busy(host));
                }
                if !response.status().is_success() {
                    return Err(WebError::Status(host, response.status().as_u16()));
                }
                let body: Value = response.json().await.map_err(|_| WebError::Shape(host))?;
                Ok(Self::found(&body["web"]["results"], "description"))
            }
        }
    }

    fn found(results: &Value, snippet_field: &str) -> Vec<Found> {
        results
            .as_array()
            .map(|results| {
                results
                    .iter()
                    .filter_map(|result| {
                        let url = result["url"].as_str()?.to_string();
                        let title: String = TAGS.replace_all(result["title"].as_str().unwrap_or(""), "").trim().chars().take(PAGE_TITLE).collect();
                        let snippet: String = TAGS.replace_all(result[snippet_field].as_str().unwrap_or(""), "").trim().chars().take(320).collect();
                        Some(Found { title: unescape(&title), url, snippet: unescape(&snippet) })
                    })
                    .take(RESULTS)
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Fetches a public URL, following redirects only to public addresses, and returns its final address, content type
    /// and bytes.
    pub async fn fetch(&self, address: &str) -> Result<(reqwest::Url, String, Vec<u8>), WebError> {
        let mut url = reqwest::Url::parse(address.trim()).map_err(|_| WebError::NotPublic)?;
        for _ in 0..=REDIRECTS {
            let pinned = public_address(&url).await?;
            let host = url.host_str().unwrap_or_default().to_string();
            let client = reqwest::Client::builder()
                .timeout(Duration::from_secs(25))
                .connect_timeout(Duration::from_secs(8))
                .user_agent(USER_AGENT)
                .redirect(reqwest::redirect::Policy::none())
                .resolve(&host, pinned)
                .no_proxy()
                .build()
                .map_err(|error| WebError::Unreachable(host.clone(), error.without_url().to_string()))?;
            let mut response = client
                .get(url.clone())
                .header("Accept-Language", "en")
                .send()
                .await
                .map_err(|error| WebError::Unreachable(host.clone(), error.without_url().to_string()))?;
            if response.status().is_redirection() {
                let next = response.headers().get(reqwest::header::LOCATION).and_then(|location| location.to_str().ok()).ok_or(WebError::Shape(host))?;
                url = url.join(next).map_err(|_| WebError::NotPublic)?;
                continue;
            }
            if !response.status().is_success() {
                return Err(WebError::Status(host, response.status().as_u16()));
            }
            if response.content_length().is_some_and(|length| length as usize > LARGEST_DOWNLOAD) {
                return Err(WebError::TooLarge(host));
            }
            let kind = response.headers().get(reqwest::header::CONTENT_TYPE).and_then(|kind| kind.to_str().ok()).unwrap_or("").to_lowercase();
            let mut bytes = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|error| WebError::Unreachable(host.clone(), error.without_url().to_string()))? {
                bytes.extend_from_slice(&chunk);
                if bytes.len() > LARGEST_DOWNLOAD {
                    return Err(WebError::TooLarge(host));
                }
            }
            return Ok((url, kind, bytes));
        }
        Err(WebError::Shape(url.host_str().unwrap_or_default().to_string()))
    }

    /// Reads a public page as text cut to `room` characters, with the images it offers as artwork.
    pub async fn read(&self, address: &str, room: usize) -> Result<Page, WebError> {
        let (url, kind, bytes) = self.fetch(address).await?;
        let host = url.host_str().unwrap_or_default().to_string();
        if !(kind.is_empty() || kind.contains("html") || kind.contains("text") || kind.contains("xml")) {
            return Err(WebError::Shape(host));
        }
        let mut page = read_html(&url, &String::from_utf8_lossy(&bytes));
        if page.text.chars().count() > room {
            page.text = page.text.chars().take(room).collect();
        }
        Ok(page)
    }

    /// Whether the engine answers a search, for the checklist.
    pub async fn works(&self) -> Result<usize, WebError> {
        Ok(self.search("UFC 300").await?.len())
    }
}

/// The engines a SearXNG answer says turned it away for asking too often, or nothing when none did.
fn throttled(body: &Value) -> Option<String> {
    let engines: Vec<String> = body["unresponsive_engines"]
        .as_array()?
        .iter()
        .filter_map(|pair| {
            let reason = pair.get(1)?.as_str()?.to_lowercase();
            (reason.contains("too many") || reason.contains("captcha") || reason.contains("access denied") || reason.contains("suspended"))
                .then(|| pair.get(0)?.as_str().map(str::to_string))
                .flatten()
        })
        .collect();
    (!engines.is_empty()).then(|| engines.join(", "))
}

/// A search's results as the model reads them.
pub fn results_for_model(found: &[Found]) -> Value {
    json!({"results": found})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_text_title_and_artwork_from_html() {
        let html = r#"<html><head><title>UFC 334: Gane vs. Hokit | UFC</title>
            <meta property="og:image" content="/images/2026-10/111426-ufc-334-EVENT-ART.jpg">
            <meta name="twitter:image" content="https://ufc.com/images/2026-10/111426-ufc-334-EVENT-ART.jpg">
            <script>var x = "<p>ignored</p>";</script><style>.a{}</style></head>
            <body><nav>Menu Home</nav><h1>UFC 334</h1><p>Madison Square Garden &amp; New York</p>
            <table><tr><td>Heavyweight</td><td>Ciryl Gane</td><td>vs.</td><td>Josh Hokit</td></tr></table>
            <img src="/themes/logo.png"><img src="https://cdn.example/poster-ufc334.jpg"></body></html>"#;
        let page = read_html(&reqwest::Url::parse("https://www.ufc.com/event/ufc-334").unwrap(), html);
        assert_eq!(page.title, "UFC 334: Gane vs. Hokit | UFC");
        assert!(page.text.contains("Madison Square Garden & New York"));
        assert!(page.text.contains("Heavyweight | Ciryl Gane | vs. | Josh Hokit"));
        assert!(!page.text.contains("ignored") && !page.text.contains("Menu Home"));
        assert_eq!(
            page.images,
            vec![
                "https://www.ufc.com/images/2026-10/111426-ufc-334-EVENT-ART.jpg",
                "https://ufc.com/images/2026-10/111426-ufc-334-EVENT-ART.jpg",
                "https://cdn.example/poster-ufc334.jpg"
            ]
        );
    }

    #[test]
    fn an_empty_answer_from_throttled_engines_is_busy_not_nothing() {
        let body = json!({"results": [], "unresponsive_engines": [["brave", "Suspended: too many requests"], ["duckduckgo", "CAPTCHA"], ["bing", "timeout"]]});
        assert_eq!(throttled(&body).as_deref(), Some("brave, duckduckgo"));
        assert_eq!(throttled(&json!({"results": [], "unresponsive_engines": [["bing", "timeout"]]})), None);
        assert_eq!(throttled(&json!({"results": []})), None);
    }

    #[test]
    fn addresses_never_show_credentials() {
        assert_eq!(shown_address("http://me:secret@nas.local:8888"), "http://nas.local:8888");
        assert_eq!(Engine::Searxng { url: "http://me:secret@nas.local:8888".into() }.label(), "SearXNG at http://nas.local:8888");
        assert_eq!(shown_address("http://127.0.0.1:8888"), "http://127.0.0.1:8888");
    }

    #[test]
    fn decodes_entities() {
        assert_eq!(unescape("Proch&#225;zka &#x26; Ulberg&nbsp;&ndash;"), "Procházka & Ulberg -");
    }

    #[tokio::test]
    async fn never_reads_the_owners_own_network() {
        for address in [
            "http://127.0.0.1/",
            "http://192.168.1.10/admin",
            "http://100.91.211.44:8090/",
            "http://[::1]/",
            "ftp://example.com/",
            "http://10.0.0.1/",
            "http://localhost/",
            "http://0.1.2.3/",
            "http://240.0.0.1/",
            "http://[64:ff9b::a00:1]/",
            "http://[2002:c0a8:101::]/",
            "http://[fec0::1]/",
            "http://[2001:0:4136:e378::1]/",
            "http://[::ffff:192.168.1.1]/",
            "http://[64:ff9b:1::a00:1]/",
            "http://[::c0a8:101]/",
        ] {
            let url = reqwest::Url::parse(address).unwrap();
            assert!(matches!(public_address(&url).await, Err(WebError::NotPublic)), "{address}");
        }
        let odd_port = reqwest::Url::parse("http://93.184.215.14:8080/").unwrap();
        assert!(matches!(public_address(&odd_port).await, Err(WebError::NotPublic)));
        let public = reqwest::Url::parse("https://93.184.215.14/").unwrap();
        assert!(public_address(&public).await.is_ok());
        let public_through_nat64 = reqwest::Url::parse("https://[64:ff9b::5db8:d70e]/").unwrap();
        assert!(public_address(&public_through_nat64).await.is_ok());
    }

    #[test]
    fn reads_searxng_and_brave_results() {
        let searxng = json!([{"title": "UFC 334 <b>Gane</b>", "url": "https://www.ufc.com/event/ufc-334", "content": "Saturday &amp; more"}]);
        assert_eq!(
            Web::found(&searxng, "content"),
            vec![Found { title: "UFC 334 Gane".into(), url: "https://www.ufc.com/event/ufc-334".into(), snippet: "Saturday & more".into() }]
        );
        let brave = json!([{"title": "UFC 334", "url": "https://x.example", "description": "<strong>Nov 14</strong>"}]);
        assert_eq!(Web::found(&brave, "description")[0].snippet, "Nov 14");
    }
}
