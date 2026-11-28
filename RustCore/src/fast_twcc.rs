use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use rtcp::transport_feedbacks::transport_layer_cc::{
    PacketStatusChunk, RecvDelta, RunLengthChunk, StatusChunkTypeTcc, StatusVectorChunk,
    SymbolSizeTypeTcc, SymbolTypeTcc, TransportLayerCc,
};
use rtp::extension::transport_cc_extension::TransportCcExtension;
use tokio::sync::{watch, Notify};
use tokio::time::MissedTickBehavior;
use webrtc::interceptor::stream_info::StreamInfo;
use webrtc::interceptor::{
    Attributes, Error as InterceptorError, Interceptor, InterceptorBuilder, RTCPReader, RTCPWriter,
    RTPReader, RTPWriter,
};
use webrtc::sdp::extmap::TRANSPORT_CC_URI;
use webrtc::util::Unmarshal;

const MAX_TRACKED_PACKETS: usize = 2048;
const MAX_PACKETS_PER_FEEDBACK: usize = 192;
const MAX_FEEDBACK_BYTES: usize = 1000;
const IMMEDIATE_FEEDBACK_PACKET_THRESHOLD: usize = 64;
const MAX_REORDER_LOOKBACK: i64 = 256;
const MAX_RUN_LENGTH_CAP: usize = 0x1fff; // 13 bits
const MAX_ONE_BIT_CAP: usize = 14;
const MAX_TWO_BIT_CAP: usize = 7;

/// High-throughput, zero-drift, reorder-safe TWCC receiver interceptor.
///
/// Replaces both `webrtc-rs`'s blocking `twcc::receiver::Receiver` AND its buggy `twcc::Recorder`:
/// 1. **Zero quantization drift**: advances `last_quantized_us` strictly by encoded `delta_ticks * 250`
///    (never raw `arrival_us`), eliminating the systematic delay-gradient drift that caused Xbox GCC
///    to misdetect overuse and collapse bitrate whenever high-bitrate packet gaps fell below 250us.
/// 2. **Reorder-safe sliding history**: retains recent `(unwrapped_seq -> arrival_us)` entries across
///    feedback intervals so late/out-of-order WAN packets never mark previously received packets as
///    `PacketNotReceived` (false packet loss).
/// 3. **Safe multi-packet splitting**: properly initializes `base_sequence_number` and
///    `reference_time` on every split RTCP packet and respects MTU bounds.
pub struct FastTwccReceiverBuilder {
    interval: Duration,
}

impl FastTwccReceiverBuilder {
    pub fn new(interval: Duration) -> Self {
        Self { interval }
    }
}

impl InterceptorBuilder for FastTwccReceiverBuilder {
    fn build(
        &self,
        _id: &str,
    ) -> Result<Arc<dyn Interceptor + Send + Sync>, InterceptorError> {
        let (close_tx, close_rx) = watch::channel(false);
        let sender_ssrc = ((Instant::now().elapsed().as_nanos() as u32) ^ 0x5A3C_19F1).max(1);
        Ok(Arc::new(FastTwccReceiver {
            interval: self.interval,
            start_time: Instant::now(),
            recorder: Arc::new(StdMutex::new(ExactTwccRecorder::new(sender_ssrc))),
            video_ssrc: Arc::new(AtomicU32::new(0)),
            has_video_ssrc: Arc::new(AtomicBool::new(false)),
            wake_notify: Arc::new(Notify::new()),
            close_tx: StdMutex::new(Some(close_tx)),
            close_rx,
        }))
    }
}

struct FastTwccReceiver {
    interval: Duration,
    start_time: Instant,
    recorder: Arc<StdMutex<ExactTwccRecorder>>,
    video_ssrc: Arc<AtomicU32>,
    has_video_ssrc: Arc<AtomicBool>,
    wake_notify: Arc<Notify>,
    close_tx: StdMutex<Option<watch::Sender<bool>>>,
    close_rx: watch::Receiver<bool>,
}

