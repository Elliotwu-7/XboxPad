use std::any::Any;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use bytes::Bytes;
use rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication;
use rtcp::payload_feedbacks::receiver_estimated_maximum_bitrate::ReceiverEstimatedMaximumBitrate;
use tokio::time::{sleep, timeout};
use webrtc::api::media_engine::{MediaEngine, MIME_TYPE_H264, MIME_TYPE_OPUS};
use webrtc::api::setting_engine::SettingEngine;
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_init::RTCDataChannelInit;
use webrtc::data_channel::data_channel_message::DataChannelMessage;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice::network_type::NetworkType;
use webrtc::ice::udp_mux::{UDPMux, UDPMuxDefault, UDPMuxParams};
use webrtc::ice::udp_network::UDPNetwork;
use webrtc::ice_transport::ice_candidate::{RTCIceCandidate, RTCIceCandidateInit};
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::interceptor::nack::responder::Responder as NackResponder;
use webrtc::interceptor::registry::Registry;
use webrtc::interceptor::report::sender::SenderReport;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::rtp_transceiver::rtp_codec::{
    RTCRtpCodecCapability, RTCRtpCodecParameters, RTCRtpHeaderExtensionCapability, RTPCodecType,
};
use webrtc::rtp_transceiver::rtp_receiver::RTCRtpReceiver;
use webrtc::rtp_transceiver::rtp_transceiver_direction::RTCRtpTransceiverDirection;
use webrtc::rtp_transceiver::{RTCPFeedback, RTCRtpTransceiverInit, TYPE_RTCP_FB_TRANSPORT_CC};
use webrtc::sdp::extmap::TRANSPORT_CC_URI;
use webrtc::stats::StatsReportType;
use webrtc::track::track_local::track_local_static_sample::TrackLocalStaticSample;
use webrtc::track::track_local::TrackLocal;
use webrtc::track::track_remote::TrackRemote;
use webrtc::util::{Conn, Error as UtilError};
use webrtc_media::Sample as MediaSample;

use crate::audio_sink::AudioFrameSink;
use crate::backend::SessionEventSink;
use crate::channels::{
    initial_system_ui_messages, parse_input_server_message, ControlMessage, InputFrame,
    InputPacket, KeyboardFrame, MessageHandshake, MetadataFrame, MouseFrame,
};
use crate::error::NanoError;
use crate::fast_rtcp::{AccurateReceiverReportBuilder, SmartNackGeneratorBuilder};
use crate::fast_twcc::FastTwccReceiverBuilder;
use crate::h264_depacketizer::LowLatencyH264Assembler;
use crate::protocol::{
    boost_video_bitrate_sdp, force_stereo_audio_sdp, IceCandidate, PeerConnectionPlan,
    TransceiverDirection,
};
use crate::session::MediaTrackKind;
use crate::stats::StreamStats;
use crate::video_sink::VideoFrameSink;

const CONTROL_ACCESS_KEY: &str = "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E";
const PROCESSED_FRAME_FEEDBACK_DECODE_MS: u32 = 10;
const VIDEO_PLI_REQUEST_MIN_INTERVAL: Duration = Duration::from_millis(380);
const DEFAULT_VIDEO_RTP_SAMPLE_MAX_DELAY_MS: u64 = 80;
const REMB_TARGET_BITRATE_BPS: f32 = 40_000_000.0;

#[derive(Debug)]
struct PeerSharedState {
    local_candidates: Mutex<Vec<IceCandidate>>,
    observed_tracks: Mutex<Vec<MediaTrackKind>>,
    message_ready: AtomicBool,
    input_ready: AtomicBool,
    keyframe_requested: AtomicBool,
    video_ssrc: AtomicU32,
    message_id: AtomicU64,
    message_cv: AtomicU64,
    input_sequence: AtomicU64,
    video_packets_received: AtomicU64,
    video_bytes_received: AtomicU64,
    video_packets_lost: AtomicU64,
    video_frames_received: AtomicU64,
    video_frames_dropped: AtomicU64,
    video_jitter_us: Arc<AtomicU64>,
    stun_rtt_us: Arc<AtomicU64>,
    stun_req_count: Arc<AtomicU64>,
    stun_resp_count: Arc<AtomicU64>,
    probe_rtt_us: Arc<AtomicU64>,
    nack_rtt_us: Arc<AtomicU64>,
    route_kind: Arc<AtomicU8>,
    is_true_lan: AtomicBool,
    remb_current_bps: AtomicU64,
    remb_sender_ssrc: u32,
    tuned_local_sig: AtomicU64,
    last_selected_pair: Mutex<String>,
    probe_target: Mutex<Option<(SocketAddr, bool)>>,
    probe_started: AtomicBool,
    rtt_diag_ticks: AtomicU64,
    has_custom_ice: bool,
    max_touchpoints: u8,
    coop: bool,
    max_video_delay_ms: u64,
    max_video_bitrate_kbps: u32,
}

impl PeerSharedState {
    fn new(
        max_touchpoints: u8,
        coop: bool,
        has_custom_ice: bool,
        max_video_delay_ms: u64,
        max_video_bitrate_kbps: u32,
    ) -> Self {
        let remb_sender_ssrc = ((Instant::now().elapsed().as_nanos() as u32) ^ 0x6C4E_3A91).max(1);
        Self {
            local_candidates: Mutex::new(Vec::new()),
            observed_tracks: Mutex::new(Vec::new()),
            message_ready: AtomicBool::new(false),
            input_ready: AtomicBool::new(false),
            keyframe_requested: AtomicBool::new(false),
            video_ssrc: AtomicU32::new(0),
            message_id: AtomicU64::new(1),
            message_cv: AtomicU64::new(1),
            input_sequence: AtomicU64::new(1),
            video_packets_received: AtomicU64::new(0),
            video_bytes_received: AtomicU64::new(0),
            video_packets_lost: AtomicU64::new(0),
            video_frames_received: AtomicU64::new(0),
            video_frames_dropped: AtomicU64::new(0),
            video_jitter_us: Arc::new(AtomicU64::new(0)),
            stun_rtt_us: Arc::new(AtomicU64::new(0)),
            stun_req_count: Arc::new(AtomicU64::new(0)),
            stun_resp_count: Arc::new(AtomicU64::new(0)),
            probe_rtt_us: Arc::new(AtomicU64::new(0)),
            nack_rtt_us: Arc::new(AtomicU64::new(0)),
            route_kind: Arc::new(AtomicU8::new(0)),
            is_true_lan: AtomicBool::new(false),
            remb_current_bps: AtomicU64::new(0),
            remb_sender_ssrc,
            tuned_local_sig: AtomicU64::new(0),
            last_selected_pair: Mutex::new(String::new()),
            probe_target: Mutex::new(None),
            probe_started: AtomicBool::new(false),
            rtt_diag_ticks: AtomicU64::new(0),
            has_custom_ice,
            max_touchpoints,
            coop,
            max_video_delay_ms: if max_video_delay_ms == 0 {
                DEFAULT_VIDEO_RTP_SAMPLE_MAX_DELAY_MS
            } else {
                max_video_delay_ms
            },
            max_video_bitrate_kbps,
        }
    }

    fn next_message_id(&self) -> String {
        self.message_id.fetch_add(1, Ordering::Relaxed).to_string()
    }

    fn next_message_cv(&self) -> String {
        self.message_cv.fetch_add(1, Ordering::Relaxed).to_string()
    }

    fn next_input_sequence(&self) -> u32 {
        self.input_sequence.fetch_add(1, Ordering::Relaxed) as u32
    }

    fn push_local_candidate(&self, candidate: IceCandidate) {
        if let Ok(mut guard) = self.local_candidates.lock() {
            guard.push(candidate);
        }
    }

    fn local_candidates(&self) -> Vec<IceCandidate> {
        self.local_candidates
            .lock()
            .map(|guard| guard.clone())
            .unwrap_or_default()
    }

    fn record_track(&self, kind: MediaTrackKind) -> bool {
        if let Ok(mut guard) = self.observed_tracks.lock() {
            if !guard.contains(&kind) {
                guard.push(kind);
            }
            return guard.contains(&MediaTrackKind::Video)
                && guard.contains(&MediaTrackKind::Audio);
        }
        false
    }
}

#[derive(Clone)]
pub struct RealNanoPeerConnection {
    pc: Arc<RTCPeerConnection>,
    udp_mux: Option<Arc<UDPMuxDefault>>,
    shared: Arc<PeerSharedState>,
    video_sink: Option<Arc<dyn VideoFrameSink + Send + Sync>>,
    audio_sink: Option<Arc<dyn AudioFrameSink + Send + Sync>>,
    event_sink: Option<Arc<dyn SessionEventSink + Send + Sync>>,
    control_channel: Option<Arc<RTCDataChannel>>,
    input_channel: Option<Arc<RTCDataChannel>>,
    message_channel: Option<Arc<RTCDataChannel>>,
    mic_track: Option<Arc<TrackLocalStaticSample>>,
}

#[derive(Debug, Default)]
pub struct PeerStatsBaseline {
    sampled_at: Option<Instant>,
    video_bytes_received: u64,
    video_frames_received: u64,
    video_packets_received: u64,
    video_packets_lost: u64,
}

impl RealNanoPeerConnection {
    pub async fn new(
        plan: &PeerConnectionPlan,
        max_touchpoints: u8,
        coop: bool,
        network_mode: u8,
        is_home_platform: bool,
        has_custom_ice: bool,
        max_video_delay_ms: u64,
        max_video_bitrate_kbps: u32,
        video_sink: Option<Arc<dyn VideoFrameSink + Send + Sync>>,
        audio_sink: Option<Arc<dyn AudioFrameSink + Send + Sync>>,
        event_sink: Option<Arc<dyn SessionEventSink + Send + Sync>>,
    ) -> Result<Self, NanoError> {
        crate::nano_log!(
            "peer new transceivers={} channels={} iceServers={} networkMode={} isHome={} customIce={} maxVideoDelayMs={} maxBitrateKbps={} videoSink={} audioSink={}",
            plan.transceivers.len(),
            plan.channels.len(),
            plan.ice_servers.len(),
            network_mode,
            is_home_platform,
            has_custom_ice,
            max_video_delay_ms,
            max_video_bitrate_kbps,
            video_sink.is_some(),
            audio_sink.is_some()
        );
        let shared = Arc::new(PeerSharedState::new(
            max_touchpoints,
            coop,
            has_custom_ice,
            max_video_delay_ms,
            max_video_bitrate_kbps,
        ));
        let (api, udp_mux) = build_api(
            network_mode,
            is_home_platform,
            has_custom_ice,
            Arc::clone(&shared.stun_rtt_us),
            Arc::clone(&shared.stun_req_count),
            Arc::clone(&shared.stun_resp_count),
            Arc::clone(&shared.probe_rtt_us),
            Arc::clone(&shared.nack_rtt_us),
            Arc::clone(&shared.route_kind),
            Arc::clone(&shared.video_jitter_us),
        )?;
        let config = RTCConfiguration {
            ice_servers: plan
                .ice_servers
                .iter()
                .map(to_rtc_ice_server)
                .collect::<Vec<_>>(),
            ..Default::default()
        };
        let pc = Arc::new(
            api.new_peer_connection(config)
                .await
                .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?,
        );
        let mut peer = Self {
            pc,
            udp_mux,
            shared,
            video_sink,
            audio_sink,
            event_sink,
            control_channel: None,
            input_channel: None,
            message_channel: None,
            mic_track: None,
        };
        peer.prepare(plan).await?;
        Ok(peer)
    }

    async fn prepare(&mut self, plan: &PeerConnectionPlan) -> Result<(), NanoError> {
        for transceiver in &plan.transceivers {
            let direction = match transceiver.direction {
                TransceiverDirection::SendRecv => RTCRtpTransceiverDirection::Sendrecv,
                TransceiverDirection::SendOnly => RTCRtpTransceiverDirection::Sendonly,
                TransceiverDirection::RecvOnly => RTCRtpTransceiverDirection::Recvonly,
                TransceiverDirection::Inactive => RTCRtpTransceiverDirection::Inactive,
            };
            if transceiver.kind == "audio"
                && matches!(
                    direction,
                    RTCRtpTransceiverDirection::Sendrecv | RTCRtpTransceiverDirection::Sendonly
                )
            {
                let mic_track = Arc::new(TrackLocalStaticSample::new(
                    RTCRtpCodecCapability {
                        mime_type: MIME_TYPE_OPUS.to_owned(),
                        clock_rate: 48_000,
                        channels: 2,
                        sdp_fmtp_line: "minptime=10;useinbandfec=1".to_owned(),
                        rtcp_feedback: Vec::new(),
                    },
                    "audio".to_owned(),
                    "xboxpad-mic".to_owned(),
                ));
                self.pc
                    .add_transceiver_from_track(
                        Arc::clone(&mic_track) as Arc<dyn TrackLocal + Send + Sync>,
                        Some(RTCRtpTransceiverInit {
                            direction,
                            send_encodings: Vec::new(),
                        }),
                    )
                    .await
                    .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
                self.mic_track = Some(mic_track);
            } else {
                self.pc
                    .add_transceiver_from_kind(
                        match transceiver.kind {
                            "audio" => RTPCodecType::Audio,
                            "video" => RTPCodecType::Video,
                            _ => RTPCodecType::Audio,
                        },
                        Some(RTCRtpTransceiverInit {
                            direction,
                            send_encodings: Vec::new(),
                        }),
                    )
                    .await
                    .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
            }
        }

        self.open_data_channels(plan).await?;
        self.bind_callbacks().await?;
        Ok(())
    }

    async fn open_data_channels(&mut self, plan: &PeerConnectionPlan) -> Result<(), NanoError> {
        for channel in &plan.channels {
            crate::nano_log!(
                "open data channel name={} protocol={} ordered={}",
                channel.name,
                channel.protocol,
                channel.ordered
            );
            let init = RTCDataChannelInit {
                ordered: Some(channel.ordered),
                protocol: Some(channel.protocol.to_owned()),
                ..Default::default()
            };
            let data_channel = self
                .pc
                .create_data_channel(channel.name, Some(init))
                .await
                .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;

            match channel.name {
                "input" => {
                    self.input_channel = Some(Arc::clone(&data_channel));
                    self.bind_input_channel(Arc::clone(&data_channel)).await?;
                }
                "control" => {
                    self.control_channel = Some(Arc::clone(&data_channel));
                    self.bind_control_channel(Arc::clone(&data_channel)).await?;
                }
                "message" => {
                    self.message_channel = Some(Arc::clone(&data_channel));
                    self.bind_message_channel(Arc::clone(&data_channel)).await?;
                }
                "chat" => {
                    self.bind_passthrough_channel(Arc::clone(&data_channel), "chat")
                        .await?;
                }
                _ => {}
            }
        }
        Ok(())
    }

