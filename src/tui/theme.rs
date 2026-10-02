//! USIX colors resolved for dark/light/mono terminals and their color capability.
use anyhow::{bail, Result};
use ratatui::{
    buffer::Buffer,
    style::{Color, Modifier},
};
use std::{io::IsTerminal, sync::OnceLock};

pub const MUTED: Color = Color::Rgb(153, 153, 153);
pub const ACCENT: Color = Color::Rgb(215, 175, 255);
pub const CODE: Color = Color::Rgb(177, 185, 249);
pub const QUOTE: Color = Color::Rgb(178, 178, 178);
pub const BORDER: Color = Color::Rgb(136, 136, 136);
pub const BASH: Color = Color::Rgb(255, 0, 135);
pub const WARN: Color = Color::Rgb(255, 193, 7);

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Dark,
    Light,
    Mono,
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Level {
    None,
    Ansi16,
    Ansi256,
    TrueColor,
}
#[derive(Clone, Copy)]
pub struct Settings {
    pub mode: Mode,
    pub level: Level,
}
static SETTINGS: OnceLock<Settings> = OnceLock::new();

pub fn init() -> Result<()> {
    let automatic_light = std::env::var("COLORFGBG")
        .ok()
        .and_then(|v| v.rsplit(';').next()?.parse::<u8>().ok())
        .is_some_and(|background| background >= 8);
    let mode = match std::env::var("USIX_THEME").as_deref() {
        Ok("dark") => Mode::Dark,
        Ok("light") => Mode::Light,
        Ok("mono") => Mode::Mono,
        Err(_) => {
            if automatic_light {
                Mode::Light
            } else {
                Mode::Dark
            }
        }
        Ok(other) => bail!("unknown USIX_THEME `{other}`; use dark, light, or mono"),
    };
    let term = std::env::var("TERM").unwrap_or_default();
    let colors = std::env::var("COLORTERM").unwrap_or_default();
    let level = if std::env::var_os("NO_COLOR").is_some()
        || !std::io::stdout().is_terminal()
        || term == "dumb"
    {
        Level::None
    } else if matches!(colors.as_str(), "truecolor" | "24bit") || term.ends_with("-direct") {
        Level::TrueColor
    } else if term.contains("256color") {
        Level::Ansi256
    } else {
        Level::Ansi16
    };
    let _ = SETTINGS.set(Settings { mode, level });
    Ok(())
}

pub fn active() -> Settings {
    *SETTINGS.get_or_init(|| Settings {
        mode: Mode::Dark,
        level: if std::env::var_os("NO_COLOR").is_some() {
            Level::None
        } else {
            Level::TrueColor
        },
    })
}

impl Settings {
    pub fn resolve(self, color: Color) -> Color {
        if self.level == Level::None || self.mode == Mode::Mono {
            return Color::Reset;
        }
        let color = if self.mode == Mode::Light {
            match color {
                MUTED => Color::Rgb(102, 102, 102),
                ACCENT => Color::Rgb(95, 0, 175),
                CODE => Color::Rgb(73, 84, 169),
                QUOTE => Color::Rgb(85, 85, 85),
                BORDER => Color::Rgb(153, 153, 153),
                other => other,
            }
        } else {
            color
        };
        match (color, self.level) {
            (Color::Rgb(r, g, b), Level::Ansi256) => Color::Indexed(nearest(r, g, b, 256)),
            (Color::Rgb(r, g, b), Level::Ansi16) => basic(nearest(r, g, b, 16)),
            (Color::Indexed(index), Level::Ansi16) => {
                let (r, g, b) = rgb(index);
                basic(nearest(r, g, b, 16))
            }
            _ => color,
        }
    }

    pub fn resolve_buffer(self, buffer: &mut Buffer) {
        for cell in &mut buffer.content {
            cell.fg = self.resolve(cell.fg);
            cell.bg = self.resolve(cell.bg);
            if self.level == Level::None {
                cell.modifier = Modifier::empty();
            }
        }
    }
}

fn basic(index: u8) -> Color {
    [
        Color::Black,
        Color::Red,
        Color::Green,
        Color::Yellow,
        Color::Blue,
        Color::Magenta,
        Color::Cyan,
        Color::Gray,
        Color::DarkGray,
        Color::LightRed,
        Color::LightGreen,
        Color::LightYellow,
        Color::LightBlue,
        Color::LightMagenta,
        Color::LightCyan,
        Color::White,
    ][index as usize]
}

fn rgb(index: u8) -> (u8, u8, u8) {
    const BASIC: [(u8, u8, u8); 16] = [
        (0, 0, 0),
        (128, 0, 0),
        (0, 128, 0),
        (128, 128, 0),
        (0, 0, 128),
        (128, 0, 128),
        (0, 128, 128),
        (192, 192, 192),
        (128, 128, 128),
        (255, 0, 0),
        (0, 255, 0),
        (255, 255, 0),
        (0, 0, 255),
        (255, 0, 255),
        (0, 255, 255),
        (255, 255, 255),
    ];
    match index {
        0..=15 => BASIC[index as usize],
        16..=231 => {
            let i = index - 16;
            let levels = [0, 95, 135, 175, 215, 255];
            (
                levels[(i / 36) as usize],
                levels[((i / 6) % 6) as usize],
                levels[(i % 6) as usize],
            )
        }
        _ => {
            let value = 8 + (index - 232) * 10;
            (value, value, value)
        }
    }
}

fn nearest(r: u8, g: u8, b: u8, count: u16) -> u8 {
    // Prefer cube entries over configurable ANSI basic colors in 256-color mode.
    let start = if count == 256 { 16 } else { 0 };
    (start..count)
        .min_by_key(|i| {
            let (a, c, d) = rgb(*i as u8);
            (r as i32 - a as i32).pow(2)
                + (g as i32 - c as i32).pow(2)
                + (b as i32 - d as i32).pow(2)
        })
        .unwrap_or(0) as u8
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sixteen_color_terminals_use_basic_ansi_colors() {
        let settings = Settings {
            mode: Mode::Dark,
            level: Level::Ansi16,
        };
        for color in [ACCENT, CODE, Color::Indexed(218), Color::Indexed(0)] {
            assert!(!matches!(
                settings.resolve(color),
                Color::Indexed(_) | Color::Rgb(..)
            ));
        }
    }

    #[test]
    fn identity_colors_survive_256_color_resolution() {
        let settings = Settings {
            mode: Mode::Dark,
            level: Level::Ansi256,
        };
        for (color, index) in [
            (Color::Rgb(255, 215, 0), 220),
            (Color::Rgb(255, 175, 215), 218),
            (Color::Rgb(215, 135, 0), 172),
        ] {
            assert_eq!(settings.resolve(color), Color::Indexed(index));
        }
    }
    #[test]
    fn default_body_and_monochrome_do_not_force_white() {
        for mode in [Mode::Dark, Mode::Light, Mode::Mono] {
            let settings = Settings {
                mode,
                level: Level::TrueColor,
            };
            assert_eq!(settings.resolve(Color::Reset), Color::Reset);
            if mode == Mode::Mono {
                assert_eq!(settings.resolve(ACCENT), Color::Reset);
            }
        }
        let settings = Settings {
            mode: Mode::Dark,
            level: Level::None,
        };
        assert_eq!(settings.resolve(Color::Rgb(255, 215, 0)), Color::Reset);
    }
}
