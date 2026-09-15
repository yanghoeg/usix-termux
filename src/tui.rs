// TUI — usix chat_tui 모델 이식. 편집할 때만 인라인 뷰포트(ratatui)를 잡고, 대화록(사용자
// 제출 박스·어시스턴트 답변·시스템 메시지)은 뷰포트를 restore 한 뒤 일반 stdout 으로
// 직접 찍는다. 이렇게 해야 단말 고유 폭으로 CJK 가 그려져(2셀 예약이 없어) 글자 사이가
// 벌어지지 않는다. 입력 박스·wrap·커서는 usix draw.rs 이식. 편집기는 editor.rs.
mod editor;
mod markdown;

use crate::domain::agent::{Agent, Turn};
use crate::ports::Tool;
use crate::tools::shell::Shell;
use anyhow::Result;
use crossterm::event::{self, DisableBracketedPaste, EnableBracketedPaste, Event, KeyEventKind};
use crossterm::execute;
use editor::{Action, Editor};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::{Frame, TerminalOptions, Viewport};
use serde_json::json;
use std::io::{self, Write};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

// usix 팔레트.
const MUTED: Color = Color::Rgb(175, 175, 175);
const ACCENT: Color = Color::Rgb(215, 175, 255);
const CODE: Color = Color::Rgb(135, 215, 215);
const YELLOW: Color = Color::Indexed(220);
const PINK: Color = Color::Indexed(218);
const BROWN: Color = Color::Indexed(172);
const RED: Color = Color::Indexed(203);

const PROMPT: &str = "> ";
const PROMPT_W: usize = 2;
/// 입력 박스가 먹는 가로 크롬 = 좌우 테두리(2) + 좌우 여백(2).
const BOX_CHROME: u16 = 4;
/// 하단 인라인 뷰포트 높이(테두리 2 + 입력 최대 3 + footer 1).
const VIEWPORT_H: u16 = 6;
const MAX_INPUT_ROWS: u16 = 3;

/// read_line 결과 — 한 줄 입력 종료 신호.
enum Read {
    Submit(String),
    Exit,
}

/// 입력 중 오류나 panic이 나도 raw mode와 bracketed paste를 복구한다.
struct TerminalGuard;

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = execute!(io::stdout(), DisableBracketedPaste);
        ratatui::restore();
    }
}

pub fn run(mut agent: Agent, model_label: String) -> Result<()> {
    print_banner(&model_label);
    let mut ed = Editor::new();
    loop {
        match read_line(&mut ed, &model_label)? {
            Read::Exit => break,
            Read::Submit(text) => {
                let t = text.trim();
                if t == "exit" || t == "quit" {
                    break;
                }
                if let Some(cmd) = text.strip_prefix('!') {
                    run_shell(cmd);
                } else {
                    agent.submit(&text);
                    drive(&mut agent)?;
                }
            }
        }
    }
    Ok(())
}

// ── 한 줄 입력 (인라인 뷰포트) ─────────────────────────────────────────────

fn read_line(ed: &mut Editor, model: &str) -> Result<Read> {
    let mut term = ratatui::try_init_with_options(TerminalOptions {
        viewport: Viewport::Inline(VIEWPORT_H),
    })?;
    let _terminal_guard = TerminalGuard;
    let _ = execute!(io::stdout(), EnableBracketedPaste);

    let out = loop {
        term.draw(|f| draw_box(f, &ed.buffer, ed.cursor, model, true))?;
        match event::read()? {
            Event::Paste(t) => ed.insert_str(&t),
            Event::Key(k) if k.kind != KeyEventKind::Release => {
                match ed.on_key(k.code, k.modifiers) {
                    Action::None | Action::Cancel => {}
                    Action::Exit => break Read::Exit,
                    Action::Submit(text) => {
                        // 커밋 프레임: 제출한 텍스트를 footer 없이 한 번 더 그려 스크롤백에 남긴다.
                        let _ = term.draw(|f| draw_box(f, &text, text.len(), model, false));
                        break Read::Submit(text);
                    }
                }
            }
            _ => {}
        }
    };

    Ok(out)
}

