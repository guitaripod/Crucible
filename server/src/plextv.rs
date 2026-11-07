//! plex.tv: at setup the owner signs in with a PIN at plex.tv/link and the companion checks that the Plex server on this
//! machine belongs to them; under the My Plex Home policy it also lists who is in the owner's Plex Home.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use quick_xml::events::Event;
use quick_xml::XmlVersion;
use serde::Deserialize;

use crate::plex::PRODUCT;

/// plex.tv's API, or `CRUCIBLE_PLEXTV_URL` (a test server that speaks the same routes).
fn base() -> String {
    std::env::var("CRUCIBLE_PLEXTV_URL").map(|url| format!("{}/api/v2", url.trim_end_matches('/'))).unwrap_or_else(|_| "https://plex.tv/api/v2".into())
}

/// plex.tv's older XML API, where the owner's friends and the shares of each server are listed.
fn legacy_base() -> String {
    std::env::var("CRUCIBLE_PLEXTV_URL").map(|url| url.trim_end_matches('/').to_string()).unwrap_or_else(|_| "https://plex.tv".into())
}

#[derive(Debug, thiserror::Error)]
pub enum PlexTvError {
    #[error("plex.tv did not answer: {0}")]
    Unreachable(String),
    #[error("plex.tv answered {0}")]
    Status(u16),
    #[error("plex.tv sent something unexpected: {0}")]
    Decode(String),
    #[error("the owner is not signed in: run crucible-server setup")]
    NotSignedIn,
}

/// A sign-in code the owner types at plex.tv/link.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pin {
    pub id: u64,
    pub code: String,
    #[serde(default)]
    pub auth_token: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub uuid: String,
}

/// A server on the account, as plex.tv lists it.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Resource {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub client_identifier: String,
    #[serde(default)]
    pub provides: String,
    #[serde(default)]
    pub owned: bool,
    #[serde(default)]
    pub access_token: Option<String>,
}

pub struct PlexTv {
    http: reqwest::Client,
    client_id: String,
}

impl PlexTv {
    pub fn new(client_id: &str) -> Self {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(20)).build().expect("an HTTP client builds");
        PlexTv { http, client_id: client_id.into() }
    }

    fn get(&self, path: &str) -> reqwest::RequestBuilder {
        self.with_headers(self.http.get(format!("{}{path}", base())))
    }

    fn with_headers(&self, request: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        request
            .header("Accept", "application/json")
            .header("X-Plex-Product", PRODUCT)
            .header("X-Plex-Version", env!("CARGO_PKG_VERSION"))
            .header("X-Plex-Client-Identifier", &self.client_id)
    }

    async fn json<T: for<'de> Deserialize<'de>>(request: reqwest::RequestBuilder) -> Result<T, PlexTvError> {
        let response = request.send().await.map_err(|error| PlexTvError::Unreachable(error.to_string()))?;
        if !response.status().is_success() {
            return Err(PlexTvError::Status(response.status().as_u16()));
        }
        response.json().await.map_err(|error| PlexTvError::Decode(error.to_string()))
    }

    /// A short code for plex.tv/link.
    pub async fn create_pin(&self) -> Result<Pin, PlexTvError> {
        Self::json(self.with_headers(self.http.post(format!("{}/pins", base())))).await
    }

    /// The PIN again; its `auth_token` is set once the owner has entered the code.
    pub async fn check_pin(&self, id: u64) -> Result<Pin, PlexTvError> {
        Self::json(self.get(&format!("/pins/{id}"))).await
    }

    pub async fn account(&self, token: &str) -> Result<Account, PlexTvError> {
        Self::json(self.get("/user").header("X-Plex-Token", token)).await
    }

    pub async fn resources(&self, token: &str) -> Result<Vec<Resource>, PlexTvError> {
        Self::json(self.get("/resources?includeHttps=1").header("X-Plex-Token", token)).await
    }

    /// The Plex tokens that the people in the owner's Plex Home, other than the owner, use for the server with this
    /// machine identifier.
    pub async fn home_tokens(&self, owner_token: &str, machine_identifier: &str) -> Result<Vec<String>, PlexTvError> {
        let users = self.xml("/api/users", owner_token).await?;
        let shares = self.xml(&format!("/api/servers/{machine_identifier}/shared_servers"), owner_token).await?;
        home_share_tokens(&users, &shares).map_err(PlexTvError::Decode)
    }

    async fn xml(&self, path: &str, token: &str) -> Result<String, PlexTvError> {
        let request = self
            .http
            .get(format!("{}{path}", legacy_base()))
            .header("Accept", "application/xml")
            .header("X-Plex-Product", PRODUCT)
            .header("X-Plex-Version", env!("CARGO_PKG_VERSION"))
            .header("X-Plex-Client-Identifier", &self.client_id)
            .header("X-Plex-Token", token);
        let response = request.send().await.map_err(|error| PlexTvError::Unreachable(error.to_string()))?;
        if !response.status().is_success() {
            return Err(PlexTvError::Status(response.status().as_u16()));
        }
        response.text().await.map_err(|error| PlexTvError::Decode(error.to_string()))
    }
}

