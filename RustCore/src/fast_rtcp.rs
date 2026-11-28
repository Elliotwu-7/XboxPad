use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use rtcp::receiver_report::ReceiverReport as RtcpReceiverReport;
use rtcp::reception_report::ReceptionReport;
use rtcp::sender_report::SenderReport as RtcpSenderReport;
use rtcp::transport_feedbacks::transport_layer_nack::{
    nack_pairs_from_sequence_numbers, TransportLayerNack,
};
use tokio::sync::watch;
use tokio::time::MissedTickBehavior;
use webrtc::interceptor::stream_info::StreamInfo;
use webrtc::interceptor::{
    Attributes, Error as InterceptorError, Interceptor, InterceptorBuilder, RTCPReader, RTCPWriter,
    RTPReader, RTPWriter,
};

// ============================================================================
// 1. Accurate RFC 3550 Receiver Report Interceptor
// ============================================================================
//
// Replaces `webrtc-rs`'s stock `interceptor::report::receiver::ReceiverReport`,
// which has a critical bug in `receiver_stream.rs`:
//   `let pos = (seq as usize) % self.packets.len();` (len = 128, NOT 128*64!)
// At bitrates > 3 Mbps (> 128 packets per 500ms interval), the 128-bit bitmap wraps
// multiple times per report, multiplying every single lost packet by 4x-15x in
// `fraction_lost` and crushing Xbox's LossBasedBandwidthEstimation.

const RR_DEDUP_BITS: usize = 4096;
const RR_DEDUP_WORDS: usize = RR_DEDUP_BITS / 64;

pub struct AccurateReceiverReportBuilder {
    interval: Duration,
}

impl AccurateReceiverReportBuilder {
    pub fn new(interval: Duration) -> Self {
        Self { interval }
    }
}

impl InterceptorBuilder for AccurateReceiverReportBuilder {
    fn build(
        &self,
        _id: &str,
    ) -> Result<Arc<dyn Interceptor + Send + Sync>, InterceptorError> {
        let (close_tx, close_rx) = watch::channel(false);
        let receiver_ssrc = ((Instant::now().elapsed().as_nanos() as u32) ^ 0x2B7E_1516).max(1);
        Ok(Arc::new(AccurateReceiverReport {
            interval: self.interval,
            receiver_ssrc,
            streams: Arc::new(StdMutex::new(HashMap::new())),
            close_tx: StdMutex::new(Some(close_tx)),
            close_rx,
        }))
    }
}

struct AccurateReceiverReport {
    interval: Duration,
    receiver_ssrc: u32,
    streams: Arc<StdMutex<HashMap<u32, Arc<StdMutex<RrStreamState>>>>>,
    close_tx: StdMutex<Option<watch::Sender<bool>>>,
    close_rx: watch::Receiver<bool>,
}

pub(crate) struct RrStreamState {
    ssrc: u32,
    clock_rate: f64,
    started: bool,
    base_seq: i64,
    max_seq: i64,
    received_unique: u64,
    expected_prior: u64,
    received_prior: u64,
    seen_bitmap: [u64; RR_DEDUP_WORDS],
    last_transit_ticks: Option<f64>,
    jitter_ticks: f64,
    origin: Instant,
    last_sr_ntp_mid32: u32,
    last_sr_received_at: Option<Instant>,
}

impl RrStreamState {
    pub(crate) fn new(ssrc: u32, clock_rate: u32) -> Self {
        Self {
            ssrc,
            clock_rate: f64::from(clock_rate.max(1)),
            started: false,
            base_seq: 0,
            max_seq: 0,
            received_unique: 0,
            expected_prior: 0,
            received_prior: 0,
            seen_bitmap: [0u64; RR_DEDUP_WORDS],
            last_transit_ticks: None,
            jitter_ticks: 0.0,
            origin: Instant::now(),
            last_sr_ntp_mid32: 0,
            last_sr_received_at: None,
        }
    }

