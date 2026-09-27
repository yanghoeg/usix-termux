// MARKDOWN — 완성된 assistant 텍스트를 ratatui Line 으로 렌더한다.
// usix chat_render 의 비주얼 규약(USIX 팔레트)을 폰 규모로 축약: 스트리밍 상태머신 대신
// 블록 단위. syntect 문법 하이라이팅은 제외(폰 빌드 경량화) — 코드블록은 원본과 같은
// `┃ ` gutter + 언어 라벨(boxless) 스타일로만 그린다.
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

// usix ColorTheme::USIX 팔레트. 본문은 색을 안 칠하고 단말 기본 전경(Reset)에 위임한다.
const MUTED: Color = Color::Rgb(175, 175, 175); // gutter·라벨·HR·리스트 마커
const QUOTE: Color = Color::Rgb(215, 215, 215); // 인용구 본문
const ACCENT: Color = Color::Rgb(215, 175, 255); // heading 1 (lilac)
const CODE: Color = Color::Rgb(135, 215, 215); // 인라인 코드·heading 3 (cyan)
const LINK: Color = Color::Rgb(135, 175, 255); // 링크

/// heading 레벨별 (색, bold). 1→lilac·bold, 2→본문·bold, 3→cyan, 4→quote, 5·6→muted.
fn heading_style(level: u8) -> Style {
    let color = match level {
        1 => ACCENT,
        2 => Color::Reset,
        3 => CODE,
        4 => QUOTE,
        _ => MUTED,
    };
    let mut s = Style::default().fg(color);
    if matches!(level, 1 | 2) {
        s = s.add_modifier(Modifier::BOLD);
    }
    s
}

/// 코드 펜스 상태를 줄 간에 유지하는 스트리밍 렌더러 — 토큰이 완성한 한 줄씩 그린다.
/// 닫는 펜스는 출력 없음(None). 그 외엔 항상 Line 하나.
pub struct Stream {
    in_code: bool,
}

impl Stream {
    pub fn new() -> Self {
        Self { in_code: false }
    }

    pub fn feed_line(&mut self, raw: &str) -> Option<Line<'static>> {
        let trimmed = raw.trim_start();

        // 트리플-백틱 코드 펜스 — 여닫이 토글.
        if let Some(rest) = trimmed.strip_prefix("```") {
            if self.in_code {
                self.in_code = false;
                return None;
            }
            self.in_code = true;
            let lang = rest.trim();
            let label = if lang.is_empty() { "code" } else { lang };
            return Some(Line::from(Span::styled(
                label.to_string(),
                Style::default().fg(MUTED),
            )));
        }
        if self.in_code {
            return Some(Line::from(vec![
                Span::styled("┃ ", Style::default().fg(MUTED)),
                Span::raw(raw.to_string()),
            ]));
        }
        Some(render_block_line(raw, trimmed))
    }
}

/// markdown-lite 텍스트 → 렌더된 라인들.
pub fn render(text: &str) -> Vec<Line<'static>> {
    let mut s = Stream::new();
    let mut out = Vec::new();
    for raw in text.split('\n') {
        if let Some(line) = s.feed_line(raw) {
            out.push(line);
        }
    }
    out
}

/// 코드 블록 밖의 한 줄을 블록 문법으로 해석해 Line 하나로.
fn render_block_line(raw: &str, trimmed: &str) -> Line<'static> {
    if trimmed.is_empty() {
        return Line::from(String::new());
    }

    // 수평선 --- / *** / ___
    if is_hr(trimmed) {
        return Line::from(Span::styled("─".repeat(24), Style::default().fg(MUTED)));
    }

    // heading #..######
    if let Some((level, content)) = parse_heading(trimmed) {
        return Line::from(inline(content, heading_style(level)));
    }

    // blockquote > ...
    if let Some(content) = trimmed.strip_prefix('>') {
        let content = content.strip_prefix(' ').unwrap_or(content);
        let mut spans = vec![Span::styled("▏ ", Style::default().fg(QUOTE))];
        spans.extend(inline(content, Style::default().fg(QUOTE)));
        return Line::from(spans);
    }

    // 리스트 / 체크박스 (중첩 들여쓰기 보존)
    if let Some(line) = parse_list(raw) {
        return line;
    }

    // 일반 문단
    Line::from(inline(trimmed, Style::default()))
}

fn is_hr(s: &str) -> bool {
    let s = s.trim();
    (s.len() >= 3)
        && (s.chars().all(|c| c == '-')
            || s.chars().all(|c| c == '*')
            || s.chars().all(|c| c == '_'))
}

