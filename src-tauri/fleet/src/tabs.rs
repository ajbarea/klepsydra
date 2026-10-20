//! Which Windows Terminal tab is a session's. Claude Code titles the tab with
//! the session's name after a status glyph, so a tab is the session's when its
//! title equals the name after the glyph. The fleet's own tab is titled
//! exactly, so it is found by its exact title. Anything but exactly one such
//! tab is refused.

#[derive(Debug, PartialEq, Eq)]
pub enum TabMatch {
    None,
    One(usize),
    Many(usize),
}

/// Drops a leading run of non-alphanumerics (the status glyph and its space)
/// and trailing whitespace.
fn bare(text: &str) -> &str {
    text.trim_start_matches(|c: char| !c.is_alphanumeric())
        .trim_end()
}

/// The tab, among `titles`, whose title equals `name` after its glyph.
pub fn match_tab(name: &str, titles: &[String]) -> TabMatch {
    let name = bare(name.trim());
    if name.is_empty() {
        return TabMatch::None;
    }
    one_of(titles, |t| bare(t) == name)
}

/// The tab whose title is exactly `title`.
pub fn match_exact(title: &str, titles: &[String]) -> TabMatch {
    one_of(titles, |t| t == title)
}

fn one_of(titles: &[String], hit: impl Fn(&str) -> bool) -> TabMatch {
    let hits: Vec<usize> = (0..titles.len()).filter(|&i| hit(&titles[i])).collect();
    match hits.as_slice() {
        [] => TabMatch::None,
        [one] => TabMatch::One(*one),
        many => TabMatch::Many(many.len()),
    }
}

/// Which tab to find.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lookup<'a> {
    /// A session's tab, by its name after Claude Code's status glyph.
    Session(&'a str),
    /// The fleet's tab: `--suppressApplicationTitle` keeps its title exact, so
    /// a hand-opened session with the same name after a glyph is not it.
    Exact(&'a str),
}

impl Lookup<'_> {
    /// Refused before any tab is listed: a session with no name.
    pub fn check(self) -> Result<(), TabError> {
        match self {
            Lookup::Session(name) if name.trim().is_empty() => Err(TabError::NoName),
            _ => Ok(()),
        }
    }
}

/// Why no tab was picked. `NoName` and `NoMatch` mean no tab matched; the
/// others mean one may exist but cannot be chosen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TabError {
    /// The session has no name to look for.
    NoName,
    /// No tab has the title.
    NoMatch(String),
    /// More than one session tab has it.
    Many(String, usize),
    /// More than one tab has the fixed title; none of them can be renamed away.
    ManyFixed(String, usize),
    /// A Windows Terminal window hides its tabs, so a match may be among them.
    Hidden,
}

impl std::fmt::Display for TabError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TabError::NoName => f.write_str("This session has no name yet."),
            TabError::NoMatch(name) => f.write_str(&no_tab(name)),
            TabError::Many(name, n) => f.write_str(&many_tabs(name, *n)),
            TabError::ManyFixed(title, n) => write!(
                f,
                "{n} Windows Terminal tabs are titled \u{201c}{title}\u{201d}. Close all but one."
            ),
            TabError::Hidden => f.write_str(HIDDEN_TABS),
        }
    }
}

/// The index of the one tab to jump to, or why not. `tabs_hidden` is set
/// when a Windows Terminal window exposed no tabs (full screen or focus mode),
/// so a missing match may be a hidden tab.
pub fn pick(lookup: Lookup<'_>, titles: &[String], tabs_hidden: bool) -> Result<usize, TabError> {
    lookup.check()?;
    let (name, found) = match lookup {
        Lookup::Session(name) => (name.trim(), match_tab(name, titles)),
        Lookup::Exact(title) => (title, match_exact(title, titles)),
    };
    match found {
        TabMatch::One(i) => Ok(i),
        TabMatch::Many(n) if matches!(lookup, Lookup::Exact(_)) => {
            Err(TabError::ManyFixed(name.into(), n))
        }
        TabMatch::Many(n) => Err(TabError::Many(name.into(), n)),
        TabMatch::None if tabs_hidden => Err(TabError::Hidden),
        TabMatch::None => Err(TabError::NoMatch(name.into())),
    }
}

pub const HIDDEN_TABS: &str =
    "Windows Terminal is hiding its tabs (full screen or focus mode). Show the tabs to jump.";

/// Claude Code titles a tab with the session's name, but a tab renamed in
/// Windows Terminal keeps the name it was given, so say what to do instead.
pub fn no_tab(name: &str) -> String {
    format!(
        "No Windows Terminal tab is titled \u{201c}{name}\u{201d}. A tab renamed in Windows Terminal keeps that name; rename the tab to exactly the session's name, or start the session from + New session."
    )
}

