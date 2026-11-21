#ifndef XBOXPAD_NANO_H
#define XBOXPAD_NANO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct XboxPadHandle XboxPadHandle;

typedef struct XboxPadConfig {
    const char *session_id;          // xHome: console serverId; xCloud: titleId
    const char *stream_type;         // "home" or "cloud"
    const char *base_uri;            // Streaming region baseUri (e.g. https://uks.core.gssv-play-prod.xboxlive.com)
    const char *gs_token;            // Streaming gsToken
    const char *connect_user_token;  // MSAL transfer token (lpt) used for /connect
    int32_t resolution;              // 720, 1080, 1081 (1080p HQ / 1440p)
    const char *preferred_language;  // e.g. "zh-CN", "en-US"
    const char *ice_server_url;      // Optional custom STUN/TURN URL
    const char *ice_server_username; // Optional
    const char *ice_server_credential; // Optional
    bool stereo_audio_enabled;
    bool coop;
    uint8_t network_mode;            // 0=auto (IPv4+IPv6), 1=IPv4 only, 2=IPv6 only
    uint32_t max_video_delay_ms;     // Low-latency jitter cap (e.g. 60..220; 0 uses default 80ms)
    const char *force_region_ip;     // Optional X-Forwarded-For IP for cross-region xCloud
} XboxPadConfig;

typedef struct XboxPadInputFrame {
    uint8_t gamepad_index;
    uint8_t nexus;
    uint8_t menu;
    uint8_t view;
    uint8_t a;
    uint8_t b;
    uint8_t x;
    uint8_t y;
    uint8_t dpad_up;
    uint8_t dpad_down;
    uint8_t dpad_left;
    uint8_t dpad_right;
    uint8_t left_shoulder;
    uint8_t right_shoulder;
    uint8_t left_thumb;
    uint8_t right_thumb;
    // Matches W3C / nano-rs convention: X right=+1, Y down=+1 (up=-1).
    float left_thumb_x;
    float left_thumb_y;
    float right_thumb_x;
    float right_thumb_y;
    float left_trigger;
    float right_trigger;
} XboxPadInputFrame;

typedef struct XboxPadRumble {
    uint16_t start_delay_ms;
    uint16_t duration_ms;
    uint16_t delay_ms;
    uint8_t repeat;
    float weak_magnitude;    // Right handle motor (0.0 .. 1.0)
    float strong_magnitude;  // Left handle motor  (0.0 .. 1.0)
    float left_trigger;      // Left impulse trigger (0.0 .. 1.0)
    float right_trigger;     // Right impulse trigger (0.0 .. 1.0)
} XboxPadRumble;

typedef struct XboxPadStats {
    double rtt_ms;           // -1 if unavailable
    double jitter_ms;        // -1 if unavailable
    double fps;              // -1 if unavailable
    uint64_t frames_dropped;
    uint64_t frames_received;
    uint64_t packets_received;
    uint64_t packets_lost;
    double packet_loss_pct;  // -1 if unavailable
    double bitrate_mbps;     // -1 if unavailable
    double decode_time_ms;   // -1 if unavailable
    uint8_t route_kind;      // 0=unknown, 1=LAN host direct, 2=NAT direct, 3=TURN relay
} XboxPadStats;

typedef void (*XboxPadVideoCallback)(
    void *user_data,
    const uint8_t *data,
    size_t len,
    int64_t pts_us,
    bool keyframe
);

typedef void (*XboxPadAudioCallback)(
    void *user_data,
    const uint8_t *data,
    size_t len,
    int64_t pts_us,
    uint32_t sample_rate,
    uint16_t channels
);

typedef void (*XboxPadStatusCallback)(
    void *user_data,
    const char *stage,
    const char *message,
    bool terminal
);

typedef void (*XboxPadStatsCallback)(
    void *user_data,
    const XboxPadStats *stats
);

typedef void (*XboxPadRumbleCallback)(
    void *user_data,
    const XboxPadRumble *rumble
);

typedef void (*XboxPadLogCallback)(
    uint8_t level,
    const char *message
);

void xboxpad_set_log_callback(XboxPadLogCallback callback);

typedef struct XboxPadCallbacks {
    void *user_data;
    XboxPadVideoCallback on_video_frame;
    XboxPadAudioCallback on_audio_frame;
    XboxPadStatusCallback on_status;
    XboxPadStatsCallback on_stats;
    XboxPadRumbleCallback on_rumble;
} XboxPadCallbacks;

/// Returns true if this binary was compiled with optional built-in STUN/TURN relay nodes.
bool xboxpad_has_builtin_ice(void);

/// Create a new streaming engine handle. Must be destroyed with xboxpad_destroy.
XboxPadHandle *xboxpad_create(XboxPadCallbacks callbacks);

/// Start streaming with the supplied configuration. Returns 0 on success, non-zero on error.
int32_t xboxpad_start(XboxPadHandle *handle, const XboxPadConfig *config);

/// Stop the active stream session and wait for worker threads to terminate cleanly.
void xboxpad_stop(XboxPadHandle *handle);

/// Stop (if running) and free the engine handle.
void xboxpad_destroy(XboxPadHandle *handle);

/// Enqueue a gamepad input snapshot. Returns 0 on success.
int32_t xboxpad_send_input(XboxPadHandle *handle, const XboxPadInputFrame *frame);

/// Request an immediate IDR keyframe (e.g. after foreground resume or decoder flush).
int32_t xboxpad_request_keyframe(XboxPadHandle *handle);

/// Send an encoded 48kHz Opus microphone frame to Xbox party/in-game voice chat. Returns 0 on success.
int32_t xboxpad_send_mic_opus(
    XboxPadHandle *handle,
    const uint8_t *data,
    size_t len,
    uint32_t duration_ms
);

/// Dynamically notify Xbox that gamepad slot (0..3) connected or disconnected (multiplayer co-op).
int32_t xboxpad_set_gamepad_connected(
    XboxPadHandle *handle,
    uint8_t gamepad_index,
    bool connected
);

/// Send a native Xbox InputChannel Mouse event (relative=0 for relative delta, 1 for absolute).
int32_t xboxpad_send_mouse(
    XboxPadHandle *handle,
    int32_t x,
    int32_t y,
    int32_t wheel_x,
    int32_t wheel_y,
    uint8_t buttons,
    uint8_t relative
);

/// Send a native Xbox InputChannel Keyboard event (Windows virtual key code).
int32_t xboxpad_send_keyboard(
    XboxPadHandle *handle,
    uint8_t key_code,
    bool pressed
);

#ifdef __cplusplus
}
#endif

#endif // XBOXPAD_NANO_H