    #[inline]
    fn get_seen(&self, seq: i64) -> bool {
        let idx = (seq as usize) & (RR_DEDUP_BITS - 1);
        (self.seen_bitmap[idx >> 6] & (1u64 << (idx & 63))) != 0
    }

    #[inline]
    fn set_seen(&mut self, seq: i64) {
        let idx = (seq as usize) & (RR_DEDUP_BITS - 1);
        self.seen_bitmap[idx >> 6] |= 1u64 << (idx & 63);
    }

    #[inline]
    fn clear_seen(&mut self, seq: i64) {
        let idx = (seq as usize) & (RR_DEDUP_BITS - 1);
        self.seen_bitmap[idx >> 6] &= !(1u64 << (idx & 63));
    }

    pub(crate) fn on_rtp(&mut self, seq: u16, rtp_timestamp: u32, now: Instant) {
        if !self.started {
            self.started = true;
            let s = i64::from(seq);
            self.base_seq = s;
            self.max_seq = s;
            self.seen_bitmap.fill(0);
            self.set_seen(s);
            self.received_unique = 1;
            self.origin = now;
        } else {
            let delta = (seq.wrapping_sub((self.max_seq & 0xFFFF) as u16) as i16) as i64;
            let unwrapped = self.max_seq + delta;

            if unwrapped > self.max_seq {
                let advance = unwrapped - self.max_seq;
                if advance >= RR_DEDUP_BITS as i64 {
                    self.seen_bitmap.fill(0);
                } else {
                    for s in (self.max_seq + 1)..=unwrapped {
                        self.clear_seen(s);
                    }
                }
                self.max_seq = unwrapped;
                self.set_seen(unwrapped);
                self.received_unique += 1;
            } else if self.max_seq - unwrapped < RR_DEDUP_BITS as i64 {
                if !self.get_seen(unwrapped) {
                    self.set_seen(unwrapped);
                    self.received_unique += 1;
                }
            }
        }

        // RFC 3550 Section 6.4.1 interarrival jitter estimate (wrap-safe)
        let arrival_ticks = now.duration_since(self.origin).as_secs_f64() * self.clock_rate;
        let transit = arrival_ticks - f64::from(rtp_timestamp);
        if let Some(prev_transit) = self.last_transit_ticks {
            let mut d = transit - prev_transit;
            // Ignore 32-bit RTP timestamp wraparound discontinuity
            if d.abs() < self.clock_rate * 2.0 {
                d = d.abs();
                self.jitter_ticks += (d - self.jitter_ticks) / 16.0;
            }
        }
        self.last_transit_ticks = Some(transit);
    }

    pub(crate) fn on_sender_report(&mut self, ntp_time: u64, now: Instant) {
        self.last_sr_ntp_mid32 = ((ntp_time >> 16) & 0xFFFF_FFFF) as u32;
        self.last_sr_received_at = Some(now);
    }

    pub(crate) fn generate_reception_report(&mut self, now: Instant) -> Option<ReceptionReport> {
        if !self.started {
            return None;
        }

        let expected = (self.max_seq - self.base_seq + 1).max(0) as u64;
        let expected_interval = expected.saturating_sub(self.expected_prior);
        let received_interval = self.received_unique.saturating_sub(self.received_prior);
        self.expected_prior = expected;
        self.received_prior = self.received_unique;

        let lost_interval = expected_interval.saturating_sub(received_interval);
        let fraction_lost = if expected_interval == 0 || lost_interval == 0 {
            0u8
        } else {
            ((lost_interval * 256) / expected_interval).min(255) as u8
        };

        // RFC 3550: 24-bit signed cumulative packets lost; clamp to [0, 0x7FFFFF]
        let total_lost = expected
            .saturating_sub(self.received_unique)
            .min(0x007F_FFFF) as u32;

        let delay = self
            .last_sr_received_at
            .map(|sr_at| {
                let elapsed_us = now.duration_since(sr_at).as_micros();
                ((elapsed_us * 65536) / 1_000_000).min(u128::from(u32::MAX)) as u32
            })
            .unwrap_or(0);

        Some(ReceptionReport {
            ssrc: self.ssrc,
            fraction_lost,
            total_lost,
            last_sequence_number: (self.max_seq as u64 & 0xFFFF_FFFF) as u32,
            jitter: self.jitter_ticks.max(0.0).round() as u32,
            last_sender_report: self.last_sr_ntp_mid32,
            delay,
        })
    }
}

