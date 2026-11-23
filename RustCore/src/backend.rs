use std::sync::mpsc as std_mpsc;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use tokio::runtime::Builder;
use tokio::sync::{mpsc as tokio_mpsc, watch};
use tokio::time::sleep;

use crate::audio_sink::AudioFrameSink;
use crate::auth::AuthBundle;
use crate::channels::{InputFrame, KeyboardFrame, MouseFrame, RumbleData};
use crate::error::NanoError;
use crate::protocol::{IceServer, PeerConnectionPlan, SessionBlueprint, StreamRequest};
use crate::session::NanoWebRtcSession;
use crate::signaling::NanoHttpSignalingClient;
use crate::stats::StreamStats;
use crate::video_sink::VideoFrameSink;
use crate::webrtc_backend::{PeerStatsBaseline, RealNanoPeerConnection};

pub trait SessionEventSink {
    fn update_status(&self, stage: &str, message: &str, terminal: bool);
    fn update_stats(&self, stats: &StreamStats);
    fn on_rumble(&self, _rumble: RumbleData) {}
}

#[derive(Clone)]
pub struct NanoSessionConfig {
    pub auth: AuthBundle,
    pub request: StreamRequest,
    pub stereo_audio_enabled: bool,
    pub max_touchpoints: u8,
    pub coop: bool,
    pub network_mode: u8, // 0=auto (IPv4+IPv6), 1=IPv4 only, 2=IPv6 only
    pub max_video_delay_ms: u64,
    pub max_video_bitrate_kbps: u32,
    pub force_region_ip: Option<String>,
    pub extra_ice_servers: Vec<IceServer>,
    pub video_sink: Option<Arc<dyn VideoFrameSink + Send + Sync>>,
    pub audio_sink: Option<Arc<dyn AudioFrameSink + Send + Sync>>,
    pub event_sink: Option<Arc<dyn SessionEventSink + Send + Sync>>,
}

#[derive(Debug, Clone)]
enum AuxInputCommand {
    GamepadConnected { index: u8, connected: bool },
    Mouse(MouseFrame),
    Keyboard(KeyboardFrame),
}

#[derive(Debug)]
pub struct NanoSessionHandle {
    stop_tx: watch::Sender<bool>,
    input_tx: tokio_mpsc::UnboundedSender<InputFrame>,
    aux_tx: tokio_mpsc::UnboundedSender<AuxInputCommand>,
    keyframe_tx: tokio_mpsc::UnboundedSender<()>,
    mic_tx: tokio_mpsc::UnboundedSender<(Vec<u8>, u32)>,
    join_handle: Option<thread::JoinHandle<Result<(), NanoError>>>,
}

