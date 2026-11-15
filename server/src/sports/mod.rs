//! Research for Plex's Other Videos libraries: for files in the libraries the owner chose, the owner's own model
//! researches what each one is on the web (a sports event, an adult film or scene, or anything else) and the server
//! writes a proper title, date, description, people and artwork into Plex, locked, without ever touching the files,
//! and can take it all back.

pub mod apply;
pub mod checks;
pub mod cli;
pub mod record;
pub mod release;
pub mod research;
pub mod runner;
pub mod view;
pub mod web;
pub mod work;
