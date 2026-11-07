//! plex.tv, asked only at setup: the owner signs in with a PIN at plex.tv/link, and the companion checks that the
//! Plex server on this machine belongs to them.

use std::time::Duration;

use serde::Deserialize;

use crate::plex::PRODUCT;

/// plex.tv's API, or `CRUCIBLE_PLEXTV_URL` (a test server that speaks the same routes).
fn base() -> String {
    std::env::var("CRUCIBLE_PLEXTV_URL").map(|url| format!("{}/api/v2", url.trim_end_matches('/'))).unwrap_or_else(|_| "https://plex.tv/api/v2".into())
}

#[derive(Debug, thiserror::Error)]
pub enum PlexTvError {
    #[error("plex.tv did not answer: {0}")]
    Unreachable(String),
    #[error("plex.tv answered {0}")]
    Status(u16),
    #[error("plex.tv sent something unexpected: {0}")]
    Decode(String),
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
}

/// The owner's entry for the Plex server with this machine identifier, if the account owns it.
pub fn owned_server<'a>(resources: &'a [Resource], machine_identifier: &str) -> Option<&'a Resource> {
    resources.iter().find(|resource| resource.client_identifier == machine_identifier && resource.owned && resource.provides.contains("server"))
}

#[cfg(test)]
mod tests {
    use super::*;

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
