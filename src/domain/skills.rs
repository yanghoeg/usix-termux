// DOMAIN — 마크다운 스킬. 재빌드 없이 ~/.usix/skills/*.md 로 절차형 능력을 추가한다.
// 스킬은 새 도구가 아니라, 기존 도구를 엮는 지침 → 시스템 프롬프트에 얹는다.
use std::fs;
use std::path::PathBuf;

// 소형 로컬 모델 컨텍스트 보호 — 한 번에 활성화되는 스킬 상한.
const MAX_ACTIVE: usize = 8;

pub struct Skill {
    pub name: String,
    pub description: String,
    pub body: String,
}

/// 스킬 디렉터리 — ~/.usix/skills.
pub fn skills_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".usix/skills")
}

/// ~/.usix/skills/*.md 로드(frontmatter name/description + 본문). 최대 MAX_ACTIVE.
pub fn load() -> Vec<Skill> {
    let mut out = Vec::new();
    let Ok(entries) = fs::read_dir(skills_dir()) else {
        return out;
    };
    let mut paths: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "md"))
        .collect();
    paths.sort();
    for p in paths {
        if let Ok(text) = fs::read_to_string(&p) {
            if let Some(s) = parse(&text) {
                out.push(s);
                if out.len() >= MAX_ACTIVE {
                    break;
                }
            }
        }
    }
    out
}

/// 얇은 frontmatter 파서 — 첫 `---` 블록의 name/description + 이후 본문.
fn parse(text: &str) -> Option<Skill> {
    let rest = text.strip_prefix("---")?;
    let end = rest.find("\n---")?;
    let (fm, after) = rest.split_at(end);
    let body = after
        .trim_start_matches('\n')
        .trim_start_matches("---")
        .trim()
        .to_string();
    let mut name = String::new();
    let mut description = String::new();
    for line in fm.lines() {
        if let Some(v) = line.strip_prefix("name:") {
            name = v.trim().to_string();
        } else if let Some(v) = line.strip_prefix("description:") {
            description = v.trim().to_string();
        }
    }
    if name.is_empty() {
        return None;
    }
    Some(Skill {
        name,
        description,
        body,
    })
}

/// 2글자 이상 알파넘 토큰으로 쪼갠다.
fn tokenize(s: &str) -> Vec<String> {
    s.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| t.chars().count() >= 2)
        .map(|t| t.to_string())
        .collect()
}

/// 요청과 관련된 스킬만 고른다 — 소형 모델은 무관한 스킬 지침이 끼면 후속 절차를
/// 놓친다(빈 응답). 요청 토큰과 스킬 토큰이 어느 방향으로든 포함되면 채택한다. 양방향
/// 비교라 한국어 조사("카톡에"→"카톡")로 어미가 붙어도 스킬 키워드에 걸린다.
pub fn select<'a>(skills: &'a [Skill], query: &str) -> Vec<&'a Skill> {
    let q_tokens = tokenize(query);
    let mut out = Vec::new();
    for sk in skills {
        let hay = format!("{} {} {}", sk.name, sk.description, sk.body);
        let s_tokens = tokenize(&hay);
        let hit = q_tokens.iter().any(|qt| {
            s_tokens
                .iter()
                .any(|st| st.contains(qt.as_str()) || qt.contains(st.as_str()))
        });
        if hit {
            out.push(sk);
            if out.len() >= MAX_ACTIVE {
                break;
            }
        }
    }
    out
}

/// 로드된 스킬을 시스템 프롬프트에 덧붙일 지침 블록으로 합친다. 없으면 빈 문자열.
pub fn guidance(skills: &[&Skill]) -> String {
    if skills.is_empty() {
        return String::new();
    }
    let mut s =
        String::from("\n\n# 사용 가능한 스킬(절차)\n관련 요청이 오면 아래 절차를 따른다.\n");
    for sk in skills {
        s.push_str(&format!(
            "\n## {} — {}\n{}\n",
            sk.name, sk.description, sk.body
        ));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_frontmatter_and_body() {
        let md = "---\nname: sms_reply\ndescription: 요약·답장\n---\n\n1. sms_list 호출\n2. 요약";
        let s = parse(md).expect("parse");
        assert_eq!(s.name, "sms_reply");
        assert_eq!(s.description, "요약·답장");
        assert!(s.body.starts_with("1. sms_list"));
        assert!(!s.body.contains("---"));
    }

    #[test]
    fn no_name_is_rejected() {
        assert!(parse("---\ndescription: x\n---\nbody").is_none());
        assert!(parse("no frontmatter").is_none());
    }

    #[test]
    fn guidance_empty_when_no_skills() {
        assert_eq!(guidance(&[]), "");
    }

    #[test]
    fn select_picks_only_relevant() {
        let skills = vec![
            Skill {
                name: "sms_reply".into(),
                description: "문자 요약·답장".into(),
                body: "sms_list 후 요약".into(),
            },
            Skill {
                name: "kakao_notify".into(),
                description: "카톡 알림 응답".into(),
                body: "notif_list 사용".into(),
            },
        ];
        let hit = select(&skills, "카톡 알림 확인해줘");
        assert_eq!(hit.len(), 1);
        assert_eq!(hit[0].name, "kakao_notify");

        // 무관한 요청이면 아무 스킬도 얹지 않는다.
        assert!(select(&skills, "배터리 몇 퍼야").is_empty());

        // 조사가 붙어 "카톡에"로 와도 스킬 키워드 "카톡"에 걸려야 한다.
        let hit = select(&skills, "카톡에 뭐보여?");
        assert_eq!(hit.len(), 1);
        assert_eq!(hit[0].name, "kakao_notify");
    }
}
