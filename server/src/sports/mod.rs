//! Sports in Plex: for files in the libraries the owner chose, the owner's own model researches the event on the web
//! and the server writes a proper title, date, card and artwork into Plex, locked, without ever touching the files.

pub mod apply;
pub mod checks;
pub mod cli;
pub mod record;
pub mod release;
pub mod research;
pub mod runner;
pub mod view;
pub mod web;