struct FastTwccStream {
    parent_reader: Arc<dyn RTPReader + Send + Sync>,
    hdr_ext_id: u8,
    ssrc: u32,
    is_video: bool,
    start_time: Instant,
    recorder: Arc<StdMutex<ExactTwccRecorder>>,
    video_ssrc: Arc<AtomicU32>,
    has_video_ssrc: Arc<AtomicBool>,
    wake_notify: Arc<Notify>,
}

#[async_trait]
impl RTPReader for FastTwccStream {
    async fn read(
        &self,
        buf: &mut [u8],
        attributes: &Attributes,
    ) -> Result<(rtp::packet::Packet, Attributes), InterceptorError> {
        let (pkt, attr) = self.parent_reader.read(buf, attributes).await?;

        if let Some(mut ext) = pkt.header.get_extension(self.hdr_ext_id) {
            if let Ok(tcc_ext) = TransportCcExtension::unmarshal(&mut ext) {
                let arrival_us = self.start_time.elapsed().as_micros() as i64;
                if self.is_video {
                    self.video_ssrc.store(self.ssrc, Ordering::Relaxed);
                    self.has_video_ssrc.store(true, Ordering::Relaxed);
                }
                let media_ssrc = if self.has_video_ssrc.load(Ordering::Relaxed) {
                    self.video_ssrc.load(Ordering::Relaxed)
                } else {
                    self.ssrc
                };
                let should_wake = if let Ok(mut rec) = self.recorder.lock() {
                    rec.record(media_ssrc, tcc_ext.transport_sequence, arrival_us)
                } else {
                    false
                };
                if should_wake {
                    self.wake_notify.notify_one();
                }
            }
        }

        Ok((pkt, attr))
    }
}

#[async_trait]
impl Interceptor for FastTwccReceiver {
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
        let recorder = Arc::clone(&self.recorder);
        let interval = self.interval;
        let wake_notify = Arc::clone(&self.wake_notify);
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
                    _ = wake_notify.notified() => {
                        let pkts = match recorder.lock() {
                            Ok(mut rec) => rec.build_feedback_packets(),
                            Err(_) => Vec::new(),
                        };
                        if !pkts.is_empty() {
                            if let Err(err) = writer_clone.write(&pkts, &attrs).await {
                                crate::nano_warn!("fast-twcc rtcp write error: {err}");
                            }
                        }
                    }
                    _ = ticker.tick() => {
                        let pkts = match recorder.lock() {
                            Ok(mut rec) => rec.build_feedback_packets(),
                            Err(_) => Vec::new(),
                        };
                        if pkts.is_empty() {
                            continue;
                        }
                        if let Err(err) = writer_clone.write(&pkts, &attrs).await {
                            crate::nano_warn!("fast-twcc rtcp write error: {err}");
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
        let mut hdr_ext_id = 0u8;
        for ext in &info.rtp_header_extensions {
            if ext.uri == TRANSPORT_CC_URI {
                hdr_ext_id = ext.id as u8;
                break;
            }
        }
        if hdr_ext_id == 0 {
            return reader;
        }

        let is_video = info.mime_type.to_ascii_lowercase().starts_with("video/");
        if is_video {
            self.video_ssrc.store(info.ssrc, Ordering::Relaxed);
            self.has_video_ssrc.store(true, Ordering::Relaxed);
        }

        Arc::new(FastTwccStream {
            parent_reader: reader,
            hdr_ext_id,
            ssrc: info.ssrc,
            is_video,
            start_time: self.start_time,
            recorder: Arc::clone(&self.recorder),
            video_ssrc: Arc::clone(&self.video_ssrc),
            has_video_ssrc: Arc::clone(&self.has_video_ssrc),
            wake_notify: Arc::clone(&self.wake_notify),
        })
    }

    async fn unbind_remote_stream(&self, _info: &StreamInfo) {}

    async fn close(&self) -> Result<(), InterceptorError> {
        if let Ok(mut guard) = self.close_tx.lock() {
            if let Some(tx) = guard.take() {
                let _ = tx.send(true);
            }
        }
        Ok(())
    }
}

/// RFC-compliant, zero-drift TWCC recorder modeled after Chromium's `RemoteEstimatorProxy`.
pub(crate) struct ExactTwccRecorder {
    sender_ssrc: u32,
    media_ssrc: u32,
    fb_pkt_cnt: u8,
    max_unwrapped_seq: Option<i64>,
    next_feedback_seq: Option<i64>,
    dirty_min_seq: Option<i64>,
    dirty_count: usize,
    arrivals: BTreeMap<i64, i64>,
}

impl ExactTwccRecorder {
    pub(crate) fn new(sender_ssrc: u32) -> Self {
        Self {
            sender_ssrc,
            media_ssrc: 0,
            fb_pkt_cnt: 0,
            max_unwrapped_seq: None,
            next_feedback_seq: None,
            dirty_min_seq: None,
            dirty_count: 0,
            arrivals: BTreeMap::new(),
        }
    }