impl NanoSessionHandle {
    pub fn start(config: NanoSessionConfig) -> Result<Self, NanoError> {
        let (stop_tx, stop_rx) = watch::channel(false);
        let (input_tx, input_rx) = tokio_mpsc::unbounded_channel();
        let (aux_tx, aux_rx) = tokio_mpsc::unbounded_channel();
        let (keyframe_tx, keyframe_rx) = tokio_mpsc::unbounded_channel();
        let (mic_tx, mic_rx) = tokio_mpsc::unbounded_channel();
        let (ready_tx, ready_rx) = std_mpsc::channel();
        crate::nano_log!("session-handle start thread");

        let event_sink = config.event_sink.clone();
        let join_handle = thread::spawn(move || {
            let runtime = Builder::new_multi_thread()
                .enable_all()
                .worker_threads(4)
                .thread_name("nano-web-rtc")
                .build()
                .map_err(|error| NanoError::RuntimeMessage(error.to_string()))?;

            let _ = ready_tx.send(Ok(()));
            let result = runtime.block_on(run_session(
                config,
                stop_rx,
                input_rx,
                aux_rx,
                keyframe_rx,
                mic_rx,
            ));
            if let Err(error) = &result {
                crate::nano_error!("run-session failed: {error}");
                if let Some(event_sink) = event_sink.as_ref() {
                    event_sink.update_status("failed", &error.to_string(), true);
                }
            } else {
                crate::nano_log!("run-session finished");
            }
            result
        });

        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(Ok(())) => Ok(Self {
                stop_tx,
                input_tx,
                aux_tx,
                keyframe_tx,
                mic_tx,
                join_handle: Some(join_handle),
            }),
            Ok(Err(error)) => {
                let _ = stop_tx.send(true);
                let _ = join_handle.join();
                Err(error)
            }
            Err(_) => Ok(Self {
                stop_tx,
                input_tx,
                aux_tx,
                keyframe_tx,
                mic_tx,
                join_handle: Some(join_handle),
            }),
        }
    }

    pub fn send_gamepad_frame(&self, frame: InputFrame) -> Result<(), NanoError> {
        self.input_tx
            .send(frame)
            .map_err(|_| NanoError::RuntimeMessage("nano input channel closed".to_owned()))
    }

    pub fn set_gamepad_connected(&self, index: u8, connected: bool) -> Result<(), NanoError> {
        self.aux_tx
            .send(AuxInputCommand::GamepadConnected { index, connected })
            .map_err(|_| NanoError::RuntimeMessage("nano aux channel closed".to_owned()))
    }

    pub fn send_mouse_frame(&self, frame: MouseFrame) -> Result<(), NanoError> {
        self.aux_tx
            .send(AuxInputCommand::Mouse(frame))
            .map_err(|_| NanoError::RuntimeMessage("nano aux channel closed".to_owned()))
    }

    pub fn send_keyboard_frame(&self, frame: KeyboardFrame) -> Result<(), NanoError> {
        self.aux_tx
            .send(AuxInputCommand::Keyboard(frame))
            .map_err(|_| NanoError::RuntimeMessage("nano aux channel closed".to_owned()))
    }

    pub fn request_keyframe(&self) -> Result<(), NanoError> {
        self.keyframe_tx
            .send(())
            .map_err(|_| NanoError::RuntimeMessage("nano keyframe channel closed".to_owned()))
    }

    pub fn send_mic_opus(&self, data: Vec<u8>, duration_ms: u32) -> Result<(), NanoError> {
        self.mic_tx
            .send((data, duration_ms))
            .map_err(|_| NanoError::RuntimeMessage("nano mic channel closed".to_owned()))
    }

    pub fn stop(&mut self) -> Result<(), NanoError> {
        let _ = self.stop_tx.send(true);
        if let Some(join_handle) = self.join_handle.take() {
            match join_handle.join() {
                Ok(result) => result,
                Err(_) => Err(NanoError::RuntimeMessage(
                    "nano session thread panicked".to_owned(),
                )),
            }
        } else {
            Ok(())
        }
    }
}

