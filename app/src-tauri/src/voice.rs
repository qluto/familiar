// Optional speech servers, set like Hermes Agent: a base URL up to `/v1`, an API key, and a model (and a voice for speech).
// Both speak the OpenAI audio API, so OpenAI itself or a local server (whisper.cpp, Speaches, Kokoro-FastAPI, ...) works.
// Requests go out from here, so the pages never send the key anywhere themselves.
use std::time::Duration;
use serde_json::{json, Map, Value};
use tauri::ipc::{InvokeBody, Request, Response};

use crate::{read_config, save_config};

pub mod realtime;

pub const DEFAULT_STT_MODEL: &str = "whisper-1";
pub const DEFAULT_TTS_MODEL: &str = "gpt-4o-mini-tts";
pub const DEFAULT_VOICE: &str = "alloy";
const MAX_SPEECH_CHARS: usize = 4000; // OpenAI takes up to 4096 characters per request

#[derive(Clone, Copy, PartialEq)]
enum Kind { Stt, Tts }

impl Kind {
    fn parse(kind: &str) -> Result<Self, String> {
        match kind { "stt" => Ok(Kind::Stt), "tts" => Ok(Kind::Tts), _ => Err("invalid voice kind".into()) }
    }
    fn key(self) -> &'static str { if self == Kind::Stt { "stt" } else { "tts" } }
}

/// One server as saved. An empty base URL means the feature is off.
#[derive(Debug, PartialEq)]
struct Server { base_url: String, api_key: String, model: String, voice: String }

fn field(entry: &Map<String, Value>, name: &str) -> String {
    entry.get(name).and_then(Value::as_str).unwrap_or_default().trim().to_string()
}

fn saved(config: &Map<String, Value>, kind: Kind) -> Option<Map<String, Value>> {
    config.get("voice")?.get(kind.key())?.as_object().cloned()
}

/// The server in use, with defaults filled in. None while it is not set.
fn server(kind: Kind) -> Result<Option<Server>, String> {
    Ok(in_use(&read_config()?, kind))
}

fn in_use(config: &Map<String, Value>, kind: Kind) -> Option<Server> {
    let entry = saved(config, kind)?;
    let base_url = field(&entry, "baseUrl").trim_end_matches('/').to_string();
    if base_url.is_empty() { return None; }
    let or = |value: String, default: &str| if value.is_empty() { default.to_string() } else { value };
    let default_model = if kind == Kind::Stt { DEFAULT_STT_MODEL } else { DEFAULT_TTS_MODEL };
    Some(Server {
        base_url,
        api_key: field(&entry, "apiKey"),
        model: or(field(&entry, "model"), default_model),
        voice: or(field(&entry, "voice"), DEFAULT_VOICE),
    })
}

fn check_url(url: &str) -> Result<(), String> {
    if url.is_empty() || url.starts_with("http://") || url.starts_with("https://") { Ok(()) }
    else { Err("サーバの URL は http:// か https:// で始めてください".into()) }
}

/// Transcribes while you speak over the Realtime API, instead of uploading the recording after.
fn live(entry: &Map<String, Value>) -> bool { entry.get("realtime").and_then(Value::as_bool).unwrap_or(false) }

/// Reads replies aloud. On unless turned off, so a server set before this switch keeps speaking.
fn speaks(entry: &Map<String, Value>) -> bool { entry.get("speak").and_then(Value::as_bool).unwrap_or(true) }

/// Which features are on, for the conversation.
#[tauri::command]
pub fn voice() -> Result<Value, String> {
    let config = read_config()?;
    let stt = in_use(&config, Kind::Stt).is_some();
    let realtime = stt && saved(&config, Kind::Stt).is_some_and(|e| live(&e));
    let tts = in_use(&config, Kind::Tts).is_some() && saved(&config, Kind::Tts).is_some_and(|e| speaks(&e));
    Ok(json!({ "stt": stt, "realtime": realtime, "tts": tts, "rate": realtime::RATE }))
}

/// The fields as saved, for the settings page.
#[tauri::command]
pub fn voice_settings() -> Result<Value, String> {
    let config = read_config()?;
    let entry = |kind| {
        let e = saved(&config, kind).unwrap_or_default();
        json!({ "baseUrl": field(&e, "baseUrl"), "apiKey": field(&e, "apiKey"), "model": field(&e, "model"), "voice": field(&e, "voice"), "realtime": live(&e), "speak": speaks(&e) })
    };
    Ok(json!({ "stt": entry(Kind::Stt), "tts": entry(Kind::Tts) }))
}