    fn unwrap_seq(&self, seq: u16) -> i64 {
        match self.max_unwrapped_seq {
            None => i64::from(seq),
            Some(max_seq) => {
                let delta = (seq.wrapping_sub((max_seq & 0xFFFF) as u16) as i16) as i64;
                max_seq + delta
            }
        }
    }

    /// Record a received packet. Returns `true` when enough fresh packets have accumulated
    /// to trigger an immediate feedback flush (keeps high-bitrate packets compact & timely).
    pub(crate) fn record(&mut self, media_ssrc: u32, seq: u16, arrival_us: i64) -> bool {
        if media_ssrc != 0 {
            self.media_ssrc = media_ssrc;
        }
        let unwrapped = self.unwrap_seq(seq);

        if let Some(max_seq) = self.max_unwrapped_seq {
            // Ignore ancient packets far behind our sliding window.
            if unwrapped < max_seq - (MAX_TRACKED_PACKETS as i64) {
                return false;
            }
            // Handle huge forward jump (e.g., sender reset) cleanly.
            if unwrapped - max_seq > (MAX_TRACKED_PACKETS as i64) {
                self.arrivals.clear();
                self.next_feedback_seq = Some(unwrapped);
                self.dirty_min_seq = Some(unwrapped);
                self.dirty_count = 0;
            }
            if unwrapped > max_seq {
                self.max_unwrapped_seq = Some(unwrapped);
            }
        } else {
            self.max_unwrapped_seq = Some(unwrapped);
            self.next_feedback_seq = Some(unwrapped);
        }

        // Preserve first arrival timestamp if a duplicate arrives.
        if self.arrivals.contains_key(&unwrapped) {
            return false;
        }
        self.arrivals.insert(unwrapped, arrival_us);
        self.dirty_count += 1;
        self.dirty_min_seq = Some(match self.dirty_min_seq {
            Some(prev) => prev.min(unwrapped),
            None => unwrapped,
        });

        // Trim old history outside sliding window.
        if let Some(max_seq) = self.max_unwrapped_seq {
            let cutoff = max_seq - (MAX_TRACKED_PACKETS as i64);
            while let Some((&oldest, _)) = self.arrivals.iter().next() {
                if oldest < cutoff {
                    self.arrivals.remove(&oldest);
                } else {
                    break;
                }
            }
        }

        self.dirty_count >= IMMEDIATE_FEEDBACK_PACKET_THRESHOLD
    }

    pub(crate) fn build_feedback_packets(
        &mut self,
    ) -> Vec<Box<dyn rtcp::packet::Packet + Send + Sync>> {
        self.build_feedback_structs()
            .into_iter()
            .map(|p| Box::new(p) as Box<dyn rtcp::packet::Packet + Send + Sync>)
            .collect()
    }

