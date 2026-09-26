//! OpenCode Go subscription usage. This is a separate account and endpoint from Z.ai GLM.
//! OPENCODE_APIKEY takes precedence; OpenCode's own sign-in is used otherwise.

use crate::usage::{LimitWindow, UsageSnapshot};
use crate::AppState;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const ENDPOINT: &str = "https://opencode.ai/zen/go/v1/usage";
const POLL_SECS: u64 = 300;
static REFRESH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn store_path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("opencode-go-usage.json")
}

fn auth_paths() -> Vec<std::path::PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".local/share/opencode/auth.json"));
    }
    if let Some(appdata) = dirs::config_dir() {
        paths.push(appdata.join("opencode/auth.json"));
    }
    paths
}

fn token_from_auth(path: &std::path::Path) -> Option<String> {
    let root: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()?;
    token_from_json(&root)
}

fn token_from_json(root: &serde_json::Value) -> Option<String> {
    let entry = root.get("opencode-go")?;
    let value = entry.as_str().or_else(|| {
        ["key", "apiKey", "api_key", "token", "accessToken"]
            .iter()
            .find_map(|field| entry.get(field).and_then(|v| v.as_str()))
    })?;
    let token = value.trim();
    (!token.is_empty()).then(|| token.to_string())
}

fn credential() -> Option<(String, &'static str)> {
    if let Some(token) = std::env::var("OPENCODE_APIKEY")
        .ok()
        .filter(|v| !v.trim().is_empty())
    {
        return Some((token.trim().to_string(), "OPENCODE_APIKEY"));
    }
    for path in auth_paths() {
        if let Some(token) = token_from_auth(&path) {
            return Some((token, "OpenCode"));
        }
    }
    None
}

pub fn load_persisted() -> UsageSnapshot {
    std::fs::read_to_string(store_path())
        .ok()
        .and_then(|t| serde_json::from_str::<UsageSnapshot>(&t).ok())
        .map(|mut s| {
            if !s.windows.is_empty() {
                s.status = "stale".into();
            }
            s
        })
        .unwrap_or_default()
}

fn persist(snap: &UsageSnapshot) {
    if let Ok(text) = serde_json::to_string_pretty(snap) {
        let _ = std::fs::write(store_path(), text);
    }
}

fn windows_from(root: &serde_json::Value) -> Vec<LimitWindow> {
    let Some(usage) = root.get("usage") else {
        return Vec::new();
    };
    [
        ("rolling", "5h limit"),
        ("weekly", "Weekly limit"),
        ("monthly", "Monthly limit"),
    ]
    .into_iter()
    .filter_map(|(id, label)| {
        let entry = usage.get(id)?;
        let percent = entry.get("percent")?.as_f64()?;
        if !percent.is_finite() {
            return None;
        }
        let resets_at = entry
            .get("resetsAt")
            .and_then(|v| v.as_str())
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .and_then(|d| u64::try_from(d.timestamp_millis()).ok());
        Some(LimitWindow {
            id: id.into(),
            label: label.into(),
            used: (percent / 100.0).clamp(0.0, 1.0),
            resets_at,
            ..Default::default()
        })
    })
    .collect()
}

fn read_once() -> UsageSnapshot {
    let mut snap = UsageSnapshot::default();
    let Some((token, source)) = credential() else {
        snap.status = "absent".into();
        return snap;
    };
    let result = ureq::get(ENDPOINT)
        .set("Authorization", &format!("Bearer {token}"))
        .set("Accept", "application/json")
        .set(
            "User-Agent",
            concat!("codenotch/", env!("CARGO_PKG_VERSION"), " (Windows)"),
        )
        .timeout(Duration::from_secs(15))
        .call();
    match result {
        Ok(response) => match response.into_json::<serde_json::Value>() {
            Ok(body) => {
                snap.windows = windows_from(&body);
                if snap.windows.is_empty() {
                    snap.status = "error".into();
                    snap.note = "OpenCode Go returned no usage windows".into();
                } else {
                    snap.status = "ok".into();
                    snap.fetched_at = now_ms();
                    snap.note = format!("Go · via {source}");
                }
            }
            Err(_) => {
                snap.status = "error".into();
                snap.note = "Invalid OpenCode Go response".into();
            }
        },
        Err(ureq::Error::Status(401, _)) => {
            snap.status = "needsAuth".into();
            snap.note = "OpenCode Go rejected the key".into();
        }
        Err(ureq::Error::Status(403, _)) => {
            snap.status = "needsAuth".into();
            snap.note = "No OpenCode Go subscription on this key".into();
        }
        Err(ureq::Error::Status(429, response)) => {
            let wait = response
                .header("retry-after")
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(60)
                .max(60);
            snap.status = "backoff".into();
            snap.backoff_until = now_ms().saturating_add(wait.saturating_mul(1000));
            snap.note = format!("Rate limited — retrying in {wait}s");
        }
        Err(ureq::Error::Status(code, _)) => {
            snap.status = "error".into();
            snap.note = format!("OpenCode Go returned HTTP {code}");
        }
        Err(_) => {
            snap.status = "error".into();
            snap.note = "Could not reach OpenCode Go".into();
        }
    }
    snap
}

fn broadcast(app: &AppHandle, mut snap: UsageSnapshot) {
    let st = app.state::<AppState>();
    let mut current = st.opencode.lock().unwrap();
    if matches!(snap.status.as_str(), "error" | "backoff") && !current.windows.is_empty() {
        snap.windows = current.windows.clone();
        snap.fetched_at = current.fetched_at;
        snap.status = "stale".into();
    }
    *current = snap.clone();
    drop(current);
    persist(&snap);
    let _ = app.emit("opencode", &snap);
}

pub fn request_refresh() {
    REFRESH.store(true, std::sync::atomic::Ordering::Relaxed);
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || loop {
        let current = app.state::<AppState>().opencode.lock().unwrap().clone();
        let snap = if current.backoff_until > now_ms() {
            current
        } else {
            read_once()
        };
        let wait = POLL_SECS.max(snap.backoff_until.saturating_sub(now_ms()) / 1000);
        broadcast(&app, snap);
        for _ in 0..wait {
            if REFRESH.swap(false, std::sync::atomic::Ordering::Relaxed) {
                break;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    });
}

pub fn probe() -> String {
    match credential() {
        Some((_, source)) => format!("OpenCode Go: key via {source}"),
        None => "OpenCode Go: no opencode-go sign-in or OPENCODE_APIKEY".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_go_windows_and_fractional_reset() {
        let body = serde_json::json!({"usage": {
            "rolling": {"percent": 16.5, "resetsAt": "2026-09-24T12:31:06.611Z"},
            "weekly": {"percent": 10, "resetsAt": "2026-09-27T00:00:00Z"}
        }});
        let windows = windows_from(&body);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].id, "rolling");
        assert!((windows[0].used - 0.165).abs() < 0.00001);
        assert!(windows[0].resets_at.unwrap() > 0);
    }

    #[test]
    fn accepts_only_opencode_go_credentials() {
        let other = serde_json::json!({"zai": {"type": "api", "key": "other-plan"}});
        assert_eq!(token_from_json(&other), None);
        let go = serde_json::json!({"opencode-go": {"type": "api", "key": "go-plan"}});
        assert_eq!(token_from_json(&go).as_deref(), Some("go-plan"));
        let direct = serde_json::json!({"opencode-go": "go-plan"});
        assert_eq!(token_from_json(&direct).as_deref(), Some("go-plan"));
    }
}