#[tauri::command]
pub fn set_voice(kind: String, fields: Map<String, Value>) -> Result<Value, String> {
    let kind = Kind::parse(&kind)?;
    let mut entry = Map::new();
    for name in ["baseUrl", "apiKey", "model", "voice"] {
        if kind == Kind::Stt && name == "voice" { continue; }
        entry.insert(name.into(), json!(field(&fields, name)));
    }
    match kind {
        Kind::Stt => entry.insert("realtime".into(), json!(live(&fields))),
        Kind::Tts => entry.insert("speak".into(), json!(speaks(&fields))),
    };
    check_url(&field(&entry, "baseUrl"))?;
    let mut voice = read_config()?.get("voice").and_then(Value::as_object).cloned().unwrap_or_default();
    voice.insert(kind.key().into(), Value::Object(entry));
    save_config("voice", Value::Object(voice))?;
    voice_settings()
}

fn client() -> Result<reqwest::Client, String> {
    // The updater installs the same provider. Whichever runs first wins; both are ring.
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder().timeout(Duration::from_secs(90)).build().map_err(|e| e.to_string())
}

fn authorized(request: reqwest::RequestBuilder, server: &Server) -> reqwest::RequestBuilder {
    if server.api_key.is_empty() { request } else { request.bearer_auth(&server.api_key) }
}

/// A failed request as a sentence, with the server's own message when it gave one.
async fn failure(what: &str, response: reqwest::Response) -> String {
    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    let detail = serde_json::from_str::<Value>(&body).ok()
        .and_then(|v| v.pointer("/error/message").or(v.get("detail")).or(v.get("error")).cloned())
        .map(|v| v.as_str().map(String::from).unwrap_or_else(|| v.to_string()))
        .unwrap_or_else(|| body.chars().take(200).collect());
    format!("{what}のサーバがエラーを返しました（{status}）: {detail}")
}

fn unreachable(what: &str, e: reqwest::Error) -> String {
    if e.is_timeout() { format!("{what}のサーバから返事がありません") } else { format!("{what}のサーバにつながりません: {e}") }
}

/// MediaRecorder in WebKit records AAC in MP4. Servers pick the decoder from the file name.
fn file_name(mime: &str) -> &'static str {
    match mime.split(';').next().unwrap_or_default().trim() {
        "audio/webm" => "speech.webm",
        "audio/ogg" => "speech.ogg",
        "audio/wav" | "audio/x-wav" => "speech.wav",
        "audio/mpeg" => "speech.mp3",
        _ => "speech.m4a",
    }
}

/// The recording comes as the raw request body, its type in the `content-type` header.
#[tauri::command]
pub async fn transcribe(request: Request<'_>) -> Result<String, String> {
    let InvokeBody::Raw(audio) = request.body() else { return Err("音声がありません".into()) };
    let mime = request.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("audio/mp4").to_string();
    let server = server(Kind::Stt)?.ok_or("音声認識のサーバが設定されていません")?;
    transcription(&server, audio.clone(), &mime).await
}

async fn transcription(server: &Server, audio: Vec<u8>, mime: &str) -> Result<String, String> {
    let part = reqwest::multipart::Part::bytes(audio).file_name(file_name(mime))
        .mime_str(mime).map_err(|e| e.to_string())?;
    let form = reqwest::multipart::Form::new().part("file", part).text("model", server.model.clone()).text("response_format", "json");
    let request = client()?.post(format!("{}/audio/transcriptions", server.base_url)).multipart(form);
    let response = authorized(request, server).send().await.map_err(|e| unreachable("音声認識", e))?;
    if !response.status().is_success() { return Err(failure("音声認識", response).await); }
    let body: Value = response.json().await.map_err(|e| format!("音声認識の返事を読めません: {e}"))?;
    Ok(body.get("text").and_then(Value::as_str).unwrap_or_default().trim().to_string())
}

/// MP3 bytes of `text` read aloud. Every OpenAI-compatible server accepts MP3, and WebKit plays it.
#[tauri::command]
pub async fn speak(text: String) -> Result<Response, String> {
    let server = server(Kind::Tts)?.ok_or("音声合成のサーバが設定されていません")?;
    speech(&server, &text).await.map(Response::new)
}

