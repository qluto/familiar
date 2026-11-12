// Live transcription over the Realtime API's WebSocket (`GET {base}/realtime?intent=transcription`), as OpenAI and
// Echo serve it. The page sends 24 kHz PCM16 while you speak; the text so far comes back as `listen-text` events,
// and stopping commits the turn and waits for the whole transcript.
// The socket opens from here: Echo refuses sockets that carry a web page's Origin, and the key stays out of the page.
use std::{sync::{Arc, Mutex}, time::Duration};
use base64::Engine as _;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tauri::{ipc::{InvokeBody, Request}, Emitter, State, WebviewWindow};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, http::HeaderValue, Message};

use super::{server, Kind, Server};

pub const RATE: u32 = 24_000; // OpenAI's rate for audio/pcm
const FINISH_TIMEOUT: Duration = Duration::from_secs(60);

enum Out { Audio(Vec<u8>), Commit }

/// The open turn. Dropping `outgoing` without a commit clears the turn and closes the socket.
struct Live { outgoing: mpsc::UnboundedSender<Out>, done: oneshot::Receiver<Result<String, String>> }

#[derive(Default)]
pub struct Listening(Mutex<Option<Live>>);

fn socket_url(base_url: &str) -> Result<String, String> {
    let rest = base_url.strip_prefix("https://").map(|r| format!("wss://{r}"))
        .or_else(|| base_url.strip_prefix("http://").map(|r| format!("ws://{r}")))
        .ok_or("サーバの URL は http:// か https:// で始めてください")?;
    Ok(format!("{rest}/realtime?intent=transcription"))
}

/// The session as OpenAI's GA Realtime API takes it. Turns end when we commit, not on the server's VAD.
fn session_update(server: &Server) -> Value {
    json!({ "type": "session.update", "session": { "type": "transcription", "audio": { "input": {
        "format": { "type": "audio/pcm", "rate": RATE },
        "transcription": { "model": server.model },
        "turn_detection": null,
    } } } })
}

/// The text so far for one server event, the transcript when the turn is done, or the error.
#[derive(Debug, PartialEq)]
enum Heard { Nothing, Text(String), Done(String), Failed(String) }

fn heard(event: &Value, committed: &mut String) -> Heard {
    let message = |v: &Value| v.pointer("/error/message").and_then(Value::as_str).unwrap_or("理由は分かりません").to_string();
    match event["type"].as_str().unwrap_or_default() {
        // Final pieces, append-only
        "conversation.item.input_audio_transcription.delta" => {
            committed.push_str(event["delta"].as_str().unwrap_or_default());
            Heard::Text(committed.clone())
        }
        // Echo's draft: the committed text plus a tail that may still change
        "echo.transcription.draft" => Heard::Text(event["text"].as_str().unwrap_or_default().to_string()),
        "conversation.item.input_audio_transcription.completed" =>
            Heard::Done(event["transcript"].as_str().unwrap_or_default().trim().to_string()),
        "conversation.item.input_audio_transcription.failed" | "error" => Heard::Failed(message(event)),
        _ => Heard::Nothing,
    }
}

