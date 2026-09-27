//! Filesystem skill source; parsing and selection remain in the domain.
use super::host::state_dir;
use crate::domain::skills::{parse, Skill};
use crate::ports::BundledSkill;
use anyhow::Result;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

pub fn skills_dir() -> PathBuf {
    state_dir().join("skills")
}

pub fn load(bundled: &[BundledSkill]) -> Vec<Skill> {
    load_from(&skills_dir(), bundled)
}

fn load_from(dir: &Path, bundled: &[BundledSkill]) -> Vec<Skill> {
    let mut skills = Vec::new();
    if let Ok(entries) = fs::read_dir(dir) {
        let mut paths: Vec<_> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "md"))
            .collect();
        paths.sort();
        for path in paths {
            if let Ok(text) = fs::read_to_string(path) {
                if let Some(skill) = parse_installed(&text, bundled) {
                    skills.push(skill);
                    if skills.len() >= 8 {
                        break;
                    }
                }
            }
        }
    }
    with_builtins(skills, bundled)
}

fn parse_installed(text: &str, bundled: &[BundledSkill]) -> Option<Skill> {
    let current = bundled
        .iter()
        .find(|s| s.legacy == Some(text))
        .map_or(text, |s| s.text);
    parse(current)
}

fn with_builtins(mut skills: Vec<Skill>, bundled: &[BundledSkill]) -> Vec<Skill> {
    for source in bundled {
        let skill = parse(source.text).expect("bundled skill has frontmatter");
        if skills.len() < 8 && !skills.iter().any(|s| s.name == skill.name) {
            skills.push(skill);
        }
    }
    skills
}

pub fn seed(bundled: &[BundledSkill]) -> Result<()> {
    let dir = skills_dir();
    fs::create_dir_all(&dir)?;
    for skill in bundled {
        let path = dir.join(skill.filename);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(mut file) => {
                file.write_all(skill.text.as_bytes())?;
                println!("seeded skill → {}", path.display());
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::host::{linux::Linux, termux::Termux};
    use crate::ports::Host;

    #[test]
    fn each_host_gets_only_its_builtins_and_preserves_custom_skills() {
        let linux = with_builtins(Vec::new(), Linux.bundled_skills());
        assert_eq!(
            linux.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
            ["local_work"]
        );
        let termux = with_builtins(Vec::new(), Termux.bundled_skills());
        for name in ["local_work", "mail", "kakao_read", "sms_reply"] {
            assert!(termux.iter().any(|s| s.name == name), "{name}");
        }
        let custom = Skill {
            name: "mail".into(),
            description: "custom".into(),
            body: "keep me".into(),
        };
        let skills = with_builtins(vec![custom], Termux.bundled_skills());
        assert_eq!(skills.iter().filter(|s| s.name == "mail").count(), 1);
        assert_eq!(
            skills.iter().find(|s| s.name == "mail").unwrap().body,
            "keep me"
        );
    }

    #[test]
    fn only_exact_legacy_stock_skill_is_upgraded() {
        let bundled = Termux.bundled_skills();
        let legacy = bundled.iter().find_map(|s| s.legacy).unwrap();
        let updated = parse_installed(legacy, bundled).unwrap();
        assert!(updated.body.contains("ui_scroll"));
        let edited = format!("{legacy}\ncustom instruction");
        assert!(parse_installed(&edited, bundled)
            .unwrap()
            .body
            .contains("custom instruction"));
    }
}
