//! The character each session wears when it has no cast voice of its own
//! (#148): keryx muted, a repo with no home voice, a voice another card
//! keeps, or a voice outside the cast. A pick is made once, the first time
//! the session is on the wall without a voice, as the least shown of the
//! faces showing then (own voices and picks already held), and kept while the
//! session stays on the wall, so no card's face moves when another comes or
//! goes. Saved in `picks.json`, so a restart keeps every face. The wall, the
//! strip and the phone all read it from the snapshot. A fleet agent's pick is
//! kept by its name, so an agent relaunched on the other account keeps its
//! face; Heph's face (`HEPH`) is the orchestrator's alone (#172).

use crate::view::View;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

/// The voice keys every theme casts (src/fleet/themes/*.json; a test holds
/// them equal).
pub const CAST: [&str; 15] = [
    "af_alloy",
    "af_aoede",
    "af_bella",
    "af_heart",
    "af_kore",
    "af_nicole",
    "af_nova",
    "af_sarah",
    "am_fenrir",
    "am_michael",
    "am_puck",
    "bf_emma",
    "bf_isabella",
    "bm_fable",
    "bm_george",
];

pub const FILE: &str = "picks.json";

/// Hephaestus in the kourai theme (each theme's orchestrator): only the
/// session in the orchestrator's pane wears it, never a pick.
pub const HEPH: &str = "am_michael";

/// Where a session's pick is kept: by its fleet agent's name when it has
/// one, so a relaunch keeps the face, else by its session id.
fn key(v: &View) -> String {
    match &v.fleet_name {
        Some(name) => format!("agent:{name}"),
        None => v.session_id.clone(),
    }
}

fn cast(voice: Option<&str>) -> Option<&str> {
    voice.filter(|v| CAST.contains(v))
}

/// FNV-1a, as the wall's medallion hash.
fn hash(text: &str) -> u32 {
    text.bytes().fold(0x811c_9dc5, |h: u32, b| {
        (h ^ b as u32).wrapping_mul(0x0100_0193)
    })
}

#[derive(Debug, Default)]
pub struct Picks {
    held: BTreeMap<String, String>,
    path: Option<PathBuf>,
}

impl Picks {
    /// The picks saved in `dir`, or none. A file that does not parse is set
    /// aside as `picks.json.bad`, as the Ledger does, so the next save keeps it.
    pub fn load(dir: &Path) -> Self {
        let path = dir.join(FILE);
        let parsed = std::fs::read(&path)
            .ok()
            .map(|b| serde_json::from_slice::<BTreeMap<String, String>>(&b));
        if let Some(Err(_)) = parsed {
            let _ = std::fs::rename(&path, dir.join(format!("{FILE}.bad")));
        }
        let held = parsed
            .and_then(Result::ok)
            .map(|m| {
                m.into_iter()
                    .filter(|(_, v)| CAST.contains(&v.as_str()) && v != HEPH)
                    .collect()
            })
            .unwrap_or_default();
        Picks {
            held,
            path: Some(path),
        }
    }

    /// Give each session in `sessions` without a cast voice its pick, making
    /// one where it has none; drop the picks of sessions gone from the wall
    /// and of those that have a cast voice again. The orchestrator wears
    /// `HEPH`, and no one else is ever given it. Returns whether a pick
    /// changed (the caller saves).
    pub fn assign(&mut self, sessions: &mut [View]) -> bool {
        let before = self.held.clone();
        let workers = || sessions.iter().filter(|v| !v.orchestrator);
        let here: HashSet<String> = workers().map(key).collect();
        self.held.retain(|k, _| here.contains(k));
        for v in workers() {
            if cast(v.voice.as_deref()).is_some() {
                self.held.remove(&key(v));
            }
        }
        let mut shown: HashMap<&str, usize> = CAST.iter().map(|c| (*c, 0)).collect();
        for v in sessions.iter() {
            let face = if v.orchestrator {
                Some(HEPH)
            } else {
                cast(v.voice.as_deref()).or_else(|| self.held.get(&key(v)).map(String::as_str))
            };
            if let Some(f) = face.and_then(|f| CAST.iter().find(|c| **c == f)) {
                *shown.entry(f).or_default() += 1;
            }
        }
        // Oldest first, so when several need a pick at once the older chooses first.
        let mut need: Vec<&View> = workers()
            .filter(|v| cast(v.voice.as_deref()).is_none() && !self.held.contains_key(&key(v)))
            .collect();
        need.sort_by(|a, b| {
            a.started_at
                .unwrap_or(i64::MAX)
                .cmp(&b.started_at.unwrap_or(i64::MAX))
                .then_with(|| a.session_id.cmp(&b.session_id))
        });
        for v in need {
            // The voice it just gave up shows on another card; avoid it while any other is free.
            if self.held.contains_key(&key(v)) {
                continue; // another session of the same agent chose it this pass
            }
            let gave = cast(v.ceded.as_deref());
            let free: Vec<&str> = CAST
                .iter()
                .copied()
                .filter(|c| Some(*c) != gave && *c != HEPH)
                .collect();
            let least = free.iter().map(|c| shown[c]).min().unwrap_or(0);
            let pick = free
                .iter()
                .copied()
                .filter(|c| shown[c] == least)
                .max_by_key(|c| hash(&format!("{}:{c}", v.session_id)))
                .unwrap_or(CAST[0]);
            *shown.entry(pick).or_default() += 1;
            self.held.insert(key(v), pick.to_string());
        }
        for v in sessions.iter_mut() {
            v.pick = if v.orchestrator {
                (v.voice.as_deref() != Some(HEPH)).then(|| HEPH.to_string())
            } else {
                self.held.get(&key(v)).cloned()
            };
        }
        self.held != before
    }