    async fn bind_callbacks(&self) -> Result<(), NanoError> {
        let shared = Arc::clone(&self.shared);
        let control_channel = self.control_channel.as_ref().map(Arc::clone);
        let peer_connection = Arc::clone(&self.pc);
        let video_sink = self.video_sink.as_ref().map(Arc::clone);
        let audio_sink = self.audio_sink.as_ref().map(Arc::clone);
        self.pc.on_track(Box::new(
            move |track: Arc<TrackRemote>, receiver: Arc<RTCRtpReceiver>, _transceiver| {
                let shared = Arc::clone(&shared);
                let control_channel = control_channel.as_ref().map(Arc::clone);
                let peer_connection = Arc::clone(&peer_connection);
                let video_sink = video_sink.as_ref().map(Arc::clone);
                let audio_sink = audio_sink.as_ref().map(Arc::clone);
                Box::pin(async move {
                    let kind = match track.kind() {
                        RTPCodecType::Audio => MediaTrackKind::Audio,
                        RTPCodecType::Video => MediaTrackKind::Video,
                        _ => MediaTrackKind::Other,
                    };
                    let codec = track.codec().capability;
                    crate::nano_log!(
                        "on-track kind={:?} codec={} clockRate={} ssrc={}",
                        kind,
                        codec.mime_type,
                        codec.clock_rate,
                        track.ssrc()
                    );
                    // Continuously drain inbound RTCP on every receiver so AccurateReceiverReport
                    // processes Xbox Sender Reports (populating LSR/DLSR for sender-side RTT) and
                    // the 100KB SRTCP receive buffer never stalls or overflows.
                    tokio::spawn(run_rtcp_reader(receiver, kind));
                    match kind {
                        MediaTrackKind::Video => {
                            let video_control = control_channel.as_ref().map(Arc::clone);
                            if let Some(video_sink) = video_sink {
                                tokio::spawn(run_low_latency_video_track(
                                    track,
                                    video_sink,
                                    Arc::clone(&shared),
                                    peer_connection,
                                    video_control,
                                ));
                            } else {
                                tokio::spawn(run_low_latency_video_track(
                                    track,
                                    Arc::new(NoopVideoSink),
                                    Arc::clone(&shared),
                                    peer_connection,
                                    video_control,
                                ));
                            }
                        }
                        MediaTrackKind::Audio => {
                            tokio::spawn(run_audio_track(track, audio_sink));
                        }
                        MediaTrackKind::Other => {}
                    }

                    if shared.record_track(kind)
                        && !shared.keyframe_requested.swap(true, Ordering::SeqCst)
                    {
                        if let Some(channel) = control_channel {
                            let message = ControlMessage::video_keyframe_requested(false).to_json();
                            let _ = channel.send_text(message).await;
                            crate::nano_log!("initial video keyframe requested");
                        }
                    }
                })
            },
        ));

        let shared = Arc::clone(&self.shared);
        self.pc
            .on_ice_candidate(Box::new(move |candidate: Option<RTCIceCandidate>| {
                let shared = Arc::clone(&shared);
                Box::pin(async move {
                    if let Some(candidate) = candidate {
                        if let Ok(init) = candidate.to_json() {
                            if let Some(text) = candidate_to_protocol_candidate(&init) {
                                let typ = text
                                    .candidate
                                    .split_whitespace()
                                    .skip_while(|t| *t != "typ")
                                    .nth(1)
                                    .unwrap_or("?");
                                let family = candidate_ip_family(&text.candidate);
                                crate::nano_log!(
                                    "local ice candidate gathered typ={} family={} mid={} mline={}",
                                    typ,
                                    family,
                                    text.sdp_mid,
                                    text.sdp_mline_index
                                );
                                shared.push_local_candidate(text);
                            }
                        }
                    }
                })
            }));

        self.pc
            .on_ice_connection_state_change(Box::new(move |state| {
                Box::pin(async move {
                    crate::nano_log!("ice state={state:?}");
                })
            }));

        let event_sink = self.event_sink.as_ref().map(Arc::clone);
        self.pc
            .on_peer_connection_state_change(Box::new(move |state: RTCPeerConnectionState| {
                let event_sink = event_sink.as_ref().map(Arc::clone);
                Box::pin(async move {
                    crate::nano_log!("peer state={state:?}");
                    if let Some(event_sink) = event_sink {
                        match state {
                            RTCPeerConnectionState::Connected => {
                                event_sink.update_status("connected", "已连接", false);
                            }
                            RTCPeerConnectionState::Disconnected => {
                                event_sink.update_status("disconnected", "网络连接波动，正在恢复...", false);
                            }
                            RTCPeerConnectionState::Failed => {
                                event_sink.update_status("failed", "WebRTC 连接失败 (NAT/网络中断)", true);
                            }
                            RTCPeerConnectionState::Closed => {
                                event_sink.update_status("closed", "串流已结束", true);
                            }
                            _ => {}
                        }
                    }
                })
            }));

        Ok(())
    }

    async fn bind_input_channel(&self, channel: Arc<RTCDataChannel>) -> Result<(), NanoError> {
        let shared = Arc::clone(&self.shared);
        let channel_for_open = Arc::clone(&channel);
        channel.on_open(Box::new(move || {
            let channel = Arc::clone(&channel_for_open);
            let shared = Arc::clone(&shared);
            Box::pin(async move {
                crate::nano_log!("input channel open");
                shared.input_ready.store(true, Ordering::SeqCst);
                let packet = InputPacket::client_metadata(0, shared.max_touchpoints);
                let _ = channel.send(&Bytes::from(packet.to_bytes(now_ms()))).await;
                crate::nano_log!("input client metadata sent");
                tokio::spawn(run_processed_frame_loop(channel, shared));
            })
        }));

        let event_sink = self.event_sink.as_ref().map(Arc::clone);
        channel.on_message(Box::new(move |msg: DataChannelMessage| {
            let event_sink = event_sink.as_ref().map(Arc::clone);
            Box::pin(async move {
                let Some(parsed) = parse_input_server_message(&msg.data) else {
                    crate::nano_warn!("input channel server message parse skipped len={}", msg.data.len());
                    return;
                };
                if let Some(rumble) = parsed.rumble {
                    if let Some(event_sink) = event_sink {
                        event_sink.on_rumble(rumble);
                    }
                }
            })
        }));
        Ok(())
    }

    async fn bind_control_channel(&self, channel: Arc<RTCDataChannel>) -> Result<(), NanoError> {
        channel.on_open(Box::new(move || {
            Box::pin(async move {
                crate::nano_log!("control channel open");
            })
        }));
        Ok(())
    }

    async fn bind_message_channel(&self, channel: Arc<RTCDataChannel>) -> Result<(), NanoError> {
        let shared = Arc::clone(&self.shared);
        let control_channel = self.control_channel.as_ref().map(Arc::clone);
        let channel_for_open = Arc::clone(&channel);
        channel.on_open(Box::new(move || {
            let channel = Arc::clone(&channel_for_open);
            let shared = Arc::clone(&shared);
            Box::pin(async move {
                crate::nano_log!("message channel open");
                let handshake = MessageHandshake {
                    version: "messageV1".to_owned(),
                    id: shared.next_message_id(),
                    cv: shared.next_message_cv(),
                };
                let _ = channel.send_text(handshake.to_json()).await;
            })
        }));

        let shared = Arc::clone(&self.shared);
        let channel_for_message = Arc::clone(&channel);
        channel.on_message(Box::new(move |msg: DataChannelMessage| {
            let shared = Arc::clone(&shared);
            let control_channel = control_channel.as_ref().map(Arc::clone);
            let channel = Arc::clone(&channel_for_message);
            Box::pin(async move {
                let Ok(text) = String::from_utf8(msg.data.to_vec()) else {
                    return;
                };
                if !shared.message_ready.load(Ordering::SeqCst) {
                    if let Some(message_type) = json_message_type(&text) {
                        if message_type == "HandshakeAck" {
                            crate::nano_log!("message handshake ack received");
                            shared.message_ready.store(true, Ordering::SeqCst);
                            if let Some(control_channel) = control_channel {
                                let _ = control_channel
                                    .send_text(
                                        ControlMessage::authorization_request(CONTROL_ACCESS_KEY)
                                            .to_json(),
                                    )
                                    .await;
                                let _ = control_channel
                                    .send_text(ControlMessage::gamepad_changed(0, false).to_json())
                                    .await;
                                if shared.coop {
                                    let _ = control_channel
                                        .send_text(
                                            ControlMessage::gamepad_changed(1, false).to_json(),
                                        )
                                        .await;
                                }
                                let shared = Arc::clone(&shared);
                                tokio::spawn(async move {
                                    sleep(Duration::from_millis(500)).await;
                                    let _ = control_channel
                                        .send_text(
                                            ControlMessage::gamepad_changed(0, true).to_json(),
                                        )
                                        .await;
                                    if shared.coop {
                                        let _ = control_channel
                                            .send_text(
                                                ControlMessage::gamepad_changed(1, true).to_json(),
                                            )
                                            .await;
                                    }
                                });
                            }
                            let _ = send_initial_message_bundle(&channel, &shared).await;
                        }
                    }
                }
            })
        }));
        Ok(())
    }

    async fn bind_passthrough_channel(
        &self,
        channel: Arc<RTCDataChannel>,
        label: &'static str,
    ) -> Result<(), NanoError> {
        channel.on_open(Box::new(move || {
            let label = label.to_owned();
            Box::pin(async move {
                crate::nano_log!("data channel opened label={label}");
            })
        }));
        Ok(())
    }