async fn run(
    socket: tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    mut outgoing: mpsc::UnboundedReceiver<Out>,
    window: WebviewWindow,
    done: oneshot::Sender<Result<String, String>>,
) {
    let (mut sink, mut stream) = socket.split();
    let mut committed = String::new();
    let result = loop {
        tokio::select! {
            out = outgoing.recv() => {
                let event = match out {
                    Some(Out::Audio(pcm)) => json!({ "type": "input_audio_buffer.append",
                        "audio": base64::engine::general_purpose::STANDARD.encode(pcm) }),
                    Some(Out::Commit) => json!({ "type": "input_audio_buffer.commit" }),
                    None => {
                        let _ = sink.send(Message::text(json!({ "type": "input_audio_buffer.clear" }).to_string())).await;
                        break Err("取り消しました".to_string());
                    }
                };
                if let Err(e) = sink.send(Message::text(event.to_string())).await { break Err(format!("音声認識のサーバとの接続が切れました: {e}")); }
            }
            incoming = stream.next() => match incoming {
                Some(Ok(Message::Text(text))) => {
                    let Ok(event) = serde_json::from_str::<Value>(text.as_str()) else { continue };
                    match heard(&event, &mut committed) {
                        Heard::Nothing => {}
                        Heard::Text(text) => { let _ = window.emit_to(window.label(), "listen-text", text); }
                        Heard::Done(text) => break Ok(text),
                        Heard::Failed(message) => break Err(format!("音声認識のサーバがエラーを返しました: {message}")),
                    }
                }
                Some(Ok(_)) => {}
                Some(Err(e)) => break Err(format!("音声認識のサーバとの接続が切れました: {e}")),
                None => break Err("音声認識のサーバが接続を閉じました".to_string()),
            }
        }
    };
    let _ = sink.close().await;
    let _ = done.send(result);
}

async fn connect(server: &Server) -> Result<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, String> {
    let url = socket_url(&server.base_url)?;
    let mut request = url.as_str().into_client_request().map_err(|e| e.to_string())?;
    if !server.api_key.is_empty() {
        let auth = HeaderValue::from_str(&format!("Bearer {}", server.api_key)).map_err(|_| "API キーに使えない文字があります")?;
        request.headers_mut().insert("authorization", auth);
    }
    let connector = if url.starts_with("wss://") {
        use rustls_platform_verifier::ConfigVerifierExt;
        let _ = rustls::crypto::ring::default_provider().install_default();
        let config = rustls::ClientConfig::with_platform_verifier().map_err(|e| e.to_string())?;
        Some(tokio_tungstenite::Connector::Rustls(Arc::new(config)))
    } else { None };
    let connecting = tokio_tungstenite::connect_async_tls_with_config(request, None, true, connector);
    let (socket, _) = tokio::time::timeout(Duration::from_secs(10), connecting).await
        .map_err(|_| "音声認識のサーバから返事がありません".to_string())?
        .map_err(|e| match e {
            tokio_tungstenite::tungstenite::Error::Http(r) => format!("音声認識のサーバが接続を断りました（{}）", r.status()),
            e => format!("音声認識のサーバにつながりません: {e}"),
        })?;
    Ok(socket)
}

/// Opens a turn and sends the session settings. A turn left open from before is dropped.
async fn start(server: &Server, window: WebviewWindow) -> Result<Live, String> {
    let mut socket = connect(server).await?;
    socket.send(Message::text(session_update(server).to_string())).await.map_err(|e| e.to_string())?;
    let (tx, rx) = mpsc::unbounded_channel();
    let (done_tx, done) = oneshot::channel();
    tauri::async_runtime::spawn(run(socket, rx, window, done_tx));
    Ok(Live { outgoing: tx, done })
}

#[tauri::command]
pub async fn listen_start(window: WebviewWindow, state: State<'_, Listening>) -> Result<(), String> {
    let server = server(Kind::Stt)?.ok_or("音声認識のサーバが設定されていません")?;
    let live = start(&server, window).await?;
    *state.0.lock().unwrap() = Some(live);
    Ok(())
}

/// 24 kHz PCM16 mono as the raw request body.
#[tauri::command]
pub fn listen_audio(request: Request<'_>, state: State<'_, Listening>) -> Result<(), String> {
    let InvokeBody::Raw(pcm) = request.body() else { return Err("音声がありません".into()) };
    let live = state.0.lock().unwrap();
    let live = live.as_ref().ok_or("聞き取りを始めていません")?;
    live.outgoing.send(Out::Audio(pcm.clone())).map_err(|_| "音声認識のサーバとの接続が切れました".to_string())
}

/// Ends the turn and returns the whole transcript.
#[tauri::command]
pub async fn listen_stop(state: State<'_, Listening>) -> Result<String, String> {
    let live = state.0.lock().unwrap().take().ok_or("聞き取りを始めていません")?;
    finish(live).await
}