    pub(crate) fn build_feedback_structs(&mut self) -> Vec<TransportLayerCc> {
        if self.dirty_count == 0 {
            return Vec::new();
        }
        let Some(max_seq) = self.max_unwrapped_seq else {
            self.dirty_count = 0;
            self.dirty_min_seq = None;
            return Vec::new();
        };
        let dirty_min = self.dirty_min_seq.unwrap_or(max_seq);

        // Normally start right where the last feedback left off (`next_feedback_seq`).
        // If an out-of-order packet arrived slightly behind `next_feedback_seq`, look back
        // at most `MAX_REORDER_LOOKBACK` packets behind `next_feedback_seq` AND fill every
        // already-received seq in between from `self.arrivals` so we NEVER emit false losses.
        // Never truncate brand-new unacknowledged packets after `next_feedback_seq`.
        let next_seq = self.next_feedback_seq.unwrap_or(dirty_min);
        let mut start_seq = if dirty_min < next_seq {
            dirty_min.max(next_seq - MAX_REORDER_LOOKBACK)
        } else {
            next_seq
        };
        let hard_floor = max_seq - (MAX_TRACKED_PACKETS as i64) + 1;
        if start_seq < hard_floor {
            start_seq = hard_floor;
        }

        // Collect all received packets in [start_seq..=max_seq].
        let mut range_received: Vec<(i64, i64)> = self
            .arrivals
            .range(start_seq..=max_seq)
            .map(|(&s, &t)| (s, t))
            .collect();

        if range_received.is_empty() {
            self.dirty_count = 0;
            self.dirty_min_seq = None;
            return Vec::new();
        }

        // Ensure first sequence number in feedback is a received packet so we have an exact
        // `reference_time` anchor without leading lost-packet bloat unless there is a true gap
        // from `next_feedback_seq`.
        let effective_start = start_seq.min(range_received[0].0);

        let mut packets = Vec::new();
        let mut cursor = 0usize;
        let mut current_start = effective_start;

        while cursor < range_received.len() {
            let first_arrival = range_received[cursor].1;
            let mut fb = FeedbackBuilder::new(
                self.sender_ssrc,
                self.media_ssrc,
                self.fb_pkt_cnt,
                current_start,
                first_arrival,
            );
            self.fb_pkt_cnt = self.fb_pkt_cnt.wrapping_add(1);

            let mut added_any = false;
            while cursor < range_received.len() {
                let (seq, arrival_us) = range_received[cursor];
                if fb.try_add_received(seq, arrival_us) {
                    added_any = true;
                    cursor += 1;
                } else {
                    break;
                }
            }

            if !added_any {
                // Single gap too wide for one packet (shouldn't happen due to MAX_REORDER_LOOKBACK);
                // re-anchor directly at the received packet.
                let (seq, arrival_us) = range_received[cursor];
                fb = FeedbackBuilder::new(
                    self.sender_ssrc,
                    self.media_ssrc,
                    self.fb_pkt_cnt,
                    seq,
                    arrival_us,
                );
                self.fb_pkt_cnt = self.fb_pkt_cnt.wrapping_add(1);
                let _ = fb.try_add_received(seq, arrival_us);
                cursor += 1;
            }

            if cursor < range_received.len() {
                current_start = fb.next_seq;
            }
            packets.push(fb.finish());
        }

        range_received.clear();
        self.next_feedback_seq = Some(max_seq + 1);
        self.dirty_count = 0;
        self.dirty_min_seq = None;

        packets
    }
}

struct FeedbackBuilder {
    sender_ssrc: u32,
    media_ssrc: u32,
    fb_pkt_count: u8,
    base_seq: i64,
    next_seq: i64,
    status_count: u16,
    ref_time_24bit: u32,
    /// Quantized reference clock in microseconds — advances strictly in 250us multiples
    /// so sub-250us inter-packet gaps at 20-60Mbps NEVER accumulate quantization drift!
    last_quantized_us: i64,
    approx_bytes: usize,
    last_chunk: ChunkEncoder,
    chunks: Vec<PacketStatusChunk>,
    deltas: Vec<RecvDelta>,
}

impl FeedbackBuilder {
    fn new(
        sender_ssrc: u32,
        media_ssrc: u32,
        fb_pkt_count: u8,
        base_seq: i64,
        anchor_arrival_us: i64,
    ) -> Self {
        let ref_time_64ms = anchor_arrival_us.div_euclid(64_000);
        let last_quantized_us = ref_time_64ms * 64_000;
        let ref_time_24bit = (ref_time_64ms as u64 & 0x00FF_FFFF) as u32;
        Self {
            sender_ssrc,
            media_ssrc,
            fb_pkt_count,
            base_seq,
            next_seq: base_seq,
            status_count: 0,
            ref_time_24bit,
            last_quantized_us,
            approx_bytes: 20, // RTCP header (4) + SSRC(8) + base/count/ref/fb(8)
            last_chunk: ChunkEncoder::default(),
            chunks: Vec::new(),
            deltas: Vec::new(),
        }
    }