    pub async fn send_mic_opus(&self, data: Vec<u8>, duration_ms: u32) -> Result<(), NanoError> {
        let Some(track) = self.mic_track.as_ref() else {
            return Ok(());
        };
        if data.is_empty() {
            return Ok(());
        }
        let sample = MediaSample {
            data: Bytes::from(data),
            duration: Duration::from_millis(u64::from(duration_ms.clamp(5, 60))),
            ..Default::default()
        };
        track
            .write_sample(&sample)
            .await
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))
    }

    pub async fn create_offer(&self, stereo_audio_enabled: bool) -> Result<String, NanoError> {
        crate::nano_log!("create offer stereoAudio={stereo_audio_enabled}");
        crate::nano_log!("create offer begin");
        let offer = timeout(Duration::from_secs(8), self.pc.create_offer(None))
            .await
            .map_err(|_| NanoError::PeerConnectionOwned("create offer timeout".to_owned()))?
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
        crate::nano_log!("create offer raw sdp len={}", offer.sdp.len());
        let mut server_offer_sdp = offer.sdp.clone();
        if stereo_audio_enabled {
            match force_stereo_audio_sdp(&offer.sdp) {
                Ok(sdp) => {
                    crate::nano_log!("create offer stereo rewrite applied");
                    server_offer_sdp = sdp;
                }
                Err(error) => {
                    crate::nano_warn!("create offer stereo rewrite skipped: {error}");
                }
            }
        }
        let (min_kbps, start_kbps, max_kbps) = if self.shared.max_video_bitrate_kbps > 0 {
            let max_k = self.shared.max_video_bitrate_kbps.clamp(2_000, 80_000);
            // Keep start/min bitrate gentle enough not to blow out WAN/TURN queues on frame 1,
            // while still ramping promptly to `max_k` via clean zero-drift TWCC feedback.
            let start_k = ((max_k as u64 * 6) / 10).clamp(2_000, 18_000).min(max_k as u64) as u32;
            let min_k = (max_k / 5).clamp(1_000, 6_000).min(start_k);
            (min_k, start_k, max_k)
        } else {
            (4_000, 12_000, 40_000)
        };
        server_offer_sdp = boost_video_bitrate_sdp(&server_offer_sdp, min_kbps, start_kbps, max_kbps);
        crate::nano_log!(
            "create offer video bitrate sdp boost applied ({}/{}/{} kbps)",
            min_kbps,
            start_kbps,
            max_kbps
        );
        crate::nano_log!("create offer set local description begin");
        timeout(
            Duration::from_secs(8),
            self.pc.set_local_description(offer.clone()),
        )
        .await
        .map_err(|_| NanoError::PeerConnectionOwned("set local description timeout".to_owned()))?
        .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
        crate::nano_log!("create offer set local description done");
        crate::nano_log!("create offer wait ice begin");
        self.wait_for_candidate_gathering().await?;
        crate::nano_log!("create offer wait ice done");
        Ok(server_offer_sdp)
    }

    async fn wait_for_candidate_gathering(&self) -> Result<(), NanoError> {
        let started = Instant::now();
        let mut last_count = 0usize;
        let mut stable_count = 0usize;
        // Wait for local host + STUN srflx (and TURN relay when custom/builtin ICE is enabled)
        // so WAN hole-punching candidates are never truncated prematurely, while still capping
        // wait at 2.4s once any candidate exists (or 3.5s absolute ceiling).
        while started.elapsed() < Duration::from_millis(3800) {
            sleep(Duration::from_millis(100)).await;
            let candidates = self.shared.local_candidates();
            let count = candidates.len();
            if count > 0 {
                let mut has_srflx = false;
                let mut has_relay = false;
                for c in &candidates {
                    if c.candidate.contains(" typ srflx") {
                        has_srflx = true;
                    } else if c.candidate.contains(" typ relay") {
                        has_relay = true;
                    }
                }
                let elapsed = started.elapsed();
                let ready_for_early_exit = if self.shared.has_custom_ice {
                    // On 4G/5G cellular, DNS + 2-RTT TURN Allocate can take 1.0-2.0s;
                    // exit immediately once both srflx and relay are gathered, otherwise
                    // wait up to 2.2s before allowing early exit without relay.
                    (has_srflx && has_relay) || elapsed >= Duration::from_millis(2200)
                } else {
                    has_srflx || elapsed >= Duration::from_millis(600)
                };
                if count == last_count {
                    stable_count += 1;
                    if (ready_for_early_exit && stable_count >= 3)
                        || elapsed >= Duration::from_millis(3000)
                    {
                        break;
                    }
                } else {
                    stable_count = 0;
                    last_count = count;
                }
            }
        }
        Ok(())
    }

    pub async fn set_remote_answer(&self, sdp: &str) -> Result<(), NanoError> {
        crate::nano_log!(
            "set remote answer len={} summary={}",
            sdp.len(),
            summarize_remote_answer_sdp(sdp)
        );
        let answer = RTCSessionDescription::answer(sdp.to_owned())
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
        self.pc
            .set_remote_description(answer)
            .await
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))
    }

    pub async fn drain_local_candidates(&self) -> Result<Vec<IceCandidate>, NanoError> {
        let mut candidates = self.shared.local_candidates();
        if self.shared.has_custom_ice
            && !candidates.iter().any(|c| c.candidate.contains(" typ relay"))
        {
            // Give slow cellular TURN allocations a brief final window before POST /ice.
            for _ in 0..5 {
                sleep(Duration::from_millis(100)).await;
                candidates = self.shared.local_candidates();
                if candidates.iter().any(|c| c.candidate.contains(" typ relay")) {
                    break;
                }
            }
        }
        // Proactively enlarge SO_RCVBUF (4MB) / SO_SNDBUF (1MB) + WMM AC_VI QoS on all gathered
        // ephemeral UDP sockets (host, STUN srflx rport, TURN relay rport) BEFORE media flows.
        #[cfg(unix)]
        {
            let early_ports = collect_local_udp_ports(0, &candidates);
            if !early_ports.is_empty() {
                let tuned = tune_active_udp_sockets_by_ports(&early_ports);
                if tuned > 0 {
                    crate::nano_log!(
                        "proactive udp socket tuning applied sockets={tuned} ports={}",
                        early_ports.len()
                    );
                }
            }
        }
        let mut host_cnt = 0usize;
        let mut srflx_cnt = 0usize;
        let mut relay_cnt = 0usize;
        for c in &candidates {
            if c.candidate.contains(" typ relay") {
                relay_cnt += 1;
            } else if c.candidate.contains(" typ srflx") {
                srflx_cnt += 1;
            } else if c.candidate.contains(" typ host") {
                host_cnt += 1;
            }
        }
        crate::nano_log!(
            "drain local candidates count={} host={} srflx={} relay={}",
            candidates.len(),
            host_cnt,
            srflx_cnt,
            relay_cnt
        );
        Ok(candidates)
    }

    pub async fn add_remote_candidate(&self, candidate: &IceCandidate) -> Result<(), NanoError> {
        if candidate.is_end_of_candidates() || candidate.has_invalid_tcp_type() {
            crate::nano_log!(
                "skip remote candidate mid={} mline={}",
                candidate.sdp_mid,
                candidate.sdp_mline_index
            );
            return Ok(());
        }
        let normalized = normalize_remote_candidate_line(&candidate.candidate);
        let typ = normalized
            .split_whitespace()
            .skip_while(|t| *t != "typ")
            .nth(1)
            .unwrap_or("?");
        let family = candidate_ip_family(&normalized);
        crate::nano_log!(
            "add remote candidate typ={} family={} mid={} mline={}",
            typ,
            family,
            candidate.sdp_mid,
            candidate.sdp_mline_index
        );
        let sdp_mid = {
            let trimmed = candidate.sdp_mid.trim();
            if trimmed.is_empty() {
                "0".to_owned()
            } else {
                trimmed.to_owned()
            }
        };
        let init = RTCIceCandidateInit {
            candidate: normalized,
            sdp_mid: Some(sdp_mid),
            sdp_mline_index: Some(candidate.sdp_mline_index.parse::<u16>().unwrap_or(0)),
            username_fragment: None,
        };
        self.pc
            .add_ice_candidate(init)
            .await
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))
    }

    pub async fn send_gamepad_frame(&self, frame: InputFrame) -> Result<(), NanoError> {
        if !self.shared.input_ready.load(Ordering::SeqCst) {
            return Ok(());
        }

        let Some(channel) = self.input_channel.as_ref() else {
            return Err(NanoError::RuntimeMessage(
                "input channel not ready".to_owned(),
            ));
        };

        let packet = InputPacket::with_data(
            self.shared.next_input_sequence(),
            Vec::new(),
            vec![frame],
            Vec::new(),
            1920,
            1080,
        );
        channel
            .send(&Bytes::from(packet.to_bytes(now_ms())))
            .await
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
        Ok(())
    }

    pub async fn set_gamepad_connected(&self, gamepad_index: u8, connected: bool) -> Result<(), NanoError> {
        let Some(control_channel) = self.control_channel.as_ref() else {
            return Ok(());
        };
        let idx = u32::from(gamepad_index.min(3));
        crate::nano_log!("control gamepad_changed index={idx} connected={connected}");
        control_channel
            .send_text(ControlMessage::gamepad_changed(idx, connected).to_json())
            .await
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
        Ok(())
    }

    pub async fn send_mouse_frame(&self, frame: MouseFrame) -> Result<(), NanoError> {
        if !self.shared.input_ready.load(Ordering::SeqCst) {
            return Ok(());
        }
        let Some(channel) = self.input_channel.as_ref() else {
            return Ok(());
        };
        let packet = InputPacket::with_mouse(self.shared.next_input_sequence(), frame);
        channel
            .send(&Bytes::from(packet.to_bytes(now_ms())))
            .await
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
        Ok(())
    }

    pub async fn send_keyboard_frame(&self, frame: KeyboardFrame) -> Result<(), NanoError> {
        if !self.shared.input_ready.load(Ordering::SeqCst) {
            return Ok(());
        }
        let Some(channel) = self.input_channel.as_ref() else {
            return Ok(());
        };
        let packet = InputPacket::with_keyboard(self.shared.next_input_sequence(), frame);
        channel
            .send(&Bytes::from(packet.to_bytes(now_ms())))
            .await
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
        Ok(())
    }

    pub async fn collect_stream_stats(&self, baseline: &mut PeerStatsBaseline) -> StreamStats {
        let mut stats = StreamStats::default();
        let now = Instant::now();
        let mut video_bytes_received = self.shared.video_bytes_received.load(Ordering::Relaxed);
        let packets_received = self.shared.video_packets_received.load(Ordering::Relaxed);
        let packets_lost = self.shared.video_packets_lost.load(Ordering::Relaxed);
        let frames_received = self.shared.video_frames_received.load(Ordering::Relaxed);
        let frames_dropped = self.shared.video_frames_dropped.load(Ordering::Relaxed);
        let jitter_us = self.shared.video_jitter_us.load(Ordering::Relaxed);

        let report = self.pc.get_stats().await;
        let mut selected_pair: Option<(&str, &str, f64, bool)> = None;
        for entry in report.reports.values() {
            match entry {
                StatsReportType::CandidatePair(candidate)
                    if candidate.state.to_string() == "succeeded" =>
                {
                    let is_better = match selected_pair {
                        None => true,
                        Some((_, _, _, was_nominated)) => candidate.nominated && !was_nominated,
                    };
                    if is_better {
                        let rtt = if candidate.current_round_trip_time.is_finite()
                            && candidate.current_round_trip_time > 0.0
                        {
                            candidate.current_round_trip_time
                        } else if candidate.responses_received > 0
                            && candidate.total_round_trip_time.is_finite()
                            && candidate.total_round_trip_time > 0.0
                        {
                            candidate.total_round_trip_time / candidate.responses_received as f64
                        } else {
                            0.0
                        };
                        selected_pair = Some((
                            candidate.local_candidate_id.as_str(),
                            candidate.remote_candidate_id.as_str(),
                            rtt,
                            candidate.nominated,
                        ));
                    }
                }
                StatsReportType::InboundRTP(inbound) if inbound.kind == "video" => {
                    video_bytes_received = inbound.bytes_received;
                    stats.update_packets_received(inbound.packets_received);
                }
                StatsReportType::RemoteInboundRTP(remote) if remote.kind == "video" => {
                    if let Some(rtt) = remote.round_trip_time {
                        if rtt.is_finite() && rtt > 0.0 && stats.round_trip_time_ms.is_none() {
                            stats.update_rtt(rtt * 1000.0);
                        }
                    }
                    if remote.packets_lost > 0 {
                        stats.update_packets_lost(remote.packets_lost as u64);
                        let total = remote.packets_received + remote.packets_lost as u64;
                        if total > 0 {
                            stats.update_packet_loss(
                                remote.packets_lost as f64 * 100.0 / total as f64,
                            );
                        }
                    }
                }
                _ => {}
            }
        }

        if let Some((local_id, remote_id, rtt_s, _)) = selected_pair {
            if rtt_s.is_finite() && rtt_s > 0.0 {
                stats.update_rtt(rtt_s * 1000.0);
            }
            let local_cand = report.reports.get(local_id).and_then(|r| match r {
                StatsReportType::LocalCandidate(c) => Some(c),
                _ => None,
            });
            let remote_cand = report.reports.get(remote_id).and_then(|r| match r {
                StatsReportType::RemoteCandidate(c) => Some(c),
                _ => None,
            });
            let local_kind = local_cand.map(|c| format!("{:?}", c.candidate_type));
            let remote_kind = remote_cand.map(|c| format!("{:?}", c.candidate_type));
            let same_lan_subnet = match (local_cand, remote_cand) {
                (Some(lc), Some(rc)) => are_same_lan_subnet(&lc.ip, &rc.ip),
                _ => false,
            };
            stats.route_kind = match (local_kind.as_deref(), remote_kind.as_deref()) {
                (Some("Relay"), _) | (_, Some("Relay")) => 3,
                (Some(_), Some(_)) if same_lan_subnet => 1,
                (Some(_), Some(_)) => 2,
                _ => 0,
            };
            self.shared
                .route_kind
                .store(stats.route_kind, Ordering::Relaxed);
            self.shared
                .is_true_lan
                .store(stats.route_kind == 1, Ordering::Relaxed);

            // Apply low-latency UDP QoS (`SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI`, DSCP AF41,
            // 4MB SO_RCVBUF) to EVERY active ephemeral WebRTC media socket — including Srflx/Relay
            // whose selected candidate port is the external NAT port while the local bound socket
            // lives on `rport` / local `host` candidate ports.
            #[cfg(unix)]
            if let Some(lc) = local_cand {
                let local_cands = self.shared.local_candidates();
                let ports = collect_local_udp_ports(lc.port, &local_cands);
                let sig = ((u64::from(lc.port)) << 16) | (ports.len() as u64);
                if !ports.is_empty()
                    && self.shared.tuned_local_sig.load(Ordering::Relaxed) != sig
                {
                    if tune_active_udp_sockets_by_ports(&ports) > 0 {
                        self.shared
                            .tuned_local_sig
                            .store(sig, Ordering::Relaxed);
                    }
                }
            }

            // Publish active remote candidate IP:port for our backup RTT probe (TCP / ICMPv4 / ICMPv6 / STUN).
            // Strip any IPv6 link-local `%iface` zone suffix before parsing.
            if let Some(rc) = remote_cand {
                let raw_ip = rc.ip.split('%').next().unwrap_or(&rc.ip).trim();
                if let Ok(ip) = raw_ip.parse::<std::net::IpAddr>() {
                    let addr = SocketAddr::new(ip, rc.port);
                    let is_host_lan = stats.route_kind == 1;
                    if let Ok(mut guard) = self.shared.probe_target.lock() {
                        *guard = Some((addr, is_host_lan));
                    }
                    if !self.shared.probe_started.swap(true, Ordering::SeqCst) {
                        let shared_probe = Arc::clone(&self.shared);
                        tokio::spawn(run_active_rtt_probe_loop(shared_probe));
                    }
                }
            }

            let local_str = local_cand
                .map(|c| format!("{}({:?}):{}", c.ip, c.candidate_type, c.port))
                .unwrap_or_else(|| "?".to_owned());
            let remote_str = remote_cand
                .map(|c| format!("{}({:?}):{}", c.ip, c.candidate_type, c.port))
                .unwrap_or_else(|| "?".to_owned());
            let pair_key = format!("{local_str}->{remote_str}");
            let pair_changed = self
                .shared
                .last_selected_pair
                .lock()
                .map(|mut prev| {
                    if *prev != pair_key {
                        *prev = pair_key.clone();
                        true
                    } else {
                        false
                    }
                })
                .unwrap_or(false);

            let diag_tick = self.shared.rtt_diag_ticks.fetch_add(1, Ordering::Relaxed);
            let have_rtt = self.shared.stun_rtt_us.load(Ordering::Relaxed) > 0
                || self.shared.probe_rtt_us.load(Ordering::Relaxed) > 0
                || self.shared.nack_rtt_us.load(Ordering::Relaxed) > 0;
            if pair_changed
                || diag_tick == 0
                || diag_tick == 3
                || diag_tick % 60 == 0
                || (!have_rtt && diag_tick % 10 == 0)
            {
                crate::nano_log!(
                    "ice selected pair routeKind={} local={} remote={} stunReq={} stunResp={} stunRttUs={} probeRttUs={} nackRttUs={}",
                    stats.route_kind,
                    local_str,
                    remote_str,
                    self.shared.stun_req_count.load(Ordering::Relaxed),
                    self.shared.stun_resp_count.load(Ordering::Relaxed),
                    self.shared.stun_rtt_us.load(Ordering::Relaxed),
                    self.shared.probe_rtt_us.load(Ordering::Relaxed),
                    self.shared.nack_rtt_us.load(Ordering::Relaxed)
                );
            }
        }

        if stats.round_trip_time_ms.is_none() {
            let best_rtt_us = latest_live_rtt_us(&self.shared);
            if best_rtt_us > 0 {
                stats.update_rtt(best_rtt_us as f64 / 1000.0);
            }
        }

        if stats.packets_received == 0 {
            stats.update_packets_received(packets_received);
        }
        if stats.packets_lost == 0 {
            stats.update_packets_lost(packets_lost);
        }
        stats.update_frames_received(frames_received);
        stats.frames_dropped = frames_dropped;
        if jitter_us > 0 {
            stats.update_jitter(jitter_us as f64 / 1000.0);
        }

        if let Some(sampled_at) = baseline.sampled_at {
            let elapsed = now.duration_since(sampled_at).as_secs_f64();
            if elapsed > 0.0 {
                let byte_delta = video_bytes_received.saturating_sub(baseline.video_bytes_received);
                stats.update_bitrate((byte_delta as f64 * 8.0 / elapsed).round() as u64);
                let frame_delta = frames_received.saturating_sub(baseline.video_frames_received);
                stats.update_fps(frame_delta as f64 / elapsed);

                // Windowed (live 1s) packet loss % so transient startup loss doesn't pollute HUD
                let recv_delta = stats
                    .packets_received
                    .saturating_sub(baseline.video_packets_received);
                let lost_delta = stats
                    .packets_lost
                    .saturating_sub(baseline.video_packets_lost);
                let total_delta = recv_delta + lost_delta;
                if total_delta > 0 {
                    stats.update_packet_loss(lost_delta as f64 * 100.0 / total_delta as f64);
                } else {
                    stats.update_packet_loss(0.0);
                }
            }
        } else {
            stats.update_packet_loss(0.0);
        }
        baseline.sampled_at = Some(now);
        baseline.video_bytes_received = video_bytes_received;
        baseline.video_frames_received = frames_received;
        baseline.video_packets_received = stats.packets_received;
        baseline.video_packets_lost = stats.packets_lost;

        // Smooth loss-aware AIMD REMB ceiling across LAN, WAN P2P, and TURN relay so Xbox GCC
        // climbs smoothly to full link capacity when clean and backs off gracefully on real loss.
        let video_ssrc = self.shared.video_ssrc.load(Ordering::Relaxed);
        if video_ssrc != 0 {
            let live_rtt_ms = stats.round_trip_time_ms.unwrap_or(0.0);
            let live_loss_pct = stats.packet_loss_pct.unwrap_or(0.0);
            let custom_cap_bps: Option<f64> = if self.shared.max_video_bitrate_kbps > 0 {
                Some(f64::from(self.shared.max_video_bitrate_kbps.clamp(2_000, 80_000)) * 1000.0)
            } else {
                None
            };
            let target_ceiling_bps = match custom_cap_bps {
                Some(cap) => cap,
                None => match stats.route_kind {
                    1 => f64::from(REMB_TARGET_BITRATE_BPS),
                    2 if live_rtt_ms > 0.0 && live_rtt_ms < 45.0 => 35_000_000.0,
                    2 if live_rtt_ms < 95.0 => 26_000_000.0,
                    2 => 18_000_000.0,
                    3 => 20_000_000.0,
                    _ => 24_000_000.0,
                },
            };
            let prev_bps = self.shared.remb_current_bps.load(Ordering::Relaxed) as f64;
            let current_bps = if prev_bps <= 0.0 {
                if stats.route_kind == 1 {
                    target_ceiling_bps
                } else {
                    target_ceiling_bps.min(18_000_000.0)
                }
            } else {
                prev_bps
            };
            let next_bps = if live_loss_pct < 0.5 {
                let stepped = (current_bps * 1.15).max(current_bps + 2_000_000.0);
                stepped.min(target_ceiling_bps)
            } else if live_loss_pct >= 2.0 {
                let floor = target_ceiling_bps.min(4_000_000.0);
                (current_bps * 0.85).max(floor)
            } else {
                current_bps.min(target_ceiling_bps)
            };
            self.shared
                .remb_current_bps
                .store(next_bps.round() as u64, Ordering::Relaxed);
            let remb = ReceiverEstimatedMaximumBitrate {
                sender_ssrc: self.shared.remb_sender_ssrc,
                bitrate: next_bps as f32,
                ssrcs: vec![video_ssrc],
            };
            let _ = self.pc.write_rtcp(&[Box::new(remb)]).await;
        }

        stats
    }

    pub async fn request_keyframe(&self) {
        if let Some(channel) = self.control_channel.as_ref() {
            let message = ControlMessage::video_keyframe_requested(true).to_json();
            let _ = channel.send_text(message).await;
        }
        let ssrc = self.shared.video_ssrc.load(Ordering::Relaxed);
        if ssrc != 0 {
            let pli = PictureLossIndication {
                sender_ssrc: 0,
                media_ssrc: ssrc,
            };
            let _ = self.pc.write_rtcp(&[Box::new(pli)]).await;
        }
        crate::nano_log!("video keyframe+pli requested reason=decoder-recovery ssrc={ssrc}");
    }

    pub async fn close(&self) -> Result<(), NanoError> {
        if let Ok(mut guard) = self.shared.probe_target.lock() {
            *guard = None;
        }
        let res = self
            .pc
            .close()
            .await
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()));
        if let Some(mux) = self.udp_mux.as_ref() {
            let _ = mux.close().await;
        }
        res
    }
}