async fn run_session(
    config: NanoSessionConfig,
    mut stop_rx: watch::Receiver<bool>,
    mut input_rx: tokio_mpsc::UnboundedReceiver<InputFrame>,
    mut aux_rx: tokio_mpsc::UnboundedReceiver<AuxInputCommand>,
    mut keyframe_rx: tokio_mpsc::UnboundedReceiver<()>,
    mut mic_rx: tokio_mpsc::UnboundedReceiver<(Vec<u8>, u32)>,
) -> Result<(), NanoError> {
    crate::nano_log!("run-session start");
    emit_status(
        config.event_sink.as_ref(),
        "connecting",
        "正在向 Xbox 请求串流会话...",
        false,
    );
    let mut session = NanoWebRtcSession::from_request(&config.auth, config.request.clone())?;
    session.start();
    crate::nano_log!("run-session initialized");

    let forwarded_ip = if session.blueprint().platform == crate::auth::Platform::Cloud {
        config.force_region_ip.clone()
    } else {
        None
    };
    let signaling = NanoHttpSignalingClient::with_forwarded_for(forwarded_ip)?;
    let mut request = session.play_request();
    if request.body.is_none() {
        request.body = Some(session.blueprint().play_body().to_json());
    }
    crate::nano_log!("run-session play request");
    let play_response = signaling.play(request).await?;
    session.record_play_response_body(play_response)?;
    crate::nano_log!("run-session play response recorded");

    let connect_sent = wait_for_provisioned_state(
        &signaling,
        &mut session,
        &mut stop_rx,
        config.event_sink.as_ref(),
    )
    .await?;
    crate::nano_log!("run-session provisioned connectSent={connect_sent}");

    let configuration = signaling
        .configuration(session.build_configuration_request()?)
        .await?;
    session.record_configuration(configuration);
    crate::nano_log!("run-session configuration recorded");
    emit_status(
        config.event_sink.as_ref(),
        "configuration",
        "会话配置就绪，正在协商 WebRTC...",
        false,
    );

    let peer_plan = build_peer_plan(session.blueprint(), &config);
    let is_home_platform = session.blueprint().platform == crate::auth::Platform::Home;
    let has_custom_ice = !config.extra_ice_servers.is_empty();
    let peer = RealNanoPeerConnection::new(
        &peer_plan,
        config.max_touchpoints,
        config.coop,
        config.network_mode,
        is_home_platform,
        has_custom_ice,
        config.max_video_delay_ms,
        config.max_video_bitrate_kbps,
        config.video_sink.clone(),
        config.audio_sink.clone(),
        config.event_sink.clone(),
    )
    .await?;
    crate::nano_log!("run-session peer created");
    let input_peer = peer.clone();
    tokio::spawn(async move {
        while let Some(mut frame) = input_rx.recv().await {
            // Coalesce queued stick-only updates for the SAME player slot only,
            // never dropping button transitions or overwriting another player's slot.
            let initial_buttons = button_signature(&frame);
            let mut deferred: Option<InputFrame> = None;
            while let Ok(next) = input_rx.try_recv() {
                if next.gamepad_index != frame.gamepad_index {
                    deferred = Some(next);
                    break;
                }
                let next_buttons = button_signature(&next);
                frame = next;
                if next_buttons != initial_buttons {
                    break;
                }
            }
            if let Err(error) = input_peer.send_gamepad_frame(frame).await {
                crate::nano_warn!("input gamepad frame send failed: {error}");
            }
            if let Some(other_player) = deferred {
                if let Err(error) = input_peer.send_gamepad_frame(other_player).await {
                    crate::nano_warn!("input gamepad frame send failed: {error}");
                }
            }
        }
        crate::nano_log!("input gamepad frame loop stopped");
    });

    let aux_peer = peer.clone();
    tokio::spawn(async move {
        while let Some(cmd) = aux_rx.recv().await {
            match cmd {
                AuxInputCommand::GamepadConnected { index, connected } => {
                    if let Err(error) = aux_peer.set_gamepad_connected(index, connected).await {
                        crate::nano_warn!("gamepad_changed send failed: {error}");
                    }
                }
                AuxInputCommand::Mouse(frame) => {
                    if let Err(error) = aux_peer.send_mouse_frame(frame).await {
                        crate::nano_warn!("mouse frame send failed: {error}");
                    }
                }
                AuxInputCommand::Keyboard(frame) => {
                    if let Err(error) = aux_peer.send_keyboard_frame(frame).await {
                        crate::nano_warn!("keyboard frame send failed: {error}");
                    }
                }
            }
        }
    });

    let keyframe_peer = peer.clone();
    tokio::spawn(async move {
        while keyframe_rx.recv().await.is_some() {
            keyframe_peer.request_keyframe().await;
        }
    });

    let mic_peer = peer.clone();
    tokio::spawn(async move {
        while let Some((opus_bytes, duration_ms)) = mic_rx.recv().await {
            // Drain stale buffered mic packets if network momentarily backed up
            let mut latest = (opus_bytes, duration_ms);
            let mut dropped = 0u32;
            while let Ok(next) = mic_rx.try_recv() {
                latest = next;
                dropped += 1;
                if dropped >= 4 {
                    break;
                }
            }
            if let Err(error) = mic_peer.send_mic_opus(latest.0, latest.1).await {
                crate::nano_warn!("mic opus write failed: {error}");
            }
        }
        crate::nano_log!("mic opus uplink loop stopped");
    });

    let offer_sdp = peer.create_offer(config.stereo_audio_enabled).await?;
    crate::nano_log!("run-session local offer created");
    signaling
        .post_sdp_offer(session.build_primary_sdp_offer_request(offer_sdp)?)
        .await?;
    crate::nano_log!("run-session local offer posted");

    let answer = wait_for_sdp_answer(&signaling, &session, &mut stop_rx).await?;
    emit_status(
        config.event_sink.as_ref(),
        "remote-offer",
        "远端 SDP 应答已收到...",
        false,
    );
    peer.set_remote_answer(&answer.sdp).await?;
    session.record_sdp_answer_response(answer)?;
    crate::nano_log!("run-session remote answer set");
    emit_status(
        config.event_sink.as_ref(),
        "ready-ice",
        "正在交换 ICE 候选通道...",
        false,
    );

    if let Some(event_sink) = config.event_sink.clone() {
        let stats_peer = peer.clone();
        let mut stats_stop_rx = stop_rx.clone();
        tokio::spawn(async move {
            run_stats_loop(stats_peer, event_sink, &mut stats_stop_rx).await;
        });
    }

    let local_candidates = peer.drain_local_candidates().await?;
    crate::nano_log!(
        "run-session posting local candidates count={}",
        local_candidates.len()
    );
    signaling
        .post_ice_candidates(session.build_ice_post_request(local_candidates)?)
        .await?;

    let mut remote_candidates = wait_for_remote_ice(&signaling, &session, &mut stop_rx).await?;
    if session.blueprint().platform == crate::auth::Platform::Home {
        remote_candidates =
            crate::teredo::expand_teredo_candidates(remote_candidates, config.network_mode != 1);
    }
    crate::nano_log!(
        "run-session remote candidates count={}",
        remote_candidates.len()
    );
    for candidate in remote_candidates {
        if let Err(error) = peer.add_remote_candidate(&candidate).await {
            crate::nano_warn!(
                "skip invalid remote candidate mid={} mline={}: {}",
                candidate.sdp_mid,
                candidate.sdp_mline_index,
                error
            );
            continue;
        }
        session.record_remote_candidate(candidate)?;
    }
    emit_status(
        config.event_sink.as_ref(),
        "ice-exchanged",
        "已交换 ICE 候选，正在穿透建立连接...",
        false,
    );

    if !connect_sent && session.blueprint().web_token().is_some() {
        signaling
            .connect(session.build_connect_request_from_web_token()?)
            .await?;
        session.connect()?;
        crate::nano_log!("run-session connect sent from web token");
    }

    let pulse = session
        .configuration()
        .map(|configuration| configuration.keep_alive_pulse_in_seconds)
        .unwrap_or(20)
        .max(5);
    crate::nano_log!("run-session keepalive interval seconds={pulse}");
    let mut keepalive = tokio::time::interval(Duration::from_secs(u64::from(pulse)));
    let mut consecutive_keepalive_errors = 0u32;

    loop {
        tokio::select! {
            _ = stop_rx.changed() => {
                break;
            }
            _ = keepalive.tick() => {
                crate::nano_log!("run-session keepalive");
                match signaling.keepalive(session.build_keepalive_request()?).await {
                    Ok(()) => {
                        consecutive_keepalive_errors = 0;
                    }
                    Err(error) => {
                        consecutive_keepalive_errors += 1;
                        crate::nano_warn!(
                            "keepalive error ({consecutive_keepalive_errors}/3): {error}"
                        );
                        if consecutive_keepalive_errors >= 3 {
                            let _ = signaling.stop(session.build_stop_request()?).await;
                            let _ = peer.close().await;
                            session.close();
                            return Err(error);
                        }
                    }
                }
            }
        }
    }

    crate::nano_log!("run-session stopping");
    let _ = signaling.stop(session.build_stop_request()?).await;
    let _ = peer.close().await;
    session.close();
    crate::nano_log!("run-session closed");
    Ok(())
}