    fn try_add_received(&mut self, seq: i64, arrival_us: i64) -> bool {
        if seq < self.next_seq {
            return true;
        }
        let gap = (seq - self.next_seq) as usize;
        let projected_count = self.status_count as usize + gap + 1;
        if self.status_count > 0
            && (projected_count > MAX_PACKETS_PER_FEEDBACK || self.approx_bytes > MAX_FEEDBACK_BYTES)
        {
            return false;
        }

        // Quantize to nearest 250us tick relative to `last_quantized_us`.
        let raw_delta_us = arrival_us - self.last_quantized_us;
        let delta_ticks = if raw_delta_us >= 0 {
            (raw_delta_us + 125) / 250
        } else {
            (raw_delta_us - 125) / 250
        };
        if delta_ticks < i16::MIN as i64 || delta_ticks > i16::MAX as i64 {
            return false;
        }

        // Fill any missing sequence numbers in between as PacketNotReceived.
        while self.next_seq < seq {
            self.push_symbol(SymbolTypeTcc::PacketNotReceived);
            self.status_count = self.status_count.wrapping_add(1);
            self.next_seq += 1;
        }

        let symbol = if (0..=0xFF).contains(&delta_ticks) {
            self.approx_bytes += 1;
            SymbolTypeTcc::PacketReceivedSmallDelta
        } else {
            self.approx_bytes += 2;
            SymbolTypeTcc::PacketReceivedLargeDelta
        };
        self.push_symbol(symbol);

        let quantized_delta_us = delta_ticks * 250;
        self.deltas.push(RecvDelta {
            type_tcc_packet: symbol,
            delta: quantized_delta_us,
        });
        // CRITICAL: Advance by quantized delta, NOT raw `arrival_us`, so remainder carries over!
        self.last_quantized_us += quantized_delta_us;
        self.status_count = self.status_count.wrapping_add(1);
        self.next_seq += 1;
        true
    }

    fn push_symbol(&mut self, sym: SymbolTypeTcc) {
        let code = sym as u16;
        if !self.last_chunk.can_add(code) {
            self.chunks.push(self.last_chunk.encode());
            self.approx_bytes += 2;
        }
        self.last_chunk.add(code);
    }