fn parse_heading(s: &str) -> Option<(u8, &str)> {
    let hashes = s.chars().take_while(|&c| c == '#').count();
    if (1..=6).contains(&hashes) && s.as_bytes().get(hashes) == Some(&b' ') {
        Some((hashes as u8, s[hashes + 1..].trim_start()))
    } else {
        None
    }
}

/// 불릿(`-`/`*`/`+`)·순서(`1.`) 리스트와 체크박스. 들여쓰기는 그대로 유지한다.
fn parse_list(raw: &str) -> Option<Line<'static>> {
    let indent = raw.len() - raw.trim_start().len();
    let body = raw.trim_start();

    // 마커 추출: 불릿 or 순서.
    let (marker, rest) = if let Some(r) = body
        .strip_prefix("- ")
        .or_else(|| body.strip_prefix("* "))
        .or_else(|| body.strip_prefix("+ "))
    {
        ("•".to_string(), r)
    } else if let Some((num, r)) = parse_ordered(body) {
        (format!("{num}."), r)
    } else {
        return None;
    };

    let mut spans = vec![Span::raw(" ".repeat(indent))];

    // 체크박스: 마커 직후 `[ ]`/`[x]`.
    if let Some(r) = rest.strip_prefix("[ ] ") {
        spans.push(Span::styled("☐ ".to_string(), Style::default().fg(MUTED)));
        spans.extend(inline(r, Style::default()));
    } else if let Some(r) = rest
        .strip_prefix("[x] ")
        .or_else(|| rest.strip_prefix("[X] "))
    {
        spans.push(Span::styled("☑ ".to_string(), Style::default().fg(CODE)));
        spans.extend(inline(r, Style::default()));
    } else {
        spans.push(Span::styled(
            format!("{marker} "),
            Style::default().fg(MUTED),
        ));
        spans.extend(inline(rest, Style::default()));
    }

    Some(Line::from(spans))
}

/// `12. rest` → (12, "rest"). 종료자는 `.` 또는 `)`.
fn parse_ordered(s: &str) -> Option<(&str, &str)> {
    let digits = s.chars().take_while(|c| c.is_ascii_digit()).count();
    if digits == 0 {
        return None;
    }
    let after = &s[digits..];
    let rest = after
        .strip_prefix(". ")
        .or_else(|| after.strip_prefix(") "))?;
    Some((&s[..digits], rest))
}

fn has_closing_delimiter(chars: &[char], start: usize, marker: char, width: usize) -> bool {
    let mut i = start + width;
    while i + width <= chars.len() {
        if chars[i] == marker
            && (width == 1 || chars[i + 1] == marker)
            && delimiter_can_close(chars, i)
        {
            return true;
        }
        i += 1;
    }
    false
}

fn delimiter_can_open(chars: &[char], start: usize, width: usize) -> bool {
    chars.get(start + width).is_some_and(|c| !c.is_whitespace())
}

fn delimiter_can_close(chars: &[char], start: usize) -> bool {
    start
        .checked_sub(1)
        .and_then(|i| chars.get(i))
        .is_some_and(|c| !c.is_whitespace())
}

fn underscore_can_emphasize(chars: &[char], start: usize, width: usize) -> bool {
    let previous = start.checked_sub(1).and_then(|i| chars.get(i));
    let next = chars.get(start + width);
    !(previous.is_some_and(|c| c.is_alphanumeric()) && next.is_some_and(|c| c.is_alphanumeric()))
}