struct RrRtpStream {
    parent_reader: Arc<dyn RTPReader + Send + Sync>,
    state: Arc<StdMutex<RrStreamState>>,
}

#[async_trait]
impl RTPReader for RrRtpStream {
    async fn read(
        &self,
        buf: &mut [u8],
        attributes: &Attributes,
    ) -> Result<(rtp::packet::Packet, Attributes), InterceptorError> {
        let (pkt, attr) = self.parent_reader.read(buf, attributes).await?;
        let now = Instant::now();
        if let Ok(mut st) = self.state.lock() {
            st.on_rtp(pkt.header.sequence_number, pkt.header.timestamp, now);
        }
        Ok((pkt, attr))
    }
}

struct RrRtcpReader {
    parent_reader: Arc<dyn RTCPReader + Send + Sync>,
    streams: Arc<StdMutex<HashMap<u32, Arc<StdMutex<RrStreamState>>>>>,
}

#[async_trait]
impl RTCPReader for RrRtcpReader {
    async fn read(
        &self,
        buf: &mut [u8],
        attributes: &Attributes,
    ) -> Result<(Vec<Box<dyn rtcp::packet::Packet + Send + Sync>>, Attributes), InterceptorError> {
        let (pkts, attr) = self.parent_reader.read(buf, attributes).await?;
        let now = Instant::now();
        for p in &pkts {
            if let Some(sr) = p.as_any().downcast_ref::<RtcpSenderReport>() {
                let stream_opt = self
                    .streams
                    .lock()
                    .ok()
                    .and_then(|map| map.get(&sr.ssrc).cloned());
                if let Some(stream) = stream_opt {
                    if let Ok(mut st) = stream.lock() {
                        st.on_sender_report(sr.ntp_time, now);
                    }
                }
            }
        }
        Ok((pkts, attr))
    }
}

#[async_trait]
impl Interceptor for AccurateReceiverReport {
    async fn bind_rtcp_reader(
        &self,
        reader: Arc<dyn RTCPReader + Send + Sync>,
    ) -> Arc<dyn RTCPReader + Send + Sync> {
        Arc::new(RrRtcpReader {
            parent_reader: reader,
            streams: Arc::clone(&self.streams),
        })
    }