fn build_api(
    network_mode: u8,
    is_home_platform: bool,
    has_custom_ice: bool,
    stun_rtt_us: Arc<AtomicU64>,
    stun_req_count: Arc<AtomicU64>,
    stun_resp_count: Arc<AtomicU64>,
    probe_rtt_us: Arc<AtomicU64>,
    nack_rtt_us: Arc<AtomicU64>,
    route_kind: Arc<AtomicU8>,
    video_jitter_us: Arc<AtomicU64>,
) -> Result<(webrtc::api::API, Option<Arc<UDPMuxDefault>>), NanoError> {
    let mut media_engine = MediaEngine::default();
    register_xbox_codecs(&mut media_engine)?;
    let registry = register_low_latency_interceptors(
        Registry::new(),
        &mut media_engine,
        Arc::clone(&stun_rtt_us),
        probe_rtt_us,
        nack_rtt_us,
        route_kind,
        video_jitter_us,
    )?;

    let mut setting_engine = SettingEngine::default();
    // Send ICE STUN keepalive checks every 1s so our STUN RTT tracker continuously
    // measures true end-to-end network RTT on the active WMM AC_VI media socket.
    setting_engine.set_ice_timeouts(
        Some(Duration::from_secs(5)),
        Some(Duration::from_secs(12)),
        Some(Duration::from_secs(1)),
    );

    // Never gather or probe Apple AWDL / AirDrop / internal virtual interfaces:
    // touching `awdl0`/`llw0` wakes up AWDL off-channel Wi-Fi scanning on iPadOS.
    setting_engine.set_interface_filter(Box::new(|iface_name: &str| {
        let lower = iface_name.to_ascii_lowercase();
        !lower.starts_with("awdl")
            && !lower.starts_with("llw")
            && !lower.starts_with("anpi")
            && !lower.starts_with("ap")
            && !lower.starts_with("lo")
            && !lower.starts_with("bridge")
    }));

    // network_mode:
    //   0 = Auto (IPv4 + IPv6 dual-stack race: Host v6 + Host v4 + STUN srflx + TURN relay)
    //   1 = IPv4 Only (Host v4 + STUN srflx + TURN relay, or tuned IPv4 UDPMux if relay off)
    //   2 = IPv6 Only (QoS-tuned IPv6 UDPMux + automatic IPv4 TURN relay fallback)
    if network_mode == 0 {
        let has_v6 = is_home_platform && detect_primary_global_ipv6().is_some();
        let types = if has_v6 {
            vec![NetworkType::Udp4, NetworkType::Udp6]
        } else {
            vec![NetworkType::Udp4]
        };
        setting_engine.set_network_types(types);
        setting_engine.set_ip_filter(Box::new(|ip: std::net::IpAddr| match ip {
            std::net::IpAddr::V4(v4) => !v4.is_link_local() && !v4.is_loopback(),
            std::net::IpAddr::V6(v6) => is_usable_ipv6(v6),
        }));
        crate::nano_log!(
            "ice mux mode=auto-dual-stack hasV6={} customIce={} (host+srflx+relay enabled)",
            has_v6,
            has_custom_ice
        );
        let api = APIBuilder::new()
            .with_media_engine(media_engine)
            .with_interceptor_registry(registry)
            .with_setting_engine(setting_engine)
            .build();
        return Ok((api, None));
    }

    let primary_ipv6 = if network_mode == 2 && is_home_platform {
        detect_primary_global_ipv6()
    } else {
        None
    };

    if primary_ipv6.is_none() && has_custom_ice {
        setting_engine.set_network_types(vec![NetworkType::Udp4]);
        setting_engine.set_ip_filter(Box::new(|ip: std::net::IpAddr| match ip {
            std::net::IpAddr::V4(v4) => !v4.is_link_local() && !v4.is_loopback(),
            std::net::IpAddr::V6(_) => false,
        }));
        crate::nano_log!(
            "ice mux mode=ephemeral-ipv4-stun-turn networkMode={} (host+srflx+relay enabled)",
            network_mode
        );
        let api = APIBuilder::new()
            .with_media_engine(media_engine)
            .with_interceptor_registry(registry)
            .with_setting_engine(setting_engine)
            .build();
        return Ok((api, None));
    }

    let udp_mux = if let Some(v6_ip) = primary_ipv6 {
        if let Some(mux) = create_tuned_udp_mux(
            true,
            Arc::clone(&stun_rtt_us),
            Arc::clone(&stun_req_count),
            Arc::clone(&stun_resp_count),
        ) {
            setting_engine.set_network_types(vec![NetworkType::Udp6]);
            setting_engine.set_ip_filter(Box::new(move |ip: std::net::IpAddr| match ip {
                std::net::IpAddr::V6(v6) => v6 == v6_ip,
                std::net::IpAddr::V4(_) => false,
            }));
            crate::nano_log!("ice mux mode=ipv6 primaryIp={v6_ip}");
            Some(mux)
        } else {
            None
        }
    } else {
        if let Some(mux) = create_tuned_udp_mux(
            false,
            Arc::clone(&stun_rtt_us),
            Arc::clone(&stun_req_count),
            Arc::clone(&stun_resp_count),
        ) {
            setting_engine.set_network_types(vec![NetworkType::Udp4]);
            setting_engine.set_ip_filter(Box::new(|ip: std::net::IpAddr| match ip {
                std::net::IpAddr::V4(v4) => !v4.is_link_local() && !v4.is_loopback(),
                std::net::IpAddr::V6(_) => false,
            }));
            crate::nano_log!(
                "ice mux mode=ipv4 networkMode={} isHome={}",
                network_mode,
                is_home_platform
            );
            Some(mux)
        } else {
            None
        }
    };

    if let Some(mux) = udp_mux.as_ref() {
        setting_engine.set_udp_network(UDPNetwork::Muxed(
            Arc::clone(mux) as Arc<dyn UDPMux + Send + Sync>,
        ));
    }

    let api = APIBuilder::new()
        .with_media_engine(media_engine)
        .with_interceptor_registry(registry)
        .with_setting_engine(setting_engine)
        .build();
    Ok((api, udp_mux))
}

fn is_usable_ipv6(v6: std::net::Ipv6Addr) -> bool {
    if v6.is_loopback() || v6.is_unspecified() || v6.is_multicast() {
        return false;
    }
    let seg0 = v6.segments()[0];
    // Exclude link-local fe80::/10 and IPv4-mapped ::ffff:0:0/96
    let is_link_local = (seg0 & 0xffc0) == 0xfe80;
    !is_link_local && v6.to_ipv4_mapped().is_none()
}

/// Ask the OS routing table (zero packets sent) for the exact source IPv6 address
/// Darwin will stamp on outgoing IPv6 UDP datagrams.
fn detect_primary_global_ipv6() -> Option<std::net::Ipv6Addr> {
    for probe_dst in &["[2606:4700:4700::1111]:443", "[2001:4860:4860::8888]:443"] {
        if let Ok(sock) = std::net::UdpSocket::bind("[::]:0") {
            if sock.connect(probe_dst).is_ok() {
                if let Ok(SocketAddr::V6(local_v6)) = sock.local_addr() {
                    let ip = *local_v6.ip();
                    if is_usable_ipv6(ip) {
                        return Some(ip);
                    }
                }
            }
        }
    }
    None
}

/// Transparent UDP socket wrapper that tracks RFC 5389/8489 STUN Binding Request -> Response
/// transaction round-trip times with microsecond precision (identical to libwebrtc ICE RTT).
struct RttMeasuringUdpConn {
    socket: tokio::net::UdpSocket,
    pending_stun: Mutex<HashMap<[u8; 12], Instant>>,
    measured_rtt_us: Arc<AtomicU64>,
    stun_req_count: Arc<AtomicU64>,
    stun_resp_count: Arc<AtomicU64>,
}

impl RttMeasuringUdpConn {
    const STUN_MAGIC_COOKIE: [u8; 4] = [0x21, 0x12, 0xA4, 0x42];

    fn new(
        socket: tokio::net::UdpSocket,
        measured_rtt_us: Arc<AtomicU64>,
        stun_req_count: Arc<AtomicU64>,
        stun_resp_count: Arc<AtomicU64>,
    ) -> Self {
        Self {
            socket,
            pending_stun: Mutex::new(HashMap::with_capacity(16)),
            measured_rtt_us,
            stun_req_count,
            stun_resp_count,
        }
    }

    #[inline]
    fn record_outgoing_stun(&self, buf: &[u8]) {
        // STUN Binding Request: type = 0x0001, magic cookie at bytes 4..8, tx_id at bytes 8..20
        if buf.len() >= 20
            && buf[0] == 0x00
            && buf[1] == 0x01
            && buf[4..8] == Self::STUN_MAGIC_COOKIE
        {
            self.stun_req_count.fetch_add(1, Ordering::Relaxed);
            let mut tx_id = [0u8; 12];
            tx_id.copy_from_slice(&buf[8..20]);
            let now = Instant::now();
            if let Ok(mut pending) = self.pending_stun.lock() {
                if pending.len() > 32 {
                    pending.retain(|_, sent| now.duration_since(*sent) < Duration::from_secs(8));
                }
                pending.insert(tx_id, now);
            }
        }
    }

    #[inline]
    fn record_incoming_stun(&self, buf: &[u8]) {
        // STUN Binding Success (0x0101) or Error (0x0111) Response, magic cookie at 4..8
        if buf.len() >= 20
            && buf[0] == 0x01
            && (buf[1] == 0x01 || buf[1] == 0x11)
            && buf[4..8] == Self::STUN_MAGIC_COOKIE
        {
            self.stun_resp_count.fetch_add(1, Ordering::Relaxed);
            let mut tx_id = [0u8; 12];
            tx_id.copy_from_slice(&buf[8..20]);
            let sent_at = self
                .pending_stun
                .lock()
                .ok()
                .and_then(|mut pending| pending.remove(&tx_id));
            if let Some(sent_at) = sent_at {
                let rtt_us = sent_at.elapsed().as_micros().clamp(100, 10_000_000) as u64;
                self.measured_rtt_us.store(rtt_us, Ordering::Relaxed);
            }
        }
    }
}

/// Active 1Hz network RTT probe fallback (runs only when passive STUN RTT has no sample):
/// 1) Standard TCP 1-RTT handshake/RST to Xbox UPnP (2869 on LAN/Host-to-Host, incl. Global IPv6)
///    or HTTPS (443 on WAN) — 100% iOS sandbox safe,
/// 2) Darwin unprivileged `SOCK_DGRAM` `IPPROTO_ICMP` / `IPPROTO_ICMPV6` Echo Request,
/// 3) Unauthenticated 20-byte STUN Binding Request to `remote_ip:remote_port`.
async fn run_active_rtt_probe_loop(shared: Arc<PeerSharedState>) {
    let mut seq: u16 = 1;
    let mut logged_source = false;
    loop {
        let entry = shared.probe_target.lock().ok().and_then(|g| *g);
        let Some((target, is_host_lan)) = entry else {
            break;
        };

        // Only probe actively when passive STUN tracking hasn't produced a sample
        if shared.stun_rtt_us.load(Ordering::Relaxed) == 0 {
            let probe_seq = seq;
            seq = seq.wrapping_add(1);
            let measured = tokio::task::spawn_blocking(move || {
                measure_rtt_once(target, is_host_lan, probe_seq)
            })
            .await
            .ok()
            .flatten();
            if let Some((source, rtt_us)) = measured {
                shared.probe_rtt_us.store(rtt_us, Ordering::Relaxed);
                if !logged_source {
                    logged_source = true;
                    crate::nano_log!(
                        "rtt active probe locked source={} target={} rttMs={:.2}",
                        source,
                        target,
                        rtt_us as f64 / 1000.0
                    );
                }
            }
        }
        sleep(Duration::from_secs(1)).await;
    }
}

fn measure_rtt_once(target: SocketAddr, is_host_lan: bool, seq: u16) -> Option<(&'static str, u64)> {
    // 1. Prefer unprivileged Darwin ICMP / ICMPv6 Echo with NET_SERVICE_TYPE_VI (WMM AC_VI):
    //    kernel-level response with zero TCP/UPnP userspace accept overhead.
    match target {
        SocketAddr::V4(v4) => {
            if let Some(us) = measure_icmp_v4_rtt(*v4.ip(), seq) {
                return Some(("icmp4", us));
            }
        }
        SocketAddr::V6(v6) => {
            if let Some(us) = measure_icmp_v6_rtt(*v6.ip(), seq) {
                return Some(("icmp6", us));
            }
        }
    }

    // 2. QoS-marked TCP 1-RTT probe (Xbox LAN UPnP 2869 or xCloud/WAN HTTPS 443)
    let is_lan = is_host_lan
        || match target.ip() {
            std::net::IpAddr::V4(v4) => v4.is_private() || v4.is_link_local() || v4.is_loopback(),
            std::net::IpAddr::V6(v6) => {
                let seg0 = v6.segments()[0];
                v6.is_loopback() || (seg0 & 0xfe00) == 0xfc00 || (seg0 & 0xffc0) == 0xfe80
            }
        };
    let tcp_ports: &[u16] = if is_lan { &[2869, 443, 80] } else { &[443, 2869, 80] };
    for &port in tcp_ports {
        if let Some(us) = measure_tcp_rtt(SocketAddr::new(target.ip(), port)) {
            return Some(("tcp", us));
        }
    }

    // 3. Unauthenticated STUN Binding Request to the ICE peer port
    if let Some(us) = measure_stun_udp_rtt(target, seq) {
        return Some(("stun-udp", us));
    }
    None
}