/// 답변은 토큰이 도착하는 대로 한 줄씩 스트리밍 출력한다. 첫 토큰 전까지는 `Thinking…`
/// 경과 초를 보여주고, 승인 필요 시 일반 모드 stdin 으로 y/n 을 받아 다시 진행한다.
fn drive(agent: &mut Agent) -> Result<()> {
    let mut sp = StreamPrinter::new();
    loop {
        match run_turn(agent, &mut sp)? {
            Turn::Answer(a) => {
                if sp.any {
                    sp.finish();
                    println!();
                } else {
                    clear_line();
                    if !a.trim().is_empty() {
                        print_assistant(&a); // 비스트리밍 폴백(ollama)
                    }
                }
                return Ok(());
            }
            Turn::NeedApproval { desc } => {
                clear_line();
                let yes = read_yes_no(&format!("approval needed: {desc}"));
                agent.approve(yes)?;
                if !yes {
                    // 취소면 모델을 다시 돌리지 않고 턴을 끝낸다 — 소형 모델이 "실행했다"고
                    // 거짓말하는 걸 막는다. 승인이면 계속 진행해 실제 실행 결과를 보고하게 둔다.
                    print_system("cancelled");
                    return Ok(());
                }
            }
        }
    }
}

fn clear_line() {
    print!("\r\x1b[K");
    let _ = io::stdout().flush();
}

const MAX_APPROVAL_PROMPT_CHARS: usize = 1200;

fn is_terminal_control(c: char) -> bool {
    c.is_control()
        || matches!(
            c,
            '\u{202A}'
                | '\u{202B}'
                | '\u{202C}'
                | '\u{202D}'
                | '\u{202E}'
                | '\u{2066}'
                | '\u{2067}'
                | '\u{2068}'
                | '\u{2069}'
        )
}

/// 모델·파일·알림·셸에서 온 문자열이 터미널 제어 시퀀스로 해석되지 않게 한다.
fn sanitize_terminal_text(text: &str) -> String {
    text.chars()
        .map(|c| if is_terminal_control(c) { '�' } else { c })
        .collect()
}

fn truncate_display(text: &str, limit: usize) -> String {
    let mut chars = text.chars();
    let out: String = chars.by_ref().take(limit).collect();
    if chars.next().is_some() {
        format!("{out}…")
    } else {
        out
    }
}