fn emit_status(
    event_sink: Option<&Arc<dyn SessionEventSink + Send + Sync>>,
    stage: &str,
    message: &str,
    terminal: bool,
) {
    if let Some(event_sink) = event_sink {
        event_sink.update_status(stage, message, terminal);
    }
}

async fn run_stats_loop(
    peer: RealNanoPeerConnection,
    event_sink: Arc<dyn SessionEventSink + Send + Sync>,
    stop_rx: &mut watch::Receiver<bool>,
) {
    let mut baseline = PeerStatsBaseline::default();
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            _ = stop_rx.changed() => {
                break;
            }
            _ = interval.tick() => {
                let stats = peer.collect_stream_stats(&mut baseline).await;
                event_sink.update_stats(&stats);
            }
        }
    }
    crate::nano_log!("stats loop stopped");
}

async fn sleep_or_stop(duration: Duration, stop_rx: &mut watch::Receiver<bool>) -> Result<(), NanoError> {
    tokio::select! {
        _ = stop_rx.changed() => {
            if *stop_rx.borrow() {
                return Err(NanoError::RuntimeMessage("session stopped".to_owned()));
            }
        }
        _ = sleep(duration) => {}
    }
    Ok(())
}

async fn wait_for_provisioned_state(
    signaling: &NanoHttpSignalingClient,
    session: &mut NanoWebRtcSession,
    stop_rx: &mut watch::Receiver<bool>,
    event_sink: Option<&Arc<dyn SessionEventSink + Send + Sync>>,
) -> Result<bool, NanoError> {
    let mut connect_sent = false;
    let started = std::time::Instant::now();
    let max_wait = if session.blueprint().platform == crate::auth::Platform::Cloud {
        Duration::from_secs(180)
    } else {
        Duration::from_secs(45)
    };
    let mut poll_step: u32 = 0;

    loop {
        if *stop_rx.borrow() {
            return Err(NanoError::RuntimeMessage("session stopped".to_owned()));
        }
        if started.elapsed() > max_wait {
            return Err(NanoError::SignalingOwned("等待主机串流就绪超时，请检查主机状态后重试".to_owned()));
        }

        let state = signaling.state(session.build_state_request()?).await?;
        if let Some(transfer_uri) = state.transfer_uri.as_deref() {
            if !transfer_uri.trim().is_empty() {
                session.set_base_uri(transfer_uri.to_owned());
            }
        }
        crate::nano_log!("state poll state={}", state.state);
        poll_step = poll_step.saturating_add(1);
        let fast_delay = if poll_step <= 4 {
            Duration::from_millis(350)
        } else {
            Duration::from_millis(750)
        };
        match state.state.as_str() {
            "Provisioned" => return Ok(connect_sent),
            "WaitingForResources" => {
                emit_status(event_sink, "queueing", "正在排队分配云端主机...", false);
                sleep_or_stop(Duration::from_secs(1), stop_rx).await?;
            }
            "Provisioning" => {
                emit_status(event_sink, "provisioning", "主机正在准备串流环境...", false);
                sleep_or_stop(fast_delay, stop_rx).await?;
            }
            "ReadyToConnect" => {
                emit_status(event_sink, "authenticating", "正在校验账户串流授权...", false);
                if !connect_sent && session.blueprint().web_token().is_some() {
                    signaling
                        .connect(session.build_connect_request_from_web_token()?)
                        .await?;
                    connect_sent = true;
                }
                sleep_or_stop(Duration::from_millis(300), stop_rx).await?;
            }
            "Failed" => {
                crate::nano_error!(
                    "state failed message={}",
                    state.error_message.as_deref().unwrap_or("unknown")
                );
                return Err(NanoError::SignalingOwned(
                    state
                        .error_message
                        .unwrap_or_else(|| "streaming failed".to_owned()),
                ));
            }
            _ => {
                sleep_or_stop(fast_delay, stop_rx).await?;
            }
        }
    }
}

