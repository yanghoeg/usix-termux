// 라인 에디터 — usix chat_tui/session_key.rs 편집 서브셋을 폰 규모로 이식.
// 바이트 오프셋 커서 + 멀티라인(Ctrl+J) + 세션 히스토리(↑/↓) + 단어 단위 편집.
// popup/자동완성/역검색/paste-burst 게이팅은 제외(폰엔 불필요 — 조사 결론).
use crossterm::event::{KeyCode, KeyModifiers};

/// on_key 결과 — 편집 계속(None) 또는 입력 종료 신호.
pub enum Action {
    None,
    Submit(String),
    Cancel,
    Exit,
}

pub struct Editor {
    pub buffer: String,
    pub cursor: usize, // byte offset (항상 char 경계)
    history: Vec<String>,
    hist_cursor: Option<usize>, // None = 라이브 버퍼
    stash: Option<String>,      // 히스토리 진입 시 원본 보관
}

fn prev_boundary(s: &str, mut i: usize) -> usize {
    if i == 0 {
        return 0;
    }
    i -= 1;
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

fn next_boundary(s: &str, mut i: usize) -> usize {
    let len = s.len();
    if i >= len {
        return len;
    }
    i += 1;
    while i < len && !s.is_char_boundary(i) {
        i += 1;
    }
    i
}

fn word_left(buf: &str, mut pos: usize) -> usize {
    while pos > 0 && buf[..pos].ends_with(|c: char| c.is_whitespace()) {
        pos = prev_boundary(buf, pos);
    }
    while pos > 0 && !buf[..pos].ends_with(|c: char| c.is_whitespace()) {
        pos = prev_boundary(buf, pos);
    }
    pos
}

fn word_right(buf: &str, mut pos: usize) -> usize {
    let len = buf.len();
    while pos < len && buf[pos..].starts_with(|c: char| c.is_whitespace()) {
        pos = next_boundary(buf, pos);
    }
    while pos < len && !buf[pos..].starts_with(|c: char| c.is_whitespace()) {
        pos = next_boundary(buf, pos);
    }
    pos
}

impl Editor {
    pub fn new() -> Self {
        Self {
            buffer: String::new(),
            cursor: 0,
            history: Vec::new(),
            hist_cursor: None,
            stash: None,
        }
    }

    /// 타이핑/편집은 히스토리 탐색 상태를 라이브 버퍼로 되돌린다.
    fn touch(&mut self) {
        self.hist_cursor = None;
        self.stash = None;
    }

    pub fn insert_str(&mut self, text: &str) {
        self.buffer.insert_str(self.cursor, text);
        self.cursor += text.len();
        self.touch();
    }

    fn insert_char(&mut self, c: char) {
        self.buffer.insert(self.cursor, c);
        self.cursor += c.len_utf8();
        self.touch();
    }

    fn history_back(&mut self) {
        if self.history.is_empty() {
            return;
        }
        match self.hist_cursor {
            None => {
                self.stash = Some(self.buffer.clone());
                self.hist_cursor = Some(self.history.len() - 1);
            }
            Some(0) => return,
            Some(i) => self.hist_cursor = Some(i - 1),
        }
        self.buffer = self.history[self.hist_cursor.unwrap()].clone();
        self.cursor = self.buffer.len();
    }

    fn history_forward(&mut self) {
        match self.hist_cursor {
            None => {}
            Some(i) if i + 1 < self.history.len() => {
                self.hist_cursor = Some(i + 1);
                self.buffer = self.history[i + 1].clone();
                self.cursor = self.buffer.len();
            }
            Some(_) => {
                self.hist_cursor = None;
                self.buffer = self.stash.take().unwrap_or_default();
                self.cursor = self.buffer.len();
            }
        }
    }

    fn submit(&mut self) -> Action {
        let text = self.buffer.clone();
        if self.history.last().map(String::as_str) != Some(text.as_str()) {
            self.history.push(text.clone());
        }
        self.buffer.clear();
        self.cursor = 0;
        self.hist_cursor = None;
        self.stash = None;
        Action::Submit(text)
    }

    pub fn on_key(&mut self, code: KeyCode, mods: KeyModifiers) -> Action {
        use KeyCode as K;
        let ctrl = mods.contains(KeyModifiers::CONTROL);
        let alt = mods.contains(KeyModifiers::ALT);
        match (code, ctrl, alt) {
            (K::Char('c'), true, _) | (K::Esc, _, _) => {
                if self.buffer.is_empty() {
                    Action::Exit
                } else {
                    self.buffer.clear();
                    self.cursor = 0;
                    self.touch();
                    Action::Cancel
                }
            }
            (K::Char('d'), true, _) => Action::Exit,
            // Ctrl+J = 개행(가장 신뢰성 높은 범용 폴백; Termux는 kitty 미지원이라 Shift+Enter 불가).
            (K::Char('j'), true, _) => {
                self.buffer.insert(self.cursor, '\n');
                self.cursor += 1;
                self.touch();
                Action::None
            }
            (K::Char('a'), true, _) => {
                self.cursor = 0;
                Action::None
            }
            (K::Char('e'), true, _) => {
                self.cursor = self.buffer.len();
                Action::None
            }
            (K::Char('u'), true, _) => {
                self.buffer.drain(..self.cursor);
                self.cursor = 0;
                self.touch();
                Action::None
            }
            (K::Char('w'), true, _) => {
                let start = word_left(&self.buffer, self.cursor);
                self.buffer.drain(start..self.cursor);
                self.cursor = start;
                self.touch();
                Action::None
            }
            (K::Left, _, true) => {
                self.cursor = word_left(&self.buffer, self.cursor);
                Action::None
            }
            (K::Right, _, true) => {
                self.cursor = word_right(&self.buffer, self.cursor);
                Action::None
            }
            (K::Backspace, _, true) => {
                let start = word_left(&self.buffer, self.cursor);
                self.buffer.drain(start..self.cursor);
                self.cursor = start;
                self.touch();
                Action::None
            }
            (K::Enter, _, _) => {
                if self.buffer.trim().is_empty() {
                    Action::None
                } else {
                    self.submit()
                }
            }
            (K::Char(c), false, false) => {
                self.insert_char(c);
                Action::None
            }
            (K::Backspace, _, _) => {
                if self.cursor > 0 {
                    let new = prev_boundary(&self.buffer, self.cursor);
                    self.buffer.drain(new..self.cursor);
                    self.cursor = new;
                    self.touch();
                }
                Action::None
            }
            (K::Delete, _, _) => {
                if self.cursor < self.buffer.len() {
                    let end = next_boundary(&self.buffer, self.cursor);
                    self.buffer.drain(self.cursor..end);
                    self.touch();
                }
                Action::None
            }
            (K::Left, _, _) => {
                self.cursor = prev_boundary(&self.buffer, self.cursor);
                Action::None
            }
            (K::Right, _, _) => {
                self.cursor = next_boundary(&self.buffer, self.cursor);
                Action::None
            }
            (K::Home, _, _) => {
                self.cursor = 0;
                Action::None
            }
            (K::End, _, _) => {
                self.cursor = self.buffer.len();
                Action::None
            }
            (K::Up, _, _) => {
                self.history_back();
                Action::None
            }
            (K::Down, _, _) => {
                self.history_forward();
                Action::None
            }
            _ => Action::None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{KeyCode as K, KeyModifiers as M};

    #[test]
    fn insert_and_backspace_utf8() {
        let mut e = Editor::new();
        for c in "가나".chars() {
            e.on_key(K::Char(c), M::NONE);
        }
        assert_eq!(e.buffer, "가나");
        assert_eq!(e.cursor, 6);
        e.on_key(K::Backspace, M::NONE);
        assert_eq!(e.buffer, "가");
        assert_eq!(e.cursor, 3);
    }

    #[test]
    fn ctrl_w_deletes_word() {
        let mut e = Editor::new();
        e.insert_str("foo bar baz");
        e.on_key(K::Char('w'), M::CONTROL);
        assert_eq!(e.buffer, "foo bar ");
    }

    #[test]
    fn history_up_down() {
        let mut e = Editor::new();
        e.insert_str("first");
        e.on_key(K::Enter, M::NONE);
        e.insert_str("second");
        e.on_key(K::Enter, M::NONE);
        e.insert_str("typing");
        e.on_key(K::Up, M::NONE);
        assert_eq!(e.buffer, "second");
        e.on_key(K::Up, M::NONE);
        assert_eq!(e.buffer, "first");
        e.on_key(K::Down, M::NONE);
        assert_eq!(e.buffer, "second");
        e.on_key(K::Down, M::NONE);
        assert_eq!(e.buffer, "typing"); // stash 복원
    }

    #[test]
    fn enter_ignores_blank() {
        let mut e = Editor::new();
        assert!(matches!(e.on_key(K::Enter, M::NONE), Action::None));
        e.insert_str("hi");
        assert!(matches!(e.on_key(K::Enter, M::NONE), Action::Submit(_)));
    }
}