async fn speech(server: &Server, text: &str) -> Result<Vec<u8>, String> {
    let input: String = text.trim().chars().take(MAX_SPEECH_CHARS).collect();
    if input.is_empty() { return Ok(Vec::new()); }
    let body = json!({ "model": server.model, "voice": server.voice, "input": input, "response_format": "mp3" });
    let request = client()?.post(format!("{}/audio/speech", server.base_url)).json(&body);
    let response = authorized(request, server).send().await.map_err(|e| unreachable("音声合成", e))?;
    if !response.status().is_success() { return Err(failure("音声合成", response).await); }
    let audio = response.bytes().await.map_err(|e| unreachable("音声合成", e))?;
    Ok(audio.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_web_urls_are_saved() {
        assert!(check_url("").is_ok());
        assert!(check_url("http://localhost:8000/v1").is_ok());
        assert!(check_url("https://api.openai.com/v1").is_ok());
        assert!(check_url("localhost:8000").is_err());
        assert!(check_url("file:///etc/passwd").is_err());
    }

    #[test]
    fn recordings_keep_their_container() {
        assert_eq!(file_name("audio/mp4"), "speech.m4a");
        assert_eq!(file_name("audio/webm;codecs=opus"), "speech.webm");
        assert_eq!(file_name(""), "speech.m4a");
    }

    /// A one-request OpenAI-compatible server. Returns its base URL and the raw request it got.
    fn fake(status: &str, content_type: &str, body: &'static [u8]) -> (String, std::sync::mpsc::Receiver<String>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}/v1/", listener.local_addr().unwrap()); // a trailing slash is allowed
        let (tx, rx) = std::sync::mpsc::channel();
        let head = format!("HTTP/1.1 {status}\r\ncontent-type: {content_type}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n", body.len());
        std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut got = Vec::new();
            let mut buf = [0u8; 8192];
            loop {
                let n = socket.read(&mut buf).unwrap();
                got.extend_from_slice(&buf[..n]);
                let text = String::from_utf8_lossy(&got).to_string();
                let Some(end) = text.find("\r\n\r\n") else { continue };
                let length = text.lines().find_map(|l| l.to_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap())).unwrap_or(0);
                if got.len() >= end + 4 + length { break; }
            }
            socket.write_all(head.as_bytes()).unwrap();
            socket.write_all(body).unwrap();
            tx.send(String::from_utf8_lossy(&got).into_owned()).unwrap();
        });
        (base, rx)
    }

    fn configured(kind: Kind, base: &str, key: &str) -> Server {
        let config = json!({ "voice": { kind.key(): { "baseUrl": base, "apiKey": key } } });
        in_use(config.as_object().unwrap(), kind).unwrap()
    }

    #[test]
    fn unset_or_empty_url_is_off() {
        assert!(in_use(&Map::new(), Kind::Stt).is_none());
        let config = json!({ "voice": { "tts": { "baseUrl": "  ", "model": "x" } } });
        assert!(in_use(config.as_object().unwrap(), Kind::Tts).is_none());
    }

    #[test]
    fn reading_aloud_is_on_until_turned_off() {
        let entry = |v: Value| v.as_object().unwrap().clone();
        assert!(speaks(&entry(json!({ "baseUrl": "http://x/v1" }))));
        assert!(!speaks(&entry(json!({ "speak": false }))));
    }

    #[test]
    fn speech_posts_openai_body_and_returns_audio() {
        let (base, rx) = fake("200 OK", "audio/mpeg", b"ID3fake-mp3");
        let server = configured(Kind::Tts, &base, "sk-test");
        let audio = tauri::async_runtime::block_on(speech(&server, "  こんにちは  ")).unwrap();
        assert_eq!(audio, b"ID3fake-mp3");
        let request = rx.recv().unwrap();
        assert!(request.starts_with("POST /v1/audio/speech "), "{request}");
        assert!(request.to_lowercase().contains("authorization: bearer sk-test"));
        let body: Value = serde_json::from_str(&request[request.find("\r\n\r\n").unwrap() + 4..]).unwrap();
        assert_eq!(body, json!({ "model": DEFAULT_TTS_MODEL, "voice": DEFAULT_VOICE, "input": "こんにちは", "response_format": "mp3" }));
    }

    #[test]
    fn transcription_uploads_the_recording_without_a_key() {
        let (base, rx) = fake("200 OK", "application/json", r#"{"text":" 明日の予定を教えて "}"#.as_bytes());
        let server = configured(Kind::Stt, &base, "");
        let text = tauri::async_runtime::block_on(transcription(&server, b"fake-aac".to_vec(), "audio/mp4")).unwrap();
        assert_eq!(text, "明日の予定を教えて");
        let request = rx.recv().unwrap();
        assert!(request.starts_with("POST /v1/audio/transcriptions "), "{request}");
        assert!(!request.to_lowercase().contains("authorization:"));
        assert!(request.contains("filename=\"speech.m4a\"") && request.contains("fake-aac"));
        assert!(request.contains("name=\"model\"\r\n\r\nwhisper-1"));
    }

    #[test]
    fn server_errors_carry_their_message() {
        let (base, _rx) = fake("401 Unauthorized", "application/json", br#"{"error":{"message":"Incorrect API key provided"}}"#);
        let server = configured(Kind::Tts, &base, "bad");
        let error = tauri::async_runtime::block_on(speech(&server, "test")).unwrap_err();
        assert!(error.contains("401") && error.contains("Incorrect API key provided"), "{error}");
    }

    #[test]
    fn unreachable_server_is_reported() {
        let server = configured(Kind::Stt, "http://127.0.0.1:9/v1", "");
        let error = tauri::async_runtime::block_on(transcription(&server, vec![1], "audio/mp4")).unwrap_err();
        assert!(error.contains("つながりません"), "{error}");
    }
}