/// 모델 진행을 워커 스레드로 돌리고, content 델타는 채널로 받아 메인에서 출력한다.
/// 첫 델타 전까지만 `Thinking…` 타이머를 갱신한다.
fn run_turn(agent: &mut Agent, sp: &mut StreamPrinter) -> Result<Turn> {
    let start = Instant::now();
    let (dtx, drx) = mpsc::channel::<String>();
    let (rtx, rrx) = mpsc::channel::<Result<Turn>>();
    std::thread::scope(|s| -> Result<Turn> {
        s.spawn(move || {
            let mut sink = |d: &str| {
                let _ = dtx.send(d.to_string());
            };
            let r = agent.advance(&mut sink);
            let _ = rtx.send(r);
        });
        loop {
            while let Ok(d) = drx.try_recv() {
                sp.on_delta(&d);
            }
            match rrx.recv_timeout(Duration::from_millis(80)) {
                Ok(res) => {
                    while let Ok(d) = drx.try_recv() {
                        sp.on_delta(&d);
                    }
                    return res;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if !sp.any {
                        print!(
                            "\r\x1b[K\x1b[38;2;175;175;175mThinking… ({}s)\x1b[0m",
                            start.elapsed().as_secs()
                        );
                        let _ = io::stdout().flush();
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Ok(Turn::Answer(String::new()))
                }
            }
        }
    })
}

/// 스트리밍 답변을 한 줄씩 markdown 렌더해 출력한다. 부분 줄은 buffer 에 두고
/// 개행이 완성될 때마다 그린다(finish 로 마지막 부분 줄을 마무리).
struct StreamPrinter {
    md: markdown::Stream,
    partial: String,
    any: bool,
}

impl StreamPrinter {
    fn new() -> Self {
        Self {
            md: markdown::Stream::new(),
            partial: String::new(),
            any: false,
        }
    }

    fn on_delta(&mut self, d: &str) {
        if !self.any {
            print!("\r\x1b[K\n"); // Thinking 줄 지우고 답변 앞 빈 줄
            self.any = true;
        }
        self.partial.push_str(d);
        while let Some(i) = self.partial.find('\n') {
            let line: String = self.partial.drain(..=i).collect();
            let raw = &line[..line.len() - 1];
            if let Some(l) = self.md.feed_line(raw) {
                println!("{}", line_to_ansi(&l));
            }
        }
        let _ = io::stdout().flush();
    }

    fn finish(&mut self) {
        if !self.partial.is_empty() {
            let raw = std::mem::take(&mut self.partial);
            if let Some(l) = self.md.feed_line(&raw) {
                println!("{}", line_to_ansi(&l));
            }
        }
    }
}

fn read_yes_no(prompt: &str) -> bool {
    let prompt = truncate_display(&sanitize_terminal_text(prompt), MAX_APPROVAL_PROMPT_CHARS);
    eprint!("\n\x1b[33m{prompt}  [y/N] \x1b[0m");
    let _ = io::stderr().flush();
    let mut s = String::new();
    let _ = io::stdin().read_line(&mut s);
    matches!(s.trim(), "y" | "Y" | "yes")
}

// `! cmd` — 로컬 셸 실행. 셸 도구와 같은 timeout·출력 상한을 적용한다.
fn run_shell(cmd: &str) {
    let cmd = cmd.trim();
    if cmd.is_empty() {
        return;
    }
    match Shell.run(&json!({ "command": cmd })) {
        Ok(output) => print_system(&output),
        Err(e) => print_system(&format!("shell error: {e}")),
    }
}

// ── 대화록 출력 (일반 stdout — 단말 고유 폭) ───────────────────────────────

fn print_banner(model: &str) {
    for line in banner_lines(model) {
        println!("{}", line_to_ansi(&line));
    }
    println!();
}

fn print_assistant(md: &str) {
    println!();
    for line in markdown::render(md) {
        println!("{}", line_to_ansi(&line));
    }
}

fn print_system(text: &str) {
    println!();
    for l in text.lines() {
        println!("\x1b[38;2;175;175;175m{}\x1b[0m", sanitize_terminal_text(l));
    }
}

/// ratatui Line → ANSI 문자열. 뷰포트 밖으로 직접 찍을 때 색·강조를 보존한다.
fn line_to_ansi(line: &Line) -> String {
    let mut s = String::new();
    for span in &line.spans {
        if let Some(c) = span.style.fg {
            s.push_str(&ansi_fg(c));
        }
        let m = span.style.add_modifier;
        if m.contains(Modifier::BOLD) {
            s.push_str("\x1b[1m");
        }
        if m.contains(Modifier::ITALIC) {
            s.push_str("\x1b[3m");
        }
        if m.contains(Modifier::UNDERLINED) {
            s.push_str("\x1b[4m");
        }
        if m.contains(Modifier::CROSSED_OUT) {
            s.push_str("\x1b[9m");
        }
        s.push_str(&sanitize_terminal_text(&span.content));
        s.push_str("\x1b[0m");
    }
    s
}

fn ansi_fg(c: Color) -> String {
    match c {
        Color::Rgb(r, g, b) => format!("\x1b[38;2;{r};{g};{b}m"),
        Color::Indexed(n) => format!("\x1b[38;5;{n}m"),
        Color::Black => "\x1b[30m".into(),
        Color::Red => "\x1b[31m".into(),
        Color::Green => "\x1b[32m".into(),
        Color::Yellow => "\x1b[33m".into(),
        Color::Blue => "\x1b[34m".into(),
        Color::Magenta => "\x1b[35m".into(),
        Color::Cyan => "\x1b[36m".into(),
        Color::White | Color::Gray => "\x1b[37m".into(),
        _ => "\x1b[39m".into(),
    }
}

// ── 입력 박스 렌더 (usix draw.rs 이식) ─────────────────────────────────────

/// `editing`=true → footer·커서·placeholder 포함(편집 중). false → 박스+입력만(커밋).
fn draw_box(f: &mut Frame, buffer: &str, cursor: usize, model: &str, editing: bool) {
    let area = f.area();
    let bash = buffer.starts_with('!');
    let border = Style::default().fg(if bash { RED } else { MUTED });
    let inner_w = area.width.saturating_sub(BOX_CHROME).max(1);
    let text_style = Style::default().fg(Color::White);
    let accent = Style::default().fg(ACCENT).add_modifier(Modifier::BOLD);

    let buf_lines: Vec<&str> = buffer.split('\n').collect();
    let mut vis: Vec<Line> = Vec::new();
    for (i, bl) in buf_lines.iter().enumerate() {
        let mut spans: Vec<Span> = Vec::new();
        if i == 0 {
            spans.push(Span::styled(PROMPT, accent));
            if bl.starts_with('!') {
                spans.extend(bang_spans(bl));
            } else {
                spans.push(Span::styled((*bl).to_string(), text_style));
            }
        } else {
            spans.push(Span::styled((*bl).to_string(), text_style));
        }
        if i == 0 && editing && buffer.is_empty() {
            spans.push(Span::styled("How can I help?", Style::default().fg(MUTED)));
        }
        vis.extend(wrap_spans(spans, inner_w));
    }
    let input_h = (vis.len() as u16).clamp(1, MAX_INPUT_ROWS);

    let constraints = if editing {
        vec![
            Constraint::Length(1),
            Constraint::Length(input_h),
            Constraint::Length(1),
            Constraint::Length(1),
            Constraint::Min(0),
        ]
    } else {
        vec![
            Constraint::Length(1),
            Constraint::Length(input_h),
            Constraint::Length(1),
            Constraint::Min(0),
        ]
    };
    let rows = Layout::vertical(constraints).split(area);
    let (top, body_area, bottom) = (rows[0], rows[1], rows[2]);

    f.render_widget(Paragraph::new(box_rule(area.width, "╭", "╮", border)), top);
    f.render_widget(
        Paragraph::new(box_rule(area.width, "╰", "╯", border)),
        bottom,
    );

    let (vrow, col) = cursor_line_col(buffer, cursor, area.width);
    let scroll = vrow.saturating_sub(input_h.saturating_sub(1));
    let framed: Vec<Line> = vis
        .into_iter()
        .map(|l| frame_row(l, inner_w as usize, border))
        .collect();
    f.render_widget(Paragraph::new(framed).scroll((scroll, 0)), body_area);

    if editing {
        let x_off = (BOX_CHROME / 2) + if vrow == 0 { PROMPT_W as u16 } else { 0 };
        f.set_cursor_position((body_area.x + x_off + col, body_area.y + (vrow - scroll)));

        let (left, lstyle) = if bash {
            (
                "bash — Enter runs local shell".to_string(),
                Style::default().fg(RED),
            )
        } else {
            (
                "Ctrl+J newline · ↑ history · ! shell · exit quits".to_string(),
                Style::default().fg(MUTED),
            )
        };
        f.render_widget(
            Paragraph::new(footer_line(
                &left,
                lstyle,
                model,
                Style::default().fg(ACCENT),
                area.width,
            )),
            rows[3],
        );
    }
}

fn bang_spans(line: &str) -> Vec<Span<'static>> {
    let mut spans = Vec::with_capacity(2);
    spans.push(Span::styled(
        "!".to_string(),
        Style::default().fg(RED).add_modifier(Modifier::BOLD),
    ));
    let rest = &line[1..];
    if !rest.is_empty() {
        spans.push(Span::styled(rest.to_string(), Style::default().fg(CODE)));
    }
    spans
}