    fn finish(mut self) -> TransportLayerCc {
        while !self.last_chunk.deltas.is_empty() {
            self.chunks.push(self.last_chunk.encode());
        }
        TransportLayerCc {
            sender_ssrc: self.sender_ssrc,
            media_ssrc: self.media_ssrc,
            base_sequence_number: (self.base_seq & 0xFFFF) as u16,
            packet_status_count: self.status_count,
            reference_time: self.ref_time_24bit,
            fb_pkt_count: self.fb_pkt_count,
            packet_chunks: self.chunks,
            recv_deltas: self.deltas,
        }
    }
}

#[derive(Default)]
struct ChunkEncoder {
    has_large_delta: bool,
    has_different_types: bool,
    deltas: Vec<u16>,
}

impl ChunkEncoder {
    fn can_add(&self, delta: u16) -> bool {
        if self.deltas.len() < MAX_TWO_BIT_CAP {
            return true;
        }
        if self.deltas.len() < MAX_ONE_BIT_CAP
            && !self.has_large_delta
            && delta != SymbolTypeTcc::PacketReceivedLargeDelta as u16
        {
            return true;
        }
        if self.deltas.len() < MAX_RUN_LENGTH_CAP
            && !self.has_different_types
            && delta == self.deltas[0]
        {
            return true;
        }
        false
    }

    fn add(&mut self, delta: u16) {
        self.deltas.push(delta);
        self.has_large_delta =
            self.has_large_delta || delta == SymbolTypeTcc::PacketReceivedLargeDelta as u16;
        self.has_different_types = self.has_different_types || delta != self.deltas[0];
    }

    fn encode(&mut self) -> PacketStatusChunk {
        if !self.has_different_types {
            let p = PacketStatusChunk::RunLengthChunk(RunLengthChunk {
                type_tcc: StatusChunkTypeTcc::RunLengthChunk,
                packet_status_symbol: self.deltas[0].into(),
                run_length: self.deltas.len() as u16,
            });
            self.reset();
            return p;
        }
        if self.deltas.len() <= MAX_ONE_BIT_CAP && !self.has_large_delta {
            let p = PacketStatusChunk::StatusVectorChunk(StatusVectorChunk {
                type_tcc: StatusChunkTypeTcc::StatusVectorChunk,
                symbol_size: SymbolSizeTypeTcc::OneBit,
                symbol_list: self.deltas.iter().map(|&x| SymbolTypeTcc::from(x)).collect(),
            });
            self.reset();
            return p;
        }

        let take = std::cmp::min(MAX_TWO_BIT_CAP, self.deltas.len());
        let svc = PacketStatusChunk::StatusVectorChunk(StatusVectorChunk {
            type_tcc: StatusChunkTypeTcc::StatusVectorChunk,
            symbol_size: SymbolSizeTypeTcc::TwoBit,
            symbol_list: self.deltas[..take]
                .iter()
                .map(|&x| SymbolTypeTcc::from(x))
                .collect(),
        });
        self.deltas.drain(..take);
        self.has_different_types = false;
        self.has_large_delta = false;
        if !self.deltas.is_empty() {
            let first = self.deltas[0];
            for &d in &self.deltas {
                if d != first {
                    self.has_different_types = true;
                }
                if d == SymbolTypeTcc::PacketReceivedLargeDelta as u16 {
                    self.has_large_delta = true;
                }
            }
        }
        svc
    }