async fn wait_for_sdp_answer(
    signaling: &NanoHttpSignalingClient,
    session: &NanoWebRtcSession,
    stop_rx: &mut watch::Receiver<bool>,
) -> Result<crate::protocol::SdpExchangeResponse, NanoError> {
    let started = std::time::Instant::now();
    let mut attempt: u32 = 0;
    loop {
        if *stop_rx.borrow() {
            return Err(NanoError::RuntimeMessage("session stopped".to_owned()));
        }
        if started.elapsed() > Duration::from_secs(25) {
            return Err(NanoError::SignalingOwned("等待远端 SDP 应答超时".to_owned()));
        }
        match signaling
            .poll_sdp_answer(session.build_sdp_poll_request()?)
            .await
        {
            Ok(answer) => {
                crate::nano_log!("sdp answer received");
                return Ok(answer);
            }
            Err(NanoError::Json(_)) => {
                attempt = attempt.saturating_add(1);
                let delay = if attempt <= 5 {
                    Duration::from_millis(200)
                } else {
                    Duration::from_millis(450)
                };
                sleep_or_stop(delay, stop_rx).await?;
            }
            Err(error) => {
                crate::nano_error!("sdp answer poll failed: {error}");
                return Err(error);
            }
        }
    }
}

async fn wait_for_remote_ice(
    signaling: &NanoHttpSignalingClient,
    session: &NanoWebRtcSession,
    stop_rx: &mut watch::Receiver<bool>,
) -> Result<Vec<crate::protocol::IceCandidate>, NanoError> {
    let started = std::time::Instant::now();
    let mut attempt: u32 = 0;
    loop {
        if *stop_rx.borrow() {
            return Err(NanoError::RuntimeMessage("session stopped".to_owned()));
        }
        if started.elapsed() > Duration::from_secs(25) {
            return Err(NanoError::SignalingOwned("等待远端 ICE 候选地址超时".to_owned()));
        }
        match signaling
            .poll_ice_candidates(session.build_ice_poll_request()?)
            .await
        {
            Ok(candidates) if !candidates.is_empty() => {
                crate::nano_log!("remote ice received count={}", candidates.len());
                return Ok(candidates);
            }
            Ok(_) | Err(NanoError::Json(_)) => {
                attempt = attempt.saturating_add(1);
                let delay = if attempt <= 5 {
                    Duration::from_millis(200)
                } else {
                    Duration::from_millis(450)
                };
                sleep_or_stop(delay, stop_rx).await?;
            }
            Err(error) => {
                crate::nano_error!("remote ice poll failed: {error}");
                return Err(error);
            }
        }
    }
}