/// 표시폭(셀) 기준 char-level wrap — cursor 계산(wrap_advance)과 동일 규칙이라 커서가
/// 글자 위에 정확히 놓인다. CJK(2셀)·긴 무공백 토큰도 절단 없이 다음 줄로.
fn wrap_spans<'a>(spans: Vec<Span<'a>>, width: u16) -> Vec<Line<'a>> {
    let width = (width as usize).max(1);
    let mut lines: Vec<Line<'a>> = Vec::new();
    let mut cur: Vec<Span<'a>> = Vec::new();
    let mut seg = String::new();
    let mut style = Style::default();
    let mut col = 0usize;
    for span in spans {
        if !seg.is_empty() && span.style != style {
            cur.push(Span::styled(std::mem::take(&mut seg), style));
        }
        style = span.style;
        for ch in span.content.chars() {
            let w = UnicodeWidthChar::width(ch).unwrap_or(0);
            if col + w > width && col > 0 {
                if !seg.is_empty() {
                    cur.push(Span::styled(std::mem::take(&mut seg), style));
                }
                lines.push(Line::from(std::mem::take(&mut cur)));
                col = 0;
            }
            seg.push(ch);
            col += w;
        }
        if !seg.is_empty() {
            cur.push(Span::styled(std::mem::take(&mut seg), style));
        }
    }
    lines.push(Line::from(cur));
    lines
}