/// Apply Interactive Video QoS (`SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI` + DSCP AF41)
/// so RTT probes travel in the same WMM AC_VI priority queue as live WebRTC media.
#[cfg(any(target_os = "ios", target_os = "macos"))]
fn apply_probe_qos(fd: std::os::unix::io::RawFd, is_ipv6: bool) -> bool {
    const SO_NET_SERVICE_TYPE: libc::c_int = 0x1116;
    const NET_SERVICE_TYPE_VI: libc::c_int = 3; // Interactive Video (WMM AC_VI)
    let svc = NET_SERVICE_TYPE_VI;
    let rc_svc = unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            SO_NET_SERVICE_TYPE,
            &svc as *const libc::c_int as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        )
    };
    let dscp: libc::c_int = 0x88; // DSCP AF41 (Interactive Video)
    if is_ipv6 {
        let _ = unsafe {
            libc::setsockopt(
                fd,
                libc::IPPROTO_IPV6,
                libc::IPV6_TCLASS,
                &dscp as *const libc::c_int as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
    } else {
        let _ = unsafe {
            libc::setsockopt(
                fd,
                libc::IPPROTO_IP,
                libc::IP_TOS,
                &dscp as *const libc::c_int as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
    }
    rc_svc == 0
}

/// Measures exact 1-RTT via QoS-marked TCP SYN -> SYN-ACK (or immediate TCP RST `ConnectionRefused`).
#[cfg(any(target_os = "ios", target_os = "macos"))]
fn measure_tcp_rtt(addr: SocketAddr) -> Option<u64> {
    use std::os::unix::io::RawFd;
    let is_v6 = addr.is_ipv6();
    let domain = if is_v6 { libc::AF_INET6 } else { libc::AF_INET };
    let fd: RawFd = unsafe { libc::socket(domain, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return None;
    }
    struct FdGuard(RawFd);
    impl Drop for FdGuard {
        fn drop(&mut self) {
            unsafe { libc::close(self.0) };
        }
    }
    let _guard = FdGuard(fd);

    apply_probe_qos(fd, is_v6);
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL, 0) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return None;
    }

    let started = Instant::now();
    let rc = match addr {
        SocketAddr::V4(v4) => {
            let mut sa: libc::sockaddr_in = unsafe { std::mem::zeroed() };
            sa.sin_len = std::mem::size_of::<libc::sockaddr_in>() as u8;
            sa.sin_family = libc::AF_INET as libc::sa_family_t;
            sa.sin_port = v4.port().to_be();
            sa.sin_addr = libc::in_addr {
                s_addr: u32::from_ne_bytes(v4.ip().octets()),
            };
            unsafe {
                libc::connect(
                    fd,
                    &sa as *const libc::sockaddr_in as *const libc::sockaddr,
                    std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
                )
            }
        }
        SocketAddr::V6(v6) => {
            let mut sa: libc::sockaddr_in6 = unsafe { std::mem::zeroed() };
            sa.sin6_len = std::mem::size_of::<libc::sockaddr_in6>() as u8;
            sa.sin6_family = libc::AF_INET6 as libc::sa_family_t;
            sa.sin6_port = v6.port().to_be();
            sa.sin6_addr = libc::in6_addr {
                s6_addr: v6.ip().octets(),
            };
            unsafe {
                libc::connect(
                    fd,
                    &sa as *const libc::sockaddr_in6 as *const libc::sockaddr,
                    std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t,
                )
            }
        }
    };

    if rc == 0 {
        return Some(started.elapsed().as_micros().clamp(100, 10_000_000) as u64);
    }
    let err = std::io::Error::last_os_error();
    if err.raw_os_error() == Some(libc::ECONNREFUSED) {
        return Some(started.elapsed().as_micros().clamp(100, 10_000_000) as u64);
    }
    if err.raw_os_error() != Some(libc::EINPROGRESS) {
        return None;
    }

    let mut pfd = libc::pollfd {
        fd,
        events: libc::POLLOUT,
        revents: 0,
    };
    let polled = unsafe { libc::poll(&mut pfd, 1, 250) };
    if polled <= 0 {
        return None;
    }
    let mut so_err: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    let grc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_ERROR,
            &mut so_err as *mut libc::c_int as *mut libc::c_void,
            &mut len,
        )
    };
    if grc == 0 && (so_err == 0 || so_err == libc::ECONNREFUSED) {
        Some(started.elapsed().as_micros().clamp(100, 10_000_000) as u64)
    } else {
        None
    }
}

#[cfg(not(any(target_os = "ios", target_os = "macos")))]
fn measure_tcp_rtt(addr: SocketAddr) -> Option<u64> {
    let started = Instant::now();
    match std::net::TcpStream::connect_timeout(&addr, Duration::from_millis(250)) {
        Ok(stream) => {
            let us = started.elapsed().as_micros().clamp(100, 10_000_000) as u64;
            drop(stream);
            Some(us)
        }
        Err(err) if err.kind() == std::io::ErrorKind::ConnectionRefused => {
            let us = started.elapsed().as_micros().clamp(100, 10_000_000) as u64;
            Some(us)
        }
        Err(_) => None,
    }
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
fn measure_icmp_v6_rtt(ip: std::net::Ipv6Addr, seq: u16) -> Option<u64> {
    use std::os::unix::io::RawFd;
    let fd: RawFd = unsafe { libc::socket(libc::AF_INET6, libc::SOCK_DGRAM, libc::IPPROTO_ICMPV6) };
    if fd < 0 {
        return None;
    }
    struct FdGuard(RawFd);
    impl Drop for FdGuard {
        fn drop(&mut self) {
            unsafe { libc::close(self.0) };
        }
    }
    let _guard = FdGuard(fd);
    apply_probe_qos(fd, true);

    let tv = libc::timeval {
        tv_sec: 0,
        tv_usec: 350_000,
    };
    unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVTIMEO,
            &tv as *const libc::timeval as *const libc::c_void,
            std::mem::size_of::<libc::timeval>() as libc::socklen_t,
        );
    }

    let ident: u16 = 0x5842; // "XB"
    let mut pkt = [0u8; 16];
    pkt[0] = 128; // ICMPv6 Echo Request
    pkt[1] = 0;   // Code 0 (kernel computes ICMPv6 checksum for SOCK_DGRAM)
    pkt[4..6].copy_from_slice(&ident.to_be_bytes());
    pkt[6..8].copy_from_slice(&seq.to_be_bytes());
    pkt[8..16].copy_from_slice(b"XBOXPAD!");

    let mut addr: libc::sockaddr_in6 = unsafe { std::mem::zeroed() };
    addr.sin6_len = std::mem::size_of::<libc::sockaddr_in6>() as u8;
    addr.sin6_family = libc::AF_INET6 as libc::sa_family_t;
    addr.sin6_port = 0;
    addr.sin6_addr = libc::in6_addr {
        s6_addr: ip.octets(),
    };

    let started = Instant::now();
    let sent = unsafe {
        libc::sendto(
            fd,
            pkt.as_ptr() as *const libc::c_void,
            pkt.len(),
            0,
            &addr as *const libc::sockaddr_in6 as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t,
        )
    };
    if sent < 0 {
        return None;
    }

    let mut recv_buf = [0u8; 128];
    let n = unsafe {
        libc::recvfrom(
            fd,
            recv_buf.as_mut_ptr() as *mut libc::c_void,
            recv_buf.len(),
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if n >= 8 {
        Some(started.elapsed().as_micros().clamp(100, 10_000_000) as u64)
    } else {
        None
    }
}

#[cfg(not(any(target_os = "ios", target_os = "macos")))]
fn measure_icmp_v6_rtt(_ip: std::net::Ipv6Addr, _seq: u16) -> Option<u64> {
    None
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
fn measure_icmp_v4_rtt(ip: std::net::Ipv4Addr, seq: u16) -> Option<u64> {
    use std::os::unix::io::RawFd;
    let fd: RawFd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, libc::IPPROTO_ICMP) };
    if fd < 0 {
        return None;
    }
    struct FdGuard(RawFd);
    impl Drop for FdGuard {
        fn drop(&mut self) {
            unsafe { libc::close(self.0) };
        }
    }
    let _guard = FdGuard(fd);
    apply_probe_qos(fd, false);

    let tv = libc::timeval {
        tv_sec: 0,
        tv_usec: 350_000,
    };
    unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVTIMEO,
            &tv as *const libc::timeval as *const libc::c_void,
            std::mem::size_of::<libc::timeval>() as libc::socklen_t,
        );
    }

    let ident: u16 = 0x5842; // "XB"
    let mut pkt = [0u8; 16];
    pkt[0] = 8; // ICMP Echo Request
    pkt[1] = 0; // Code 0
    pkt[4..6].copy_from_slice(&ident.to_be_bytes());
    pkt[6..8].copy_from_slice(&seq.to_be_bytes());
    pkt[8..16].copy_from_slice(b"XBOXPAD!");
    let mut sum: u32 = 0;
    for chunk in pkt.chunks(2) {
        sum += u32::from(u16::from_be_bytes([chunk[0], chunk[1]]));
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    let cksum = !(sum as u16);
    pkt[2..4].copy_from_slice(&cksum.to_be_bytes());

    let mut addr: libc::sockaddr_in = unsafe { std::mem::zeroed() };
    addr.sin_len = std::mem::size_of::<libc::sockaddr_in>() as u8;
    addr.sin_family = libc::AF_INET as libc::sa_family_t;
    addr.sin_port = 0;
    addr.sin_addr = libc::in_addr {
        s_addr: u32::from_ne_bytes(ip.octets()),
    };

    let started = Instant::now();
    let sent = unsafe {
        libc::sendto(
            fd,
            pkt.as_ptr() as *const libc::c_void,
            pkt.len(),
            0,
            &addr as *const libc::sockaddr_in as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
        )
    };
    if sent < 0 {
        return None;
    }

    let mut recv_buf = [0u8; 128];
    let n = unsafe {
        libc::recvfrom(
            fd,
            recv_buf.as_mut_ptr() as *mut libc::c_void,
            recv_buf.len(),
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if n >= 8 {
        Some(started.elapsed().as_micros().clamp(100, 10_000_000) as u64)
    } else {
        None
    }
}

#[cfg(not(any(target_os = "ios", target_os = "macos")))]
fn measure_icmp_v4_rtt(_ip: std::net::Ipv4Addr, _seq: u16) -> Option<u64> {
    None
}

fn measure_stun_udp_rtt(target: SocketAddr, seq: u16) -> Option<u64> {
    let bind_addr = if target.is_ipv4() {
        "0.0.0.0:0"
    } else {
        "[::]:0"
    };
    let sock = std::net::UdpSocket::bind(bind_addr).ok()?;
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    {
        use std::os::unix::io::AsRawFd;
        apply_probe_qos(sock.as_raw_fd(), target.is_ipv6());
    }
    sock.set_read_timeout(Some(Duration::from_millis(350))).ok()?;

    let mut req = [0u8; 20];
    req[0] = 0x00;
    req[1] = 0x01; // STUN Binding Request
    req[4..8].copy_from_slice(&RttMeasuringUdpConn::STUN_MAGIC_COOKIE);
    req[8..10].copy_from_slice(&seq.to_be_bytes());
    req[10..20].copy_from_slice(b"XBOXPADRTT");

    let started = Instant::now();
    sock.send_to(&req, target).ok()?;
    let mut resp = [0u8; 256];
    let (n, _) = sock.recv_from(&mut resp).ok()?;
    if n >= 20
        && resp[4..8] == RttMeasuringUdpConn::STUN_MAGIC_COOKIE
        && resp[8..20] == req[8..20]
    {
        Some(started.elapsed().as_micros().clamp(100, 10_000_000) as u64)
    } else {
        None
    }
}

#[async_trait]
impl Conn for RttMeasuringUdpConn {
    async fn connect(&self, addr: SocketAddr) -> Result<(), UtilError> {
        Ok(self.socket.connect(addr).await?)
    }

    async fn recv(&self, buf: &mut [u8]) -> Result<usize, UtilError> {
        let n = self.socket.recv(buf).await?;
        self.record_incoming_stun(&buf[..n]);
        Ok(n)
    }

    async fn recv_from(&self, buf: &mut [u8]) -> Result<(usize, SocketAddr), UtilError> {
        let (n, addr) = self.socket.recv_from(buf).await?;
        self.record_incoming_stun(&buf[..n]);
        Ok((n, addr))
    }

    async fn send(&self, buf: &[u8]) -> Result<usize, UtilError> {
        self.record_outgoing_stun(buf);
        Ok(self.socket.send(buf).await?)
    }

    async fn send_to(&self, buf: &[u8], target: SocketAddr) -> Result<usize, UtilError> {
        self.record_outgoing_stun(buf);
        Ok(self.socket.send_to(buf, target).await?)
    }

    fn local_addr(&self) -> Result<SocketAddr, UtilError> {
        Ok(self.socket.local_addr()?)
    }

    fn remote_addr(&self) -> Option<SocketAddr> {
        None
    }

    async fn close(&self) -> Result<(), UtilError> {
        Ok(())
    }

    fn as_any(&self) -> &(dyn Any + Send + Sync) {
        self
    }
}

/// Bind an IPv4 (`0.0.0.0:0`) or IPv6 (`[::]:0`, `IPV6_V6ONLY = 1`) UDP socket with:
/// - Enlarged kernel `SO_RCVBUF` (up to 4MB) & `SO_SNDBUF` (up to 1MB)
/// - Apple `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI` (Interactive Video: WMM AC_VI + Wi-Fi PSM suppression)
/// - `IP_TOS` / `IPV6_TCLASS` = `0x88` (DSCP AF41) for router WMM AC_VI hardware queue priority
/// - `RttMeasuringUdpConn` passive RFC 5389 STUN RTT tracking on the live WebRTC media socket.
fn create_tuned_udp_mux(
    is_ipv6: bool,
    stun_rtt_us: Arc<AtomicU64>,
    stun_req_count: Arc<AtomicU64>,
    stun_resp_count: Arc<AtomicU64>,
) -> Option<Arc<UDPMuxDefault>> {
    let std_socket = bind_udp_socket(is_ipv6)?;
    std_socket.set_nonblocking(true).ok()?;

    #[cfg(unix)]
    {
        use std::os::unix::io::AsRawFd;
        let fd = std_socket.as_raw_fd();
        let (applied_rcv, applied_snd, applied_qos) = apply_low_latency_udp_tuning(fd, is_ipv6);
        crate::nano_log!(
            "udp socket tuned family={} SO_RCVBUF={}KB SO_SNDBUF={}KB netServiceVI={}",
            if is_ipv6 { "ipv6" } else { "ipv4" },
            applied_rcv / 1024,
            applied_snd / 1024,
            applied_qos
        );
    }

    let tokio_socket = tokio::net::UdpSocket::from_std(std_socket).ok()?;
    let tracked_conn = RttMeasuringUdpConn::new(
        tokio_socket,
        stun_rtt_us,
        stun_req_count,
        stun_resp_count,
    );
    Some(UDPMuxDefault::new(UDPMuxParams::new(tracked_conn)))
}

#[cfg(unix)]
fn bind_udp_socket(is_ipv6: bool) -> Option<std::net::UdpSocket> {
    use std::os::unix::io::FromRawFd;
    if !is_ipv6 {
        return std::net::UdpSocket::bind("0.0.0.0:0").ok();
    }
    let fd = unsafe { libc::socket(libc::AF_INET6, libc::SOCK_DGRAM, 0) };
    if fd < 0 {
        return None;
    }
    let v6only: libc::c_int = 1;
    let _ = unsafe {
        libc::setsockopt(
            fd,
            libc::IPPROTO_IPV6,
            libc::IPV6_V6ONLY,
            &v6only as *const libc::c_int as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        )
    };
    let mut sa: libc::sockaddr_in6 = unsafe { std::mem::zeroed() };
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    {
        sa.sin6_len = std::mem::size_of::<libc::sockaddr_in6>() as u8;
    }
    sa.sin6_family = libc::AF_INET6 as libc::sa_family_t;
    sa.sin6_port = 0;
    sa.sin6_addr = libc::in6_addr { s6_addr: [0u8; 16] };
    let rc = unsafe {
        libc::bind(
            fd,
            &sa as *const libc::sockaddr_in6 as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t,
        )
    };
    if rc < 0 {
        unsafe { libc::close(fd) };
        return None;
    }
    Some(unsafe { std::net::UdpSocket::from_raw_fd(fd) })
}

#[cfg(not(unix))]
fn bind_udp_socket(is_ipv6: bool) -> Option<std::net::UdpSocket> {
    if is_ipv6 {
        std::net::UdpSocket::bind("[::]:0").ok()
    } else {
        std::net::UdpSocket::bind("0.0.0.0:0").ok()
    }
}

#[cfg(unix)]
fn apply_low_latency_udp_tuning(fd: std::os::unix::io::RawFd, is_ipv6: bool) -> (i32, i32, bool) {
    let mut applied_rcv = 0i32;
    for &sz in &[4 * 1024 * 1024i32, 2 * 1024 * 1024, 1024 * 1024, 512 * 1024] {
        let rc = unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_RCVBUF,
                &sz as *const i32 as *const libc::c_void,
                std::mem::size_of::<i32>() as libc::socklen_t,
            )
        };
        if rc == 0 {
            applied_rcv = sz;
            break;
        }
    }
    let mut applied_snd = 0i32;
    for &sz in &[1024 * 1024i32, 512 * 1024, 256 * 1024] {
        let rc = unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_SNDBUF,
                &sz as *const i32 as *const libc::c_void,
                std::mem::size_of::<i32>() as libc::socklen_t,
            )
        };
        if rc == 0 {
            applied_snd = sz;
            break;
        }
    }

    #[cfg(any(target_os = "ios", target_os = "macos"))]
    let applied_qos = apply_probe_qos(fd, is_ipv6);
    #[cfg(not(any(target_os = "ios", target_os = "macos")))]
    let applied_qos = false;

    (applied_rcv, applied_snd, applied_qos)
}