    async fn bind_rtcp_writer(
        &self,
        writer: Arc<dyn RTCPWriter + Send + Sync>,
    ) -> Arc<dyn RTCPWriter + Send + Sync> {
        let streams = Arc::clone(&self.streams);
        let interval = self.interval;
        let receiver_ssrc = self.receiver_ssrc;
        let mut close_rx = self.close_rx.clone();
        let writer_clone = Arc::clone(&writer);

        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
            let attrs = Attributes::new();
            loop {
                tokio::select! {
                    _ = close_rx.changed() => {
                        if *close_rx.borrow() {
                            break;
                        }
                    }
                    _ = ticker.tick() => {
                        let now = Instant::now();
                        let active_streams: Vec<Arc<StdMutex<RrStreamState>>> = streams
                            .lock()
                            .map(|map| map.values().cloned().collect())
                            .unwrap_or_default();
                        let mut reports = Vec::with_capacity(active_streams.len());
                        for st_lock in active_streams {
                            if let Ok(mut st) = st_lock.lock() {
                                if let Some(rep) = st.generate_reception_report(now) {
                                    reports.push(rep);
                                }
                            }
                        }
                        if reports.is_empty() {
                            continue;
                        }
                        let rr = RtcpReceiverReport {
                            ssrc: receiver_ssrc,
                            reports,
                            ..Default::default()
                        };
                        if let Err(err) = writer_clone.write(&[Box::new(rr)], &attrs).await {
                            crate::nano_warn!("accurate-rr rtcp write error: {err}");
                        }
                    }
                }
            }
        });

        writer
    }

    async fn bind_local_stream(
        &self,
        _info: &StreamInfo,
        writer: Arc<dyn RTPWriter + Send + Sync>,
    ) -> Arc<dyn RTPWriter + Send + Sync> {
        writer
    }

    async fn unbind_local_stream(&self, _info: &StreamInfo) {}

    async fn bind_remote_stream(
        &self,
        info: &StreamInfo,
        reader: Arc<dyn RTPReader + Send + Sync>,
    ) -> Arc<dyn RTPReader + Send + Sync> {
        let state = Arc::new(StdMutex::new(RrStreamState::new(
            info.ssrc,
            info.clock_rate,
        )));
        if let Ok(mut map) = self.streams.lock() {
            map.insert(info.ssrc, Arc::clone(&state));
        }
        Arc::new(RrRtpStream {
            parent_reader: reader,
            state,
        })
    }

    async fn unbind_remote_stream(&self, info: &StreamInfo) {
        if let Ok(mut map) = self.streams.lock() {
            map.remove(&info.ssrc);
        }
    }

    async fn close(&self) -> Result<(), InterceptorError> {
        if let Ok(mut guard) = self.close_tx.lock() {
            if let Some(tx) = guard.take() {
                let _ = tx.send(true);
            }
        }
        Ok(())
    }
}

// ============================================================================
// 2. RTT-Aware Smart NACK Generator (Chromium NackRequester style)
// ============================================================================
//
// Replaces `webrtc-rs`'s stock `NackGenerator`, which blasts NACK for every missing
// sequence number every 12ms with ZERO RTT cooldown and ZERO retry limit — flooding
// WAN/TURN links with 5x-40x duplicate retransmission requests per lost packet.

const MAX_NACK_RETRIES: u8 = 4;
const MAX_NACK_WINDOW_PACKETS: i64 = 384;
const MAX_NACK_PER_PACKET: usize = 32;

pub struct SmartNackGeneratorBuilder {
    poll_interval: Duration,
    stun_rtt_us: Arc<AtomicU64>,
    probe_rtt_us: Arc<AtomicU64>,
    nack_rtt_us: Arc<AtomicU64>,
    route_kind: Arc<AtomicU8>,
    video_jitter_us: Arc<AtomicU64>,
}

impl SmartNackGeneratorBuilder {
    pub fn new(
        poll_interval: Duration,
        stun_rtt_us: Arc<AtomicU64>,
        probe_rtt_us: Arc<AtomicU64>,
        nack_rtt_us: Arc<AtomicU64>,
        route_kind: Arc<AtomicU8>,
        video_jitter_us: Arc<AtomicU64>,
    ) -> Self {
        Self {
            poll_interval,
            stun_rtt_us,
            probe_rtt_us,
            nack_rtt_us,
            route_kind,
            video_jitter_us,
        }
    }
}

impl InterceptorBuilder for SmartNackGeneratorBuilder {
    fn build(
        &self,
        _id: &str,
    ) -> Result<Arc<dyn Interceptor + Send + Sync>, InterceptorError> {
        let (close_tx, close_rx) = watch::channel(false);
        let sender_ssrc = ((Instant::now().elapsed().as_nanos() as u32) ^ 0x9E37_79B9).max(1);
        Ok(Arc::new(SmartNackGenerator {
            poll_interval: self.poll_interval,
            sender_ssrc,
            stun_rtt_us: Arc::clone(&self.stun_rtt_us),
            probe_rtt_us: Arc::clone(&self.probe_rtt_us),
            nack_rtt_us: Arc::clone(&self.nack_rtt_us),
            route_kind: Arc::clone(&self.route_kind),
            video_jitter_us: Arc::clone(&self.video_jitter_us),
            streams: Arc::new(StdMutex::new(HashMap::new())),
            close_tx: StdMutex::new(Some(close_tx)),
            close_rx,
        }))
    }
}

