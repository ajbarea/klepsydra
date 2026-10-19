//! Which Windows Terminal tab is a session's. Claude Code titles the tab with
//! the session's name, after a status glyph, so a tab is the session's when
//! its title contains the name; anything but exactly one such tab is refused.

#[derive(Debug, PartialEq, Eq)]
pub enum TabMatch {
    None,
    One(usize),
    Many(usize),
}

/// The tab, among `titles`, whose title contains `name`.
pub fn match_tab(name: &str, titles: &[String]) -> TabMatch {
    let name = name.trim();
    if name.is_empty() {
        return TabMatch::None;
    }
    let hits: Vec<usize> = (0..titles.len())
        .filter(|&i| titles[i].contains(name))
        .collect();
    match hits.as_slice() {
        [] => TabMatch::None,
        [one] => TabMatch::One(*one),
        many => TabMatch::Many(many.len()),
    }
}

pub fn no_tab(name: &str) -> String {
    format!("No Windows Terminal tab is titled \u{201c}{name}\u{201d}.")
}

pub fn many_tabs(name: &str, n: usize) -> String {
    format!("{n} Windows Terminal tabs contain \u{201c}{name}\u{201d}. Rename the session to jump to it.")
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
    fn a_name_inside_two_titles_is_refused_not_guessed() {
        let t = titles(&["\u{2733} klepsydra", "\u{2733} klepsydra-e2"]);
        assert_eq!(match_tab("klepsydra", &t), TabMatch::Many(2));
        let t = titles(&["Fix tests", "Fix tests in CI"]);
        assert_eq!(match_tab("Fix tests", &t), TabMatch::Many(2));
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
            "No Windows Terminal tab is titled \u{201c}Plan\u{201d}."
        );
        assert_eq!(
            many_tabs("Plan", 2),
            "2 Windows Terminal tabs contain \u{201c}Plan\u{201d}. Rename the session to jump to it."
        );
    }
}