/// The tokens of the shares (`SharedServer` in `shares`) that belong to a Plex Home member (`User` with `home="1"` in
/// `users`), or why either list is not one plex.tv would send.
pub fn home_share_tokens(users: &str, shares: &str) -> Result<Vec<String>, String> {
    let home: HashSet<String> = elements(users, "User")?
        .into_iter()
        .filter(|user| matches!(user.get("home").map(String::as_str), Some("1" | "true")))
        .filter_map(|user| user.get("id").cloned())
        .collect();
    Ok(elements(shares, "SharedServer")?
        .into_iter()
        .filter(|share| share.get("userID").is_some_and(|id| home.contains(id)))
        .filter_map(|share| share.get("accessToken").cloned())
        .filter(|token| !token.is_empty())
        .collect())
}

/// The attributes of every `tag` element in a whole, well-formed `MediaContainer` document; anything else (an empty
/// body, a captive portal's page, a cut-off answer) is an error rather than an empty list.
fn elements(xml: &str, tag: &str) -> Result<Vec<HashMap<String, String>>, String> {
    let mut reader = quick_xml::Reader::from_str(xml);
    reader.config_mut().check_end_names = true;
    let mut found = Vec::new();
    let mut container = false;
    let mut depth = 0usize;
    loop {
        let event = reader.read_event();
        match &event {
            Ok(Event::Start(_)) => depth += 1,
            Ok(Event::End(_)) => depth = depth.saturating_sub(1),
            _ => {}
        }
        match event {
            Ok(Event::Start(element) | Event::Empty(element)) if element.name().as_ref() == "MediaContainer" => container = true,
            Ok(Event::Start(element) | Event::Empty(element)) if element.name().as_ref() == tag => found.push(
                element
                    .attributes()
                    .flatten()
                    .filter_map(|attribute| {
                        let value = attribute.normalized_value(XmlVersion::Implicit1_0).ok()?;
                        Some((attribute.key.as_ref().to_string(), value.into_owned()))
                    })
                    .collect(),
            ),
            Ok(Event::Eof) if container && depth == 0 => return Ok(found),
            Ok(Event::Eof) => return Err("plex.tv's answer is not a MediaContainer".into()),
            Err(error) => return Err(format!("plex.tv's answer does not parse: {error}")),
            _ => {}
        }
    }
}

/// The owner's entry for the Plex server with this machine identifier, if the account owns it.
pub fn owned_server<'a>(resources: &'a [Resource], machine_identifier: &str) -> Option<&'a Resource> {
    resources.iter().find(|resource| resource.client_identifier == machine_identifier && resource.owned && resource.provides.contains("server"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_home_members_share_token_counts_and_a_friends_does_not() {
        let users = r#"<?xml version="1.0" encoding="UTF-8"?>
<MediaContainer friendlyName="myPlex" identifier="com.plexapp.plugins.myplex" totalSize="3">
  <User id="31" title="Kids" username="" home="1" restricted="1"><Server id="9" machineIdentifier="abc" name="arch" owned="1"/></User>
  <User id="32" title="Sam &amp; Co" username="sam" home="1" restricted="0"/>
  <User id="41" title="Robin" username="robin" home="0" restricted="0"/>
</MediaContainer>"#;
        let shares = r#"<MediaContainer friendlyName="myPlex" machineIdentifier="abc">
  <SharedServer id="1" userID="31" accessToken="kids-token" owned="0"><Section id="2" key="2" title="TV" type="show" shared="1"/></SharedServer>
  <SharedServer id="2" userID="41" accessToken="robin-token" owned="0"/>
  <SharedServer id="3" userID="32" accessToken="" owned="0"/>
</MediaContainer>"#;
        assert_eq!(home_share_tokens(users, shares), Ok(vec!["kids-token".to_string()]));
        assert!(home_share_tokens("", shares).is_err());
        assert!(home_share_tokens("<html><body>Sign in to this Wi-Fi</body></html>", shares).is_err());
        assert!(home_share_tokens(users, "<MediaContainer><SharedServer userID=\"31\" accessToken=\"kids-token\">").is_err());
    }

    #[test]
    fn finds_only_an_owned_server_with_the_same_identifier() {
        let resources: Vec<Resource> = serde_json::from_str(
            r#"[{"name":"arch","clientIdentifier":"abc","provides":"server","owned":true,"accessToken":"t"},
                {"name":"friend","clientIdentifier":"def","provides":"server","owned":false},
                {"name":"phone","clientIdentifier":"ghi","provides":"client,player","owned":true}]"#,
        )
        .unwrap();
        assert_eq!(owned_server(&resources, "abc").map(|r| r.name.as_str()), Some("arch"));
        assert!(owned_server(&resources, "def").is_none());
        assert!(owned_server(&resources, "ghi").is_none());
    }
}