fn wrap_advance(content: &str, start_col: usize, width: usize) -> (usize, usize) {
    let mut row = 0usize;
    let mut col = start_col;
    for ch in content.chars() {
        let w = UnicodeWidthChar::width(ch).unwrap_or(0);
        if col + w > width && col > 0 {
            row += 1;
            col = 0;
        }
        col += w;
    }
    (row, col)
}

/// cursor 의 시각 (행, 열). 렌더의 wrap_spans 와 동일 규칙.
fn cursor_line_col(buffer: &str, cursor: usize, width: u16) -> (u16, u16) {
    let width = (width.saturating_sub(BOX_CHROME).max(1)) as usize;
    let before = &buffer[..cursor];
    let segs: Vec<&str> = before.split('\n').collect();
    let last = segs.len() - 1;
    let mut visual_row = 0usize;
    for (i, seg) in segs.iter().enumerate() {
        let start = if i == 0 { PROMPT_W } else { 0 };
        let (row_delta, col) = wrap_advance(seg, start, width);
        if i == last {
            let abs_row = visual_row + row_delta;
            let content_col = if abs_row == 0 {
                col.saturating_sub(PROMPT_W)
            } else {
                col
            };
            return (abs_row as u16, content_col as u16);
        }
        visual_row += row_delta + 1;
    }
    (0, 0)
}

/// wrap 된 시각 행 하나를 박스 안에: `│ ` + 내용 + 우측 패딩 + ` │`.
fn frame_row<'a>(inner: Line<'a>, inner_w: usize, border: Style) -> Line<'a> {
    let used: usize = inner
        .spans
        .iter()
        .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
        .sum();
    let mut spans = Vec::with_capacity(inner.spans.len() + 2);
    spans.push(Span::styled("│ ", border));
    spans.extend(inner.spans);
    spans.push(Span::styled(
        format!("{} │", " ".repeat(inner_w.saturating_sub(used))),
        border,
    ));
    Line::from(spans)
}

fn box_rule(width: u16, left: &str, right: &str, style: Style) -> Line<'static> {
    let fill = "─".repeat((width as usize).saturating_sub(2));
    Line::from(Span::styled(format!("{left}{fill}{right}"), style))
}

fn clamp_cells(s: &str, budget: usize) -> String {
    if UnicodeWidthStr::width(s) <= budget {
        return s.to_string();
    }
    let mut acc = String::new();
    let mut col = 0usize;
    for ch in s.chars() {
        let w = UnicodeWidthChar::width(ch).unwrap_or(0);
        if col + w > budget.saturating_sub(1) {
            break;
        }
        acc.push(ch);
        col += w;
    }
    acc.push('…');
    acc
}