/// Collect all local UDP ports owned by this PeerConnection's ICE agent (selected candidate port,
/// gathered `host` candidate ports, and `rport` base ports from `srflx`/`relay` candidates).
fn collect_local_udp_ports(selected_port: u16, candidates: &[IceCandidate]) -> Vec<u16> {
    let mut ports = Vec::new();
    if selected_port > 0 {
        ports.push(selected_port);
    }
    for cand in candidates {
        let tokens: Vec<&str> = cand.candidate.split_whitespace().collect();
        // RFC 5245: foundation component proto priority ip port typ <type> [raddr <ip> rport <port>]
        if let Some(port_tok) = tokens.get(5) {
            if let Ok(port) = port_tok.parse::<u16>() {
                let is_host = tokens.get(7).copied() == Some("host");
                if is_host && port > 0 && !ports.contains(&port) {
                    ports.push(port);
                }
            }
        }
        for pair in tokens.windows(2) {
            if pair[0] == "rport" {
                if let Ok(rport) = pair[1].parse::<u16>() {
                    if rport > 0 && !ports.contains(&rport) {
                        ports.push(rport);
                    }
                }
            }
        }
    }
    ports
}

/// Locate all live ephemeral UDP sockets owned by this process bound to any port in `local_ports`
/// and apply `SO_RCVBUF` (4MB), `SO_SNDBUF` (1MB), `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI`
/// (WMM AC_VI + iOS Wi-Fi PSM suppression), and DSCP AF41.
#[cfg(unix)]
fn tune_active_udp_sockets_by_ports(local_ports: &[u16]) -> usize {
    if local_ports.is_empty() {
        return 0;
    }
    let mut matched = 0usize;
    for fd in 3..4096i32 {
        let mut sock_type: libc::c_int = 0;
        let mut type_len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        let rc_type = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_TYPE,
                &mut sock_type as *mut libc::c_int as *mut libc::c_void,
                &mut type_len,
            )
        };
        if rc_type != 0 || sock_type != libc::SOCK_DGRAM {
            continue;
        }
        let mut storage: libc::sockaddr_storage = unsafe { std::mem::zeroed() };
        let mut addr_len = std::mem::size_of::<libc::sockaddr_storage>() as libc::socklen_t;
        let rc_name = unsafe {
            libc::getsockname(
                fd,
                &mut storage as *mut libc::sockaddr_storage as *mut libc::sockaddr,
                &mut addr_len,
            )
        };
        if rc_name != 0 {
            continue;
        }
        let (port, fd_is_v6) = if storage.ss_family == libc::AF_INET as libc::sa_family_t {
            let sin = unsafe { &*(&storage as *const libc::sockaddr_storage as *const libc::sockaddr_in) };
            (u16::from_be(sin.sin_port), false)
        } else if storage.ss_family == libc::AF_INET6 as libc::sa_family_t {
            let sin6 = unsafe { &*(&storage as *const libc::sockaddr_storage as *const libc::sockaddr_in6) };
            (u16::from_be(sin6.sin6_port), true)
        } else {
            continue;
        };
        if local_ports.contains(&port) {
            let (rcv, snd, qos) = apply_low_latency_udp_tuning(fd, fd_is_v6);
            crate::nano_log!(
                "ephemeral udp socket tuned fd={} port={} family={} SO_RCVBUF={}KB SO_SNDBUF={}KB netServiceVI={}",
                fd,
                port,
                if fd_is_v6 { "ipv6" } else { "ipv4" },
                rcv / 1024,
                snd / 1024,
                qos
            );
            matched += 1;
        }
    }
    matched
}

/// Register Opus + H.264 with High Profile (CABAC, Level 4.2/5.0/4.1/4.0) prioritized BEFORE
/// Baseline so Xbox produces ~35% smaller keyframes and far fewer burst UDP packets.
fn register_xbox_codecs(media_engine: &mut MediaEngine) -> Result<(), NanoError> {
    media_engine
        .register_codec(
            RTCRtpCodecParameters {
                capability: RTCRtpCodecCapability {
                    mime_type: MIME_TYPE_OPUS.to_owned(),
                    clock_rate: 48_000,
                    channels: 2,
                    sdp_fmtp_line: "minptime=10;useinbandfec=1".to_owned(),
                    rtcp_feedback: vec![],
                },
                payload_type: 111,
                ..Default::default()
            },
            RTPCodecType::Audio,
        )
        .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;

    let video_rtcp_feedback = vec![
        RTCPFeedback {
            typ: "goog-remb".to_owned(),
            parameter: "".to_owned(),
        },
        RTCPFeedback {
            typ: "ccm".to_owned(),
            parameter: "fir".to_owned(),
        },
        RTCPFeedback {
            typ: "nack".to_owned(),
            parameter: "".to_owned(),
        },
        RTCPFeedback {
            typ: "nack".to_owned(),
            parameter: "pli".to_owned(),
        },
    ];

    let h264_profiles: &[(u8, &str)] = &[
        // H.264 High Profile Level 4.2 / 5.0 / 4.1 / 4.0 (CABAC -> smaller keyframes, hardware decoded on iPad)
        (120, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64002a"),
        (123, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640032"),
        (119, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640029"),
        (118, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640028"),
        // Constrained Baseline / Baseline fallbacks
        (125, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"),
        (102, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f"),
        (108, "level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42e01f"),
        (127, "level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42001f"),
    ];

    for &(pt, fmtp) in h264_profiles {
        media_engine
            .register_codec(
                RTCRtpCodecParameters {
                    capability: RTCRtpCodecCapability {
                        mime_type: MIME_TYPE_H264.to_owned(),
                        clock_rate: 90_000,
                        channels: 0,
                        sdp_fmtp_line: fmtp.to_owned(),
                        rtcp_feedback: video_rtcp_feedback.clone(),
                    },
                    payload_type: pt,
                    ..Default::default()
                },
                RTPCodecType::Video,
            )
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
    }

    Ok(())
}

/// Configure tuned low-latency RTCP interceptors:
/// - RTT-aware SmartNackGenerator (15ms poll, per-packet RTT cooldown, 4-retry cap, passive NACK RTT)
/// - AccurateReceiverReport (RFC 3550 4096-bit dedup without 128-bit loss amplification + SR LSR/DLSR)
/// - SenderReport + NackResponder
/// - Zero-drift, reorder-safe FastTwccReceiver (35ms cadence + 64-pkt burst flush)
fn register_low_latency_interceptors(
    mut registry: Registry,
    media_engine: &mut MediaEngine,
    stun_rtt_us: Arc<AtomicU64>,
    probe_rtt_us: Arc<AtomicU64>,
    nack_rtt_us: Arc<AtomicU64>,
    route_kind: Arc<AtomicU8>,
    video_jitter_us: Arc<AtomicU64>,
) -> Result<Registry, NanoError> {
    // 1. NACK (feedback attributes already registered on H.264 codecs in register_xbox_codecs)
    registry.add(Box::new(NackResponder::builder()));
    registry.add(Box::new(SmartNackGeneratorBuilder::new(
        Duration::from_millis(15),
        stun_rtt_us,
        probe_rtt_us,
        nack_rtt_us,
        route_kind,
        video_jitter_us,
    )));

    // 2. Accurate RTCP Receiver Report (500ms) + Sender Report
    registry.add(Box::new(AccurateReceiverReportBuilder::new(
        Duration::from_millis(500),
    )));
    registry.add(Box::new(SenderReport::builder()));

    // 3. Zero-drift, reorder-safe TWCC Receiver (35ms + 64-packet burst flush)
    media_engine.register_feedback(
        RTCPFeedback {
            typ: TYPE_RTCP_FB_TRANSPORT_CC.to_owned(),
            ..Default::default()
        },
        RTPCodecType::Video,
    );
    media_engine
        .register_header_extension(
            RTCRtpHeaderExtensionCapability {
                uri: TRANSPORT_CC_URI.to_owned(),
            },
            RTPCodecType::Video,
            None,
        )
        .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;

    media_engine.register_feedback(
        RTCPFeedback {
            typ: TYPE_RTCP_FB_TRANSPORT_CC.to_owned(),
            ..Default::default()
        },
        RTPCodecType::Audio,
    );
    media_engine
        .register_header_extension(
            RTCRtpHeaderExtensionCapability {
                uri: TRANSPORT_CC_URI.to_owned(),
            },
            RTPCodecType::Audio,
            None,
        )
        .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;

    registry.add(Box::new(FastTwccReceiverBuilder::new(
        Duration::from_millis(35),
    )));

    Ok(registry)
}

fn to_rtc_ice_server(server: &crate::protocol::IceServer) -> RTCIceServer {
    RTCIceServer {
        urls: vec![server.urls.clone()],
        username: server.username.clone().unwrap_or_default(),
        credential: server.credential.clone().unwrap_or_default(),
    }
}

fn normalize_remote_candidate_line(raw: &str) -> String {
    let trimmed = raw.trim();
    trimmed.strip_prefix("a=").unwrap_or(trimmed).to_owned()
}

fn candidate_ip_family(candidate_line: &str) -> &'static str {
    let normalized = candidate_line
        .trim()
        .strip_prefix("a=")
        .unwrap_or(candidate_line.trim());
    let Some(ip_str) = normalized.split_whitespace().nth(4) else {
        return "unknown";
    };
    let clean_ip = ip_str.split('%').next().unwrap_or(ip_str);
    match clean_ip.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(v4)) => {
            if v4.is_private() || v4.is_link_local() || v4.is_loopback() {
                "v4-priv"
            } else {
                "v4-pub"
            }
        }
        Ok(std::net::IpAddr::V6(v6)) => {
            let seg = v6.segments();
            if seg[0] == 0x2001 && seg[1] == 0x0000 {
                "v6-teredo"
            } else if (seg[0] & 0xffc0) == 0xfe80 || (seg[0] & 0xfe00) == 0xfc00 {
                "v6-local"
            } else {
                "v6-pub"
            }
        }
        Err(_) => "host",
    }
}

fn candidate_to_protocol_candidate(init: &RTCIceCandidateInit) -> Option<IceCandidate> {
    let candidate = init.candidate.trim();
    if candidate.is_empty() || candidate == "a=end-of-candidates" {
        return None;
    }
    if candidate.contains("UDP") && candidate.contains("tcptype") {
        return None;
    }
    // webrtc-rs 0.17.x hardcodes `sdp_mid: Some("")` in `RTCIceCandidate::to_json()`.
    // Xbox's WebRTC stack rejects or ignores candidates whose `sdpMid` doesn't match the
    // offer's bundled `a=mid:0`, which silently breaks WAN STUN/TURN hole-punching while
    // LAN still works via peer-reflexive (`prflx`) packets. Always normalize blank mid -> "0".
    let sdp_mid = init
        .sdp_mid
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("0")
        .to_owned();
    Some(IceCandidate::new(
        candidate.to_owned(),
        sdp_mid,
        init.sdp_mline_index.unwrap_or(0) as u32,
    ))
}

fn json_message_type(value: &str) -> Option<String> {
    let parsed = serde_json::from_str::<serde_json::Value>(value).ok()?;
    parsed.get("type")?.as_str().map(|value| value.to_owned())
}

async fn send_initial_message_bundle(
    channel: &RTCDataChannel,
    shared: &PeerSharedState,
) -> Result<(), NanoError> {
    for message in initial_system_ui_messages(shared.max_touchpoints as u32) {
        channel
            .send_text(message.to_json())
            .await
            .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
    }
    Ok(())
}

async fn run_processed_frame_loop(channel: Arc<RTCDataChannel>, shared: Arc<PeerSharedState>) {
    sleep(Duration::from_secs(1)).await;
    loop {
        match send_processed_frame(&channel, &shared).await {
            Ok(_) => {}
            Err(error) => {
                crate::nano_warn!("input processed frame stopped: {error}");
                break;
            }
        }
        sleep(Duration::from_secs(2)).await;
    }
}

async fn send_processed_frame(
    channel: &RTCDataChannel,
    shared: &PeerSharedState,
) -> Result<u32, NanoError> {
    let sequence = shared.next_input_sequence();
    let now = performance_now_ms();
    let now_u32 = clamp_f64_to_u32(now);
    let submitted_time_ms = now_u32.saturating_sub(PROCESSED_FRAME_FEEDBACK_DECODE_MS);
    let frame = MetadataFrame {
        server_data_key: epoch_ms_low_u32(),
        first_frame_packet_arrival_time_ms: submitted_time_ms,
        frame_submitted_time_ms: submitted_time_ms,
        frame_decoded_time_ms: now_u32,
        frame_rendered_time_ms: now_u32,
    };
    let packet = InputPacket::with_data(sequence, vec![frame], Vec::new(), Vec::new(), 1920, 1080);
    channel
        .send(&Bytes::from(packet.to_bytes(now)))
        .await
        .map_err(|error| NanoError::PeerConnectionOwned(error.to_string()))?;
    Ok(sequence)
}

fn now_ms() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as f64)
        .unwrap_or(0.0)
}

fn epoch_ms_low_u32() -> u32 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| (duration.as_millis() & u128::from(u32::MAX)) as u32)
        .unwrap_or(0)
}

fn performance_now_ms() -> f64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64() * 1000.0
}

fn clamp_f64_to_u32(value: f64) -> u32 {
    if !value.is_finite() || value <= 0.0 {
        return 0;
    }
    value.round().min(f64::from(u32::MAX)) as u32
}

struct NoopVideoSink;

impl VideoFrameSink for NoopVideoSink {
    fn push_h264_access_unit(&self, _data: &[u8], _pts_us: i64, _keyframe: bool) {}
}

