//! A tray submenu with one ticked item per choice in a fixed table: the
//! Characters theme and the Voices mode.

use std::sync::Mutex;

use klepsydra_fleet::choice::Table;
use tauri::menu::{CheckMenuItem, IsMenuItem, Submenu};
use tauri::{AppHandle, Wry};

/// A submenu's items, by choice id, kept to tick the saved one after a change.
#[derive(Default)]
pub struct ChoiceItems(Mutex<Vec<(&'static str, CheckMenuItem<Wry>)>>);

impl ChoiceItems {
    /// The submenu TITLE, one item per choice in TABLE (ids PREFIX + id), NOW ticked.
    pub fn build(
        &self,
        app: &AppHandle,
        title: &str,
        prefix: &str,
        table: &'static Table,
        now: &str,
    ) -> tauri::Result<Submenu<Wry>> {
        let mut items = Vec::new();
        for (id, label) in table {
            let item = CheckMenuItem::with_id(
                app,
                format!("{prefix}{id}"),
                label,
                true,
                *id == now,
                None::<&str>,
            )?;
            items.push((*id, item));
        }
        let refs: Vec<&dyn IsMenuItem<Wry>> = items
            .iter()
            .map(|(_, i)| i as &dyn IsMenuItem<Wry>)
            .collect();
        let submenu = Submenu::with_items(app, title, true, &refs)?;
        if let Ok(mut held) = self.0.lock() {
            *held = items;
        }
        Ok(submenu)
    }

    /// Tick NOW's item, and only it.
    pub fn tick(&self, now: &str) {
        if let Ok(items) = self.0.lock() {
            for (id, item) in items.iter() {
                let _ = item.set_checked(*id == now);
            }
        }
    }
}

/// The choice a tray click picked, when MENU_ID is one of TABLE's items.
pub fn picked(menu_id: &str, prefix: &str, table: &'static Table) -> Option<&'static str> {
    let w = menu_id.strip_prefix(prefix)?;
    table.iter().map(|(id, _)| *id).find(|id| *id == w)
}