/// footer 한 줄 — 왼쪽 힌트 + 오른쪽 모델을 양끝 정렬. 좁으면 왼쪽 힌트를 버린다.
fn footer_line(
    left: &str,
    left_style: Style,
    right: &str,
    right_style: Style,
    width: u16,
) -> Line<'static> {
    const INDENT: usize = 2;
    const MIN_GAP: usize = 2;
    const MIN_HINT: usize = 8;

    let total = width as usize;
    let rw = UnicodeWidthStr::width(right);
    let mut spans = vec![Span::raw(" ".repeat(INDENT))];

    if !right.is_empty() && INDENT + MIN_GAP + rw <= total {
        let hint_budget = total - INDENT - MIN_GAP - rw;
        let hint = if hint_budget >= MIN_HINT {
            clamp_cells(left, hint_budget)
        } else {
            String::new()
        };
        let gap = total - INDENT - UnicodeWidthStr::width(hint.as_str()) - rw;
        spans.push(Span::styled(hint, left_style));
        spans.push(Span::raw(" ".repeat(gap)));
        spans.push(Span::styled(right.to_string(), right_style));
        return Line::from(spans);
    }

    spans.push(Span::styled(
        clamp_cells(left, total.saturating_sub(INDENT)),
        left_style,
    ));
    Line::from(spans)
}

// ── 시작 배너 (병아리 + 컨텍스트) ─────────────────────────────────────────

fn mascot_rows() -> Vec<Vec<Span<'static>>> {
    // usix mascot.rs 이식 — 통통한 병아리(데스크톱 아이콘의 터미널 버전). 열린 옆구리
    // `/  \`·`|  |` 와 배·날개 행 `(           )` 로 6줄 축약본보다 몸통을 살렸다.
    let white = Style::default().fg(Color::White);
    let white_b = white.add_modifier(Modifier::BOLD);
    let pink = Style::default().fg(PINK);
    let beak = Style::default().fg(YELLOW).add_modifier(Modifier::BOLD);
    let feet = Style::default().fg(BROWN);
    vec![
        vec![Span::styled("      ,;;,", white)],
        vec![Span::styled("   .-'```'-.", white)],
        vec![
            Span::styled("  /  ", white),
            Span::styled("o   o", white_b),
            Span::styled("  \\", white),
        ],
        vec![
            Span::styled(" |  ", white),
            Span::styled(".", pink),
            Span::styled("  ", white),
            Span::styled("v", beak),
            Span::styled("  ", white),
            Span::styled(".", pink),
            Span::styled("  |", white),
        ],
        vec![Span::styled(" (           )", white)],
        vec![Span::styled("   '-.___.-'", white)],
        vec![Span::styled("     w   w", feet)],
    ]
}

/// 마스코트 한 줄의 고정 표시폭(패딩 포함). 아트는 ASCII 전용이라 byte == column.
const ART_W: usize = 16;
/// 마스코트와 copy 사이 간격.
const MASCOT_GAP: &str = "  ";
/// 좌우 배치를 유지하기 위한 copy 최소폭 — 이보다 좁으면 병아리 아래에 쌓는다.
const SIDE_MIN_COPY_W: usize = 32;

/// usix banner.rs 이식 — 한 줄 dim 컨텍스트 + 폭에 따른 좌우/상하 반응형 배치.
/// copy(로고·컨텍스트)는 상단 정렬해 병아리 첫 두 행에 나란히 놓고, 남는 행은 마스코트만.
fn banner_lines(model_label: &str) -> Vec<Line<'static>> {
    let cwd = std::env::current_dir()
        .ok()
        .and_then(|p| p.file_name().map(|s| s.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "?".into());
    let branch = read_git_branch().unwrap_or_else(|| "(no git)".into());

    let cols = crossterm::terminal::size()
        .map_or(80, |(c, _)| c as usize)
        .max(1);
    let gap = UnicodeWidthStr::width(MASCOT_GAP);
    let show_mascot = cols >= ART_W;
    let side_by_side = show_mascot && cols >= ART_W + gap + SIDE_MIN_COPY_W;
    let copy_width = if side_by_side {
        cols - ART_W - gap
    } else {
        cols
    };

    let copy = copy_lines(&cwd, &branch, model_label, copy_width);
    if !show_mascot {
        return copy;
    }

    let mascot = mascot_rows();
    let mut out = Vec::new();
    if side_by_side {
        for (i, row) in mascot.iter().enumerate() {
            let mut line = mascot_line(row);
            if let Some(c) = copy.get(i) {
                line.spans.push(Span::raw(MASCOT_GAP));
                line.spans.extend(c.spans.iter().cloned());
            }
            out.push(line);
        }
    } else {
        out.extend(mascot.iter().map(|r| mascot_line(r)));
        out.extend(copy);
    }
    out
}