struct SmartNackGenerator {
    poll_interval: Duration,
    sender_ssrc: u32,
    stun_rtt_us: Arc<AtomicU64>,
    probe_rtt_us: Arc<AtomicU64>,
    nack_rtt_us: Arc<AtomicU64>,
    route_kind: Arc<AtomicU8>,
    video_jitter_us: Arc<AtomicU64>,
    streams: Arc<StdMutex<HashMap<u32, Arc<StdMutex<NackStreamTracker>>>>>,
    close_tx: StdMutex<Option<watch::Sender<bool>>>,
    close_rx: watch::Receiver<bool>,
}

#[derive(Debug, Clone)]
struct MissingPacketEntry {
    first_seen: Instant,
    last_sent: Option<Instant>,
    retries: u8,
}

pub(crate) struct NackStreamTracker {
    max_seq: Option<i64>,
    missing: BTreeMap<i64, MissingPacketEntry>,
}

impl NackStreamTracker {
    pub(crate) fn new() -> Self {
        Self {
            max_seq: None,
            missing: BTreeMap::new(),
        }
    }

    /// Record an incoming RTP sequence number.
    /// Returns `Some(rtt_us)` if this packet recovered a single-attempt NACK (true media-path RTT!).
    pub(crate) fn on_packet(&mut self, seq: u16, now: Instant) -> Option<u64> {
        let Some(max_seq) = self.max_seq else {
            self.max_seq = Some(i64::from(seq));
            return None;
        };

        let delta = (seq.wrapping_sub((max_seq & 0xFFFF) as u16) as i16) as i64;
        let unwrapped = max_seq + delta;

        if unwrapped <= max_seq {
            if let Some(entry) = self.missing.remove(&unwrapped) {
                if entry.retries == 1 {
                    if let Some(sent_at) = entry.last_sent {
                        let rtt_us = now.duration_since(sent_at).as_micros() as u64;
                        if (8_000..=600_000).contains(&rtt_us) {
                            return Some(rtt_us);
                        }
                    }
                }
            }
            return None;
        }

        // Large jump (sender reset / prolonged blackout): reset tracker cleanly.
        if unwrapped - max_seq > MAX_NACK_WINDOW_PACKETS {
            self.missing.clear();
            self.max_seq = Some(unwrapped);
            return None;
        }

        for gap_seq in (max_seq + 1)..unwrapped {
            self.missing.entry(gap_seq).or_insert(MissingPacketEntry {
                first_seen: now,
                last_sent: None,
                retries: 0,
            });
        }
        self.max_seq = Some(unwrapped);

        // Trim ancient missing entries outside active recovery window.
        let cutoff = unwrapped - MAX_NACK_WINDOW_PACKETS;
        while let Some((&oldest, _)) = self.missing.iter().next() {
            if oldest < cutoff {
                self.missing.remove(&oldest);
            } else {
                break;
            }
        }
        None
    }