fn button_signature(f: &InputFrame) -> u16 {
    let mut mask = 0u16;
    if f.nexus > 0 { mask |= 1 << 0; }
    if f.menu > 0 { mask |= 1 << 1; }
    if f.view > 0 { mask |= 1 << 2; }
    if f.a > 0 { mask |= 1 << 3; }
    if f.b > 0 { mask |= 1 << 4; }
    if f.x > 0 { mask |= 1 << 5; }
    if f.y > 0 { mask |= 1 << 6; }
    if f.dpad_up > 0 { mask |= 1 << 7; }
    if f.dpad_down > 0 { mask |= 1 << 8; }
    if f.dpad_left > 0 { mask |= 1 << 9; }
    if f.dpad_right > 0 { mask |= 1 << 10; }
    if f.left_shoulder > 0 { mask |= 1 << 11; }
    if f.right_shoulder > 0 { mask |= 1 << 12; }
    if f.left_thumb > 0 { mask |= 1 << 13; }
    if f.right_thumb > 0 { mask |= 1 << 14; }
    mask
}

fn build_peer_plan(
    blueprint: &SessionBlueprint,
    config: &NanoSessionConfig,
) -> PeerConnectionPlan {
    let mut plan = blueprint.peer.clone();
    if !config.extra_ice_servers.is_empty() {
        plan.ice_servers.extend(config.extra_ice_servers.clone());
    }
    plan
}