    fn reset(&mut self) {
        self.deltas.clear();
        self.has_large_delta = false;
        self.has_different_types = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use webrtc::util::{Marshal, Unmarshal};

    #[test]
    fn high_bitrate_sub_250us_bursts_have_zero_cumulative_drift() {
        let mut rec = ExactTwccRecorder::new(0x1122_3344);
        // Simulate 60 packets arriving every 150us (typical 40Mbps H.264 frame burst, total span 8,850us).
        // Stock webrtc-rs Recorder reports 0us for EVERY delta (8,850us drift!); ours must stay within +-125us.
        let base_us = 1_000_000i64;
        for i in 0..60u16 {
            rec.record(0xABCD_1234, 100 + i, base_us + i64::from(i) * 150);
        }
        let pkts = rec.build_feedback_structs();
        assert_eq!(pkts.len(), 1);
        let fb = &pkts[0];
        assert_eq!(fb.base_sequence_number, 100);
        assert_eq!(fb.packet_status_count, 60);
        assert_eq!(fb.recv_deltas.len(), 60);

        let mut reconstructed_us = (fb.reference_time as i64) * 64_000;
        for (i, d) in fb.recv_deltas.iter().enumerate() {
            reconstructed_us += d.delta;
            let actual_us = base_us + (i as i64) * 150;
            assert!(
                (reconstructed_us - actual_us).abs() <= 125,
                "packet {i}: reconstructed={reconstructed_us} actual={actual_us} (drift exceeded 125us)"
            );
        }

        // Verify RTCP wire marshal/unmarshal round-trip succeeds cleanly.
        let wire = fb.marshal().expect("marshal twcc");
        let mut slice: Bytes = wire;
        let decoded = TransportLayerCc::unmarshal(&mut slice).expect("unmarshal twcc");
        assert_eq!(decoded.base_sequence_number, 100);
        assert_eq!(decoded.packet_status_count, 60);
        assert_eq!(decoded.recv_deltas.len(), 60);
    }

    #[test]
    fn cross_interval_reordered_packet_does_not_report_false_losses() {
        let mut rec = ExactTwccRecorder::new(0x1122_3344);
        // Tick 1: packets 10, 11, 13, 14 arrive (12 is delayed across interval boundary)
        rec.record(1, 10, 100_000);
        rec.record(1, 11, 101_000);
        rec.record(1, 13, 103_000);
        rec.record(1, 14, 104_000);
        let fb1 = rec.build_feedback_structs();
        assert_eq!(fb1.len(), 1);
        assert_eq!(fb1[0].base_sequence_number, 10);
        assert_eq!(fb1[0].packet_status_count, 5);
        assert_eq!(fb1[0].recv_deltas.len(), 4); // 12 missing

        // Tick 2: delayed packet 12 finally arrives, plus 15, 16.
        // Stock webrtc-rs Recorder marked 13 and 14 as LOST! Ours keeps 13 & 14 from history!
        rec.record(1, 12, 126_000);
        rec.record(1, 15, 127_000);
        rec.record(1, 16, 128_000);
        let fb2 = rec.build_feedback_structs();
        assert_eq!(fb2.len(), 1);
        assert_eq!(fb2[0].base_sequence_number, 12);
        assert_eq!(fb2[0].packet_status_count, 5); // 12, 13, 14, 15, 16
        assert_eq!(fb2[0].recv_deltas.len(), 5); // ALL FIVE reported as received!
    }

    #[test]
    fn handles_u16_wraparound_with_reordering_and_splits_large_batches() {
        let mut rec = ExactTwccRecorder::new(0x5566_7788);
        // Wrap around 65535 -> 0 with out-of-order arrival
        rec.record(9, 65534, 500_000);
        rec.record(9, 0, 502_000);
        rec.record(9, 65535, 503_000);
        rec.record(9, 1, 504_000);
        let fb = rec.build_feedback_structs();
        assert_eq!(fb.len(), 1);
        assert_eq!(fb[0].base_sequence_number, 65534);
        assert_eq!(fb[0].packet_status_count, 4);
        assert_eq!(fb[0].recv_deltas.len(), 4);

        // Large batch (> MAX_PACKETS_PER_FEEDBACK) must split cleanly with valid base seqs
        for i in 0..300u16 {
            rec.record(9, 2u16.wrapping_add(i), 600_000 + i64::from(i) * 500);
        }
        let split = rec.build_feedback_structs();
        assert_eq!(split.len(), 2);
        assert_eq!(split[0].base_sequence_number, 2);
        assert_eq!(
            split[1].base_sequence_number,
            2u16.wrapping_add(split[0].packet_status_count)
        );
        assert_eq!(
            split[0].packet_status_count + split[1].packet_status_count,
            300
        );
        for pkt in &split {
            let wire = pkt.marshal().expect("marshal split packet");
            let mut slice: Bytes = wire;
            let decoded = TransportLayerCc::unmarshal(&mut slice).expect("unmarshal split");
            assert_eq!(decoded.packet_status_count, pkt.packet_status_count);
        }
    }
}