    /// Collect sequence numbers whose NACK timer/cooldown is due right now.
    pub(crate) fn collect_due_nacks(
        &mut self,
        now: Instant,
        effective_rtt_ms: u64,
        jitter_ms: u64,
        is_wan: bool,
    ) -> Vec<u16> {
        let Some(max_seq) = self.max_seq else {
            return Vec::new();
        };
        if self.missing.is_empty() {
            return Vec::new();
        }

        // On WAN/cellular/TURN, 2-4 packet micro-reordering is common; wait briefly before the
        // very first NACK unless >= `reorder_gap` newer packets have already arrived.
        let reorder_gap: i64 = if is_wan { 4 } else { 2 };
        let first_nack_grace = Duration::from_millis(jitter_ms.clamp(4, 14));
        let retry_cooldown =
            Duration::from_millis(((effective_rtt_ms as f64) * 1.15).round().clamp(25.0, 220.0) as u64);
        let max_age = Duration::from_millis((effective_rtt_ms * 4).clamp(240, 520));

        let mut expired = Vec::new();
        let mut due = Vec::new();

        // Iterate newest-first so active-frame losses are always prioritized over older
        // backlog bursts when hitting `MAX_NACK_PER_PACKET`, then reverse into ascending
        // sequence order for compact RFC 4585 PID/BLP encoding.
        for (&seq, entry) in self.missing.iter_mut().rev() {
            let age = now.duration_since(entry.first_seen);
            if entry.retries >= MAX_NACK_RETRIES
                || age > max_age
                || max_seq - seq > MAX_NACK_WINDOW_PACKETS
            {
                expired.push(seq);
                continue;
            }

            if due.len() >= MAX_NACK_PER_PACKET {
                continue;
            }

            let ready = match entry.last_sent {
                None => (max_seq - seq) >= reorder_gap || age >= first_nack_grace,
                Some(sent_at) => now.duration_since(sent_at) >= retry_cooldown,
            };

            if ready {
                entry.last_sent = Some(now);
                entry.retries = entry.retries.saturating_add(1);
                due.push((seq & 0xFFFF) as u16);
            }
        }

        for seq in expired {
            self.missing.remove(&seq);
        }

        due.reverse();
        due
    }
}

struct SmartNackRtpStream {
    parent_reader: Arc<dyn RTPReader + Send + Sync>,
    tracker: Arc<StdMutex<NackStreamTracker>>,
    nack_rtt_us: Arc<AtomicU64>,
}

#[async_trait]
impl RTPReader for SmartNackRtpStream {
    async fn read(
        &self,
        buf: &mut [u8],
        attributes: &Attributes,
    ) -> Result<(rtp::packet::Packet, Attributes), InterceptorError> {
        let (pkt, attr) = self.parent_reader.read(buf, attributes).await?;
        let now = Instant::now();
        let measured = self
            .tracker
            .lock()
            .ok()
            .and_then(|mut tr| tr.on_packet(pkt.header.sequence_number, now));
        if let Some(rtt_us) = measured {
            let prev = self.nack_rtt_us.load(Ordering::Relaxed);
            let smoothed = if prev == 0 {
                rtt_us
            } else {
                (prev * 3 + rtt_us) / 4
            };
            self.nack_rtt_us.store(smoothed, Ordering::Relaxed);
        }
        Ok((pkt, attr))
    }
}

fn stream_supports_nack(info: &StreamInfo) -> bool {
    info.rtcp_feedback
        .iter()
        .any(|fb| fb.typ.eq_ignore_ascii_case("nack") && fb.parameter.is_empty())
}

#[async_trait]
impl Interceptor for SmartNackGenerator {
    async fn bind_rtcp_reader(
        &self,
        reader: Arc<dyn RTCPReader + Send + Sync>,
    ) -> Arc<dyn RTCPReader + Send + Sync> {
        reader
    }