/// 인라인 토큰 → Span 들. `**bold**`, `*italic*`, `~~strike~~`, `` `code` ``, `[t](url)`.
fn inline(text: &str, base: Style) -> Vec<Span<'static>> {
    let chars: Vec<char> = text.chars().collect();
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut buf = String::new();
    let mut bold = false;
    let mut italic = false;
    let mut strike = false;
    let mut i = 0;

    while i < chars.len() {
        let c = chars[i];

        // 인라인 코드 — 다음 백틱까지, 중첩 없음.
        if c == '`' {
            if let Some(close) = chars[i + 1..].iter().position(|&x| x == '`') {
                flush(&mut spans, &mut buf, base, bold, italic, strike);
                let code: String = chars[i + 1..i + 1 + close].iter().collect();
                spans.push(Span::styled(code, Style::default().fg(CODE)));
                i += close + 2;
                continue;
            }
        }

        // 링크 [text](url) — url 은 숨기고 text 만 링크색·밑줄.
        if c == '[' {
            if let Some((label, consumed)) = parse_link(&chars[i..]) {
                flush(&mut spans, &mut buf, base, bold, italic, strike);
                spans.push(Span::styled(
                    label,
                    Style::default().fg(LINK).add_modifier(Modifier::UNDERLINED),
                ));
                i += consumed;
                continue;
            }
        }

        // **bold** / __bold__
        if (c == '*' || c == '_') && chars.get(i + 1) == Some(&c) {
            let can_emphasize = (c == '*' || underscore_can_emphasize(&chars, i, 2))
                && delimiter_can_open(&chars, i, 2);
            if bold || (can_emphasize && has_closing_delimiter(&chars, i, c, 2)) {
                flush(&mut spans, &mut buf, base, bold, italic, strike);
                bold = !bold;
                i += 2;
                continue;
            }
            buf.push(c);
            buf.push(c);
            i += 2;
            continue;
        }
        // *italic* / _italic_
        if c == '*' || c == '_' {
            let can_emphasize = (c == '*' || underscore_can_emphasize(&chars, i, 1))
                && delimiter_can_open(&chars, i, 1);
            if italic || (can_emphasize && has_closing_delimiter(&chars, i, c, 1)) {
                flush(&mut spans, &mut buf, base, bold, italic, strike);
                italic = !italic;
                i += 1;
                continue;
            }
        }
        // ~~strike~~
        if c == '~'
            && chars.get(i + 1) == Some(&'~')
            && (strike || has_closing_delimiter(&chars, i, '~', 2))
        {
            flush(&mut spans, &mut buf, base, bold, italic, strike);
            strike = !strike;
            i += 2;
            continue;
        }

        buf.push(c);
        i += 1;
    }

    flush(&mut spans, &mut buf, base, bold, italic, strike);
    if spans.is_empty() {
        spans.push(Span::styled(String::new(), base));
    }
    spans
}

fn flush(
    spans: &mut Vec<Span<'static>>,
    buf: &mut String,
    base: Style,
    bold: bool,
    italic: bool,
    strike: bool,
) {
    if buf.is_empty() {
        return;
    }
    let mut st = base;
    if bold {
        st = st.add_modifier(Modifier::BOLD);
    }
    if italic {
        st = st.add_modifier(Modifier::ITALIC);
    }
    if strike {
        st = st.add_modifier(Modifier::CROSSED_OUT);
    }
    spans.push(Span::styled(std::mem::take(buf), st));
}

/// `[text](url)` 매칭 — (label, 소비한 char 수). 형식이 아니면 None.
fn parse_link(chars: &[char]) -> Option<(String, usize)> {
    // chars[0] == '['
    let close = chars.iter().position(|&c| c == ']')?;
    if chars.get(close + 1) != Some(&'(') {
        return None;
    }
    let paren = chars[close + 2..].iter().position(|&c| c == ')')?;
    let label: String = chars[1..close].iter().collect();
    let consumed = close + 2 + paren + 1;
    Some((label, consumed))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(line: &Line) -> String {
        line.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    #[test]
    fn heading_gets_accent_bold() {
        let out = render("# 제목");
        assert_eq!(plain(&out[0]), "제목");
        assert_eq!(out[0].spans[0].style.fg, Some(ACCENT));
        assert!(out[0].spans[0].style.add_modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn code_fence_adds_gutter_and_label() {
        let out = render("```rust\nlet x = 1;\n```");
        assert_eq!(plain(&out[0]), "rust"); // 언어 라벨
        assert_eq!(out[1].spans[0].content.as_ref(), "┃ ");
        assert_eq!(out[1].spans[1].content.as_ref(), "let x = 1;");
    }

    #[test]
    fn inline_code_and_bold() {
        let out = render("`code` and **bold**");
        let styles: Vec<_> = out[0].spans.iter().map(|s| s.style.fg).collect();
        assert!(styles.contains(&Some(CODE)));
        assert!(
            out[0]
                .spans
                .iter()
                .any(|s| s.content.as_ref() == "bold"
                    && s.style.add_modifier.contains(Modifier::BOLD))
        );
    }

    #[test]
    fn bullet_and_checkbox() {
        let out = render("- item\n- [x] done");
        assert_eq!(out[0].spans[1].content.as_ref(), "• ");
        assert_eq!(out[1].spans[1].content.as_ref(), "☑ ");
    }

    #[test]
    fn link_hides_url() {
        let out = render("see [docs](http://x)");
        assert!(out[0]
            .spans
            .iter()
            .any(|s| s.content.as_ref() == "docs" && s.style.fg == Some(LINK)));
        assert!(!plain(&out[0]).contains("http"));
    }

    #[test]
    fn preserves_literal_markers() {
        let out = render("foo_bar_baz and 2 * 3 and **broken");
        assert_eq!(plain(&out[0]), "foo_bar_baz and 2 * 3 and **broken");
    }
}