async fn finish(live: Live) -> Result<String, String> {
    let _ = live.outgoing.send(Out::Commit);
    // `outgoing` stays alive until the answer comes, so the turn is not cleared meanwhile
    let result = tokio::time::timeout(FINISH_TIMEOUT, live.done).await;
    drop(live.outgoing);
    match result {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err("音声認識のサーバとの接続が切れました".into()),
        Err(_) => Err("音声認識のサーバから返事がありません".into()),
    }
}

#[tauri::command]
pub fn listen_cancel(state: State<'_, Listening>) { state.0.lock().unwrap().take(); }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_follows_the_base_url() {
        assert_eq!(socket_url("http://127.0.0.1:47700/v1").unwrap(), "ws://127.0.0.1:47700/v1/realtime?intent=transcription");
        assert_eq!(socket_url("https://api.openai.com/v1").unwrap(), "wss://api.openai.com/v1/realtime?intent=transcription");
        assert!(socket_url("localhost:1").is_err());
    }

    #[test]
    fn events_build_the_text_so_far() {
        let mut committed = String::new();
        let delta = |d: &str| json!({ "type": "conversation.item.input_audio_transcription.delta", "delta": d });
        assert_eq!(heard(&delta("明日の"), &mut committed), Heard::Text("明日の".into()));
        assert_eq!(heard(&json!({ "type": "echo.transcription.draft", "text": "明日の予定を" }), &mut committed), Heard::Text("明日の予定を".into()));
        assert_eq!(heard(&delta("予定を"), &mut committed), Heard::Text("明日の予定を".into()));
        assert_eq!(heard(&json!({ "type": "session.updated" }), &mut committed), Heard::Nothing);
        assert_eq!(heard(&json!({ "type": "conversation.item.input_audio_transcription.completed", "transcript": " 明日の予定を教えて " }), &mut committed),
            Heard::Done("明日の予定を教えて".into()));
        assert_eq!(heard(&json!({ "type": "error", "error": { "message": "bad rate" } }), &mut committed), Heard::Failed("bad rate".into()));
    }

    /// Against a running server: `ECHO_BASE=http://127.0.0.1:47700/v1 ECHO_TOKEN=... ECHO_PCM=speech.pcm`
    /// (24 kHz PCM16 mono) `cargo test realtime_end_to_end -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn realtime_end_to_end() {
        let server = Server {
            base_url: std::env::var("ECHO_BASE").unwrap(), api_key: std::env::var("ECHO_TOKEN").unwrap_or_default(),
            model: "gpt-4o-transcribe".into(), voice: String::new(),
        };
        let pcm = std::fs::read(std::env::var("ECHO_PCM").unwrap()).unwrap();
        tauri::async_runtime::block_on(async {
            let mut socket = connect(&server).await.unwrap();
            socket.send(Message::text(session_update(&server).to_string())).await.unwrap();
            for chunk in pcm.chunks(RATE as usize / 10 * 2) { // 100 ms, as the page sends
                let append = json!({ "type": "input_audio_buffer.append", "audio": base64::engine::general_purpose::STANDARD.encode(chunk) });
                socket.send(Message::text(append.to_string())).await.unwrap();
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            socket.send(Message::text(json!({ "type": "input_audio_buffer.commit" }).to_string())).await.unwrap();
            let mut committed = String::new();
            while let Some(Ok(message)) = socket.next().await {
                let Message::Text(text) = message else { continue };
                let event: Value = serde_json::from_str(text.as_str()).unwrap();
                match heard(&event, &mut committed) {
                    Heard::Text(t) => println!("text so far: {t}"),
                    Heard::Done(t) => { println!("DONE: {t}"); assert!(!t.is_empty()); return; }
                    Heard::Failed(e) => panic!("{e}"),
                    Heard::Nothing => println!("event: {}", event["type"]),
                }
            }
            panic!("closed without a transcript");
        });
    }
}