async fn run_audio_track(
    track: Arc<TrackRemote>,
    audio_sink: Option<Arc<dyn AudioFrameSink + Send + Sync>>,
) {
    use std::collections::BTreeMap;

    let codec = track.codec().capability;
    let sample_rate = codec.clock_rate.max(1);
    let channels = codec.channels.max(1);
    crate::nano_log!(
        "audio track reader start mode=zero-wait-in-order+15ms-reorder codec={} sampleRate={} channels={} audioSink={}",
        codec.mime_type,
        sample_rate,
        channels,
        audio_sink.is_some()
    );
    let mut packets = 0u64;
    let mut reordered_recovered = 0u64;
    let mut first_timestamp: Option<u32> = None;
    let mut expected_seq: Option<u16> = None;
    // Small reorder buffer: in-order packets emit at 0ms; slightly out-of-order Wi-Fi/5G packets
    // wait up to 25ms (or 4 packets) instead of being dropped and causing 20ms audio gaps.
    let mut pending: BTreeMap<u16, (u32, Bytes, Instant)> = BTreeMap::new();

    let emit_packet = |ts: u32,
                       payload: &Bytes,
                       first_ts: &mut Option<u32>,
                       packets: &mut u64| {
        let first = first_ts.get_or_insert(ts);
        let pts_us =
            u64::from(ts.wrapping_sub(*first)) * 1_000_000 / u64::from(sample_rate);
        if let Some(sink) = audio_sink.as_ref() {
            sink.push_opus_frame(payload, pts_us as i64, sample_rate, channels);
        }
        *packets += 1;
        if *packets == 1 || *packets % 300 == 0 {
            crate::nano_log!(
                "audio rtp packets={} bytes={} ptsUs={}",
                *packets,
                payload.len(),
                pts_us
            );
        }
    };

    loop {
        let next_pkt = if !pending.is_empty() {
            match timeout(Duration::from_millis(8), track.read_rtp()).await {
                Ok(Ok((pkt, _))) => Some(pkt),
                Ok(Err(_)) => break,
                Err(_) => None,
            }
        } else {
            match track.read_rtp().await {
                Ok((pkt, _)) => Some(pkt),
                Err(_) => break,
            }
        };

        let now = Instant::now();
        if let Some(packet) = next_pkt {
            let payload = packet.payload;
            if !payload.is_empty() {
                let seq = packet.header.sequence_number;
                let ts = packet.header.timestamp;
                match expected_seq {
                    None => {
                        emit_packet(ts, &payload, &mut first_timestamp, &mut packets);
                        expected_seq = Some(seq.wrapping_add(1));
                    }
                    Some(exp) if seq == exp => {
                        emit_packet(ts, &payload, &mut first_timestamp, &mut packets);
                        let mut cur = seq.wrapping_add(1);
                        while let Some((pts, data, _)) = pending.remove(&cur) {
                            reordered_recovered += 1;
                            emit_packet(pts, &data, &mut first_timestamp, &mut packets);
                            cur = cur.wrapping_add(1);
                        }
                        expected_seq = Some(cur);
                    }
                    Some(exp) => {
                        let ahead = seq.wrapping_sub(exp);
                        // Accept reasonable forward reorder (1..=32); drop true duplicates / ancient packets
                        if ahead > 0 && ahead <= 32 {
                            pending.entry(seq).or_insert((ts, payload, now));
                        } else if ahead > 32 && ahead < 0x8000 {
                            // Large jump (e.g. sender reset / long drought): flush pending and resync
                            pending.clear();
                            emit_packet(ts, &payload, &mut first_timestamp, &mut packets);
                            expected_seq = Some(seq.wrapping_add(1));
                        }
                    }
                }
            }
        }

        // Release oldest buffered audio packet if gap wait exceeded 15ms or depth >= 3 packets
        if let Some(exp) = expected_seq {
            while !pending.is_empty() {
                let oldest_seq = pending
                    .keys()
                    .copied()
                    .min_by_key(|&s| s.wrapping_sub(exp));
                let Some(s) = oldest_seq else { break };
                let expired = pending
                    .get(&s)
                    .map(|(_, _, arrived)| now.duration_since(*arrived) >= Duration::from_millis(15))
                    .unwrap_or(false);
                if pending.len() >= 3 || expired {
                    if let Some((pts, data, _)) = pending.remove(&s) {
                        emit_packet(pts, &data, &mut first_timestamp, &mut packets);
                        let mut cur = s.wrapping_add(1);
                        while let Some((npts, ndata, _)) = pending.remove(&cur) {
                            emit_packet(npts, &ndata, &mut first_timestamp, &mut packets);
                            cur = cur.wrapping_add(1);
                        }
                        expected_seq = Some(cur);
                    }
                } else {
                    break;
                }
            }
        }
    }
    crate::nano_warn!(
        "audio track reader stopped packets={packets} reorderedRecovered={reordered_recovered}"
    );
}

async fn run_low_latency_video_track(
    track: Arc<TrackRemote>,
    video_sink: Arc<dyn VideoFrameSink + Send + Sync>,
    shared: Arc<PeerSharedState>,
    peer_connection: Arc<RTCPeerConnection>,
    control_channel: Option<Arc<RTCDataChannel>>,
) {
    // Complete frames still emit at 0ms on RTP marker; reorder_wait ONLY applies when a packet
    // is actually missing, dynamically adapting to live RTT + RFC 3550 jitter so NACK recovery
    // succeeds on both 4ms LAN and 70-160ms cellular/WAN without triggering PLI keyframe storms.
    let base_reorder_wait_ms = shared.max_video_delay_ms.clamp(45, 130);
    let mut current_reorder_wait_ms = base_reorder_wait_ms;
    crate::nano_log!(
        "video track reader start mode=zero-wait-marker+rtt-jitter-adaptive-nack maxVideoDelayMs={} baseReorderWaitMs={}",
        shared.max_video_delay_ms,
        base_reorder_wait_ms
    );
    let clock_rate = track.codec().capability.clock_rate.max(1);
    let media_ssrc = track.ssrc();
    shared.video_ssrc.store(media_ssrc, Ordering::Relaxed);
    let mut assembler = LowLatencyH264Assembler::new(Duration::from_millis(base_reorder_wait_ms));
    let mut first_timestamp: Option<u32> = None;
    let mut frames = 0u64;
    let mut packets = 0u64;
    let mut samples_with_drops = 0u64;
    let mut observed_keyframe = false;
    let mut last_pli_request: Option<Instant> = None;
    let mut waiting_clean_keyframe_since: Option<Instant> = None;

    // RFC 3550 inter-arrival RTP jitter estimator (in microseconds)
    let rtp_origin = Instant::now();
    let mut prev_transit_us: Option<i64> = None;
    let mut jitter_est_us: f64 = 0.0;

    loop {
        let ready_aus = if assembler.has_pending_frames() {
            match timeout(Duration::from_millis(50), track.read_rtp()).await {
                Ok(Ok((packet, _))) => {
                    shared
                        .video_packets_received
                        .fetch_add(1, Ordering::Relaxed);
                    shared
                        .video_bytes_received
                        .fetch_add(packet.payload.len() as u64, Ordering::Relaxed);
                    packets += 1;

                    let arrival_us = rtp_origin.elapsed().as_micros() as i64;
                    let rtp_us = (u64::from(packet.header.timestamp) * 1_000_000 / u64::from(clock_rate)) as i64;
                    let transit = arrival_us.wrapping_sub(rtp_us);
                    if let Some(prev) = prev_transit_us {
                        let d = (transit.wrapping_sub(prev)).abs() as f64;
                        if d < 500_000.0 {
                            jitter_est_us += (d - jitter_est_us) / 16.0;
                            shared
                                .video_jitter_us
                                .store(jitter_est_us.round() as u64, Ordering::Relaxed);
                        }
                    }
                    prev_transit_us = Some(transit);

                    if packets % 24 == 0 {
                        let live_rtt_us = latest_live_rtt_us(&shared);
                        let target_wait_ms = compute_adaptive_reorder_wait_ms(
                            base_reorder_wait_ms,
                            live_rtt_us,
                            jitter_est_us.round() as u64,
                            shared.route_kind.load(Ordering::Relaxed),
                        );
                        if target_wait_ms != current_reorder_wait_ms {
                            current_reorder_wait_ms = target_wait_ms;
                            assembler.set_max_reorder_wait(Duration::from_millis(target_wait_ms));
                        }
                    }

                    assembler.push(packet)
                }
                Ok(Err(_)) => break,
                Err(_) => assembler.flush_expired(),
            }
        } else {
            let Ok((packet, _)) = track.read_rtp().await else {
                break;
            };
            shared
                .video_packets_received
                .fetch_add(1, Ordering::Relaxed);
            shared
                .video_bytes_received
                .fetch_add(packet.payload.len() as u64, Ordering::Relaxed);
            packets += 1;

            let arrival_us = rtp_origin.elapsed().as_micros() as i64;
            let rtp_us = (u64::from(packet.header.timestamp) * 1_000_000 / u64::from(clock_rate)) as i64;
            let transit = arrival_us.wrapping_sub(rtp_us);
            if let Some(prev) = prev_transit_us {
                let d = (transit.wrapping_sub(prev)).abs() as f64;
                if d < 500_000.0 {
                    jitter_est_us += (d - jitter_est_us) / 16.0;
                    shared
                        .video_jitter_us
                        .store(jitter_est_us.round() as u64, Ordering::Relaxed);
                }
            }
            prev_transit_us = Some(transit);

            if packets % 24 == 0 {
                let live_rtt_us = latest_live_rtt_us(&shared);
                let target_wait_ms = compute_adaptive_reorder_wait_ms(
                    base_reorder_wait_ms,
                    live_rtt_us,
                    jitter_est_us.round() as u64,
                    shared.route_kind.load(Ordering::Relaxed),
                );
                if target_wait_ms != current_reorder_wait_ms {
                    current_reorder_wait_ms = target_wait_ms;
                    assembler.set_max_reorder_wait(Duration::from_millis(target_wait_ms));
                }
            }

            assembler.push(packet)
        };

        for au in ready_aus {
            if au.data.is_empty() {
                continue;
            }
            let keyframe = au.keyframe || contains_idr_nalu(&au.data);
            if au.incomplete {
                samples_with_drops += 1;
                shared
                    .video_packets_lost
                    .fetch_add(u64::from(au.dropped_packets.max(1)), Ordering::Relaxed);
                shared.video_frames_dropped.fetch_add(1, Ordering::Relaxed);
                if samples_with_drops <= 5 || samples_with_drops % 120 == 0 {
                    crate::nano_warn!(
                        "video au dropped incomplete samples={} droppedPackets={} rtpTs={} keyframe={} reorderWaitMs={} nals={}",
                        samples_with_drops,
                        au.dropped_packets,
                        au.rtp_timestamp,
                        keyframe,
                        current_reorder_wait_ms,
                        h264_nal_summary(&au.data)
                    );
                }
                // Pass ONLY clean SPS/PPS parameter sets (never corrupted slice NALs) so
                // VideoToolbox updates its format description without throwing decode errors
                // or triggering duplicate keyframe storms.
                if au.has_param_sets {
                    let param_only = extract_sps_pps_annex_b(&au.data);
                    if !param_only.is_empty() {
                        let base_timestamp = first_timestamp.get_or_insert(au.rtp_timestamp);
                        let pts_us = rtp_timestamp_to_us(au.rtp_timestamp, *base_timestamp, clock_rate);
                        video_sink.push_h264_access_unit(&param_only, pts_us, false);
                    }
                }
                observed_keyframe = false;
                waiting_clean_keyframe_since.get_or_insert_with(Instant::now);
                request_video_pli_throttled(
                    &peer_connection,
                    control_channel.as_ref(),
                    media_ssrc,
                    latest_live_rtt_us(&shared),
                    &mut last_pli_request,
                    if keyframe {
                        "dropped-incomplete-keyframe"
                    } else {
                        "dropped-incomplete-sample"
                    },
                )
                .await;
                continue;
            }

            if !observed_keyframe && !keyframe {
                if au.has_param_sets {
                    let param_only = extract_sps_pps_annex_b(&au.data);
                    if !param_only.is_empty() {
                        let base_timestamp = first_timestamp.get_or_insert(au.rtp_timestamp);
                        let pts_us = rtp_timestamp_to_us(au.rtp_timestamp, *base_timestamp, clock_rate);
                        video_sink.push_h264_access_unit(&param_only, pts_us, false);
                    }
                }
                waiting_clean_keyframe_since.get_or_insert_with(Instant::now);
                request_video_pli_throttled(
                    &peer_connection,
                    control_channel.as_ref(),
                    media_ssrc,
                    latest_live_rtt_us(&shared),
                    &mut last_pli_request,
                    "waiting-clean-keyframe",
                )
                .await;
                continue;
            }
            if !observed_keyframe && keyframe {
                let recover_ms = waiting_clean_keyframe_since
                    .take()
                    .map(|started| started.elapsed().as_millis())
                    .unwrap_or(0);
                crate::nano_log!(
                    "video clean keyframe accepted rtpTs={} recoverMs={} nals={}",
                    au.rtp_timestamp,
                    recover_ms,
                    h264_nal_summary(&au.data)
                );
                observed_keyframe = true;
            }

            let base_timestamp = first_timestamp.get_or_insert(au.rtp_timestamp);
            let pts_us = rtp_timestamp_to_us(au.rtp_timestamp, *base_timestamp, clock_rate);
            frames += 1;
            shared
                .video_frames_received
                .store(frames, Ordering::Relaxed);
            if frames == 1 || keyframe || frames % 120 == 0 {
                crate::nano_log!(
                    "video au frames={} packets={} bytes={} ptsUs={} keyframe={} nals={}",
                    frames,
                    packets,
                    au.data.len(),
                    pts_us,
                    keyframe,
                    h264_nal_summary(&au.data)
                );
            }
            video_sink.push_h264_access_unit(&au.data, pts_us, keyframe);
        }
    }

    crate::nano_warn!("video track reader stopped mode=zero-wait-marker frames={frames}");
}

async fn run_rtcp_reader(receiver: Arc<RTCRtpReceiver>, kind: MediaTrackKind) {
    let mut packets = 0u64;
    loop {
        match receiver.read_rtcp().await {
            Ok((rtcp_pkts, _)) => {
                packets += rtcp_pkts.len() as u64;
                if packets == rtcp_pkts.len() as u64 && packets > 0 {
                    crate::nano_log!("inbound rtcp active kind={kind:?} firstBatch={packets}");
                }
            }
            Err(_) => break,
        }
    }
    crate::nano_log!("inbound rtcp reader stopped kind={kind:?} totalPackets={packets}");
}

fn summarize_remote_answer_sdp(sdp: &str) -> String {
    let mut in_video = false;
    let mut fmt_line = String::new();
    let mut has_twcc = false;
    let mut has_remb = false;
    let mut has_nack = false;
    let mut has_rtx = false;
    let mut b_as = String::new();

    for raw_line in sdp.lines() {
        let line = raw_line.trim();
        if line.starts_with("m=video ") {
            in_video = true;
            fmt_line = line.to_owned();
            continue;
        }
        if line.starts_with("m=") {
            in_video = false;
            continue;
        }
        if !in_video {
            continue;
        }
        if line.contains("transport-wide-cc") || line.contains("transport-cc") {
            has_twcc = true;
        }
        if line.contains("goog-remb") {
            has_remb = true;
        }
        if line.starts_with("a=rtcp-fb:") && line.contains(" nack") {
            has_nack = true;
        }
        if line.to_ascii_lowercase().contains("rtx/") {
            has_rtx = true;
        }
        if line.starts_with("b=AS:") || line.starts_with("b=TIAS:") {
            b_as = line.to_owned();
        }
    }
    format!(
        "video=[{fmt_line}] twcc={has_twcc} remb={has_remb} nack={has_nack} rtx={has_rtx} bw={}",
        if b_as.is_empty() { "none" } else { &b_as }
    )
}