    pub fn save(&self) -> std::io::Result<()> {
        match &self.path {
            Some(p) => crate::ledger::write_atomic(p, &serde_json::to_vec(&self.held)?),
            None => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::view::Status;

    fn card(id: &str, voice: Option<&str>, started: i64) -> View {
        View {
            session_id: id.into(),
            name: None,
            launch_dir: None,
            voice: voice.map(Into::into),
            status: Status::Working,
            reason: None,
            status_at: 0,
            active_at: 0,
            place: None,
            touched: vec![],
            prompt: None,
            reply: None,
            error: None,
            updated_at: 0,
            quiet_since: None,
            tmux: None,
            distro: None,
            claude: None,
            background: Default::default(),
            ledger: None,
            ledger_partial: false,
            wrapup: None,
            turn_at: None,
            asked_after_turn: false,
            remote_url: None,
            started_at: Some(started),
            ceded: None,
            pick: None,
            account: None,
            fleet_name: None,
            orchestrator: false,
            reply_at: None,
            marks: Default::default(),
        }
    }

    fn picks_of(p: &mut Picks, cards: &mut [View]) -> BTreeMap<String, String> {
        p.assign(cards);
        cards
            .iter()
            .map(|v| (v.session_id.clone(), v.pick.clone().unwrap_or_default()))
            .collect()
    }

    #[test]
    fn every_theme_casts_the_same_voices() {
        for theme in [
            include_str!("../../../src/fleet/themes/kourai.json"),
            include_str!("../../../src/fleet/themes/dicebear.json"),
            include_str!("../../../src/fleet/themes/professions.json"),
        ] {
            let t: serde_json::Value = serde_json::from_str(theme).unwrap();
            let mut keys: Vec<&str> = t["characters"]
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect();
            keys.sort();
            assert_eq!(keys, CAST.to_vec());
        }
    }

    #[test]
    fn a_voiceless_card_gets_a_face_no_card_shows() {
        let mut p = Picks::default();
        let mut cards = vec![
            card("a", Some("af_alloy"), 1),
            card("b", None, 2),
            card("c", Some("am_onyx"), 3),
        ];
        let got = picks_of(&mut p, &mut cards);
        assert!(got["a"].is_empty(), "its own voice, no pick");
        assert!(!got["b"].is_empty() && got["b"] != "af_alloy");
        assert!(
            !got["c"].is_empty() && got["c"] != "af_alloy" && got["c"] != got["b"],
            "outside the cast: a pick too"
        );
    }

    #[test]
    fn faces_never_move_as_cards_come_and_go() {
        for seed in 0..300 {
            let mut p = Picks::default();
            let ids: Vec<String> = (0..8).map(|i| format!("s{seed}-{i}")).collect();
            let mut cards: Vec<View> = ids
                .iter()
                .enumerate()
                .map(|(i, id)| card(id, None, i as i64))
                .collect();
            let first = picks_of(&mut p, &mut cards);
            // The oldest two leave, a newcomer arrives: the rest keep their faces.
            let mut later: Vec<View> = cards[2..].to_vec();
            later.push(card(&format!("s{seed}-new"), None, 99));
            let second = picks_of(&mut p, &mut later);
            for id in &ids[2..] {
                assert_eq!(first[id], second[id], "seed {seed}: {id} moved");
            }
        }
    }

    #[test]
    fn picks_stay_distinct_until_every_face_but_hephs_shows_then_the_least_shown_is_reused() {
        let mut p = Picks::default();
        let mut cards: Vec<View> = (0..14).map(|i| card(&format!("x{i}"), None, i)).collect();
        let got = picks_of(&mut p, &mut cards);
        let distinct: HashSet<&String> = got.values().collect();
        assert_eq!(distinct.len(), 14);
        assert!(
            !distinct.contains(&HEPH.to_string()),
            "Heph's face is never a pick"
        );
        cards.push(card("y", None, 20));
        let got = picks_of(&mut p, &mut cards);
        assert!(CAST.contains(&got["y"].as_str()) && got["y"] != HEPH);
    }

    fn heph(id: &str, voice: Option<&str>, started: i64) -> View {
        View {
            orchestrator: true,
            ..card(id, voice, started)
        }
    }

    fn agent(id: &str, name: &str, started: i64) -> View {
        View {
            fleet_name: Some(name.into()),
            ..card(id, None, started)
        }
    }

    #[test]
    fn the_orchestrator_wears_hephs_face_whatever_its_voice_and_no_worker_ever_does() {
        let mut p = Picks::default();
        let mut cards = vec![heph("h", None, 5), card("w", None, 1)];
        let got = picks_of(&mut p, &mut cards);
        assert_eq!(got["h"], HEPH, "no voice: Heph by its pick");
        assert_ne!(got["w"], HEPH);
        let mut cards = vec![heph("h", Some(HEPH), 5)];
        assert_eq!(
            picks_of(&mut p, &mut cards)["h"],
            "",
            "its own voice already is Heph's"
        );
        // Every other face taken: a worker still never gets Heph's.
        let mut cards: Vec<View> = (0..20).map(|i| card(&format!("z{i}"), None, i)).collect();
        cards.push(heph("h", None, 0));
        let got = picks_of(&mut p, &mut cards);
        assert!(
            got.iter().all(|(id, f)| (id == "h") == (f == HEPH)),
            "{got:?}"
        );
    }

    #[test]
    fn a_relaunched_agent_keeps_its_face() {
        let mut p = Picks::default();
        let mut cards = vec![agent("old", "techne-evals", 1), agent("k", "klepsydra", 2)];
        let first = picks_of(&mut p, &mut cards);
        // Moved to the other account: a new session of the same agent, the old one gone.
        let mut cards = vec![agent("k", "klepsydra", 2), agent("new", "techne-evals", 9)];
        let second = picks_of(&mut p, &mut cards);
        assert_eq!(first["old"], second["new"]);
        assert_eq!(first["k"], second["k"]);
        // Both on the wall at once while the move finishes: one face for the agent.
        let mut cards = vec![
            agent("old", "techne-evals", 1),
            agent("new", "techne-evals", 9),
        ];
        let both = picks_of(&mut p, &mut cards);
        assert_eq!(both["old"], both["new"]);
        // Two sessions of one agent that both need a pick in one pass share it.
        let mut fresh = Picks::default();
        let mut cards = vec![agent("a1", "sphragis", 1), agent("a2", "sphragis", 2)];
        let got = picks_of(&mut fresh, &mut cards);
        assert_eq!(got["a1"], got["a2"]);
        assert_eq!(fresh.held.len(), 1);
    }

    #[test]
    fn a_saved_pick_of_hephs_face_is_dropped_on_load() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("klepsydra-picks-heph-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join(FILE),
            format!("{{\"agent:techne-evals\": \"{HEPH}\", \"w\": \"af_nova\"}}"),
        )
        .unwrap();
        let p = Picks::load(&dir);
        assert_eq!(p.held.len(), 1);
        assert_eq!(p.held.get("w").map(String::as_str), Some("af_nova"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_card_that_gave_up_its_voice_avoids_it_and_one_that_regains_it_drops_its_pick() {
        let mut p = Picks::default();
        let mut gave = card("a", None, 1);
        gave.ceded = Some("bf_emma".into());
        let mut cards = vec![gave, card("n", Some("bf_emma"), 9)];
        let got = picks_of(&mut p, &mut cards);
        assert!(!got["a"].is_empty() && got["a"] != "bf_emma");
        let mut back = vec![card("a", Some("bf_emma"), 1)];
        p.assign(&mut back);
        assert_eq!(back[0].pick, None);
        assert!(
            p.held.is_empty(),
            "the pick is dropped once its own voice is back"
        );
    }

    #[test]
    fn picks_survive_a_restart() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("klepsydra-picks-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let mut p = Picks::load(&dir);
        let mut cards = vec![card("a", None, 1), card("b", None, 2)];
        let first = picks_of(&mut p, &mut cards);
        p.save().unwrap();
        let mut again = Picks::load(&dir);
        let mut cards = vec![card("b", None, 2), card("c", None, 3)];
        let second = picks_of(&mut again, &mut cards);
        assert_eq!(first["b"], second["b"]);
        std::fs::write(dir.join(FILE), b"{\"z\": \"not_a_voice\"").unwrap();
        assert!(
            Picks::load(&dir).held.is_empty(),
            "a corrupt file reads as none"
        );
        assert!(
            dir.join(format!("{FILE}.bad")).exists(),
            "and is set aside, not overwritten"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