/// 마스코트 한 행을 `ART_W` 표시폭으로 우측 패딩한 Line.
fn mascot_line(row: &[Span<'static>]) -> Line<'static> {
    let w: usize = row
        .iter()
        .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
        .sum();
    let mut spans = row.to_vec();
    if w < ART_W {
        spans.push(Span::raw(" ".repeat(ART_W - w)));
    }
    Line::from(spans)
}

/// 로고 + 한 줄 컨텍스트를 copy_width 안에 맞춰 반환.
fn copy_lines(cwd: &str, branch: &str, model: &str, width: usize) -> Vec<Line<'static>> {
    const LOGO: &str = "✻ usix-termux v0.0.1";
    let logo = if UnicodeWidthStr::width(LOGO) <= width {
        Line::from(vec![
            Span::styled("✻ ", Style::default().fg(ACCENT)),
            Span::styled(
                "usix-termux",
                Style::default()
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" v0.0.1", Style::default().fg(MUTED)),
        ])
    } else {
        Line::from(Span::styled(
            clamp_cells(LOGO, width),
            Style::default().fg(ACCENT),
        ))
    };
    let ctx = context_line(cwd, branch, model, width);
    vec![
        logo,
        Line::from(Span::styled(ctx, Style::default().fg(MUTED))),
    ]
}

/// `cwd X · branch Y · model Z` 한 줄 — 좁을수록 라벨을 점진 축약하고 값은 tail 절단.
/// model 이 termux 핵심 값이라 값 예산을 가장 크게 준다(나머지를 cwd·branch 로 3:2).
fn context_line(cwd: &str, branch: &str, model: &str, max_width: usize) -> String {
    let layouts = [
        ("cwd ", " · branch ", " · model "),
        ("cwd ", " · br ", " · md "),
        ("c ", " · b ", " · m "),
    ];
    let label_w = |(a, b, c): &(&str, &str, &str)| {
        UnicodeWidthStr::width(*a) + UnicodeWidthStr::width(*b) + UnicodeWidthStr::width(*c)
    };
    let labels = layouts
        .iter()
        .find(|l| label_w(l) + 3 <= max_width)
        .copied()
        .unwrap_or(layouts[2]);
    let (l_cwd, l_branch, l_model) = labels;

    let values = max_width.saturating_sub(label_w(&labels));
    let model_w = (values * 2 / 5).max(usize::from(values > 0));
    let rest = values.saturating_sub(model_w);
    let cwd_w = (rest * 3 / 5).max(usize::from(rest > 0));
    let branch_w = rest.saturating_sub(cwd_w);

    let fit = |s: &str, w: usize| {
        if w == 0 {
            String::new()
        } else {
            clamp_cells(s, w)
        }
    };
    let line = format!(
        "{l_cwd}{}{l_branch}{}{l_model}{}",
        fit(cwd, cwd_w),
        fit(branch, branch_w),
        fit(model, model_w),
    );
    clamp_cells(&line, max_width)
}

fn read_git_branch() -> Option<String> {
    let out = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .stdin(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_text_replaces_control_and_bidi_characters() {
        let safe = sanitize_terminal_text("ok\u{1b}[31m\u{202e}text");
        assert!(!safe.contains('\u{1b}'));
        assert!(!safe.contains('\u{202e}'));
        assert!(safe.contains('�'));
    }

    #[test]
    fn display_truncation_is_character_safe() {
        assert_eq!(truncate_display("가나다", 2), "가나…");
        assert_eq!(truncate_display("가나", 2), "가나");
    }
}