fn extract_sps_pps_annex_b(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0usize;
    let mut nal_starts: Vec<(usize, usize)> = Vec::new();
    while i + 3 <= data.len() {
        if i + 4 <= data.len() && data[i..i + 4] == [0, 0, 0, 1] {
            nal_starts.push((i, i + 4));
            i += 4;
        } else if data[i..i + 3] == [0, 0, 1] {
            nal_starts.push((i, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    for idx in 0..nal_starts.len() {
        let (_, payload_start) = nal_starts[idx];
        let payload_end = if idx + 1 < nal_starts.len() {
            nal_starts[idx + 1].0
        } else {
            data.len()
        };
        if payload_start < payload_end {
            let nal_type = data[payload_start] & 0x1F;
            if nal_type == 7 || nal_type == 8 {
                out.extend_from_slice(&[0, 0, 0, 1]);
                out.extend_from_slice(&data[payload_start..payload_end]);
            }
        }
    }
    out
}

fn latest_live_rtt_us(shared: &PeerSharedState) -> u64 {
    let stun = shared.stun_rtt_us.load(Ordering::Relaxed);
    if stun > 0 {
        return stun;
    }
    let probe = shared.probe_rtt_us.load(Ordering::Relaxed);
    if probe > 0 {
        return probe;
    }
    shared.nack_rtt_us.load(Ordering::Relaxed)
}

/// Compute RTT + jitter-adaptive reorder wait so SmartNack retransmits (and 45-60ms Apple
/// AWDL off-channel Wi-Fi hops) finish before a frame is dropped. Complete frames STILL emit at
/// 0ms immediately on RTP marker; this wait ONLY engages when a packet is actually delayed/missing.
fn compute_adaptive_reorder_wait_ms(
    base_ms: u64,
    live_rtt_us: u64,
    jitter_us: u64,
    route_kind: u8,
) -> u64 {
    let floor_ms = base_ms.clamp(75, 130);
    let rtt_ms = if live_rtt_us > 0 {
        live_rtt_us as f64 / 1000.0
    } else {
        match route_kind {
            2 => 55.0, // WAN P2P fallback before first RTT probe/NACK sample arrives
            3 => 75.0, // TURN relay fallback
            _ => 0.0,
        }
    };
    let jitter_ms = (jitter_us as f64 / 1000.0).min(45.0);
    if rtt_ms <= 0.0 {
        return floor_ms;
    }
    let adaptive = (rtt_ms * 1.45 + jitter_ms * 2.5 + 28.0).round() as u64;
    floor_ms.max(adaptive).clamp(75, 240)
}

/// Distinguish true LAN (same RFC1918 private IPv4 / link-local / same IPv6 /64 prefix)
/// from public Internet end-to-end Global IPv6 direct connections.
fn are_same_lan_subnet(local_ip: &str, remote_ip: &str) -> bool {
    let local_clean = local_ip.split('%').next().unwrap_or(local_ip).trim();
    let remote_clean = remote_ip.split('%').next().unwrap_or(remote_ip).trim();
    let (Ok(lip), Ok(rip)) = (
        local_clean.parse::<std::net::IpAddr>(),
        remote_clean.parse::<std::net::IpAddr>(),
    ) else {
        return false;
    };
    match (lip, rip) {
        (std::net::IpAddr::V4(l), std::net::IpAddr::V4(r)) => {
            (l.is_private() || l.is_link_local() || l.is_loopback())
                && (r.is_private() || r.is_link_local() || r.is_loopback())
        }
        (std::net::IpAddr::V6(l), std::net::IpAddr::V6(r)) => {
            if l.is_loopback() && r.is_loopback() {
                return true;
            }
            let ls = l.segments();
            let rs = r.segments();
            let l_local = (ls[0] & 0xffc0) == 0xfe80 || (ls[0] & 0xfe00) == 0xfc00;
            let r_local = (rs[0] & 0xffc0) == 0xfe80 || (rs[0] & 0xfe00) == 0xfc00;
            if l_local && r_local {
                return true;
            }
            // Global IPv6 Host <-> Host: only true LAN when both share the same /64 prefix
            ls[0..4] == rs[0..4]
        }
        _ => false,
    }
}

async fn request_video_pli_throttled(
    peer_connection: &Arc<RTCPeerConnection>,
    control_channel: Option<&Arc<RTCDataChannel>>,
    media_ssrc: u32,
    live_rtt_us: u64,
    last_request: &mut Option<Instant>,
    reason: &str,
) {
    let rtt_ms = live_rtt_us / 1000;
    let min_interval = Duration::from_millis((rtt_ms * 3).clamp(
        VIDEO_PLI_REQUEST_MIN_INTERVAL.as_millis() as u64,
        900,
    ));
    let now = Instant::now();
    if last_request
        .map(|last| now.duration_since(last) < min_interval)
        .unwrap_or(false)
    {
        return;
    }
    *last_request = Some(now);

    // Send RTCP PLI only (1 clean IDR keyframe) when media_ssrc is known; sending BOTH
    // ControlChannel + RTCP PLI makes Xbox emit two back-to-back 32KB IDR frames,
    // which triggers cellular/WAN congestion bursts.
    if media_ssrc == 0 {
        if let Some(channel) = control_channel {
            let message = ControlMessage::video_keyframe_requested(true).to_json();
            let _ = channel.send_text(message).await;
        }
        return;
    }

    let pli = PictureLossIndication {
        sender_ssrc: 0,
        media_ssrc,
    };
    match peer_connection.write_rtcp(&[Box::new(pli)]).await {
        Ok(bytes) => {
            crate::nano_log!(
                "video pli requested reason={reason} ssrc={media_ssrc} bytes={bytes} minIntervalMs={}",
                min_interval.as_millis()
            )
        }
        Err(error) => {
            crate::nano_warn!(
                "video rtcp pli request failed reason={reason} ssrc={media_ssrc}: {error}"
            )
        }
    }
}

fn rtp_timestamp_to_us(timestamp: u32, base_timestamp: u32, clock_rate: u32) -> i64 {
    let delta = timestamp.wrapping_sub(base_timestamp) as u64;
    ((delta * 1_000_000u64) / u64::from(clock_rate.max(1))) as i64
}

fn contains_idr_nalu(data: &[u8]) -> bool {
    let mut index = 0usize;
    while index + 4 <= data.len() {
        if data[index..].starts_with(&[0, 0, 0, 1]) {
            let nal_index = index + 4;
            if nal_index < data.len() && (data[nal_index] & 0x1f) == 5 {
                return true;
            }
            index = nal_index + 1;
        } else if data[index..].starts_with(&[0, 0, 1]) {
            let nal_index = index + 3;
            if nal_index < data.len() && (data[nal_index] & 0x1f) == 5 {
                return true;
            }
            index = nal_index + 1;
        } else {
            index += 1;
        }
    }
    false
}

fn h264_nal_summary(data: &[u8]) -> String {
    let mut summary = Vec::new();
    for (_offset, nal_type) in h264_nal_units(data).into_iter().take(8) {
        summary.push(nal_type.to_string());
    }
    if summary.is_empty() {
        return "none".to_owned();
    }
    summary.join(",")
}

fn h264_nal_units(data: &[u8]) -> Vec<(usize, u8)> {
    let mut nals = Vec::new();
    let mut index = 0usize;
    while index + 4 <= data.len() {
        if data[index..].starts_with(&[0, 0, 0, 1]) {
            let nal_index = index + 4;
            if nal_index < data.len() {
                nals.push((nal_index, data[nal_index] & 0x1f));
            }
            index = nal_index + 1;
        } else if data[index..].starts_with(&[0, 0, 1]) {
            let nal_index = index + 3;
            if nal_index < data.len() {
                nals.push((nal_index, data[nal_index] & 0x1f));
            }
            index = nal_index + 1;
        } else {
            index += 1;
        }
    }
    nals
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn tuned_udp_mux_supports_ipv4_and_ipv6_with_qos_and_stun_rtt() {
        for is_ipv6 in [false, true] {
            let rtt_us = Arc::new(AtomicU64::new(0));
            let req_cnt = Arc::new(AtomicU64::new(0));
            let resp_cnt = Arc::new(AtomicU64::new(0));
            let mux = create_tuned_udp_mux(
                is_ipv6,
                Arc::clone(&rtt_us),
                Arc::clone(&req_cnt),
                Arc::clone(&resp_cnt),
            )
            .expect("tuned udp mux should bind");
            let conn = mux.clone().get_conn("testufrag").await.expect("get_conn");
            let local = conn.local_addr().expect("local_addr");
            assert_eq!(local.is_ipv6(), is_ipv6);
            assert_ne!(local.port(), 0);

            // Spawn a loopback echo responder that turns STUN Binding Request into Binding Success
            let peer_bind = if is_ipv6 { "[::1]:0" } else { "127.0.0.1:0" };
            let peer = tokio::net::UdpSocket::bind(peer_bind).await.expect("peer bind");
            let peer_addr = peer.local_addr().expect("peer local_addr");
            let responder = tokio::spawn(async move {
                let mut buf = [0u8; 256];
                let (n, src) = peer.recv_from(&mut buf).await.expect("peer recv");
                assert!(n >= 20);
                let mut resp = buf[..n].to_vec();
                resp[0] = 0x01;
                resp[1] = 0x01; // STUN Binding Success Response
                peer.send_to(&resp, src).await.expect("peer send");
            });

            let mut req = [0u8; 20];
            req[0] = 0x00;
            req[1] = 0x01;
            req[4..8].copy_from_slice(&RttMeasuringUdpConn::STUN_MAGIC_COOKIE);
            req[8..20].copy_from_slice(b"TXID12345678");
            conn.send_to(&req, peer_addr).await.expect("send stun req");

            let mut recv_buf = [0u8; 256];
            let (n, src) = timeout(Duration::from_secs(2), conn.recv_from(&mut recv_buf))
                .await
                .expect("recv timeout")
                .expect("recv_from");
            assert_eq!(n, 20);
            assert_eq!(src, peer_addr);
            responder.await.expect("responder join");

            assert_eq!(req_cnt.load(Ordering::Relaxed), 1);
            assert_eq!(resp_cnt.load(Ordering::Relaxed), 1);
            assert!(rtt_us.load(Ordering::Relaxed) >= 100);

            let _ = mux.close().await;
        }
    }

    #[test]
    fn darwin_qos_probe_and_ipv6_detection_work() {
        let primary_v6 = detect_primary_global_ipv6();
        println!("detected primary_v6 = {:?}", primary_v6);
        let tcp_v4 = measure_tcp_rtt("127.0.0.1:1".parse().unwrap());
        println!("loopback tcp_v4 = {:?}", tcp_v4);
        assert!(tcp_v4.is_some());
    }

    #[test]
    fn adaptive_reorder_wait_and_lan_subnet_detection() {
        // LAN keeps at least 75ms floor so 45-60ms AWDL off-channel pauses never drop intact frames
        assert_eq!(compute_adaptive_reorder_wait_ms(65, 4_000, 1_000, 1), 75);
        assert_eq!(compute_adaptive_reorder_wait_ms(80, 4_000, 1_000, 1), 80);
        // Moderate WAN (70ms RTT + 5ms jitter) -> 70*1.45 + 5*2.5 + 28 = 142ms
        assert_eq!(compute_adaptive_reorder_wait_ms(65, 70_000, 5_000, 2), 142);
        // WAN P2P with unknown RTT falls back to 55ms estimate -> 55*1.45 + 28 = 108ms
        assert_eq!(compute_adaptive_reorder_wait_ms(65, 0, 0, 2), 108);
        // TURN relay with unknown RTT falls back to 75ms estimate -> 75*1.45 + 28 = 137ms
        assert_eq!(compute_adaptive_reorder_wait_ms(65, 0, 0, 3), 137);
        // High-RTT WAN clamps cleanly at 240ms ceiling
        assert_eq!(compute_adaptive_reorder_wait_ms(65, 160_000, 15_000, 2), 240);
        assert!(are_same_lan_subnet(
            "2408:8276:b1a:9360:cc44:30c0:9f6f:58d0",
            "2408:8276:b1a:9360:541d:440e:4e30:5620"
        ));
        assert!(!are_same_lan_subnet(
            "2409:8900:1234:5678::1",
            "2408:8276:b1a:9360:541d:440e:4e30:5620"
        ));
        assert!(are_same_lan_subnet("192.168.31.50", "192.168.31.198"));

        // Verify SPS/PPS extraction strips corrupted slice NALs cleanly
        let mixed = vec![
            0, 0, 0, 1, 0x67, 0x64, 0x00, 0x2A, // SPS
            0, 0, 0, 1, 0x68, 0xEE, 0x3C,       // PPS
            0, 0, 0, 1, 0x65, 0x88, 0x99,       // Corrupted IDR slice (must be stripped!)
        ];
        assert_eq!(
            extract_sps_pps_annex_b(&mixed),
            vec![0, 0, 0, 1, 0x67, 0x64, 0x00, 0x2A, 0, 0, 0, 1, 0x68, 0xEE, 0x3C]
        );
    }

    #[cfg(unix)]
    #[test]
    fn ephemeral_udp_socket_tuning_finds_live_port() {
        let sock = std::net::UdpSocket::bind("0.0.0.0:0").expect("bind ipv4");
        let port = sock.local_addr().expect("local_addr").port();
        let cands = vec![IceCandidate::new(
            format!("candidate:1 1 udp 1694498815 1.2.3.4 55555 typ srflx raddr 192.168.31.10 rport {port}"),
            "0",
            0,
        )];
        let ports = collect_local_udp_ports(55555, &cands);
        assert!(ports.contains(&port));
        assert!(tune_active_udp_sockets_by_ports(&ports) >= 1);
        drop(sock);
    }

    #[test]
    fn video_sdp_bitrate_boost_injects_b_as_and_google_hints() {
        let sdp = "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 120\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:120 H264/90000\r\na=fmtp:120 level-asymmetry-allowed=1;profile-level-id=64002a\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n";
        let boosted = boost_video_bitrate_sdp(sdp, 10_000, 20_000, 40_000);
        assert!(boosted.contains("b=AS:40000"));
        assert!(boosted.contains("x-google-min-bitrate=10000"));
        assert!(boosted.contains("x-google-start-bitrate=20000"));
        assert!(boosted.contains("x-google-max-bitrate=40000"));
    }

    #[test]
    fn candidate_to_protocol_normalizes_empty_sdp_mid_and_remote_a_prefix() {
        let init_empty_mid = RTCIceCandidateInit {
            candidate: "candidate:123 1 udp 16777215 1.2.3.4 49152 typ relay raddr 0.0.0.0 rport 54321".to_owned(),
            sdp_mid: Some(String::new()),
            sdp_mline_index: Some(0),
            username_fragment: None,
        };
        let converted = candidate_to_protocol_candidate(&init_empty_mid).expect("valid relay");
        assert_eq!(converted.sdp_mid, "0");
        assert_eq!(converted.sdp_mline_index, "0");
        assert_eq!(candidate_ip_family(&converted.candidate), "v4-pub");

        let init_explicit_mid = RTCIceCandidateInit {
            candidate: "candidate:456 1 udp 2122260223 192.168.31.198 9002 typ host".to_owned(),
            sdp_mid: Some("1".to_owned()),
            sdp_mline_index: Some(1),
            username_fragment: None,
        };
        let converted2 = candidate_to_protocol_candidate(&init_explicit_mid).expect("valid host");
        assert_eq!(converted2.sdp_mid, "1");
        assert_eq!(candidate_ip_family(&converted2.candidate), "v4-priv");

        assert_eq!(
            normalize_remote_candidate_line("a=candidate:1 1 UDP 100 2001:0:4136:e378:8000:63bf:3fff:fdd2 9002 typ host "),
            "candidate:1 1 UDP 100 2001:0:4136:e378:8000:63bf:3fff:fdd2 9002 typ host"
        );
        assert_eq!(
            candidate_ip_family("a=candidate:1 1 UDP 100 2001:0:4136:e378:8000:63bf:3fff:fdd2 9002 typ host "),
            "v6-teredo"
        );
    }
}