pub fn many_tabs(name: &str, n: usize) -> String {
    format!("{n} Windows Terminal tabs are titled \u{201c}{name}\u{201d}. Rename the session to jump to it.")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titles(t: &[&str]) -> Vec<String> {
        t.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_tab_titled_with_the_name_after_a_glyph() {
        let t = titles(&[
            "Klepsydra",
            "\u{2733} Plan the fleet visualizer",
            "FedAgents",
        ]);
        assert_eq!(match_tab("Plan the fleet visualizer", &t), TabMatch::One(1));
    }

    #[test]
    fn the_same_name_with_and_without_the_glyph_is_refused() {
        let t = titles(&["\u{2733} klepsydra", "klepsydra"]);
        assert_eq!(match_tab("klepsydra", &t), TabMatch::Many(2));
    }

    #[test]
    fn a_longer_title_is_another_session_not_a_match() {
        let t = titles(&["klepsydra", "klepsydra-e2"]);
        assert_eq!(match_tab("klepsydra", &t), TabMatch::One(0));
        let t = titles(&["Fix tests in CI"]);
        assert_eq!(
            match_tab("Fix tests", &t),
            TabMatch::None,
            "a renamed tab whose neighbour merely contains the name is never taken"
        );
    }

    #[test]
    fn the_name_is_trimmed_and_blank_matches_nothing() {
        let t = titles(&["\u{2733} Plan"]);
        assert_eq!(match_tab(" Plan ", &t), TabMatch::One(0));
        assert_eq!(match_tab("  ", &titles(&["a  b"])), TabMatch::None);
    }

    #[test]
    fn two_sessions_with_one_title_are_refused() {
        let t = titles(&["\u{2733} Plan", "\u{2733} Plan"]);
        assert_eq!(match_tab("Plan", &t), TabMatch::Many(2));
    }

    #[test]
    fn no_tab_or_no_name_matches_nothing() {
        let t = titles(&["Klepsydra"]);
        assert_eq!(match_tab("FedAgents", &t), TabMatch::None);
        assert_eq!(
            match_tab("klepsydra", &t),
            TabMatch::None,
            "titles are matched as written"
        );
        assert_eq!(match_tab("  ", &t), TabMatch::None);
        assert_eq!(match_tab("x", &[]), TabMatch::None);
    }

    #[test]
    fn the_messages_name_the_session() {
        assert_eq!(
            no_tab("Plan"),
            "No Windows Terminal tab is titled \u{201c}Plan\u{201d}. A tab renamed in Windows Terminal keeps that name; rename the tab to exactly the session's name, or start the session from + New session."
        );
        assert_eq!(
            many_tabs("Plan", 2),
            "2 Windows Terminal tabs are titled \u{201c}Plan\u{201d}. Rename the session to jump to it."
        );
    }

    #[test]
    fn the_fleet_tab_is_found_by_its_exact_title_alone() {
        let fleet = Lookup::Exact("klepsydra sessions");
        assert_eq!(pick(fleet, &titles(&["klepsydra sessions"]), false), Ok(0));
        assert!(pick(fleet, &titles(&["\u{2733} klepsydra sessions"]), false).is_err());
        assert!(pick(fleet, &titles(&["klepsydra sessions "]), false).is_err());
        assert_eq!(
            pick(
                fleet,
                &titles(&["\u{2733} klepsydra sessions", "klepsydra sessions"]),
                false
            ),
            Ok(1)
        );
        assert_eq!(
            match_exact(
                "klepsydra sessions",
                &titles(&["klepsydra sessions", "klepsydra sessions"])
            ),
            TabMatch::Many(2)
        );
    }

    #[test]
    fn pick_says_why_it_will_not_jump() {
        let t = titles(&["Klepsydra"]);
        let plan = Lookup::Session("Plan");
        assert_eq!(pick(Lookup::Session(" Klepsydra "), &t, true), Ok(0));
        assert_eq!(pick(plan, &t, false), Err(TabError::NoMatch("Plan".into())));
        assert_eq!(pick(plan, &t, true), Err(TabError::Hidden));
        assert_eq!(pick(plan, &[], true), Err(TabError::Hidden));
        let t = titles(&["Plan", "\u{2733} Plan"]);
        assert_eq!(pick(plan, &t, true), Err(TabError::Many("Plan".into(), 2)));
        assert_eq!(pick(Lookup::Session("  "), &t, true), Err(TabError::NoName));
        assert_eq!(
            pick(Lookup::Exact("x"), &t, false),
            Err(TabError::NoMatch("x".into()))
        );
    }

    #[test]
    fn two_fleet_tabs_say_close_all_but_one() {
        let t = titles(&["klepsydra sessions", "pwsh", "klepsydra sessions"]);
        let e = pick(Lookup::Exact("klepsydra sessions"), &t, false).unwrap_err();
        assert_eq!(
            e.to_string(),
            "2 Windows Terminal tabs are titled \u{201c}klepsydra sessions\u{201d}. Close all but one."
        );
    }

    #[test]
    fn each_error_reads_as_a_sentence() {
        assert_eq!(TabError::NoMatch("Plan".into()).to_string(), no_tab("Plan"));
        assert_eq!(
            TabError::Many("Plan".into(), 2).to_string(),
            many_tabs("Plan", 2)
        );
        assert_eq!(TabError::Hidden.to_string(), HIDDEN_TABS);
        assert_eq!(
            TabError::NoName.to_string(),
            "This session has no name yet."
        );
        assert_eq!(Lookup::Session(" ").check(), Err(TabError::NoName));
        assert_eq!(Lookup::Exact("klepsydra sessions").check(), Ok(()));
    }
}
