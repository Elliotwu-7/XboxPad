use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::audio_sink::AudioFrameSink;
use crate::auth::{AuthBundle, Platform, StreamingTokenSnapshot, WebTokenSnapshot};
use crate::backend::{NanoSessionConfig, NanoSessionHandle, SessionEventSink};
use crate::channels::{InputFrame, KeyboardFrame, MouseFrame, RumbleData};
use crate::error::NanoError;
use crate::protocol::{default_stream_request, IceServer};
use crate::stats::StreamStats;
use crate::video_sink::VideoFrameSink;

#[repr(C)]
pub struct XboxPadConfig {
    pub session_id: *const c_char,
    pub stream_type: *const c_char,
    pub base_uri: *const c_char,
    pub gs_token: *const c_char,
    pub connect_user_token: *const c_char,
    pub resolution: i32,
    pub preferred_language: *const c_char,
    pub ice_server_url: *const c_char,
    pub ice_server_username: *const c_char,
    pub ice_server_credential: *const c_char,
    pub stereo_audio_enabled: bool,
    pub coop: bool,
    pub network_mode: u8,
    pub max_video_delay_ms: u32,
    pub force_region_ip: *const c_char,
    pub max_video_bitrate_kbps: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct XboxPadInputFrame {
    pub gamepad_index: u8,
    pub nexus: u8,
    pub menu: u8,
    pub view: u8,
    pub a: u8,
    pub b: u8,
    pub x: u8,
    pub y: u8,
    pub dpad_up: u8,
    pub dpad_down: u8,
    pub dpad_left: u8,
    pub dpad_right: u8,
    pub left_shoulder: u8,
    pub right_shoulder: u8,
    pub left_thumb: u8,
    pub right_thumb: u8,
    pub left_thumb_x: f32,
    pub left_thumb_y: f32,
    pub right_thumb_x: f32,
    pub right_thumb_y: f32,
    pub left_trigger: f32,
    pub right_trigger: f32,
}

impl From<XboxPadInputFrame> for InputFrame {
    fn from(v: XboxPadInputFrame) -> Self {
        InputFrame {
            gamepad_index: v.gamepad_index,
            nexus: v.nexus,
            menu: v.menu,
            view: v.view,
            a: v.a,
            b: v.b,
            x: v.x,
            y: v.y,
            dpad_up: v.dpad_up,
            dpad_down: v.dpad_down,
            dpad_left: v.dpad_left,
            dpad_right: v.dpad_right,
            left_shoulder: v.left_shoulder,
            right_shoulder: v.right_shoulder,
            left_thumb: v.left_thumb,
            right_thumb: v.right_thumb,
            left_thumb_x_axis: v.left_thumb_x,
            left_thumb_y_axis: v.left_thumb_y,
            right_thumb_x_axis: v.right_thumb_x,
            right_thumb_y_axis: v.right_thumb_y,
            left_trigger: v.left_trigger,
            right_trigger: v.right_trigger,
            physical_physicality: None,
            virtual_physicality: None,
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct XboxPadRumble {
    pub gamepad_index: u8,
    pub start_delay_ms: u16,
    pub duration_ms: u16,
    pub delay_ms: u16,
    pub repeat: u8,
    pub weak_magnitude: f32,
    pub strong_magnitude: f32,
    pub left_trigger: f32,
    pub right_trigger: f32,
}

impl From<RumbleData> for XboxPadRumble {
    fn from(r: RumbleData) -> Self {
        Self {
            gamepad_index: r.gamepad_index,
            start_delay_ms: r.start_delay_ms,
            duration_ms: r.duration_ms,
            delay_ms: r.delay_ms,
            repeat: r.repeat,
            weak_magnitude: r.weak_magnitude,
            strong_magnitude: r.strong_magnitude,
            left_trigger: r.left_trigger,
            right_trigger: r.right_trigger,
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct XboxPadStats {
    pub rtt_ms: f64,
    pub jitter_ms: f64,
    pub fps: f64,
    pub frames_dropped: u64,
    pub frames_received: u64,
    pub packets_received: u64,
    pub packets_lost: u64,
    pub packet_loss_pct: f64,
    pub bitrate_mbps: f64,
    pub decode_time_ms: f64,
    pub route_kind: u8,
}

impl From<&StreamStats> for XboxPadStats {
    fn from(s: &StreamStats) -> Self {
        Self {
            rtt_ms: s.round_trip_time_ms.unwrap_or(-1.0),
            jitter_ms: s.jitter_ms.unwrap_or(-1.0),
            fps: s.fps.unwrap_or(-1.0),
            frames_dropped: s.frames_dropped,
            frames_received: s.frames_received,
            packets_received: s.packets_received,
            packets_lost: s.packets_lost,
            packet_loss_pct: s.packet_loss_pct.unwrap_or(-1.0),
            bitrate_mbps: s
                .bitrate_bps
                .map(|b| b as f64 / 1_000_000.0)
                .unwrap_or(-1.0),
            decode_time_ms: s.decode_time_ms.unwrap_or(-1.0),
            route_kind: s.route_kind,
        }
    }
}

pub type XboxPadVideoCallback = Option<
    unsafe extern "C" fn(
        user_data: *mut c_void,
        data: *const u8,
        len: usize,
        pts_us: i64,
        keyframe: bool,
    ),
>;

pub type XboxPadAudioCallback = Option<
    unsafe extern "C" fn(
        user_data: *mut c_void,
        data: *const u8,
        len: usize,
        pts_us: i64,
        sample_rate: u32,
        channels: u16,
    ),
>;

pub type XboxPadStatusCallback = Option<
    unsafe extern "C" fn(
        user_data: *mut c_void,
        stage: *const c_char,
        message: *const c_char,
        terminal: bool,
    ),
>;

pub type XboxPadStatsCallback =
    Option<unsafe extern "C" fn(user_data: *mut c_void, stats: *const XboxPadStats)>;

pub type XboxPadRumbleCallback =
    Option<unsafe extern "C" fn(user_data: *mut c_void, rumble: *const XboxPadRumble)>;

pub type XboxPadLogCallback = Option<extern "C" fn(level: u8, message: *const c_char)>;

#[no_mangle]
pub extern "C" fn xboxpad_set_log_callback(callback: XboxPadLogCallback) {
    crate::logging::set_log_sink(callback);
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct XboxPadCallbacks {
    pub user_data: *mut c_void,
    pub on_video_frame: XboxPadVideoCallback,
    pub on_audio_frame: XboxPadAudioCallback,
    pub on_status: XboxPadStatusCallback,
    pub on_stats: XboxPadStatsCallback,
    pub on_rumble: XboxPadRumbleCallback,
}

unsafe impl Send for XboxPadCallbacks {}
unsafe impl Sync for XboxPadCallbacks {}

struct CallbackSink {
    callbacks: XboxPadCallbacks,
    active: Arc<AtomicBool>,
}

impl CallbackSink {
    fn new(callbacks: XboxPadCallbacks, active: Arc<AtomicBool>) -> Self {
        Self { callbacks, active }
    }
}

impl VideoFrameSink for CallbackSink {
    fn push_h264_access_unit(&self, data: &[u8], pts_us: i64, keyframe: bool) {
        if !self.active.load(Ordering::Acquire) || data.is_empty() {
            return;
        }
        if let Some(cb) = self.callbacks.on_video_frame {
            unsafe {
                cb(
                    self.callbacks.user_data,
                    data.as_ptr(),
                    data.len(),
                    pts_us,
                    keyframe,
                );
            }
        }
    }
}

impl AudioFrameSink for CallbackSink {
    fn push_opus_frame(&self, data: &[u8], pts_us: i64, sample_rate: u32, channels: u16) {
        if !self.active.load(Ordering::Acquire) || data.is_empty() {
            return;
        }
        if let Some(cb) = self.callbacks.on_audio_frame {
            unsafe {
                cb(
                    self.callbacks.user_data,
                    data.as_ptr(),
                    data.len(),
                    pts_us,
                    sample_rate,
                    channels,
                );
            }
        }
    }
}

impl SessionEventSink for CallbackSink {
    fn update_status(&self, stage: &str, message: &str, terminal: bool) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        if let Some(cb) = self.callbacks.on_status {
            let stage_c = CString::new(stage.replace('\0', " "))
                .unwrap_or_else(|_| CString::new("unknown").unwrap());
            let message_c = CString::new(message.replace('\0', " "))
                .unwrap_or_else(|_| CString::new("").unwrap());
            unsafe {
                cb(
                    self.callbacks.user_data,
                    stage_c.as_ptr(),
                    message_c.as_ptr(),
                    terminal,
                );
            }
        }
    }

    fn update_stats(&self, stats: &StreamStats) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        if let Some(cb) = self.callbacks.on_stats {
            let c_stats = XboxPadStats::from(stats);
            unsafe {
                cb(self.callbacks.user_data, &c_stats);
            }
        }
    }

    fn on_rumble(&self, rumble: RumbleData) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        if let Some(cb) = self.callbacks.on_rumble {
            let c_rumble = XboxPadRumble::from(rumble);
            unsafe {
                cb(self.callbacks.user_data, &c_rumble);
            }
        }
    }
}

pub struct XboxPadHandle {
    callbacks: XboxPadCallbacks,
    active: Arc<AtomicBool>,
    session: Mutex<Option<NanoSessionHandle>>,
}

unsafe fn cstr_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

fn build_session_config(
    raw: &XboxPadConfig,
    sink: Arc<CallbackSink>,
) -> Result<NanoSessionConfig, NanoError> {
    let session_id = unsafe { cstr_to_string(raw.session_id) };
    let stream_type = unsafe { cstr_to_string(raw.stream_type) };
    let base_uri = unsafe { cstr_to_string(raw.base_uri) };
    let gs_token = unsafe { cstr_to_string(raw.gs_token) };
    let connect_user_token = unsafe { cstr_to_string(raw.connect_user_token) };
    let preferred_language = unsafe { cstr_to_string(raw.preferred_language) };
    let ice_server_url = unsafe { cstr_to_string(raw.ice_server_url) };
    let ice_server_username = unsafe { cstr_to_string(raw.ice_server_username) };
    let ice_server_credential = unsafe { cstr_to_string(raw.ice_server_credential) };

    if gs_token.trim().is_empty() || base_uri.trim().is_empty() {
        return Err(NanoError::MissingStreamingToken);
    }
    if session_id.trim().is_empty() {
        return Err(NanoError::InvalidSessionId);
    }

    let platform = if stream_type.eq_ignore_ascii_case("cloud") {
        Platform::Cloud
    } else {
        Platform::Home
    };

    let mut auth = AuthBundle::default();
    let token_snapshot = StreamingTokenSnapshot {
        gs_token,
        base_uri: base_uri.clone(),
        created_at_ms: None,
        expires_at_ms: None,
    };
    match platform {
        Platform::Home => auth.home = Some(token_snapshot),
        Platform::Cloud => auth.cloud = Some(token_snapshot),
    }
    if !connect_user_token.trim().is_empty() {
        auth.web = Some(WebTokenSnapshot {
            raw: connect_user_token,
            not_after_ms: None,
        });
    }

    let resolution = if raw.resolution > 0 {
        raw.resolution
    } else {
        1080
    };
    let mut request = default_stream_request(platform, session_id);
    request.base_uri = base_uri;
    request.preferred_language = if preferred_language.trim().is_empty() {
        "en-US".to_owned()
    } else {
        preferred_language
    };
    request.video.height = resolution as u32;
    request.video.width = match resolution {
        720 => 1280,
        1080 | 1081 => 1920,
        1440 => 2560,
        _ => 1920,
    };

    let mut extra_ice_servers = Vec::new();
    let trimmed_ice = ice_server_url.trim();
    if trimmed_ice.eq_ignore_ascii_case("off") {
        // Explicitly disabled by user
    } else if trimmed_ice.is_empty() || trimmed_ice.eq_ignore_ascii_case("builtin") {
        // Optional compile-time injected relay nodes (used only by official OTA builds;
        // empty in open-source builds unless configured via build environment variables).
        if let Some(builtin_nodes) = option_env!("XBOXPAD_BUILTIN_ICE_NODES") {
            let builtin_user = option_env!("XBOXPAD_BUILTIN_TURN_USER")
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            let builtin_pass = option_env!("XBOXPAD_BUILTIN_TURN_PASS")
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            for raw_entry in builtin_nodes.split(|c| c == ',' || c == ';' || c == '\n') {
                let entry = raw_entry.trim();
                if entry.is_empty() {
                    continue;
                }
                let host_port = entry
                    .strip_prefix("turn:")
                    .or_else(|| entry.strip_prefix("stun:"))
                    .unwrap_or(entry);
                let stun_host = host_port.split('?').next().unwrap_or(host_port);
                extra_ice_servers.push(IceServer {
                    urls: format!("stun:{stun_host}"),
                    username: None,
                    credential: None,
                });
                if builtin_user.is_some() || builtin_pass.is_some() || entry.starts_with("turn:") {
                    extra_ice_servers.push(IceServer {
                        urls: if entry.starts_with("turn:") || entry.starts_with("turns:") {
                            entry.to_owned()
                        } else {
                            format!("turn:{host_port}")
                        },
                        username: builtin_user.clone(),
                        credential: builtin_pass.clone(),
                    });
                }
            }
        }
    } else {
        let user_opt = if ice_server_username.trim().is_empty() {
            None
        } else {
            Some(ice_server_username.trim().to_owned())
        };
        let pass_opt = if ice_server_credential.trim().is_empty() {
            None
        } else {
            Some(ice_server_credential.trim().to_owned())
        };
        // Support multiple custom ICE servers separated by comma, semicolon, or newline.
        for raw_entry in trimmed_ice.split(|c| c == ',' || c == ';' || c == '\n') {
            let entry = raw_entry.trim();
            if entry.is_empty() {
                continue;
            }
            let normalized_url = if entry.starts_with("stun:")
                || entry.starts_with("stuns:")
                || entry.starts_with("turn:")
                || entry.starts_with("turns:")
            {
                entry.to_owned()
            } else if user_opt.is_some() || pass_opt.is_some() {
                format!("turn:{entry}")
            } else {
                format!("stun:{entry}")
            };
            // If user configured a TURN server, also register its companion STUN URL on the same
            // host:port so coturn provides BOTH zero-bandwidth P2P hole-punching (srflx) AND TURN relay.
            if let Some(rest) = normalized_url.strip_prefix("turn:") {
                let host_port = rest.split('?').next().unwrap_or(rest);
                extra_ice_servers.push(IceServer {
                    urls: format!("stun:{host_port}"),
                    username: None,
                    credential: None,
                });
            }
            extra_ice_servers.push(IceServer {
                urls: normalized_url,
                username: user_opt.clone(),
                credential: pass_opt.clone(),
            });
        }
    }

    let max_video_delay_ms = if raw.max_video_delay_ms == 0 {
        80
    } else {
        raw.max_video_delay_ms.clamp(30, 300) as u64
    };

    let force_region_ip_str = unsafe { cstr_to_string(raw.force_region_ip) };
    let force_region_ip = if force_region_ip_str.trim().is_empty() {
        None
    } else {
        Some(force_region_ip_str.trim().to_owned())
    };

    Ok(NanoSessionConfig {
        auth,
        request,
        stereo_audio_enabled: raw.stereo_audio_enabled,
        max_touchpoints: 10,
        coop: raw.coop,
        network_mode: raw.network_mode,
        max_video_delay_ms,
        max_video_bitrate_kbps: raw.max_video_bitrate_kbps,
        force_region_ip,
        extra_ice_servers,
        video_sink: Some(sink.clone()),
        audio_sink: Some(sink.clone()),
        event_sink: Some(sink),
    })
}

#[no_mangle]
pub extern "C" fn xboxpad_has_builtin_ice() -> bool {
    option_env!("XBOXPAD_BUILTIN_ICE_NODES")
        .map(|v| !v.trim().is_empty())
        .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn xboxpad_create(callbacks: XboxPadCallbacks) -> *mut XboxPadHandle {
    let handle = Box::new(XboxPadHandle {
        callbacks,
        active: Arc::new(AtomicBool::new(false)),
        session: Mutex::new(None),
    });
    Box::into_raw(handle)
}

#[no_mangle]
pub extern "C" fn xboxpad_start(
    handle: *mut XboxPadHandle,
    config: *const XboxPadConfig,
) -> i32 {
    if handle.is_null() || config.is_null() {
        return -1;
    }
    let handle_ref = unsafe { &*handle };
    let config_ref = unsafe { &*config };

    // Stop any previous active session first.
    xboxpad_stop(handle);

    handle_ref.active.store(true, Ordering::Release);
    let sink = Arc::new(CallbackSink::new(
        handle_ref.callbacks,
        Arc::clone(&handle_ref.active),
    ));

    let session_config = match build_session_config(config_ref, Arc::clone(&sink)) {
        Ok(cfg) => cfg,
        Err(err) => {
            sink.update_status("failed", &err.to_string(), true);
            handle_ref.active.store(false, Ordering::Release);
            return -2;
        }
    };

    match NanoSessionHandle::start(session_config) {
        Ok(session_handle) => {
            if let Ok(mut guard) = handle_ref.session.lock() {
                *guard = Some(session_handle);
                0
            } else {
                handle_ref.active.store(false, Ordering::Release);
                -3
            }
        }
        Err(err) => {
            sink.update_status("failed", &err.to_string(), true);
            handle_ref.active.store(false, Ordering::Release);
            -4
        }
    }
}

#[no_mangle]
pub extern "C" fn xboxpad_stop(handle: *mut XboxPadHandle) {
    if handle.is_null() {
        return;
    }
    let handle_ref = unsafe { &*handle };
    handle_ref.active.store(false, Ordering::SeqCst);
    let existing = handle_ref
        .session
        .lock()
        .ok()
        .and_then(|mut guard| guard.take());
    if let Some(mut session) = existing {
        let _ = session.stop();
    }
}

#[no_mangle]
pub extern "C" fn xboxpad_destroy(handle: *mut XboxPadHandle) {
    if handle.is_null() {
        return;
    }
    xboxpad_stop(handle);
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub extern "C" fn xboxpad_send_input(
    handle: *mut XboxPadHandle,
    frame: *const XboxPadInputFrame,
) -> i32 {
    if handle.is_null() || frame.is_null() {
        return -1;
    }
    let handle_ref = unsafe { &*handle };
    if !handle_ref.active.load(Ordering::Acquire) {
        return -2;
    }
    let input_frame = InputFrame::from(unsafe { *frame });
    let Ok(guard) = handle_ref.session.lock() else {
        return -3;
    };
    let Some(session) = guard.as_ref() else {
        return -4;
    };
    if session.send_gamepad_frame(input_frame).is_ok() {
        0
    } else {
        -5
    }
}

#[no_mangle]
pub extern "C" fn xboxpad_request_keyframe(handle: *mut XboxPadHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let handle_ref = unsafe { &*handle };
    if !handle_ref.active.load(Ordering::Acquire) {
        return -2;
    }
    let Ok(guard) = handle_ref.session.lock() else {
        return -3;
    };
    let Some(session) = guard.as_ref() else {
        return -4;
    };
    if session.request_keyframe().is_ok() {
        0
    } else {
        -5
    }
}

#[no_mangle]
pub extern "C" fn xboxpad_send_mic_opus(
    handle: *mut XboxPadHandle,
    data: *const u8,
    len: usize,
    duration_ms: u32,
) -> i32 {
    if handle.is_null() || data.is_null() || len == 0 {
        return -1;
    }
    let handle_ref = unsafe { &*handle };
    if !handle_ref.active.load(Ordering::Acquire) {
        return -2;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    let Ok(guard) = handle_ref.session.lock() else {
        return -3;
    };
    let Some(session) = guard.as_ref() else {
        return -4;
    };
    if session.send_mic_opus(slice.to_vec(), duration_ms).is_ok() {
        0
    } else {
        -5
    }
}

#[no_mangle]
pub extern "C" fn xboxpad_set_gamepad_connected(
    handle: *mut XboxPadHandle,
    gamepad_index: u8,
    connected: bool,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let handle_ref = unsafe { &*handle };
    if !handle_ref.active.load(Ordering::Acquire) {
        return -2;
    }
    let Ok(guard) = handle_ref.session.lock() else {
        return -3;
    };
    let Some(session) = guard.as_ref() else {
        return -4;
    };
    if session.set_gamepad_connected(gamepad_index, connected).is_ok() {
        0
    } else {
        -5
    }
}

#[no_mangle]
pub extern "C" fn xboxpad_send_mouse(
    handle: *mut XboxPadHandle,
    x: i32,
    y: i32,
    wheel_x: i32,
    wheel_y: i32,
    buttons: u8,
    relative: u8,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let handle_ref = unsafe { &*handle };
    if !handle_ref.active.load(Ordering::Acquire) {
        return -2;
    }
    let Ok(guard) = handle_ref.session.lock() else {
        return -3;
    };
    let Some(session) = guard.as_ref() else {
        return -4;
    };
    let frame = MouseFrame {
        x,
        y,
        wheel_x,
        wheel_y,
        buttons,
        relative,
    };
    if session.send_mouse_frame(frame).is_ok() {
        0
    } else {
        -5
    }
}

#[no_mangle]
pub extern "C" fn xboxpad_send_keyboard(
    handle: *mut XboxPadHandle,
    key_code: u8,
    pressed: bool,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let handle_ref = unsafe { &*handle };
    if !handle_ref.active.load(Ordering::Acquire) {
        return -2;
    }
    let Ok(guard) = handle_ref.session.lock() else {
        return -3;
    };
    let Some(session) = guard.as_ref() else {
        return -4;
    };
    let frame = KeyboardFrame {
        is_pressed: pressed,
        key_code,
    };
    if session.send_keyboard_frame(frame).is_ok() {
        0
    } else {
        -5
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channels::InputPacket;

    #[test]
    fn ffi_input_frame_preserves_axes_and_y_inversion_contract() {
        // W3C/nano-rs convention: pushing stick UP passes y = -1.0 into nano-rs,
        // which negates it to +32767 for Xbox.
        let c_frame = XboxPadInputFrame {
            gamepad_index: 0,
            nexus: 0,
            menu: 0,
            view: 0,
            a: 1,
            b: 0,
            x: 0,
            y: 0,
            dpad_up: 0,
            dpad_down: 0,
            dpad_left: 0,
            dpad_right: 0,
            left_shoulder: 0,
            right_shoulder: 0,
            left_thumb: 0,
            right_thumb: 0,
            left_thumb_x: 1.0,
            left_thumb_y: -1.0,
            right_thumb_x: 0.0,
            right_thumb_y: 0.0,
            left_trigger: 0.5,
            right_trigger: 1.0,
        };
        let input = InputFrame::from(c_frame);
        let pkt = InputPacket::with_data(1, vec![], vec![input], vec![], 1920, 1080);
        let bytes = pkt.to_bytes(1000.0);
        // Header (14) + count (1) + index (1) + button_mask (2) = offset 18 for LX, 20 for LY
        let mask = u16::from_le_bytes([bytes[16], bytes[17]]);
        let lx = i16::from_le_bytes([bytes[18], bytes[19]]);
        let ly = i16::from_le_bytes([bytes[20], bytes[21]]);
        assert_eq!(mask, 16); // A button
        assert_eq!(lx, 32767);
        assert_eq!(ly, 32767); // UP on Xbox
    }

    #[test]
    fn ffi_create_and_destroy_lifecycle() {
        let cb = XboxPadCallbacks {
            user_data: std::ptr::null_mut(),
            on_video_frame: None,
            on_audio_frame: None,
            on_status: None,
            on_stats: None,
            on_rumble: None,
        };
        let handle = xboxpad_create(cb);
        assert!(!handle.is_null());
        xboxpad_stop(handle);
        xboxpad_destroy(handle);
    }
}