    async fn bind_rtcp_writer(
        &self,
        writer: Arc<dyn RTCPWriter + Send + Sync>,
    ) -> Arc<dyn RTCPWriter + Send + Sync> {
        let streams = Arc::clone(&self.streams);
        let poll_interval = self.poll_interval;
        let sender_ssrc = self.sender_ssrc;
        let stun_rtt_us = Arc::clone(&self.stun_rtt_us);
        let probe_rtt_us = Arc::clone(&self.probe_rtt_us);
        let nack_rtt_us = Arc::clone(&self.nack_rtt_us);
        let route_kind = Arc::clone(&self.route_kind);
        let video_jitter_us = Arc::clone(&self.video_jitter_us);
        let mut close_rx = self.close_rx.clone();
        let writer_clone = Arc::clone(&writer);

        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(poll_interval);
            ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
            let attrs = Attributes::new();
            loop {
                tokio::select! {
                    _ = close_rx.changed() => {
                        if *close_rx.borrow() {
                            break;
                        }
                    }
                    _ = ticker.tick() => {
                        let now = Instant::now();
                        let rk = route_kind.load(Ordering::Relaxed);
                        let is_wan = rk == 2 || rk == 3;
                        let raw_rtt_us = {
                            let s = stun_rtt_us.load(Ordering::Relaxed);
                            if s > 0 {
                                s
                            } else {
                                let p = probe_rtt_us.load(Ordering::Relaxed);
                                if p > 0 {
                                    p
                                } else {
                                    nack_rtt_us.load(Ordering::Relaxed)
                                }
                            }
                        };
                        let effective_rtt_ms = if raw_rtt_us > 0 {
                            (raw_rtt_us / 1000).clamp(6, 400)
                        } else {
                            match rk {
                                1 => 10,
                                2 => 55,
                                3 => 75,
                                _ => 35,
                            }
                        };
                        let jitter_ms = (video_jitter_us.load(Ordering::Relaxed) / 1000).min(45);

                        let entries: Vec<(u32, Arc<StdMutex<NackStreamTracker>>)> = streams
                            .lock()
                            .map(|map| map.iter().map(|(&k, v)| (k, Arc::clone(v))).collect())
                            .unwrap_or_default();

                        for (media_ssrc, tracker) in entries {
                            let due = tracker
                                .lock()
                                .map(|mut tr| tr.collect_due_nacks(now, effective_rtt_ms, jitter_ms, is_wan))
                                .unwrap_or_default();
                            if due.is_empty() {
                                continue;
                            }
                            let nack = TransportLayerNack {
                                sender_ssrc,
                                media_ssrc,
                                nacks: nack_pairs_from_sequence_numbers(&due),
                            };
                            if let Err(err) = writer_clone.write(&[Box::new(nack)], &attrs).await {
                                crate::nano_warn!("smart-nack rtcp write error: {err}");
                            }
                        }
                    }
                }
            }
        });

        writer
    }

    async fn bind_local_stream(
        &self,
        _info: &StreamInfo,
        writer: Arc<dyn RTPWriter + Send + Sync>,
    ) -> Arc<dyn RTPWriter + Send + Sync> {
        writer
    }

    async fn unbind_local_stream(&self, _info: &StreamInfo) {}

    async fn bind_remote_stream(
        &self,
        info: &StreamInfo,
        reader: Arc<dyn RTPReader + Send + Sync>,
    ) -> Arc<dyn RTPReader + Send + Sync> {
        if !stream_supports_nack(info) {
            return reader;
        }
        let tracker = Arc::new(StdMutex::new(NackStreamTracker::new()));
        if let Ok(mut map) = self.streams.lock() {
            map.insert(info.ssrc, Arc::clone(&tracker));
        }
        Arc::new(SmartNackRtpStream {
            parent_reader: reader,
            tracker,
            nack_rtt_us: Arc::clone(&self.nack_rtt_us),
        })
    }

    async fn unbind_remote_stream(&self, info: &StreamInfo) {
        if let Ok(mut map) = self.streams.lock() {
            map.remove(&info.ssrc);
        }
    }

    async fn close(&self) -> Result<(), InterceptorError> {
        if let Ok(mut guard) = self.close_tx.lock() {
            if let Some(tx) = guard.take() {
                let _ = tx.send(true);
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accurate_rr_does_not_amplify_loss_at_high_bitrate() {
        let mut st = RrStreamState::new(0x1234_5678, 90_000);
        let t0 = Instant::now();
        // Simulate 1000 packets in 500ms (~20 Mbps) with exactly 1 packet dropped (seq 500).
        // Stock webrtc-rs ReceiverReport (128-bit wrap bug) reported 8x amplified loss!
        for i in 0..1000u16 {
            if i == 500 {
                continue;
            }
            st.on_rtp(
                i,
                u32::from(i) * 90,
                t0 + Duration::from_micros(u64::from(i) * 500),
            );
        }
        st.on_sender_report(0xAABB_CCDD_EEFF_0011, t0 + Duration::from_millis(400));
        let rr = st
            .generate_reception_report(t0 + Duration::from_millis(500))
            .expect("rr");
        assert_eq!(rr.total_lost, 1);
        assert_eq!(rr.fraction_lost, 0); // 1 * 256 / 1000 = 0 (0.1% loss)
        assert_eq!(rr.last_sender_report, 0xCCDD_EEFF);
        assert!(rr.delay > 6000 && rr.delay < 7000); // ~100ms in 1/65536s units (~6553)
    }

    #[test]
    fn accurate_rr_deduplicates_retransmits_and_handles_wraparound() {
        let mut st = RrStreamState::new(42, 90_000);
        let t0 = Instant::now();
        for i in 0..20u16 {
            let seq = 65530u16.wrapping_add(i);
            st.on_rtp(seq, u32::from(i) * 1500, t0 + Duration::from_millis(u64::from(i)));
        }
        // Duplicate retransmitted packet must not inflate received_unique
        st.on_rtp(65535, 7500, t0 + Duration::from_millis(25));
        let rr = st
            .generate_reception_report(t0 + Duration::from_millis(30))
            .expect("rr");
        assert_eq!(rr.total_lost, 0);
        assert_eq!(rr.fraction_lost, 0);
    }

    #[test]
    fn smart_nack_respects_rtt_cooldown_retry_cap_and_measures_rtt() {
        let mut tr = NackStreamTracker::new();
        let t0 = Instant::now();
        tr.on_packet(100, t0);
        // Skip 101; arrive 102, 103, 104, 105 (4 newer packets -> triggers first NACK on WAN)
        for s in 102..=105u16 {
            tr.on_packet(s, t0 + Duration::from_millis(2));
        }

        // First poll -> NACK 101
        let d1 = tr.collect_due_nacks(t0 + Duration::from_millis(3), 60, 5, true);
        assert_eq!(d1, vec![101]);

        // 20ms later (well below 60ms * 1.15 = 69ms RTT cooldown) -> MUST NOT re-NACK!
        let d2 = tr.collect_due_nacks(t0 + Duration::from_millis(23), 60, 5, true);
        assert!(d2.is_empty());

        // 75ms after first NACK -> second NACK allowed
        let d3 = tr.collect_due_nacks(t0 + Duration::from_millis(78), 60, 5, true);
        assert_eq!(d3, vec![101]);

        // Test RTT measurement on single-attempt recovery for seq 200
        tr.on_packet(199, t0 + Duration::from_millis(100));
        for s in 201..=205u16 {
            tr.on_packet(s, t0 + Duration::from_millis(102));
        }
        let d_new = tr.collect_due_nacks(t0 + Duration::from_millis(103), 60, 5, true);
        assert!(d_new.contains(&200));
        // Retransmit for 200 arrives 52ms later -> measures 52_000us RTT!
        let measured = tr.on_packet(200, t0 + Duration::from_millis(155));
        assert_eq!(measured, Some(52_000));

        // Exhaust retries for 101 and verify it expires cleanly instead of NACKing forever
        let _ = tr.collect_due_nacks(t0 + Duration::from_millis(155), 60, 5, true); // retry #3
        let _ = tr.collect_due_nacks(t0 + Duration::from_millis(230), 60, 5, true); // retry #4
        let after_cap = tr.collect_due_nacks(t0 + Duration::from_millis(310), 60, 5, true);
        assert!(!after_cap.contains(&101));
    }
}
